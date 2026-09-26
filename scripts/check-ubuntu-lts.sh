#!/usr/bin/env bash
#
# check-ubuntu-lts.sh: the Ubuntu base image stays on an LTS release.
#
# Ubuntu LTS releases are YY.04 with an even YY. Every other release is
# interim and gets 9 months of support. Every Dependabot pull request
# auto-merges on green CI, majors included, so an interim tag Dependabot
# offers would merge itself. .github/dependabot.yml ignores the interim
# releases with one range per LTS gap: ">= YY.05, < (YY+2).04".
#
# Two checks:
#   1. Every FROM ubuntu line in a tracked Dockerfile names an LTS tag.
#   2. The ignore ranges cover every interim tag from this year through two
#      years ahead, and cover no LTS tag. So the list is extended before it
#      lapses, and the next LTS is still offered.
#
#   scripts/check-ubuntu-lts.sh              check the repository
#   scripts/check-ubuntu-lts.sh --self-test  prove each check fails on a
#                                            planted defect
#
# UBUNTU_LTS_YEAR (two digits) overrides the current year, for the
# self-test.

set -euo pipefail
cd "$(dirname "$0")/.."

# check <dir> <dockerfile>...: exit 1 naming each defect.
check() {
  local dir="$1" status=0 file line tag yy mm
  shift
  for file in "$@"; do
    while IFS= read -r line; do
      tag="$(printf '%s\n' "$line" | sed -E 's/.*ubuntu:([^@[:space:]]+).*/\1/')"
      if [[ "$tag" =~ ^([0-9]{2})\.([0-9]{2})$ ]]; then
        yy=$((10#${BASH_REMATCH[1]}))
        mm=$((10#${BASH_REMATCH[2]}))
        if [ $((yy % 2)) -eq 0 ] && [ "$mm" -eq 4 ]; then
          continue
        fi
      fi
      echo "error: $file: ubuntu:$tag is not an LTS release (YY.04 with an even YY)" >&2
      status=1
    done < <(grep -E '^[[:space:]]*FROM[[:space:]]+(docker\.io/)?(library/)?ubuntu:' "$dir/$file" || true)
  done

  # The ranges from the ignore entry whose dependency-name is ubuntu, as
  # "lo hi" pairs of YY*100+MM.
  local ranges
  ranges="$(awk '
    /dependency-name:/ { on = ($0 ~ /dependency-name: *"?ubuntu"?[[:space:]]*$/) ; next }
    /^  - package-ecosystem:/ { on = 0 }
    on && /^ *- *"?>=/ {
      if (match($0, />= *[0-9]+\.[0-9]+ *, *< *[0-9]+\.[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]+/, " ", s)
        split(s, v, " ")
        print v[1] * 100 + v[2], v[3] * 100 + v[4]
      } else {
        print "unparsed"
      }
    }
  ' "$dir/.github/dependabot.yml")"
  if [ -z "$ranges" ]; then
    echo "error: .github/dependabot.yml has no ignore versions for ubuntu" >&2
    return 1
  fi
  if printf '%s\n' "$ranges" | grep -q unparsed; then
    echo "error: .github/dependabot.yml: every ubuntu ignore version must read \">= YY.MM, < YY.MM\"" >&2
    return 1
  fi

  covered() { # covered <YY*100+MM>: is the tag inside an ignore range
    local v="$1" lo hi
    while read -r lo hi; do
      if [ "$v" -ge "$lo" ] && [ "$v" -lt "$hi" ]; then return 0; fi
    done <<< "$ranges"
    return 1
  }

  local now="${UBUNTU_LTS_YEAR:-$(date -u +%y)}" y
  now=$((10#$now))
  for ((y = now; y <= now + 2; y++)); do
    if [ $((y % 2)) -eq 1 ] && ! covered $((y * 100 + 4)); then
      printf 'error: .github/dependabot.yml: ubuntu %02d.04 is interim and not ignored; add the next ">= YY.05, < YY.04" range\n' "$y" >&2
      status=1
    fi
    if ! covered $((y * 100 + 10)); then
      printf 'error: .github/dependabot.yml: ubuntu %02d.10 is interim and not ignored; add the next ">= YY.05, < YY.04" range\n' "$y" >&2
      status=1
    fi
  done
  for ((y = now - now % 2; y <= now + 6; y += 2)); do
    if covered $((y * 100 + 4)); then
      printf 'error: .github/dependabot.yml: ubuntu %02d.04 is LTS and an ignore range covers it\n' "$y" >&2
      status=1
    fi
  done
  return "$status"
}

dockerfiles() { git ls-files -- 'Dockerfile' '*/Dockerfile' '*.Dockerfile' 'Dockerfile.*'; }

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <dir>
  local want="$1" needle="$2" label="$3" dir="$4" code=0 out
  out="$(cd "$dir" && check "$dir" Dockerfile 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir case
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  for case in clean interim lapsed lts; do
    mkdir -p "$dir/$case/.github"
    cp Dockerfile "$dir/$case/Dockerfile"
    cp .github/dependabot.yml "$dir/$case/.github/dependabot.yml"
  done
  sed -E -i.bak 's/^(FROM ubuntu:)[0-9.]+/\126.10/' "$dir/interim/Dockerfile"
  sed -E -i.bak 's/"(>= 26\.05, <) 28\.04"/"\1 28.05"/' "$dir/lts/.github/dependabot.yml"

  expect 0 "" "the real Dockerfile and dependabot.yml pass" "$dir/clean"
  expect 1 "ubuntu:26.10 is not an LTS release" "a planted FROM ubuntu:26.10 fails" "$dir/interim"
  UBUNTU_LTS_YEAR=40 expect 1 "is interim and not ignored" "ignore ranges that lapse within two years fail" "$dir/lapsed"
  expect 1 "ubuntu 28.04 is LTS and an ignore range covers it" "a range that swallows the next LTS fails" "$dir/lts"
  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: all four planted defects were caught; the real files pass"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
else
  mapfile -t files < <(dockerfiles)
  check "$PWD" "${files[@]}"
  echo "ubuntu base images are LTS, and the Dependabot ignore ranges cover every interim release through $(( 10#${UBUNTU_LTS_YEAR:-$(date -u +%y)} + 2 )).10"
fi
