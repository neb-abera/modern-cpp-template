#!/usr/bin/env bash
#
# check-newest-releases.sh: every release file the Dockerfile downloads is
# the newest release.
#
# Dependabot cannot see a file a RUN line downloads, so this closes the gap.
# Each tool below is a pair of Dockerfile lines, ENV <NAME>_VERSION and
# ENV <NAME>_SHA256, and a GitHub repository whose releases ship the file.
# A release counts when it is neither a draft nor a prerelease and ships
# that file with a SHA-256 GitHub records.
#   1. ENV <NAME>_VERSION names the newest release, once that release has
#      been out GRACE_DAYS (30).
#   2. --update moves every pair to the newest release, taking the SHA-256
#      GitHub records for the file. The release-upgrade workflow runs it and
#      opens the pull request.
#
#   scripts/check-newest-releases.sh              check the repository
#   scripts/check-newest-releases.sh --update     move the pins to the newest
#   scripts/check-newest-releases.sh --self-test  prove each check fails on
#                                                 a planted defect
#
# Exit 1 on a finding. Exit 2 when a release listing cannot be read: an
# outage, not a pass. GH_TOKEN, when set, lifts the API's anonymous rate
# limit. RELEASES_DIR, when set, reads <dir>/<NAME> instead of the API.

set -euo pipefail
cd "$(dirname "$0")/.."

GRACE_DAYS="${GRACE_DAYS:-30}"

# NAME  repository  tag  file. {v} is the version as 1.2.3, {u} as 1_2_3.
TOOLS='
LLVM    llvm/llvm-project  llvmorg-{v}  LLVM-{v}-Linux-X64.tar.zst
CMAKE   Kitware/CMake      v{v}         cmake-{v}-linux-x86_64.tar.gz
CBMC    diffblue/cbmc      cbmc-{v}     ubuntu-24.04-cbmc-{v}-Linux.deb
CCACHE  ccache/ccache      v{v}         ccache-{v}-linux-x86_64-glibc.tar.xz
DOXYGEN doxygen/doxygen    Release_{u}  doxygen-{v}.linux.bin.tar.gz
'

pinned() { sed -n "s/^ENV $1=\(.*\)$/\1/p" Dockerfile | head -1; }

# newest <name> <repo> <tag> <file>: print "<version> <published date>
# <sha256>" for the newest release of one tool.
newest() {
  local name="$1" repo="$2" tag="$3" file="$4" url json auth=()
  if [ -n "${RELEASES_DIR:-}" ]; then
    url="file://$RELEASES_DIR/$name"
  else
    url="https://api.github.com/repos/$repo/releases?per_page=50"
  fi
  json="$(mktemp)"
  if [ -n "${GH_TOKEN:-}" ] && [[ "$url" == https://* ]]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
  fi
  if ! curl -fsSL --retry 2 --max-time 60 "${auth[@]}" "$url" -o "$json" 2> /dev/null; then
    rm -f "$json"
    echo "error: could not read $url: an outage, not a pass" >&2
    return 2
  fi
  python3 - "$json" "$tag" "$file" << 'EOF' || { rm -f "$json"; echo "error: $url names no $name release: an outage, not a pass" >&2; return 2; }
import json, re, sys
path, tag, template = sys.argv[1:4]
pattern = re.escape(tag).replace(r"\{v\}", r"(\d+(?:\.\d+)+)").replace(r"\{u\}", r"(\d+(?:_\d+)+)")
best = None
for r in json.load(open(path)):
    m = re.fullmatch(pattern, r.get("tag_name", ""))
    if not m or r.get("draft") or r.get("prerelease"):
        continue
    parts = m.group(1).replace("_", ".").split(".")
    version = ".".join(parts)
    want = template.replace("{v}", version)
    asset = next((a for a in r.get("assets", []) if a.get("name") == want), None)
    if not asset or not str(asset.get("digest", "")).startswith("sha256:"):
        continue
    key = tuple(int(x) for x in parts) + (0,) * (4 - len(parts))
    if best is None or key > best[0]:
        best = (key, version, r["published_at"][:10], asset["digest"][len("sha256:"):])
if best is None:
    sys.exit(1)
print(best[1], best[2], best[3])
EOF
  rm -f "$json"
}

check() {
  local name repo tag file version date sha cur since res status=0 code
  while read -r name repo tag file; do
    [ -n "$name" ] || continue
    cur="$(pinned "${name}_VERSION")"
    if [ -z "$cur" ] || [ -z "$(pinned "${name}_SHA256")" ]; then
      echo "error: the Dockerfile has no 'ENV ${name}_VERSION=' and 'ENV ${name}_SHA256=' pair" >&2
      status=1
      continue
    fi
    code=0
    res="$(newest "$name" "$repo" "$tag" "$file")" || code=$?
    if [ "$code" -ne 0 ]; then
      status=2
      continue
    fi
    read -r version date sha <<< "$res"
    since="$(date -u -d "$date" +%s)"
    if [ "$cur" != "$version" ] && [ $((($(date -u +%s) - since) / 86400)) -ge "$GRACE_DAYS" ]; then
      echo "error: Dockerfile: $name $cur is behind $name $version, released $date; run scripts/check-newest-releases.sh --update" >&2
      [ "$status" -eq 2 ] || status=1
    else
      echo "$name $cur is the newest release (or inside the ${GRACE_DAYS}-day grace)"
    fi
  done <<< "$TOOLS"
  return "$status"
}

update() {
  local name repo tag file version date sha cur res moved=""
  while read -r name repo tag file; do
    [ -n "$name" ] || continue
    cur="$(pinned "${name}_VERSION")"
    res="$(newest "$name" "$repo" "$tag" "$file")" || return $?
    read -r version date sha <<< "$res"
    if [ "$cur" = "$version" ]; then
      echo "$name $cur is the newest release"
      continue
    fi
    sed -i.bak -e "s/^ENV ${name}_VERSION=.*$/ENV ${name}_VERSION=$version/" \
      -e "s/^ENV ${name}_SHA256=.*$/ENV ${name}_SHA256=$sha/" Dockerfile
    rm -f Dockerfile.bak
    echo "$name $cur -> $version (released $date, sha256 $sha)"
    moved+="- $name $cur to $version, released $date. The SHA-256 is the one GitHub records for $(printf '%s' "$file" | sed "s/{v}/$version/")."$'\n'
  done <<< "$TOOLS"
  if [ -z "$moved" ]; then
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "updates=false" >> "$GITHUB_OUTPUT"
    return 0
  fi
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "updates=true" >> "$GITHUB_OUTPUT"
  if [ -n "${SUMMARY_FILE:-}" ]; then
    printf 'Moves the release files the Dockerfile downloads to the newest releases.\n\n%s\nCI builds the toolchain image, so a file that does not match its SHA-256 fails the build.\n' \
      "$moved" > "$SUMMARY_FILE"
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
  local name repo tag file cur next old recent sha set ctag ntag
  DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$DIR'" EXIT
  mkdir -p "$DIR/repo"
  cp Dockerfile "$DIR/repo/Dockerfile"
  old="$(date -u -d '-200 days' +%Y-%m-%dT00:00:00Z)"
  recent="$(date -u -d '-10 days' +%Y-%m-%dT00:00:00Z)"
  sha="$(printf 'a%.0s' {1..64})"
  # release <tag> <version> <date> <file template> [prerelease] [asset name]
  release() {
    printf '{"tag_name":"%s","draft":false,"prerelease":%s,"published_at":"%s","assets":[{"name":"%s","digest":"sha256:%s"}]}' \
      "$1" "${5:-false}" "$3" "${6:-${4//\{v\}/$2}}" "$sha"
  }
  # tag_for <tag template> <version>: the tag a release of <version> carries.
  tag_for() { local t="${1//\{v\}/$2}"; printf '%s' "${t//\{u\}/${2//./_}}"; }
  for set in same behind grace pre noasset; do mkdir -p "$DIR/$set"; done
  mkdir -p "$DIR/empty"
  while read -r name repo tag file; do
    [ -n "$name" ] || continue
    cur="$(pinned "${name}_VERSION")"
    if ! [[ "$cur" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
      echo "self-test FAILED: no ENV ${name}_VERSION in Dockerfile to test against" >&2
      return 1
    fi
    next="$((${cur%%.*} + 1)).1.0"
    [[ "$cur" =~ ^[0-9]+\.[0-9]+$ ]] && next="$((${cur%%.*} + 1)).1"
    ctag="$(tag_for "$tag" "$cur")"
    ntag="$(tag_for "$tag" "$next")"
    printf '[%s]' "$(release "$ctag" "$cur" "$old" "$file")" > "$DIR/same/$name"
    printf '[%s,%s]' "$(release "$ntag" "$next" "$old" "$file")" "$(release "$ctag" "$cur" "$old" "$file")" > "$DIR/behind/$name"
    printf '[%s,%s]' "$(release "$ntag" "$next" "$recent" "$file")" "$(release "$ctag" "$cur" "$old" "$file")" > "$DIR/grace/$name"
    printf '[%s,%s]' "$(release "$ntag" "$next" "$old" "$file" true)" "$(release "$ctag" "$cur" "$old" "$file")" > "$DIR/pre/$name"
    printf '[%s,%s]' "$(release "$ntag" "$next" "$old" "$file" false other.bin)" "$(release "$ctag" "$cur" "$old" "$file")" > "$DIR/noasset/$name"
    printf '[]' > "$DIR/empty/$name"
    echo "$name $cur $next" >> "$DIR/versions"
  done <<< "$TOOLS"

  expect 0 "" "the real Dockerfile passes on the newest releases" check RELEASES_DIR="$DIR/same"
  while read -r name cur next; do
    expect 1 "$name $cur is behind $name $next" "$name a major behind past the grace fails" check RELEASES_DIR="$DIR/behind"
  done < "$DIR/versions"
  expect 0 "" "a release inside the grace passes" check RELEASES_DIR="$DIR/grace"
  expect 0 "" "a newer prerelease is not a release" check RELEASES_DIR="$DIR/pre"
  expect 0 "" "a newer release without the file cannot be taken" check RELEASES_DIR="$DIR/noasset"
  expect 2 "an outage, not a pass" "a listing with no release is an outage" check RELEASES_DIR="$DIR/empty"
  expect 2 "an outage, not a pass" "an unreadable listing is an outage" check RELEASES_DIR="$DIR/none"
  expect 0 "" "--update moves the pins" update RELEASES_DIR="$DIR/behind"
  while read -r name cur next; do
    if grep -qx "ENV ${name}_VERSION=$next" "$DIR/repo/Dockerfile" && grep -qx "ENV ${name}_SHA256=$sha" "$DIR/repo/Dockerfile"; then
      echo "self-test: ok: the Dockerfile names $name $next and its SHA-256 after --update"
    else
      echo "self-test FAILED: --update left the Dockerfile without $name $next and its SHA-256" >&2
      SELF_TEST_FAILED=1
    fi
  done < "$DIR/versions"
  expect 0 "" "the updated Dockerfile passes" check RELEASES_DIR="$DIR/behind"
  sed -i '/^ENV LLVM_SHA256=/d' "$DIR/repo/Dockerfile"
  expect 1 "no 'ENV LLVM_VERSION=' and 'ENV LLVM_SHA256=' pair" "a missing SHA-256 pin fails" check RELEASES_DIR="$DIR/behind"
  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: every planted defect was caught; the real Dockerfile passes"
  fi
  return "$SELF_TEST_FAILED"
}

case "${1:-}" in
  --self-test) self_test ;;
  --update) update ;;
  *) check ;;
esac
