#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite locally, with a
# running pass/fail count and a final summary. This mirrors what CI checks
# before a merge:
#
#    1. clean Release build with warnings-as-errors + full test suite
#    2. the same tests under AddressSanitizer + UndefinedBehaviorSanitizer
#    3. the same tests under ThreadSanitizer
#    4. clang-tidy static analysis (skipped if clang-tidy is missing)
#    5. fuzz smoke: the libFuzzer harness builds and survives a short run
#    6. benchmark smoke: the Google Benchmark harness builds and runs
#    7. the compiler is really in strict C++ standard mode (no GNU extensions)
#    8. executable mode builds and runs
#    9. the install tree contains only this project's files (LICENSE and
#       NOTICE included)
#   10. mutation canary: plant a bug and confirm the tests catch it
#   11. required-contexts drift guard: setup.sh's branch-protection list
#       matches the gate workflows' job names
#   12. sources are clang-format clean (skipped if clang-format is missing)
#
# VERIFY_CHECKS selects a subset by tag (default: all of them), e.g.
#   VERIFY_CHECKS="release strict exe install canary contexts" ./scripts/verify.sh
# CI's verify-extras job uses this to run exactly the checks no dedicated CI
# job covers. The strict/install/canary tags read the release build tree, so
# include release with them.
#
# Exit code 0 means everything passed.

set -u

cd "$(dirname "$0")/.." || exit 1

# The CMake project name, read from CMakeLists.txt, so a rename (e.g. via
# scripts/setup.sh) needs no edits here.
PROJ=$(sed -n 's/^[[:space:]]*"\([A-Za-z0-9_-]*\)"[[:space:]]*$/\1/p' CMakeLists.txt | head -1)
PROJ_LOWER=$(printf '%s' "$PROJ" | tr '[:upper:]' '[:lower:]')

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# Check tags, in run order; VERIFY_CHECKS (space-separated tags) selects a
# subset. Each check below is wrapped in `if enabled <tag>`.
ALL_CHECKS="release asan tsan tidy fuzz bench strict exe install canary contexts format"
SELECTED=${VERIFY_CHECKS:-$ALL_CHECKS}
enabled() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2086
set -- $SELECTED
CHECKS_TOTAL=$#
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

if enabled release; then
banner "Release build + full test suite (warnings as errors)"
if run_suite release "-D${PROJ}_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "Release: clean build, all tests green"
else
  count_ctest; fail "Release build/tests"
fi
fi

if enabled asan; then
banner "Tests under AddressSanitizer + UndefinedBehaviorSanitizer"
if run_suite asan "-D${PROJ}_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "Sanitizers: no memory errors or undefined behavior"
else
  count_ctest; fail "Sanitizer run"
fi
fi

if enabled tsan; then
banner "Tests under ThreadSanitizer"
if run_suite tsan "-D${PROJ}_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "ThreadSanitizer: no data races"
else
  count_ctest; fail "ThreadSanitizer run"
fi
fi

if enabled tidy; then
banner "Static analysis: clang-tidy (C++ Core Guidelines + CERT)"
if ! command -v clang-tidy > /dev/null; then
  skip "Static analysis (clang-tidy not installed)"
else
  rm -rf build/tidy
  # Warnings-as-errors here too, matching the CI static-analysis gate.
  if cmake --preset tidy "-D${PROJ}_WARNINGS_AS_ERRORS=ON" > "$LOG" 2>&1 \
     && cmake --build --preset tidy -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1; then
    pass "clang-tidy: sources conform to the configured guideline checks"
  else
    tail -30 "$LOG"
    fail "Static analysis (clang-tidy)"
  fi
fi
fi

if enabled fuzz; then
banner "Fuzz smoke: libFuzzer target builds and survives a short run"
if ! command -v clang++ > /dev/null; then
  skip "Fuzz smoke (clang++ not installed; libFuzzer needs Clang)"
else
  rm -rf build/fuzz
  # Seeded from the committed regression corpus; new inputs go to a
  # build-tree scratch dir so the committed seeds are never mutated.
  if cmake --preset fuzz > "$LOG" 2>&1 \
     && cmake --build --preset fuzz -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1 \
     && mkdir -p build/fuzz/corpus \
     && ./build/fuzz/fuzz/tmp_fuzz -max_total_time=5 build/fuzz/corpus fuzz/corpus/tmp_fuzz > "$LOG" 2>&1; then
    runs=$(grep -Eo 'Done [0-9]+ runs' "$LOG" | grep -Eo '[0-9]+' | head -1)
    echo "fuzzer executed ${runs:-?} inputs without a crash"
    pass "Fuzz smoke: no crashes under coverage-guided input"
  else
    tail -20 "$LOG"
    fail "Fuzz smoke"
  fi
fi
fi

if enabled bench; then
banner "Benchmark harness builds and runs"
rm -rf build/bench
if cmake --preset bench > "$LOG" 2>&1 \
   && cmake --build --preset bench -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1 \
   && ./build/bench/bench/tmp_bench --benchmark_min_time=0.01s > "$LOG" 2>&1; then
  pass "Benchmark harness: builds and completes a run"
else
  tail -20 "$LOG"
  fail "Benchmark harness"
fi
fi

if enabled strict; then
banner "Strict C++ standard mode"
flag=$(grep -rho '\-std=[^ ]*' build/release/CMakeFiles/*.dir/flags.make 2>/dev/null | sort -u | head -1)
if printf '%s' "$flag" | grep -q '^-std=c++'; then
  echo "compiler flag: $flag"
  pass "Standard mode is strict ($flag, no GNU extensions)"
else
  echo "compiler flag: ${flag:-<none found>}"
  fail "Strict standard mode (expected -std=c++NN)"
fi
fi

if enabled exe; then
banner "Executable mode smoke test"
rm -rf build/debug
if cmake --preset debug -D"${PROJ}"_BUILD_EXECUTABLE=ON > "$LOG" 2>&1 \
   && cmake --build --preset debug -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1 \
   && out=$(./build/debug/"${PROJ}") && [ "$out" = "1 + 2 = 3" ]; then
  echo "program output: $out"
  pass "Executable builds and prints the expected output"
else
  tail -20 "$LOG"
  fail "Executable mode"
fi
fi

if enabled install; then
banner "Install tree purity"
rm -rf build/verify-install
if cmake --install build/release --prefix build/verify-install > "$LOG" 2>&1 \
   && [ -f build/verify-install/include/"${PROJ_LOWER}"/tmp.hpp ] \
   && [ -f build/verify-install/include/"${PROJ_LOWER}"/version.hpp ] \
   && [ -f "build/verify-install/share/doc/${PROJ}/LICENSE" ] \
   && [ -f "build/verify-install/share/doc/${PROJ}/NOTICE" ] \
   && ! find build/verify-install \( -iname '*gtest*' -o -iname '*gmock*' -o -iname '*catch2*' \) | grep -q .; then
  echo "installed files:"; find build/verify-install -type f | sed 's/^/  /'
  pass "Install tree contains only this project's files (LICENSE and NOTICE included)"
else
  fail "Install tree purity (missing files, no LICENSE/NOTICE, or test framework leaked in)"
fi
fi

if enabled canary; then
banner "Mutation canary: do the tests catch a planted bug?"
# Back up and restore via a plain file copy, so this works in containers and
# source exports where no git metadata is available.
BACKUP="$(mktemp)"
cp src/tmp.cpp "$BACKUP"
restore_canary() { cp "$BACKUP" src/tmp.cpp; rm -f "$BACKUP"; }
perl -pi -e 's/return lhs \+ rhs;/return lhs - rhs;/' src/tmp.cpp
if ! cmp -s src/tmp.cpp "$BACKUP"; then
  cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1
  if ctest --preset release > "$LOG" 2>&1; then
    restore_canary
    fail "Mutation canary (tests did NOT catch the planted bug!)"
  else
    caught=$(grep -Eo '[0-9]+ tests failed out of [0-9]+' "$LOG" | awk '{print $1}' | tail -1)
    restore_canary
    cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1
    echo "planted 'a + b -> a - b'; $caught tests failed as they should, then restored"
    pass "Mutation canary: tests caught the planted bug ($caught failures)"
  fi
else
  restore_canary
  skip "Mutation canary (could not plant the mutation; src/tmp.cpp changed?)"
fi
fi

if enabled contexts; then
banner "Required-contexts drift guard (setup.sh vs gate workflow job names)"
./scripts/check-required-contexts.sh > "$LOG" 2>&1
case $? in
  0)
    cat "$LOG"
    pass "Required contexts match the gate workflows' job names"
    ;;
  2)
    skip "Required-contexts drift guard (python3 with PyYAML not available)"
    ;;
  *)
    cat "$LOG"
    fail "Required-contexts drift guard (setup.sh and workflows disagree)"
    ;;
esac
fi

if enabled format; then
banner "clang-format check"
if command -v clang-format > /dev/null; then
  if (shopt -s nullglob globstar 2>/dev/null;
      clang-format --dry-run --Werror src/**/*.cpp include/**/*.hpp test/**/*.cpp fuzz/**/*.cpp bench/**/*.cpp > "$LOG" 2>&1); then
    pass "Sources are clang-format clean"
  else
    tail -20 "$LOG"
    fail "clang-format check"
  fi
else
  skip "clang-format check (clang-format not installed)"
fi
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
