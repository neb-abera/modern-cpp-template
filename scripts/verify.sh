#!/usr/bin/env bash
#
# verify.sh — run the project's full verification suite locally, with a
# running pass/fail count and a final summary. This mirrors what CI checks
# before a merge:
#
#    0. verify itself: a check whose prerequisite failed is skipped (below)
#    1. clean Release build with warnings-as-errors + full test suite
#    2. the same tests under AddressSanitizer + UndefinedBehaviorSanitizer
#    3. the same tests under ThreadSanitizer
#    4. line coverage: the same tests under the coverage preset cover src/
#       and include/ at or above the floor in coverage-floor.txt (gcovr;
#       skipped if gcovr is missing)
#    5. clang-tidy static analysis (skipped if clang-tidy is missing)
#    6. fuzz smoke: the libFuzzer harness builds and survives a short run
#    7. benchmark smoke: the Google Benchmark harness builds and runs
#    8. the compiler is really in strict C++ standard mode (no GNU extensions)
#    9. executable mode builds and runs
#   10. the install tree contains only this project's files (LICENSE and
#       NOTICE included)
#   11. size budget: the stripped release artifact fits the committed byte
#       budget (size-budget.txt)
#   12. size-budget canary: the size gate fails one byte over budget, and
#       on a missing artifact or budget
#   13. mutation canary: plant a bug and confirm the tests catch it
#   14. proofs: CBMC settles the harnesses in proof/ for every input of the
#       type, not the inputs the tests sample
#   15. proof canary: a planted bug the tests cannot see must make CBMC fail,
#       so the proofs are load-bearing rather than vacuous
#   16. required-checks drift guard: .github/required-checks, the list
#       setup.sh sends to branch protection, matches the gate workflows'
#       job names (self-test first)
#   17. sources are clang-format clean (skipped if clang-format is missing)
#   18. prose: every tracked Markdown file passes the writing rules in
#       .vale/styles/Abera (the checker first proves every rule fires on a
#       fixture and that clean prose passes; skipped if Docker is missing,
#       as inside the toolchain container, where CI's prose job covers it)
#   19. attribution: no commit on this branch credits an AI (self-test first)
#   20. setup.sh self-test: the rename, run against a copy named
#       fake-widget, leaves no template name in any tracked file (NOTICE
#       included), sends the settings and required checks, and the renamed
#       project builds and passes its tests
#   21. template parity: every file .template-parity lists is byte-identical
#       to modern-webapp-template's default branch (self-test first)
#
# VERIFY_CHECKS selects a subset by tag (default: all of them), e.g.
#   VERIFY_CHECKS="release strict exe install size size-canary canary contexts" ./scripts/verify.sh
# CI's verify-extras job uses this to run exactly the checks no dedicated CI
# job covers. The strict/install/size/size-canary/canary tags read the
# release build tree, so include release with them.
#
# A check that needs an earlier one is skipped when that one failed, and the
# skip names it. Strict mode, the install tree, the size budget and its
# canary read the release build tree. The mutation canary rebuilds it and
# needs green tests. The proof canary needs green proofs. So the report
# leads with the failure that caused the rest: a canary scored against a
# suite that already fails would count those failures as a caught bug. The
# `self` check proves it: scripts/verify.sh --self-test runs this script on
# copies of the tree with cmake, ctest and the other checkers stubbed. A
# green copy must run the mutation canary and pass. A copy that does not
# build must report the build as its one failure and run nothing that needs
# it. A copy whose tests fail must not score the canary.
#
# When GITHUB_STEP_SUMMARY is set (GitHub Actions, or exported locally) the
# final tally is also appended there as markdown; runs without it change
# nothing.
#
# Exit code 0 means everything passed.

set -u

cd "$(dirname "$0")/.." || exit 1

# verify_self_test: run this script on stubbed copies of the tree (see the
# header) and check what it ran and what it reported.
verify_self_test() {
  local dir bin failed=0 code out ran
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  bin="$dir/bin"
  mkdir -p "$bin"
  # cmake and ctest: every call is logged. The build fails when
  # STUB_BUILD=fail, and writes what strict mode and the size checks read
  # otherwise. The install writes the tree the purity check expects. The
  # tests fail when STUB_TESTS=fail, and when the mutation canary's planted
  # subtraction is in the tree.
  cat > "$bin/cmake" <<'STUB'
#!/usr/bin/env bash
printf 'cmake %s\n' "$*" >> "$STUB_LOG"
proj=$(sed -n 's/^[[:space:]]*"\([A-Za-z0-9_-]*\)"[[:space:]]*$/\1/p' CMakeLists.txt | head -1)
lower=$(printf '%s' "$proj" | tr '[:upper:]' '[:lower:]')
case "$1" in
  --build)
    if [ "${STUB_BUILD:-}" = fail ]; then echo "error: planted: expected ';' before '}' token"; exit 1; fi
    mkdir -p build/release/CMakeFiles/lib.dir
    echo "CXX_FLAGS = -std=c++26" > build/release/CMakeFiles/lib.dir/flags.make
    : > "build/release/lib$proj.a" ;;
  --install)
    args="$*"
    prefix="${args##*--prefix }"
    mkdir -p "$prefix/include/$lower" "$prefix/share/doc/$proj"
    touch "$prefix/include/$lower/tmp.hpp" "$prefix/include/$lower/version.hpp" \
      "$prefix/share/doc/$proj/LICENSE" "$prefix/share/doc/$proj/NOTICE" ;;
esac
exit 0
STUB
  cat > "$bin/ctest" <<'STUB'
#!/usr/bin/env bash
printf 'ctest %s\n' "$*" >> "$STUB_LOG"
if [ "${STUB_TESTS:-}" = fail ] || grep -q 'return lhs - rhs;' src/tmp.cpp; then
  echo "80% tests passed, 1 tests failed out of 5"
  exit 8
fi
echo "100% tests passed, 0 tests failed out of 5"
STUB
  chmod +x "$bin/cmake" "$bin/ctest"

  # run_copy <scenario> [VAR=value...]: verify.sh on a fresh copy of the
  # tree, the size checker replaced by one that passes, running the checks
  # that read the release build. Sets code, out and ran (the calls it made).
  run_copy() {
    local copy="$dir/$1"
    shift
    mkdir -p "$copy"
    tar --exclude=./build --exclude=./.git -cf - . | tar -xf - -C "$copy"
    printf '#!/bin/sh\nexit 0\n' > "$copy/scripts/check-size-budget.sh"
    : > "$copy.calls"
    code=0
    out="$(cd "$copy" && env -u GITHUB_STEP_SUMMARY PATH="$bin:$PATH" STUB_LOG="$copy.calls" NO_COLOR=1 \
      VERIFY_CHECKS="release strict install size size-canary canary" "$@" ./scripts/verify.sh 2>&1)" || code=$?
    ran="$(cat "$copy.calls")"
  }
  ok() { echo "self-test: ok: $1"; }
  flunk() { echo "self-test FAILED: $1" >&2; printf '%s\n' "$out" | tail -30 | sed 's/^/    /' >&2; failed=1; }
  check() { if "${@:2}"; then ok "$1"; else flunk "$1"; fi; }
  # shellcheck disable=SC2329  # invoked through check()
  canary_ran() { [ "$(grep -c '^ctest' <<< "$ran")" -ge 2 ]; }
  # shellcheck disable=SC2329  # invoked through check()
  canary_did_not_run() { ! canary_ran; }
  # shellcheck disable=SC2329  # invoked through check()
  not_installed() { ! grep -q '^cmake --install' <<< "$ran"; }
  failures() { printf '%s\n' "$out" | awk '/^FAILURES:/ { f = 1; next } /^NOT RUN/ { f = 0 } f && sub(/^  - /, "")'; }

  run_copy green
  check "a tree whose checks all pass exits 0 (exit $code)" [ "$code" -eq 0 ]
  check "and it ran the mutation canary" canary_ran
  check "and the install tree check" grep -q '^cmake --install' <<< "$ran"

  run_copy nobuild STUB_BUILD=fail
  check "a tree that does not build fails the run (exit $code)" [ "$code" -eq 1 ]
  check "the build is the one failure reported" [ "$(failures)" = "Release build (does not compile)" ]
  check "the install tree check never ran" not_installed
  check "and it is reported as not run, naming the build" \
    grep -q '^\[SKIP\] Install tree purity (not run: "Release build (does not compile)" failed first)' <<< "$out"
  check "so is the mutation canary" \
    grep -q '^\[SKIP\] Mutation canary (not run: "Release build (does not compile)" failed first)' <<< "$out"

  run_copy notests STUB_TESTS=fail
  check "failing tests fail the run (exit $code)" [ "$code" -eq 1 ]
  check "they are the one failure reported" [ "$(failures)" = "Release tests" ]
  check "and the mutation canary is not scored against them" canary_did_not_run
  check "it says why" grep -q '^\[SKIP\] Mutation canary (not run: "Release tests" failed first)' <<< "$out"

  if [ "$failed" -eq 0 ]; then
    echo "self-test: a green tree ran every check, a build that did not compile stopped the checks that need it and was the one failure named, and failing tests kept the canary from running"
  fi
  return "$failed"
}

if [ "${1:-}" = --self-test ]; then
  verify_self_test
  exit $?
fi

# The CMake project name, read from CMakeLists.txt, so a rename (e.g. via
# scripts/setup.sh) needs no edits here.
PROJ=$(sed -n 's/^[[:space:]]*"\([A-Za-z0-9_-]*\)"[[:space:]]*$/\1/p' CMakeLists.txt | head -1)
PROJ_LOWER=$(printf '%s' "$PROJ" | tr '[:upper:]' '[:lower:]')

# The line-coverage floor, in percent, read from coverage-floor.txt: the one
# place it is written down. CI's coverage job reads the same file, so the
# two gates cannot drift apart. Blank lines and `#` comments are ignored.
COVERAGE_FLOOR=$(grep -Ev '^[[:space:]]*(#|$)' coverage-floor.txt 2> /dev/null | tr -d '[:space:]')

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# Check tags, in run order; VERIFY_CHECKS (space-separated tags) selects a
# subset. Each check below is wrapped in `if enabled <tag>`.
ALL_CHECKS="self release asan tsan coverage tidy fuzz bench strict exe install size size-canary canary proof proof-canary contexts format prose attribution setup parity"
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
# Line-coverage percentage, e.g. "97.5%", set by the coverage check; the
# summary lines are omitted when it is empty (the check skipped or was not
# selected).
COVERAGE_PCT=""
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

# What a later check depends on, and the failed check that broke it: one
# "<key><TAB><check name>" line per broken prerequisite (see the header).
BROKEN=""
broke() { BROKEN="$BROKEN$1"$'\t'"$2"$'\n'; }
NOT_RUN=""
# blocked <key> <check> <prerequisite key>...: when a prerequisite is
# broken, skip <check> naming the failure behind it, mark <key> broken by
# the same failure for the checks after, and succeed.
blocked() {
  local key="$1" what="$2" p cause
  shift 2
  for p; do
    cause="$(printf '%s' "$BROKEN" | awk -F '\t' -v k="$p" '$1 == k { print $2; exit }')"
    if [ -n "$cause" ]; then
      broke "$key" "$cause"
      NOT_RUN="$NOT_RUN  - $what\n"
      skip "$what (not run: \"$cause\" failed first)"
      return 0
    fi
  done
  return 1
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

if enabled self; then
banner "Verify itself: a failed check stops the checks that need it"
if ./scripts/verify.sh --self-test > "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "A build that does not compile stops the checks that need it, and is the failure reported"
else
  cat "$LOG"
  fail "Verify itself (the self-test: a check ran without its prerequisite, or the report named the wrong failure)"
fi
fi

if enabled release; then
banner "Release build + full test suite (warnings as errors)"
if run_suite release "-D${PROJ}_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; pass "Release: clean build, all tests green"
elif ! grep -Eq 'tests passed|No tests were found' "$LOG"; then
  # run_suite stops before ctest when configure or the build fails.
  broke build "Release build (does not compile)"
  fail "Release build (does not compile)"
else
  count_ctest
  broke tests "Release tests"
  fail "Release tests"
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

if enabled coverage; then
banner "Line coverage: test suite under the coverage preset vs coverage-floor.txt"
if [ -z "$COVERAGE_FLOOR" ]; then
  fail "Line coverage (coverage-floor.txt is missing or holds no number)"
elif ! command -v gcovr > /dev/null; then
  skip "Line coverage (gcovr not installed; available in the Docker toolchain image)"
elif ! run_suite coverage "-D${PROJ}_WARNINGS_AS_ERRORS=ON"; then
  count_ctest; fail "Line coverage (coverage build/tests failed)"
else
  count_ctest
  # The same gcovr invocation and scope as CI's coverage job: src/ and
  # include/, tests excluded (the scope codecov.yaml measures too), failing
  # under the shared floor.
  gcovr -r . --filter "src/" --filter "include/" \
    --print-summary --fail-under-line "$COVERAGE_FLOOR" build/coverage > "$LOG" 2>&1
  gcovr_status=$?
  cat "$LOG"
  COVERAGE_PCT=$(grep -E '^lines:' "$LOG" | grep -Eo '[0-9]+(\.[0-9]+)?%' | head -1)
  if [ "$gcovr_status" -eq 0 ]; then
    pass "Line coverage: ${COVERAGE_PCT:-?} of lines, at or above the ${COVERAGE_FLOOR}% floor"
  elif [ -n "$COVERAGE_PCT" ]; then
    fail "Line coverage (${COVERAGE_PCT} of lines, under the ${COVERAGE_FLOOR}% floor)"
  else
    fail "Line coverage (gcovr failed; see its output above)"
  fi
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
if ! blocked strict "Strict standard mode" build; then
flag=$(grep -rho '\-std=[^ ]*' build/release/CMakeFiles/*.dir/flags.make 2>/dev/null | sort -u | head -1)
if printf '%s' "$flag" | grep -q '^-std=c++'; then
  echo "compiler flag: $flag"
  pass "Standard mode is strict ($flag, no GNU extensions)"
else
  echo "compiler flag: ${flag:-<none found>}"
  fail "Strict standard mode (expected -std=c++NN)"
fi
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
if blocked install "Install tree purity" build; then
  :
elif cmake --install build/release --prefix build/verify-install > "$LOG" 2>&1 \
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

# The release artifact the size checks measure: whichever form the release
# preset built (executable, static or shared library), named after the CMake
# project exactly as the build names it, so a rename needs no edits here.
release_artifact() {
  local c
  for c in "build/release/${PROJ}" "build/release/lib${PROJ}.a" "build/release/lib${PROJ}.so"; do
    if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  # Nothing built: hand the checker the default path so it fails loudly.
  printf '%s' "build/release/lib${PROJ}.a"
}

if enabled size; then
banner "Size budget: stripped release artifact vs size-budget.txt"
if [ "$(uname -s)" != "Linux" ]; then
  skip "Size budget (the budget is set for the Linux toolchain container; use make verify-docker)"
elif blocked size "Size budget" build; then
  :
elif ./scripts/check-size-budget.sh "$(release_artifact)" size-budget.txt > "$LOG" 2>&1; then
  cat "$LOG"
  pass "Size budget: the stripped release artifact fits the committed budget"
else
  cat "$LOG"
  fail "Size budget (artifact over budget, or artifact/budget missing)"
fi
fi

if enabled size-canary; then
banner "Size-budget canary: does the size gate fail when it should?"
if blocked size-canary "Size-budget canary" build; then
  :
elif ./scripts/check-size-budget.sh --self-test "$(release_artifact)" > "$LOG" 2>&1; then
  cat "$LOG"
  pass "Size-budget canary: one byte over, a missing artifact and a missing budget all fail"
else
  cat "$LOG"
  fail "Size-budget canary (the size gate did NOT fail when it should, or there was no artifact to test it on)"
fi
fi

if enabled canary; then
banner "Mutation canary: do the tests catch a planted bug?"
# Against a suite that already fails, any failure count would score as a
# caught bug, so the canary needs a build and green tests.
if ! blocked canary "Mutation canary" build tests; then
# Back up and restore via a plain file copy, so this works in containers and
# source exports where no git metadata is available.
BACKUP="$(mktemp)"
cp src/tmp.cpp "$BACKUP"
restore_canary() { cp "$BACKUP" src/tmp.cpp; rm -f "$BACKUP"; }
perl -pi -e 's/return lhs \+ rhs;/return lhs - rhs;/' src/tmp.cpp
if ! cmp -s src/tmp.cpp "$BACKUP"; then
  # The build's exit code is checked, not discarded. A planted bug that does
  # not compile leaves the previous binary in place (or none at all), and
  # ctest then fails for a reason that has nothing to do with the mutation.
  if ! cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > "$LOG" 2>&1; then
    restore_canary
    tail -20 "$LOG"
    cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > /dev/null 2>&1
    fail "Mutation canary (the planted bug did not compile, so the tests were never run against it)"
  else
    ctest --preset release > "$LOG" 2>&1
    # As with the build: a non-zero ctest exit can mean no tests ran at all,
    # so read the reported count rather than the exit code. An empty count is
    # the broken case and used to be reported as "$caught tests failed".
    caught=$(grep -Eo '[0-9]+ tests failed out of [0-9]+' "$LOG" | awk '{print $1}' | tail -1)
    total=$(grep -Eo 'tests failed out of [0-9]+' "$LOG" | awk '{print $NF}' | tail -1)
    restore_canary
    cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" > /dev/null 2>&1
    if [ -z "$total" ]; then
      tail -20 "$LOG"
      fail "Mutation canary (ctest reported no results, so the planted bug was never measured)"
    elif [ "${caught:-0}" -eq 0 ]; then
      fail "Mutation canary (tests did NOT catch the planted bug!)"
    else
      echo "planted 'a + b -> a - b'; $caught of $total tests failed as they should, then restored"
      pass "Mutation canary: tests caught the planted bug ($caught failures)"
    fi
  fi
else
  restore_canary
  skip "Mutation canary (could not plant the mutation; src/tmp.cpp changed?)"
fi
fi
fi

if enabled proof; then
banner "Proofs under CBMC (bounded model checking, all inputs)"
if ! command -v cbmc > /dev/null; then
  skip "Proofs (cbmc not installed; it ships in the Docker toolchain image)"
elif ./scripts/check-proofs.sh > "$LOG" 2>&1; then
  grep -E '^cbmc |^all proof' "$LOG" || true
  pass "CBMC: every proof harness verified for all inputs of the type"
else
  grep -E 'FAILURE|VERIFICATION|^error' "$LOG" | head -20 || tail -20 "$LOG"
  broke proof "Proofs (CBMC)"
  fail "Proofs (CBMC)"
fi
fi

if enabled proof-canary; then
banner "Proof canary: are the proofs load-bearing, or vacuous?"
# A proof gate does not fail loudly, it reports success: an over-strong
# __CPROVER_assume proves a vacuous theorem and prints SUCCESSFUL. The
# self-test plants a wrong answer the unit tests never sample, requires CBMC
# to fail on it, and requires it to pass again once the source is restored.
if ! command -v cbmc > /dev/null; then
  skip "Proof canary (cbmc not installed)"
elif blocked proof-canary "Proof canary" proof; then
  :
elif ./scripts/check-proofs.sh --self-test > "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "Proof canary: CBMC caught a planted bug the tests miss, and passed again after the restore"
else
  tail -20 "$LOG"
  fail "Proof canary (CBMC did NOT fail on the planted bug, or did not recover)"
fi
fi

if enabled contexts; then
banner "Required-checks drift guard (.github/required-checks vs the workflows' job names)"
# The self-test first: it renames a check, drops a trigger, adds an
# unlisted job and plants an unsafe name, and requires each caught.
if ./scripts/check-required-contexts.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-required-contexts.sh >> "$LOG" 2>&1; then
  cat "$LOG"
  pass "Required checks match the gate workflows' job names (and the checker caught a renamed check)"
else
  cat "$LOG"
  fail "Required-checks drift guard (a check/job mismatch, or the checker's self-test)"
fi
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

if enabled attribution; then
banner "Attribution: no commit on this branch credits an AI"
# The commit-msg hook and the Claude PreToolUse gate both run on the machine
# making the commit, so neither sees one made anywhere they are not installed.
# This is the one that runs where the merge happens. The self-test first: it
# plants a trailer and a generated-with line in throwaway repositories and
# requires both refused.
if ./scripts/check-attribution.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-attribution.sh >> "$LOG" 2>&1; then
  grep -E '^check-attribution|^attribution:' "$LOG" || true
  pass "No commit on this branch credits an AI"
else
  tail -30 "$LOG"
  fail "Attribution (a commit carries an AI credit, or a broken self-test)"
fi
fi

if enabled prose; then
banner "Prose: every tracked Markdown file passes the writing rules"
# The rules run in the Vale image the Dockerfile pins (the `vale` stage), so
# this check needs Docker. Inside the toolchain container (make
# verify-docker, CI's verify-extras job) there is none and the check skips;
# CI's prose job runs it on the runner. The self-test runs first, every
# time: one fixture carries one violation per rule and every rule must fire
# on it, another is clean and must pass, so a rule that has stopped matching
# is caught here rather than trusted.
if ! command -v docker > /dev/null; then
  skip "Prose (docker not installed; CI's prose job runs this check on the runner)"
elif ./scripts/check-prose.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-prose.sh >> "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "Prose passes .vale/styles/Abera"
else
  tail -40 "$LOG"
  fail "Prose (a rule violation in a Markdown file, or a broken self-test)"
fi
fi

if enabled setup; then
banner "setup.sh self-test: rename a copy and look for the template's names"
# Needs git, perl, cmake and a compiler, all in the toolchain image; the
# rename runs against a temporary copy and a stub gh, never this checkout
# or GitHub.
if ./scripts/setup.sh --self-test > "$LOG" 2>&1; then
  grep -E '^self-test' "$LOG" || true
  pass "setup.sh: the renamed copy names no template, builds and passes its tests"
else
  grep -vE '^    ' "$LOG" | tail -40
  fail "setup.sh self-test (a template name survived the rename, or the renamed project failed)"
fi
fi

if enabled parity; then
banner "Template parity: shared files match modern-webapp-template"
# Exit 2 is a failed fetch, an outage rather than drift; it still fails
# here, because a check that cannot run has not passed.
if ./scripts/check-template-parity.sh --self-test > "$LOG" 2>&1 \
   && ./scripts/check-template-parity.sh >> "$LOG" 2>&1; then
  grep -E '^self-test: [a-z]' "$LOG" | tail -1 || true
  pass "Every file in .template-parity matches the template"
else
  tail -30 "$LOG"
  fail "Template parity (a shared file drifted, a listed file is missing, or the template could not be fetched)"
fi
fi

# Job-summary parity: when GITHUB_STEP_SUMMARY is set (GitHub Actions, or a
# local run exporting it), append the same tally as markdown. Local runs
# without the variable are unchanged.
write_step_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### verify.sh (%d checks selected)\n\n' "$CHECKS_TOTAL"
    printf '| Checks passed | Checks failed | Checks skipped | Tests passed | Tests failed |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| %d | %d | %d | %d | %d |\n' \
      "$CHECKS_PASSED" "$CHECKS_FAILED" "$CHECKS_SKIPPED" "$TESTS_PASSED" "$TESTS_FAILED"
    if [ -n "$COVERAGE_PCT" ]; then
      printf '\nLine coverage: %s (gate: >= %s%%)\n' "$COVERAGE_PCT" "$COVERAGE_FLOOR"
    fi
    if [ "$CHECKS_FAILED" -gt 0 ]; then
      printf '\nFailed checks:\n\n'
      printf '%b' "$FAILED_NAMES"
    fi
  } >> "$GITHUB_STEP_SUMMARY" || true
}

printf '\n%s========================= VERIFICATION COMPLETE =========================%s\n' "$BOLD" "$RESET"
printf 'Checks : %s%d passed%s, %s%d failed%s, %d skipped (of %d)\n' \
  "$GREEN" "$CHECKS_PASSED" "$RESET" "$RED" "$CHECKS_FAILED" "$RESET" "$CHECKS_SKIPPED" "$CHECKS_TOTAL"
printf 'Tests  : %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$TESTS_PASSED" "$RESET" "$RED" "$TESTS_FAILED" "$RESET"
if [ -n "$COVERAGE_PCT" ]; then
  printf 'Lines  : %s covered (floor %s%%)\n' "$COVERAGE_PCT" "$COVERAGE_FLOOR"
fi
write_step_summary
if [ "$CHECKS_FAILED" -eq 0 ]; then
  printf '%s%sALL CHECKS PASSED — this build behaves as intended.%s\n' "$BOLD" "$GREEN" "$RESET"
  exit 0
else
  printf '%s%sFAILURES:%s\n' "$BOLD" "$RED" "$RESET"
  printf '%b' "$FAILED_NAMES"
  if [ -n "$NOT_RUN" ]; then
    printf '%sNOT RUN, because a check they need failed:%s\n' "$YELLOW" "$RESET"
    printf '%b' "$NOT_RUN"
  fi
  exit 1
fi
