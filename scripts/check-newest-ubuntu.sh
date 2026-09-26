#!/usr/bin/env bash
#
# check-newest-ubuntu.sh: the Ubuntu base image is the newest release.
#
# A release counts whether it is LTS or interim. A development release does
# not: META_URL lists released versions only.
#   1. .github/dependabot.yml holds back no ubuntu release. An ignore entry
#      for ubuntu may hold an exact tag, never a range or an update type.
#   2. Every FROM ubuntu line in a tracked Dockerfile names the newest
#      release in META_URL, once that release has been out GRACE_DAYS (45).
#      The grace covers a weekly Dependabot bump that has to be fixed
#      before it merges.
#
#   scripts/check-newest-ubuntu.sh              check the repository
#   scripts/check-newest-ubuntu.sh --self-test  prove each check fails on a
#                                               planted defect
#
# Exit 1 on a finding. Exit 2 when META_URL cannot be read: an outage, not a
# pass.

set -euo pipefail
cd "$(dirname "$0")/.."

META_URL="${META_URL:-https://changelogs.ubuntu.com/meta-release}"
GRACE_DAYS="${GRACE_DAYS:-45}"
FROM_UBUNTU='^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?(docker\.io/)?(library/)?ubuntu:'

dockerfiles() {
  if [ "${NEWEST_LISTING:-git}" = find ]; then
    find . -type f \( -name Dockerfile -o -name '*.Dockerfile' -o -name 'Dockerfile.*' \) | sed 's|^\./||' | sort
  else
    git ls-files -- 'Dockerfile' '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*'
  fi
}

check() {
  local status=0 found meta newest date since f tag
  found="$(awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[ \t]*(#|$)/ { next }
    { i = ind($0); line = substr($0, i + 1) }
    i <= 4 { ig = (i == 4 && line ~ /^ignore:/); on = 0; next }
    ig && line ~ /^- dependency-name:/ { on = (line ~ /dependency-name: *"?ubuntu"?[[:space:]]*$/); next }
    ig && on && (line ~ /[<>*]/ || line ~ /version-update/) { print NR ": " line }
  ' .github/dependabot.yml)"
  if [ -n "$found" ]; then
    while IFS= read -r f; do
      echo "error: .github/dependabot.yml:$f holds back an ubuntu release; hold an exact tag or nothing" >&2
    done <<< "$found"
    status=1
  fi

  meta="$(mktemp)"
  if ! curl -fsSL --max-time 60 "$META_URL" -o "$meta" 2>/dev/null; then
    sleep 5
    if ! curl -fsSL --max-time 60 "$META_URL" -o "$meta"; then
      rm -f "$meta"
      echo "error: could not read $META_URL: an outage, not a pass" >&2
      exit 2
    fi
  fi
  read -r newest date < <(awk '
    /^Version:/ { if (match($2, /^[0-9]+\.[0-9]+/)) v = substr($2, 1, RLENGTH) }
    /^Date:/ { sub(/^Date:[ ]*/, ""); sub(/^[A-Za-z]+, /, ""); d = $0 }
    /^$/ && v != "" { print v "|" d; v = "" }
    END { if (v != "") print v "|" d }
  ' "$meta" | sort -t. -k1,1n -k2,2n | tail -1 | tr '|' ' ')
  rm -f "$meta"
  if ! [[ "${newest:-}" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
    echo "error: $META_URL names no release: an outage, not a pass" >&2
    exit 2
  fi
  since="$(date -u -d "$date" +%s)"
  if [ $((($(date -u +%s) - since) / 86400)) -ge "$GRACE_DAYS" ]; then
    for f in $(dockerfiles); do
      while IFS= read -r tag; do
        if [ "$tag" != "$newest" ]; then
          echo "error: $f: ubuntu:$tag is behind Ubuntu $newest, released $date" >&2
          status=1
        fi
      done < <(grep -E "$FROM_UBUNTU" "$f" | sed -E 's/.*ubuntu:([^@[:space:]]+).*/\1/')
    done
  fi
  return "$status"
}

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <case> [env...]
  local want="$1" needle="$2" label="$3" case="$4" code=0 out
  shift 4
  # shellcheck disable=SC2163 # the arguments are NAME=value pairs
  out="$(cd "$DIR/$case" && export NEWEST_LISTING=find "$@" && check 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && grep -qF -- "$needle" <<< "$out"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local case cur next old recent
  DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$DIR'" EXIT
  for case in clean hold; do
    mkdir -p "$DIR/$case/.github"
    cp Dockerfile "$DIR/$case/Dockerfile"
    cp .github/dependabot.yml "$DIR/$case/.github/dependabot.yml"
  done
  cur="$(grep -E "$FROM_UBUNTU" Dockerfile | sed -E 's/.*ubuntu:([0-9]{2}\.[0-9]{2}).*/\1/' | head -1)"
  if [ -z "$cur" ]; then
    echo "self-test FAILED: no FROM ubuntu:YY.MM in Dockerfile to test against" >&2
    return 1
  fi
  if [ "${cur#*.}" = 04 ]; then next="${cur%.*}.10"; else next="$(printf '%02d' $((10#${cur%.*} + 1))).04"; fi
  old="$(date -u -d '-200 days' '+%d %B %Y')"
  recent="$(date -u -d '-10 days' '+%d %B %Y')"
  meta() { # meta <newest> <its date>: an index of three releases
    printf 'Dist: a\nVersion: 20.04.6 LTS\nDate: Thu, 23 April 2020 00:26:04 UTC\nSupported: 0\n\nDist: b\nVersion: %s\nDate: Thu, %s 00:25:10 UTC\nSupported: 1\n\nDist: c\nVersion: %s.1\nDate: Thu, %s 00:26:04 UTC\nSupported: 1\n' \
      "$cur" "$old" "$1" "$2"
  }
  meta "$cur" "$old" > "$DIR/same"
  meta "$next" "$old" > "$DIR/behind"
  meta "$next" "$recent" > "$DIR/grace"
  awk '{ print } /^[ ]{4}ignore:/ && !done { print "      - dependency-name: ubuntu\n        versions:\n          - \">= 99.05, < 99.10\""; done = 1 }' \
    .github/dependabot.yml > "$DIR/hold/.github/dependabot.yml"
  if ! grep -q '99.05' "$DIR/hold/.github/dependabot.yml"; then
    awk '{ print } /^  - package-ecosystem: docker$/ { d = 1 } d && /^    schedule:/ && !done { print "    ignore:\n      - dependency-name: ubuntu\n        versions:\n          - \">= 99.05, < 99.10\""; done = 1 }' \
      .github/dependabot.yml > "$DIR/hold/.github/dependabot.yml"
  fi

  expect 0 "" "the real files pass on the newest release" clean META_URL="file://$DIR/same"
  expect 1 "is behind Ubuntu $next" "a base image a release behind past the grace fails, interim or LTS" clean META_URL="file://$DIR/behind"
  expect 0 "" "a release inside the grace passes" clean META_URL="file://$DIR/grace"
  expect 1 "holds back an ubuntu release" "an ignore range on ubuntu fails" hold META_URL="file://$DIR/same"
  expect 2 "an outage, not a pass" "an unreadable index is an outage" clean META_URL="file://$DIR/none"
  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: every planted defect was caught; the real files pass"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
else
  code=0
  check || code=$?
  if [ "$code" -eq 0 ]; then
    echo "the Ubuntu base image is the newest release (or inside the ${GRACE_DAYS}-day grace), and Dependabot holds none back"
  fi
  exit "$code"
fi
