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

# Image/container names derive from the checkout directory, so projects
# generated from this template need no edits here.
NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
IMAGE="$NAME:latest"
CONTAINER="$NAME-verify"

echo "== Building toolchain image $IMAGE (cached after the first run) =="
docker build -t "$IMAGE" .

echo
echo "== Running verification in container $CONTAINER =="
docker rm -f "$CONTAINER" 2> /dev/null || true
# --security-opt seccomp: Docker's default seccomp profile plus one syscall
# argument. ThreadSanitizer needs a fixed virtual-address layout; when the
# kernel's mmap randomisation hands it an incompatible one (seen on Azure's
# 6.17 kernel) it calls personality(ADDR_NO_RANDOMIZE) and re-execs itself
# with ASLR off. Docker's default profile allows personality() with only a
# handful of values, not that one, so the call fails and the TSan check dies
# before its first test with "FATAL: ThreadSanitizer: encountered an
# incompatible memory layout but was unable to disable ASLR (perhaps
# sandboxing is enabled?)". scripts/tsan-seccomp.json is the default profile
# (github.com/moby/profiles, seccomp/v0.2.3) with ADDR_NO_RANDOMIZE allowed
# and nothing else loosened; CI's tsan job passes the same file.
docker run --rm --name "$CONTAINER" -v "$PWD":/src:ro \
  --security-opt seccomp="$PWD/scripts/tsan-seccomp.json" "$IMAGE" bash -c '
  set -eu
  cp -r /src "$HOME/project"
  cd "$HOME/project"
  rm -rf build
  ./scripts/verify.sh
'
