#!/usr/bin/env bash
#
# lint.sh — actionlint over the workflows (with shellcheck on every run:
# block), shellcheck over scripts/*.sh, and no workflow that cancels a run
# on the default branch.
#
# Both tools come from the `lint` stage of the Dockerfile: two digest-pinned
# FROM lines that Dependabot bumps. Nothing here or in a workflow names a
# version, so CI and a laptop run the same binaries.
#
#   scripts/lint.sh              lint the repository
#   scripts/lint.sh --self-test  prove each linter fails on a planted defect
#
# It also runs scripts/check-ubuntu-lts.sh: the Ubuntu base image is an LTS
# tag and the Dependabot ignore ranges keep interim releases out.
#
# `cancel-in-progress: true` cancels a push run on the default branch when
# the next merge lands minutes later, so the first merge is never checked.
# A workflow cancels on pull requests only
# (`${{ github.event_name == 'pull_request' }}`), and one that publishes uses
# a fixed group with cancel off.
#
# --self-test copies the workflows and scripts into a temporary directory,
# plants an unquoted expansion in a workflow's run: block, another in a
# script, and a `cancel-in-progress: true`, and requires each copy to fail
# naming the file. The untouched copy must pass.

set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')-lint:latest"
docker build -q --target lint -t "$IMAGE" . > /dev/null

# lint <dir>: both linters over the tree at <dir>, as the calling user so a
# checkout the image's own user cannot read still lints.
lint() {
  local status=0
  if (cd "$1" && grep -Hn 'cancel-in-progress: *true' .github/workflows/*.yml); then
    echo "error: a workflow above cancels runs on the default branch; use \${{ github.event_name == 'pull_request' }}" >&2
    status=1
  fi
  docker run --rm --user "$(id -u):$(id -g)" -v "$1":/repo:ro -w /repo \
    --entrypoint sh "$IMAGE" -c 'actionlint -color && shellcheck scripts/*.sh' || status=1
  return "$status"
}

SELF_TEST_FAILED=0
expect() { # expect <exit> <text> <label> <dir>
  local want="$1" needle="$2" label="$3" code=0 out
  out="$(lint "$4" 2>&1)" || code=$?
  if [ "$code" -eq "$want" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "self-test: ok: $label (exit $code)"
  else
    echo "self-test FAILED: $label: wanted exit $want and '$needle', got exit $code:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  mkdir -p "$dir/clean/scripts"
  cp -R .github "$dir/clean/"
  cp scripts/*.sh "$dir/clean/scripts/"
  # actionlint finds its project, and .github/actionlint.yaml, by the
  # repository root.
  git init -q "$dir/clean"
  cp -R "$dir/clean" "$dir/workflow"
  cp -R "$dir/clean" "$dir/script"
  cp -R "$dir/clean" "$dir/cancel"
  sed 's/^  cancel-in-progress: .*/  cancel-in-progress: true/' .github/workflows/ci.yml \
    > "$dir/cancel/.github/workflows/ci.yml"
  cat > "$dir/workflow/.github/workflows/planted.yml" <<'YAML'
name: planted
on: push
permissions: {}
jobs:
  planted:
    runs-on: ubuntu-latest
    steps:
      - run: rm -rf $PLANTED/*
YAML
  # shellcheck disable=SC2016 # the planted script is literal text
  printf '#!/bin/sh\nrm -rf $1/*\n' > "$dir/script/scripts/planted.sh"
  chmod -R go+rX "$dir"

  expect 0 "" "the real workflows and scripts pass" "$dir/clean"
  expect 1 "planted.yml" "actionlint fails a workflow run: block with an unquoted expansion" "$dir/workflow"
  expect 1 "scripts/planted.sh" "shellcheck fails a script with an unquoted expansion" "$dir/script"
  expect 1 "ci.yml:" "a workflow that cancels runs on the default branch fails" "$dir/cancel"
  if [ "$SELF_TEST_FAILED" -eq 0 ]; then
    echo "self-test: all three planted defects were caught by file; the real tree passes"
  fi
  return "$SELF_TEST_FAILED"
}

if [ "${1:-}" = --self-test ]; then
  self_test
  ./scripts/check-ubuntu-lts.sh --self-test
else
  lint "$PWD"
  echo "actionlint and shellcheck pass"
  ./scripts/check-ubuntu-lts.sh
fi
