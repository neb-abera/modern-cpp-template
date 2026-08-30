cmake_minimum_required(VERSION 3.28)

#
# Google Benchmark targets. Each *_bench.cpp becomes a benchmark binary,
# built by the `bench` preset (Release, so numbers mean something).
#

project(
  ${CMAKE_PROJECT_NAME}Bench
  LANGUAGES CXX
)

include(FetchContent)

# The dependency is not ours to lint: suspend clang-tidy while the fetched
# framework compiles, restore it for this project's own targets.
set(saved_clang_tidy "${CMAKE_CXX_CLANG_TIDY}")
set(CMAKE_CXX_CLANG_TIDY "")

set(BENCHMARK_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  benchmark
  GIT_REPOSITORY https://github.com/google/benchmark.git
  # v1.9.5, pinned to its commit SHA: release tags are mutable
  GIT_TAG 192ef10025eb2c4cdd392bc502f0c852196baa48
  SYSTEM
  EXCLUDE_FROM_ALL
  FIND_PACKAGE_ARGS NAMES benchmark
)
FetchContent_MakeAvailable(benchmark)
set(CMAKE_CXX_CLANG_TIDY "${saved_clang_tidy}")

file(GLOB bench_sources CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/*_bench.cpp)

foreach(file ${bench_sources})
  get_filename_component(bench_name ${file} NAME_WE)
  add_executable(${bench_name} ${file})
  target_compile_features(${bench_name} PRIVATE cxx_std_${${CMAKE_PROJECT_NAME}_CXX_STANDARD})
  target_link_libraries(${bench_name} PRIVATE benchmark::benchmark ${CMAKE_PROJECT_NAME})
endforeach()

verbose_message("Added benchmark targets; run them from build/bench/bench/.")
