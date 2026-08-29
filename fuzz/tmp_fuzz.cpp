#include <cstddef>
#include <cstdint>
#include <cstring>

#include "project/tmp.hpp"

// libFuzzer harness. Replace the body with your project's real input path —
// a parser, a decoder, a deserializer: anything that consumes untrusted
// bytes. The fuzzer mutates `data` to search for inputs that crash, overflow
// or trip a sanitizer; every finding is a bug a unit test never wrote.
extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size)
{
  if (size < 2 * sizeof(int))
  {
    return 0;
  }
  int lhs = 0;
  int rhs = 0;
  std::memcpy(&lhs, data, sizeof(int));
  std::memcpy(&rhs, data + sizeof(int), sizeof(int));

  // Guard the example against the one thing add() cannot promise: signed
  // overflow. A real target would not pre-filter; the fuzzer's job is to
  // find exactly these edges.
  if ((rhs > 0 && lhs > INT32_MAX - rhs) || (rhs < 0 && lhs < INT32_MIN - rhs))
  {
    return 0;
  }

  (void)tmp::add(lhs, rhs);
  return 0;
}
