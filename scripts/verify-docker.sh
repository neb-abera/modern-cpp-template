#!/usr/bin/env bash
#
# verify-docker.sh — run the full verification suite (scripts/verify.sh)
# inside the project's Docker toolchain image instead of on the host, so
# results do not depend on locally installed compilers, CMake or clang-format.
#
# The source tree is mounted read-only and copied to a container-local
# directory before building, so the host checkout is never modified and no
# root-owned build artifacts are left behind.

set -eu

cd "$(dirname "$0")/.."

IMAGE="modern-cpp-template:latest"
CONTAINER="mct-verify"

echo "== Building toolchain image $IMAGE (cached after the first run) =="
docker build -t "$IMAGE" .

echo
echo "== Running verification in container $CONTAINER =="
docker rm -f "$CONTAINER" 2> /dev/null || true
docker run --rm --name "$CONTAINER" -v "$PWD":/src:ro "$IMAGE" bash -c '
  set -eu
  cp -r /src /work
  cd /work
  rm -rf build
  ./scripts/verify.sh
'
