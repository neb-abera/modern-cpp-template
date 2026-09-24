// Proof harnesses for CBMC, the bounded model checker. Built and checked by
// scripts/check-proofs.sh, which is a verify.sh check and a CI job.
//
// The difference between this file and test/ is the quantifier. A unit test
// asserts something about the inputs it names. CBMC asserts it about every
// input of the type, by handing the property to a SAT solver. `nondet_int()`
// is not a random value: it is an unconstrained one, and the solver searches
// the whole space for a counterexample.
//
// CBMC also instruments every operation that can be undefined: signed
// overflow, division by zero, out-of-bounds indexing, invalid pointer
// dereference. So a harness with no explicit assertion still proves
// something, and the flags in check-proofs.sh choose which classes to check.

#include <climits>

#include "project/tmp.hpp"

// Provided by CBMC's front end, not linked from anywhere.
extern "C" int nondet_int();

// `add` is the sum, for every input pair where the sum is representable.
//
// The precondition is the one the fuzz harness in fuzz/tmp_fuzz.cpp already
// names: `add` takes two ints and returns an int, so it cannot promise
// anything when the true sum does not fit. __CPROVER_assume narrows the
// solver's search to the inputs where the contract holds, which is the
// C++ equivalent of Kani's kani::assume.
//
// `long long` is the oracle. It is strictly wider than `int` on every
// platform this project supports, so the true sum always fits it and the
// comparison is exact rather than another overflowing addition.
void proof_add_matches_wider_oracle()
{
  const int lhs = nondet_int();
  const int rhs = nondet_int();

  const long long exact = static_cast<long long>(lhs) + static_cast<long long>(rhs);
  __CPROVER_assume(exact >= INT_MIN && exact <= INT_MAX);

  __CPROVER_assert(static_cast<long long>(tmp::add(lhs, rhs)) == exact,
                   "add returns the exact sum whenever it is representable");
}

// `add` is commutative wherever its contract holds.
//
// The precondition is the same one as above, and it is not optional: outside
// the contract both calls overflow, which is undefined, and "the two
// undefined results agree" is not a property worth proving. CBMC 6 reports
// the overflow here even without --signed-overflow-check, which is how the
// need for this assume was found.
void proof_add_is_commutative()
{
  const int lhs = nondet_int();
  const int rhs = nondet_int();

  const long long exact = static_cast<long long>(lhs) + static_cast<long long>(rhs);
  __CPROVER_assume(exact >= INT_MIN && exact <= INT_MAX);

  __CPROVER_assert(tmp::add(lhs, rhs) == tmp::add(rhs, lhs),
                   "add is commutative");
}

// `add` has no undefined behaviour given its precondition.
//
// Nothing is asserted. check-proofs.sh runs this harness with
// --signed-overflow-check and the other UB checks on, so the body is the
// whole specification: CBMC must prove every inserted check unreachable.
//
// Without the assume, this harness FAILS, and that is correct. `int + int`
// overflows and the template's `add` does not defend against it. The fuzz
// harness documents the same limitation. Widening the API is a design change
// to the placeholder, not something this gate should hide, so the precondition
// is written down here where a reader will see it.
void proof_add_no_ub_within_contract()
{
  const int lhs = nondet_int();
  const int rhs = nondet_int();

  const long long exact = static_cast<long long>(lhs) + static_cast<long long>(rhs);
  __CPROVER_assume(exact >= INT_MIN && exact <= INT_MAX);

  (void)tmp::add(lhs, rhs);
}
