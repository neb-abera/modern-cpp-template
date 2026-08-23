#include "project/tmp.hpp"

#include <gtest/gtest.h>

TEST(TmpAddTest, CheckValues)
{
  ASSERT_EQ(tmp::add(1, 2), 3);
  EXPECT_TRUE(true);
}
