#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite locally, with a
# running pass/fail count and a final summary. This mirrors what CI checks
# before a merge:
#
#   1. clean Release build with warnings-as-errors + full test suite
#   2. the same tests under AddressSanitizer + UndefinedBehaviorSanitizer
#   3. the compiler is really in strict C++ standard mode (no GNU extensions)
#   4. executable mode builds and runs
#   5. the install tree contains only this project's files
#   6. mutation canary: plant a bug and confirm the tests catch it
#   7. sources are clang-format clean (skipped if clang-format is missing)
#
# Exit code 0 means everything passed.

set -u

cd "$(dirname "$0")/.."

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

CHECKS_TOTAL=7
CHECKS_RUN=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=""
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

banner() {
  printf '\n%s== [%d/%d] %s ==%s\n' "$BOLD" "$((CHECKS_RUN + 1))" "$CHECKS_TOTAL" "$1" "$RESET"
}

tally() {
  printf '%sRunning tally: checks %d passed / %d failed, tests %d passed / %d failed%s\n' \
    "$BOLD" "$CHECKS_PASSED" "$CHECKS_FAILED" "$TESTS_PASSED" "$TESTS_FAILED" "$RESET"
}

pass() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_PASSED=$((CHECKS_PASSED + 1))
  printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"
  tally
}

fail() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_FAILED=$((CHECKS_FAILED + 1))
  FAILED_NAMES="$FAILED_NAMES  - $1\n"
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$1"
  tally
}

skip() {
  CHECKS_RUN=$((CHECKS_RUN + 1)); CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
  printf '%s[SKIP]%s %s\n' "$YELLOW" "$RESET" "$1"
}

# Parse the ctest summary line and add to the tally. Depending on the CTest
# version the line reads "100% tests passed out of M" on success or
# "X% tests passed, N tests failed out of M" on failure.
count_ctest() {
  local failed total
  total=$(grep -E 'tests passed.*out of [0-9]+' "$LOG" | grep -Eo 'out of [0-9]+' | awk '{print $3}' | tail -1)
  failed=$(grep -Eo '[0-9]+ tests failed out of' "$LOG" | awk '{print $1}' | tail -1)
  failed=${failed:-0}
  if [ -n "${total:-}" ]; then
    TESTS_FAILED=$((TESTS_FAILED + failed))
    TESTS_PASSED=$((TESTS_PASSED + total - failed))
  fi
}

# Configure + build + ctest for one preset; stream test output live.
run_suite() {
  local preset="$1" extra="${2:-}"
  rm -rf "build/$preset"
  # shellcheck disable=SC2086
  cmake --preset "$preset" $extra > "$LOG" 2>&1 || { tail -20 "$LOG"; return 1; }
  cmake --build --preset "$preset" -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1 \
    || { tail -20 "$LOG"; return 1; }
  ctest --preset "$preset" 2>&1 | tee "$LOG"
  grep -q '100% tests passed' "$LOG"
}

banner "Release build + full test suite (warnings as errors)"
if run_suite release "-DProject_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "Release: clean build, all tests green"
else
  count_ctest; fail "Release build/tests"
fi

banner "Tests under AddressSanitizer + UndefinedBehaviorSanitizer"
if run_suite asan "-DProject_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "Sanitizers: no memory errors or undefined behavior"
else
  count_ctest; fail "Sanitizer run"
fi

banner "Strict C++ standard mode"
flag=$(grep -rho '\-std=[^ ]*' build/release/CMakeFiles/*.dir/flags.make 2>/dev/null | sort -u | head -1)
if printf '%s' "$flag" | grep -q '^-std=c++'; then
  echo "compiler flag: $flag"
  pass "Standard mode is strict ($flag, no GNU extensions)"
else
  echo "compiler flag: ${flag:-<none found>}"
  fail "Strict standard mode (expected -std=c++NN)"
fi

banner "Executable mode smoke test"
rm -rf build/debug
if cmake --preset debug -DProject_BUILD_EXECUTABLE=ON > "$LOG" 2>&1 \
   && cmake --build --preset debug -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1 \
   && out=$(./build/debug/Project) && [ "$out" = "1 + 2 = 3" ]; then
  echo "program output: $out"
  pass "Executable builds and prints the expected output"
else
  tail -20 "$LOG"
  fail "Executable mode"
fi

banner "Install tree purity"
rm -rf build/verify-install
if cmake --install build/release --prefix build/verify-install > "$LOG" 2>&1 \
   && [ -f build/verify-install/include/project/tmp.hpp ] \
   && [ -f build/verify-install/include/project/version.hpp ] \
   && ! find build/verify-install \( -iname '*gtest*' -o -iname '*gmock*' -o -iname '*catch2*' \) | grep -q .; then
  echo "installed files:"; find build/verify-install -type f | sed 's/^/  /'
  pass "Install tree contains only this project's files"
else
  fail "Install tree purity (missing files or test framework leaked in)"
fi

banner "Mutation canary: do the tests catch a planted bug?"
if ! git diff --quiet -- src/tmp.cpp; then
  skip "Mutation canary (src/tmp.cpp has local edits; commit or stash them first)"
else
  perl -pi -e 's/return a \+ b;/return a - b;/' src/tmp.cpp
  cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1
  if ctest --preset release > "$LOG" 2>&1; then
    git checkout -- src/tmp.cpp
    fail "Mutation canary (tests did NOT catch the planted bug!)"
  else
    caught=$(grep -Eo '[0-9]+ tests failed out of [0-9]+' "$LOG" | awk '{print $1}' | tail -1)
    git checkout -- src/tmp.cpp
    cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1
    echo "planted 'a + b -> a - b'; $caught tests failed as they should, then restored"
    pass "Mutation canary: tests caught the planted bug ($caught failures)"
  fi
fi

banner "clang-format check"
if command -v clang-format > /dev/null; then
  if (shopt -s nullglob globstar 2>/dev/null;
      clang-format --dry-run --Werror src/**/*.cpp include/**/*.hpp test/**/*.cpp > "$LOG" 2>&1); then
    pass "Sources are clang-format clean"
  else
    tail -20 "$LOG"
    fail "clang-format check"
  fi
else
  skip "clang-format check (clang-format not installed)"
fi

printf '\n%s========================= VERIFICATION COMPLETE =========================%s\n' "$BOLD" "$RESET"
printf 'Checks : %s%d passed%s, %s%d failed%s, %d skipped (of %d)\n' \
  "$GREEN" "$CHECKS_PASSED" "$RESET" "$RED" "$CHECKS_FAILED" "$RESET" "$CHECKS_SKIPPED" "$CHECKS_TOTAL"
printf 'Tests  : %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$TESTS_PASSED" "$RESET" "$RED" "$TESTS_FAILED" "$RESET"
if [ "$CHECKS_FAILED" -eq 0 ]; then
  printf '%s%sALL CHECKS PASSED — this build behaves as intended.%s\n' "$BOLD" "$GREEN" "$RESET"
  exit 0
else
  printf '%s%sFAILURES:%s\n' "$BOLD" "$RED" "$RESET"
  printf '%b' "$FAILED_NAMES"
  exit 1
fi
