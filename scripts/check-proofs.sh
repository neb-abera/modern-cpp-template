#!/usr/bin/env bash
#
# check-proofs.sh — prove the harnesses in proof/ with CBMC, the bounded
# model checker.
#
# Every other gate in this repository is dynamic. The tests sample inputs,
# the sanitizers watch the sampled runs, the fuzzer searches for more. CBMC
# is the static one: it hands each harness to a SAT solver and settles the
# property for every input of the type, or produces a counterexample trace.
#
#   scripts/check-proofs.sh              prove every harness
#   scripts/check-proofs.sh --self-test  prove the gate can fail
#
# --self-test plants a wrong answer at one input the unit tests never sample,
# then requires two things: CBMC must fail on it, and it must pass again once
# the source is restored. A proof gate fails by reporting success (an
# over-strong __CPROVER_assume proves a vacuous theorem and prints
# SUCCESSFUL), so a canary is not optional here.
#
# The CBMC version is pinned in the Dockerfile (ENV CBMC_VERSION) and checked
# below: a proof is only as good as the solver that checked it.

set -eu

cd "$(dirname "$0")/.."

HARNESS=proof/tmp_proof.cpp
SOURCES="src/tmp.cpp"
INCLUDE="-I include"

# Which harness gets which checks. The UB checks belong on the harness whose
# whole specification is their absence; running them on the commutativity
# harness would report the overflow the template's `add` is documented not to
# defend against, which is a statement about the placeholder API and not a
# regression this gate should re-report on every pull request.
UB_FLAGS="--signed-overflow-check --conversion-check --div-by-zero-check --pointer-check --bounds-check"

pinned_version() { sed -n 's/^ENV CBMC_VERSION=\(.*\)$/\1/p' Dockerfile; }

check_version() {
  local want have
  want="$(pinned_version)"
  if [ -z "$want" ]; then
    echo "error: the Dockerfile has no 'ENV CBMC_VERSION=' line; the proof gate would run on an unpinned solver" >&2
    return 1
  fi
  have="$(cbmc --version 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$have" != "$want" ]; then
    echo "error: cbmc $have is installed but the Dockerfile pins $want" >&2
    echo "       a proof is only as good as the solver that checked it" >&2
    return 1
  fi
  echo "cbmc $have (pinned)"
}

# One harness. $1 is the entry function, $2 onwards are extra cbmc flags.
prove() {
  local fn="$1"; shift
  # shellcheck disable=SC2086
  cbmc --cpp11 $INCLUDE "$HARNESS" $SOURCES --function "$fn" "$@"
}

# Every harness, with an explicit status. `set -e` is NOT relied on here:
# bash suspends it for the whole body of a function invoked as an `if`
# condition, which is exactly how the self-test calls this. Returning the
# status of the last command would make the canary unable to fire.
run_all() {
  local status=0
  prove proof_add_matches_wider_oracle || status=1
  prove proof_add_is_commutative || status=1
  # shellcheck disable=SC2086
  prove proof_add_no_ub_within_contract $UB_FLAGS || status=1
  if [ "$status" -eq 0 ]; then
    echo "all proof harnesses verified"
  fi
  return "$status"
}

self_test() {
  local backup planted
  backup="$(mktemp)"
  cp src/tmp.cpp "$backup"
  # Restore by file copy, never git checkout: this has to work in containers
  # and source exports with no git metadata, and it must not touch anything
  # else in the tree.
  # shellcheck disable=SC2064
  trap "cp '$backup' src/tmp.cpp; rm -f '$backup'" EXIT

  # A wrong answer at one arbitrary input. The unit tests in test/ never pass
  # 1592969455, so they stay green: that gap is the whole argument for having
  # a prover at all.
  perl -pi -e 's/  return lhs \+ rhs;/  if (lhs == 1592969455) { return 0; }\n  return lhs + rhs;/' src/tmp.cpp
  if cmp -s src/tmp.cpp "$backup"; then
    echo "self-test: could not plant the bug; has src/tmp.cpp changed?" >&2
    return 1
  fi
  planted=1

  if run_all > /dev/null 2>&1; then
    echo "self-test: CBMC did NOT fail on the planted bug. The proofs are vacuous or not reached." >&2
    return 1
  fi
  echo "self-test: CBMC failed on a planted wrong answer, as it must"

  cp "$backup" src/tmp.cpp
  planted=0
  if ! run_all > /dev/null 2>&1; then
    echo "self-test: CBMC still fails after restoring the source" >&2
    return 1
  fi
  echo "self-test: CBMC passes again once the source is restored"
  [ "$planted" -eq 0 ]
}

if ! command -v cbmc > /dev/null; then
  echo "error: cbmc not found (it ships in the Docker toolchain image)" >&2
  exit 1
fi

check_version

if [ "${1:-}" = "--self-test" ]; then
  self_test
else
  run_all
fi
