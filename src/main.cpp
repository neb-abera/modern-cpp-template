#include <print>

#include "project/tmp.hpp"

int main()
{
  std::println("1 + 2 = {}", tmp::add(1, 2));
  return 0;
}
