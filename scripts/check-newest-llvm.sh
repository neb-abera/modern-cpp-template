#!/usr/bin/env bash
#
# check-newest-llvm.sh: the Dockerfile's LLVM is the newest release.
#
# Dependabot cannot see the LLVM tarball the Dockerfile's llvm stage
# downloads, so this closes the gap. A release counts when it is neither a
# draft nor a prerelease and ships LLVM-<version>-Linux-X64.tar.zst.
#   1. ENV LLVM_VERSION names the newest release, once that release has
#      been out GRACE_DAYS (30).
#   2. --update moves ENV LLVM_VERSION and ENV LLVM_SHA256 to the newest
#      release, taking the SHA-256 GitHub records for the tarball. The
#      llvm-upgrade workflow runs it and opens the pull request.
#
#   scripts/check-newest-llvm.sh              check the repository
#   scripts/check-newest-llvm.sh --update     move the pins to the newest
#   scripts/check-newest-llvm.sh --self-test  prove each check fails on a
#                                             planted defect
#
# Exit 1 on a finding. Exit 2 when RELEASES_URL cannot be read: an outage,
# not a pass. GH_TOKEN, when set, lifts the API's anonymous rate limit.

set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_URL="${RELEASES_URL:-https://api.github.com/repos/llvm/llvm-project/releases?per_page=50}"
GRACE_DAYS="${GRACE_DAYS:-30}"

pinned() { sed -n "s/^ENV $1=\(.*\)$/\1/p" Dockerfile | head -1; }

# newest: print "<version> <published date> <sha256>" for the newest release.
newest() {
  local json auth=()
  json="$(mktemp)"
  if [ -n "${GH_TOKEN:-}" ] && [[ "$RELEASES_URL" == https://* ]]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
  fi
  if ! curl -fsSL --retry 2 --max-time 60 "${auth[@]}" "$RELEASES_URL" -o "$json" 2> /dev/null; then
    rm -f "$json"
    echo "error: could not read $RELEASES_URL: an outage, not a pass" >&2
    exit 2
  fi
  python3 - "$json" << 'EOF' || { rm -f "$json"; echo "error: $RELEASES_URL names no release: an outage, not a pass" >&2; exit 2; }
import json, re, sys
best = None
for r in json.load(open(sys.argv[1])):
    m = re.fullmatch(r"llvmorg-(\d+)\.(\d+)\.(\d+)", r.get("tag_name", ""))
    if not m or r.get("draft") or r.get("prerelease"):
        continue
    version = ".".join(m.groups())
    asset = next((a for a in r.get("assets", []) if a.get("name") == f"LLVM-{version}-Linux-X64.tar.zst"), None)
    if not asset or not str(asset.get("digest", "")).startswith("sha256:"):
        continue
    key = tuple(int(x) for x in m.groups())
    if best is None or key > best[0]:
        best = (key, version, r["published_at"][:10], asset["digest"][len("sha256:"):])
if best is None:
    sys.exit(1)
print(best[1], best[2], best[3])
EOF
  rm -f "$json"
}

check() {
  local version date sha cur since res
  cur="$(pinned LLVM_VERSION)"
  if [ -z "$cur" ] || [ -z "$(pinned LLVM_SHA256)" ]; then
    echo "error: the Dockerfile has no 'ENV LLVM_VERSION=' and 'ENV LLVM_SHA256=' pair" >&2
    return 1
  fi
  res="$(newest)" || return $?
  read -r version date sha <<< "$res"
  since="$(date -u -d "$date" +%s)"
  if [ "$cur" != "$version" ] && [ $((($(date -u +%s) - since) / 86400)) -ge "$GRACE_DAYS" ]; then
    echo "error: Dockerfile: LLVM $cur is behind LLVM $version, released $date; run scripts/check-newest-llvm.sh --update" >&2
    return 1
  fi
}

update() {
  local version date sha cur res
  cur="$(pinned LLVM_VERSION)"
  res="$(newest)" || return $?
  read -r version date sha <<< "$res"
  if [ "$cur" = "$version" ]; then
    echo "LLVM $cur is the newest release"
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "updates=false" >> "$GITHUB_OUTPUT"
    return 0
  fi
  sed -i.bak -e "s/^ENV LLVM_VERSION=.*$/ENV LLVM_VERSION=$version/" \
    -e "s/^ENV LLVM_SHA256=.*$/ENV LLVM_SHA256=$sha/" Dockerfile
  rm -f Dockerfile.bak
  echo "LLVM $cur -> $version (released $date, sha256 $sha)"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "updates=true" >> "$GITHUB_OUTPUT"
  if [ -n "${SUMMARY_FILE:-}" ]; then
    printf 'Moves the LLVM tools from %s to %s, released %s.\n\nThe SHA-256 is the one GitHub records for LLVM-%s-Linux-X64.tar.zst. CI builds the toolchain image, so a tarball that does not match fails the build.\n' \
      "$cur" "$version" "$date" "$version" > "$SUMMARY_FILE"
  fi
}

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <mode> [env...]
  local want="$1" needle="$2" label="$3" mode="$4" code=0 out
  shift 4
  # shellcheck disable=SC2163 # the arguments are NAME=value pairs
  out="$(cd "$DIR/repo" && export "$@" && "$mode" 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && grep -qF -- "$needle" <<< "$out"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local cur next old recent sha
  DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$DIR'" EXIT
  mkdir -p "$DIR/repo"
  cp Dockerfile "$DIR/repo/Dockerfile"
  cur="$(pinned LLVM_VERSION)"
  if ! [[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "self-test FAILED: no ENV LLVM_VERSION=X.Y.Z in Dockerfile to test against" >&2
    return 1
  fi
  next="$((${cur%%.*} + 1)).1.0"
  old="$(date -u -d '-200 days' +%Y-%m-%dT00:00:00Z)"
  recent="$(date -u -d '-10 days' +%Y-%m-%dT00:00:00Z)"
  sha="$(printf 'a%.0s' {1..64})"
  release() { # release <version> <date> [prerelease] [asset name]
    printf '{"tag_name":"llvmorg-%s","draft":false,"prerelease":%s,"published_at":"%s","assets":[{"name":"%s","digest":"sha256:%s"}]}' \
      "$1" "${3:-false}" "$2" "${4:-LLVM-$1-Linux-X64.tar.zst}" "$sha"
  }
  printf '[%s]' "$(release "$cur" "$old")" > "$DIR/same"
  printf '[%s,%s]' "$(release "$next" "$old")" "$(release "$cur" "$old")" > "$DIR/behind"
  printf '[%s,%s]' "$(release "$next" "$recent")" "$(release "$cur" "$old")" > "$DIR/grace"
  printf '[%s,%s]' "$(release "$next" "$old" true)" "$(release "$cur" "$old")" > "$DIR/pre"
  printf '[%s,%s]' "$(release "$next" "$old" false other.tar.xz)" "$(release "$cur" "$old")" > "$DIR/noasset"
  printf '[]' > "$DIR/empty"

  expect 0 "" "the real Dockerfile passes on the newest release" check RELEASES_URL="file://$DIR/same"
  expect 1 "is behind LLVM $next" "a release a major behind past the grace fails" check RELEASES_URL="file://$DIR/behind"
  expect 0 "" "a release inside the grace passes" check RELEASES_URL="file://$DIR/grace"
  expect 0 "" "a newer prerelease is not a release" check RELEASES_URL="file://$DIR/pre"
  expect 0 "" "a newer release without the Linux tarball cannot be taken" check RELEASES_URL="file://$DIR/noasset"
  expect 2 "an outage, not a pass" "a listing with no release is an outage" check RELEASES_URL="file://$DIR/empty"
  expect 2 "an outage, not a pass" "an unreadable listing is an outage" check RELEASES_URL="file://$DIR/none"
  expect 0 "LLVM $cur -> $next" "--update moves the pins" update RELEASES_URL="file://$DIR/behind"
  if grep -qx "ENV LLVM_VERSION=$next" "$DIR/repo/Dockerfile" && grep -qx "ENV LLVM_SHA256=$sha" "$DIR/repo/Dockerfile"; then
    echo "self-test: ok: the Dockerfile names LLVM $next and its SHA-256 after --update"
  else
    echo "self-test FAILED: --update left the Dockerfile without LLVM $next and its SHA-256" >&2
    SELF_TEST_FAILED=1
  fi
  expect 0 "" "the updated Dockerfile passes" check RELEASES_URL="file://$DIR/behind"
  sed -i '/^ENV LLVM_SHA256=/d' "$DIR/repo/Dockerfile"
  expect 1 "no 'ENV LLVM_VERSION=' and 'ENV LLVM_SHA256=' pair" "a missing SHA-256 pin fails" check RELEASES_URL="file://$DIR/same"
  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: every planted defect was caught; the real Dockerfile passes"
  fi
  return "$SELF_TEST_FAILED"
}

case "${1:-}" in
  --self-test) self_test ;;
  --update) update ;;
  *)
    code=0
    check || code=$?
    if [ "$code" -eq 0 ]; then
      echo "LLVM $(pinned LLVM_VERSION) is the newest release (or inside the ${GRACE_DAYS}-day grace)"
    fi
    exit "$code"
    ;;
esac
