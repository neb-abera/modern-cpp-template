#!/usr/bin/env bash
#
# sync-cbmc.sh — move the Dockerfile's ENV CBMC_VERSION to the cbmc its
# ubuntu base image installs.
#
#   scripts/sync-cbmc.sh              ask the base image's apt for cbmc and
#                                     rewrite the pin (needs Docker)
#   scripts/sync-cbmc.sh --self-test  prove the parse and the rewrite, with
#                                     no network
#
# cbmc comes from the Ubuntu archive, so the base image decides its version.
# scripts/check-proofs.sh fails when the installed cbmc and ENV CBMC_VERSION
# differ. Dependabot's docker ecosystem bumps only the FROM ubuntu line, so a
# base image that ships another cbmc would arrive as a red pull request that
# cannot auto-merge. The Dependabot toolchain workflow runs this script on
# Dependabot's docker pull requests and commits the moved Dockerfile. The
# proofs and their canary then run against the new solver in CI, as before.
#
# Exit 0 means the pin names the cbmc the base image installs.

set -euo pipefail
cd "$(dirname "$0")/.."

# upstream: read `apt-cache policy cbmc` on stdin, print the candidate's
# upstream version (the epoch and the Debian revision removed), the form
# `cbmc --version` prints and check-proofs.sh compares.
upstream() {
  local candidate ver
  candidate=$(sed -n 's/^ *Candidate: *\([^ ]*\).*$/\1/p' | head -1)
  ver=$(printf '%s\n' "$candidate" | sed -E 's/^[0-9]+://; s/-[^-]*$//')
  if ! printf '%s\n' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "error: apt offers no cbmc release in the base image (candidate '${candidate:-<none>}')" >&2
    return 1
  fi
  printf '%s\n' "$ver"
}

# rewrite <dockerfile> <version>: set the ENV CBMC_VERSION line.
rewrite() {
  if ! grep -q '^ENV CBMC_VERSION=' "$1"; then
    echo "error: $1 has no 'ENV CBMC_VERSION=' line to rewrite" >&2
    return 1
  fi
  sed -i.bak "s/^ENV CBMC_VERSION=.*$/ENV CBMC_VERSION=$2/" "$1"
  rm -f "$1.bak"
}

if [ "${1:-}" = "--self-test" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fail() { echo "self-test FAILED: $*" >&2; exit 1; }
  pinned=$(sed -n 's/^ENV CBMC_VERSION=\(.*\)$/\1/p' Dockerfile)

  # The parse, on the shapes apt prints.
  policy() { printf 'cbmc:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "$1"; }
  [ "$(policy 6.7.1-1ubuntu1 | upstream)" = 6.7.1 ] || fail "6.7.1-1ubuntu1 did not parse to 6.7.1"
  [ "$(policy 1:6.8.0-2 | upstream)" = 6.8.0 ] || fail "an epoch (1:6.8.0-2) did not parse to 6.8.0"
  [ "$(policy 6.9.0 | upstream)" = 6.9.0 ] || fail "a version with no revision did not parse"
  if policy '(none)' | upstream > /dev/null 2>&1; then
    fail "a base image with no cbmc candidate parsed"
  fi

  # The rewrite: the pin moves and nothing else in the Dockerfile does.
  cp Dockerfile "$tmp/Dockerfile"
  rewrite "$tmp/Dockerfile" 6.7.1 || fail "the rewrite failed on the committed Dockerfile"
  grep -qx 'ENV CBMC_VERSION=6.7.1' "$tmp/Dockerfile" || fail "the pin is not 6.7.1 after the rewrite"
  changed=$(diff Dockerfile "$tmp/Dockerfile" | grep -c '^[<>]' || true)
  [ "$changed" = 2 ] || fail "the rewrite changed $changed lines, not the one pin line"

  # The pin already right: byte-identical.
  cp Dockerfile "$tmp/Dockerfile"
  rewrite "$tmp/Dockerfile" "$pinned"
  cmp -s Dockerfile "$tmp/Dockerfile" || fail "rewriting to the pinned $pinned changed the Dockerfile"

  # No pin line: fail rather than add nothing and report success.
  grep -v '^ENV CBMC_VERSION=' Dockerfile > "$tmp/Dockerfile"
  if rewrite "$tmp/Dockerfile" 6.7.1 2> /dev/null; then
    fail "a Dockerfile with no pin line was rewritten"
  fi

  echo "self-test passed: apt versions with a revision, an epoch and neither parse, no candidate fails, the rewrite moves only the pin line, $pinned stays byte-identical, a missing pin line fails"
  exit 0
fi

image=$(sed -n 's/^FROM \(ubuntu:[^ ]*\).*$/\1/p' Dockerfile | head -1)
[ -n "$image" ] || { echo "error: no 'FROM ubuntu:' line in the Dockerfile" >&2; exit 1; }
ver=$(docker run --rm "$image" sh -c 'apt-get update -qq > /dev/null && apt-cache policy cbmc' | upstream)
rewrite Dockerfile "$ver"
echo "cbmc pin: $image installs cbmc $ver; ENV CBMC_VERSION=$ver"
