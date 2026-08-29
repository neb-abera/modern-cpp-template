#
# Project settings
#

option(${PROJECT_NAME}_BUILD_EXECUTABLE "Build the project as an executable, rather than a library." OFF)
option(${PROJECT_NAME}_BUILD_HEADERS_ONLY "Build the project as a header-only library." OFF)
option(${PROJECT_NAME}_USE_ALT_NAMES "Use alternative names for the project, such as naming the include directory all lowercase." ON)

#
# Compiler options
#

# C++26 needs GCC 14+ or Clang 17+; the project's Docker image ships GCC 15.
# Lower this if a toolchain you must support cannot handle it.
set(${PROJECT_NAME}_CXX_STANDARD 26 CACHE STRING "The C++ standard the project targets (17, 20, 23 or 26).")

# MSVC does not yet expose a C++26 standard mode CMake can request
# (`cxx_std_26` is unknown for it); its newest mode, /std:c++latest, is
# reached via cxx_std_23. Clamp on MSVC only, so GCC/Clang still get C++26.
# Remove this block once MSVC and CMake support cxx_std_26.
if(MSVC AND ${PROJECT_NAME}_CXX_STANDARD GREATER 23)
  message(STATUS "MSVC has no C++26 mode yet; using cxx_std_23 (/std:c++latest) on this compiler instead.")
  set(${PROJECT_NAME}_CXX_STANDARD 23)
endif()

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

option(${PROJECT_NAME}_ENABLE_TSAN "Enable ThreadSanitizer to detect data races (GCC/Clang only; incompatible with ASan)." OFF)
if(${PROJECT_NAME}_ENABLE_TSAN AND NOT MSVC)
  if(${PROJECT_NAME}_ENABLE_ASAN)
    message(FATAL_ERROR "ThreadSanitizer and AddressSanitizer cannot be combined; enable one at a time.")
  endif()
  add_compile_options(-fsanitize=thread)
  add_link_options(-fsanitize=thread)
endif()

#
# Binary hardening (OpenSSF compiler hardening baseline)
#

option(${PROJECT_NAME}_ENABLE_HARDENING "Enable exploit-mitigation compiler and linker flags." ON)
if(${PROJECT_NAME}_ENABLE_HARDENING)
  include(CheckPIESupported)
  check_pie_supported()
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)

  if(MSVC)
    # /GS (stack cookies) and ASLR-related flags are MSVC defaults, but are
    # stated explicitly so turning the option off is meaningful; /guard:cf
    # adds Control Flow Guard.
    add_compile_options(/GS /guard:cf)
    add_link_options(/DYNAMICBASE /HIGHENTROPYVA /NXCOMPAT /guard:cf)
  else()
    add_compile_options(-fstack-protector-strong -fno-strict-overflow -fno-delete-null-pointer-checks)
    # C++26-era hardened standard library: bounds and precondition checks in
    # libstdc++/libc++ from a recompile alone. The unknown macro is inert on
    # whichever library is not in use.
    add_compile_options(-D_GLIBCXX_ASSERTIONS -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST)
    # _FORTIFY_SOURCE needs optimization and conflicts with ASan.
    if(NOT ${PROJECT_NAME}_ENABLE_ASAN)
      add_compile_options($<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE>
                          $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=3>)
    endif()
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
      add_compile_options(-fstack-clash-protection)
      add_link_options(-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)
      if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
        add_compile_options(-fcf-protection=full)
      endif()
    endif()
  endif()
endif()
