#
# Project settings
#

option(${PROJECT_NAME}_BUILD_EXECUTABLE "Build the project as an executable, rather than a library." OFF)
option(${PROJECT_NAME}_BUILD_HEADERS_ONLY "Build the project as a header-only library." OFF)
option(${PROJECT_NAME}_USE_ALT_NAMES "Use alternative names for the project, such as naming the include directory all lowercase." ON)

#
# Compiler options
#

# C++23 is the newest standard fully supported by CMake's compiler feature
# detection across GCC, Clang and MSVC; bump to 26 once your toolchains and
# CMake support it (`cxx_std_26`).
set(${PROJECT_NAME}_CXX_STANDARD 23 CACHE STRING "The C++ standard the project targets (17, 20, 23 or 26).")

# Use `-std=c++23` rather than `-std=gnu++23`: portable standard C++, no
# compiler-specific extensions.
set(CMAKE_CXX_EXTENSIONS OFF)
option(${PROJECT_NAME}_WARNINGS_AS_ERRORS "Treat compiler warnings as errors." OFF)

#
# Unit testing
#
# Currently supporting: GoogleTest, Catch2.
#
# The chosen framework is resolved with `find_package` first and fetched with
# `FetchContent` when not installed, so no manual installation is required.

option(${PROJECT_NAME}_ENABLE_UNIT_TESTING "Enable unit tests for the projects (from the `test` subfolder)." ON)

option(${PROJECT_NAME}_USE_GTEST "Use the GoogleTest project for creating unit tests." ON)
option(${PROJECT_NAME}_USE_GOOGLE_MOCK "Use the GoogleMock project for extending the unit tests." OFF)

option(${PROJECT_NAME}_USE_CATCH2 "Use the Catch2 project for creating unit tests." OFF)

#
# Static analyzers
#
# Currently supporting: Clang-Tidy, Cppcheck.

option(${PROJECT_NAME}_ENABLE_CLANG_TIDY "Enable static analysis with Clang-Tidy." OFF)
option(${PROJECT_NAME}_ENABLE_CPPCHECK "Enable static analysis with Cppcheck." OFF)

#
# Code coverage
#

option(${PROJECT_NAME}_ENABLE_CODE_COVERAGE "Enable code coverage through GCC/Clang." OFF)
if(${PROJECT_NAME}_ENABLE_CODE_COVERAGE)
  add_compile_options(--coverage -O0 -g)
  add_link_options(--coverage)
endif()

#
# Doxygen
#

option(${PROJECT_NAME}_ENABLE_DOXYGEN "Enable Doxygen documentation builds of source." OFF)

#
# Miscelanious options
#

# Generate compile_commands.json for clang based tools
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(${PROJECT_NAME}_VERBOSE_OUTPUT "Enable verbose output, allowing for a better understanding of each step taken." ON)
option(${PROJECT_NAME}_GENERATE_EXPORT_HEADER "Create a `project_export.h` file containing all exported symbols." OFF)

# Export all symbols when building a shared library
if(BUILD_SHARED_LIBS)
  set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS OFF)
  set(CMAKE_CXX_VISIBILITY_PRESET hidden)
  set(CMAKE_VISIBILITY_INLINES_HIDDEN 1)
endif()

option(${PROJECT_NAME}_ENABLE_LTO "Enable Interprocedural Optimization, aka Link Time Optimization (LTO)." OFF)
if(${PROJECT_NAME}_ENABLE_LTO)
  include(CheckIPOSupported)
  check_ipo_supported(RESULT result OUTPUT output)
  if(result)
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
  else()
    message(SEND_ERROR "IPO is not supported: ${output}.")
  endif()
endif()

option(${PROJECT_NAME}_ENABLE_CCACHE "Enable the usage of Ccache, in order to speed up rebuild times." ON)
if(${PROJECT_NAME}_ENABLE_CCACHE)
  find_program(CCACHE_FOUND ccache)
  if(CCACHE_FOUND)
    set(CMAKE_C_COMPILER_LAUNCHER ccache)
    set(CMAKE_CXX_COMPILER_LAUNCHER ccache)
  endif()
endif()

#
# Sanitizers
#

option(${PROJECT_NAME}_ENABLE_ASAN "Enable AddressSanitizer to detect memory errors." OFF)
if(${PROJECT_NAME}_ENABLE_ASAN)
  if(MSVC)
    add_compile_options(/fsanitize=address)
  else()
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address)
  endif()
endif()

option(${PROJECT_NAME}_ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer to detect undefined behavior (GCC/Clang only)." OFF)
if(${PROJECT_NAME}_ENABLE_UBSAN AND NOT MSVC)
  add_compile_options(-fsanitize=undefined)
  add_link_options(-fsanitize=undefined)
endif()
