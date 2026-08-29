cmake_minimum_required(VERSION 3.28)

#
# libFuzzer targets (Clang only: -fsanitize=fuzzer). Each *_fuzz.cpp becomes
# a fuzzer binary; run one with e.g.
#
#   ./build/fuzz/tmp_fuzz -max_total_time=60
#
# The `fuzz` preset builds these with Address+UB sanitizers so findings are
# diagnosed, not just crashed on.
#

project(
  ${CMAKE_PROJECT_NAME}Fuzz
  LANGUAGES CXX
)

if(NOT CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
  message(FATAL_ERROR "Fuzzing requires Clang (libFuzzer); configure the `fuzz` preset, which selects clang++.")
endif()

file(GLOB fuzz_sources CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/*_fuzz.cpp)

foreach(file ${fuzz_sources})
  get_filename_component(fuzz_name ${file} NAME_WE)
  add_executable(${fuzz_name} ${file})
  target_compile_features(${fuzz_name} PRIVATE cxx_std_${${CMAKE_PROJECT_NAME}_CXX_STANDARD})
  target_compile_options(${fuzz_name} PRIVATE -fsanitize=fuzzer)
  target_link_options(${fuzz_name} PRIVATE -fsanitize=fuzzer)
  target_link_libraries(${fuzz_name} PRIVATE ${CMAKE_PROJECT_NAME})
endforeach()

verbose_message("Added fuzz targets; run with -max_total_time=<seconds>.")
