#include "project/tmp.hpp"

#include <gtest/gtest.h>

#include <limits>
#include <tuple>

// Plain tests: pin down the behavioral contract of the unit under test so a
// regression fails loudly, and early.

TEST(TmpAddTest, AddsPositiveValues)
{
  EXPECT_EQ(tmp::add(1, 2), 3);
  EXPECT_EQ(tmp::add(100, 200), 300);
}

TEST(TmpAddTest, AddsNegativeValues)
{
  EXPECT_EQ(tmp::add(-1, -2), -3);
  EXPECT_EQ(tmp::add(-5, 3), -2);
  EXPECT_EQ(tmp::add(5, -3), 2);
}

TEST(TmpAddTest, ZeroIsTheIdentity)
{
  EXPECT_EQ(tmp::add(0, 0), 0);
  EXPECT_EQ(tmp::add(42, 0), 42);
  EXPECT_EQ(tmp::add(0, -42), -42);
}

TEST(TmpAddTest, IsCommutative)
{
  EXPECT_EQ(tmp::add(7, 13), tmp::add(13, 7));
  EXPECT_EQ(tmp::add(-7, 13), tmp::add(13, -7));
}

TEST(TmpAddTest, HandlesExtremesWithoutOverflowing)
{
  // Adding a value and its negation stays in range even at the extremes; the
  // sanitizer CI job (`ctest --preset asan`) would flag signed overflow here.
  constexpr int max = std::numeric_limits<int>::max();
  constexpr int min = std::numeric_limits<int>::min();
  EXPECT_EQ(tmp::add(max, 0), max);
  EXPECT_EQ(tmp::add(min, 0), min);
  EXPECT_EQ(tmp::add(max, -max), 0);
}

// Fixture example: share expensive or repeated setup between related tests.

class TmpAddFixture : public ::testing::Test
{
 protected:
  void SetUp() override
  {
    base_ = tmp::add(1, 1);
  }

  int base_ = 0;
};

TEST_F(TmpAddFixture, CanBuildOnFixtureState)
{
  EXPECT_EQ(base_, 2);
  EXPECT_EQ(tmp::add(base_, base_), 4);
}

// Parameterized example: table-driven cases keep edge cases enumerable and
// make adding a new failing case (TDD's "red" step) a one-line change.

class TmpAddParamTest : public ::testing::TestWithParam<std::tuple<int, int, int>>
{
};

TEST_P(TmpAddParamTest, AddsPairsFromTable)
{
  const auto [lhs, rhs, expected] = GetParam();
  EXPECT_EQ(tmp::add(lhs, rhs), expected);
}

INSTANTIATE_TEST_SUITE_P(
    EdgeCases,
    TmpAddParamTest,
    ::testing::Values(
        std::make_tuple(0, 0, 0),
        std::make_tuple(1, -1, 0),
        std::make_tuple(-1, 1, 0),
        std::make_tuple(1000000, 1000000, 2000000),
        std::make_tuple(std::numeric_limits<int>::max() - 1, 1, std::numeric_limits<int>::max())));
