#include <benchmark/benchmark.h>

#include "project/tmp.hpp"

// Google Benchmark harness. Replace with benchmarks of your project's hot
// paths; run with the `bench` preset:
//
//   cmake --preset bench && cmake --build --preset bench -j
//   ./build/bench/bench/tmp_bench
//
// Benchmarks are a harness, not a CI gate: shared runners make timings
// noise, so CI only proves the harness builds and runs. Compare numbers on
// quiet, identical hardware.
static void BM_add(benchmark::State& state)
{
  int lhs = static_cast<int>(state.range(0));
  int rhs = 42;
  for (auto _ : state)
  {
    benchmark::DoNotOptimize(tmp::add(lhs, rhs));
  }
}
BENCHMARK(BM_add)->Arg(1)->Arg(1 << 20);

BENCHMARK_MAIN();
