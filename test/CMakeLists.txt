cmake_minimum_required(VERSION 3.28)

#
# Project details
#

project(
  ${CMAKE_PROJECT_NAME}Tests
  LANGUAGES CXX
)

verbose_message("Adding tests under ${CMAKE_PROJECT_NAME}Tests...")

#
# Load the desired unit testing framework
#
# Currently supported: GoogleTest (and GoogleMock), Catch2.
#
# `FIND_PACKAGE_ARGS` makes FetchContent try a system-installed copy first
# (`find_package`) and only download the sources when none is found.

include(FetchContent)

if(${CMAKE_PROJECT_NAME}_USE_GTEST)
  FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.18.0
    SYSTEM
    EXCLUDE_FROM_ALL
    FIND_PACKAGE_ARGS NAMES GTest
  )
  # Keep the fetched framework out of this project's install rules
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  # Prevent overriding the parent project's compiler/linker settings (MSVC)
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
  include(GoogleTest)

  if(${CMAKE_PROJECT_NAME}_USE_GOOGLE_MOCK)
    set(GOOGLE_MOCK_LIBRARIES GTest::gmock)
  endif()

  set(${CMAKE_PROJECT_NAME}_TEST_FRAMEWORK_LIBRARIES
      GTest::gtest_main ${GOOGLE_MOCK_LIBRARIES})
elseif(${CMAKE_PROJECT_NAME}_USE_CATCH2)
  FetchContent_Declare(
    Catch2
    GIT_REPOSITORY https://github.com/catchorg/Catch2.git
    GIT_TAG v3.15.3
    SYSTEM
    EXCLUDE_FROM_ALL
    FIND_PACKAGE_ARGS
  )
  FetchContent_MakeAvailable(Catch2)
  list(APPEND CMAKE_MODULE_PATH ${Catch2_SOURCE_DIR}/extras)
  include(Catch)

  set(${CMAKE_PROJECT_NAME}_TEST_FRAMEWORK_LIBRARIES Catch2::Catch2WithMain)
else()
  message(FATAL_ERROR "Unknown testing library. Please setup your desired unit testing library by using `target_link_libraries`.")
endif()

if(${CMAKE_PROJECT_NAME}_BUILD_EXECUTABLE)
  set(${CMAKE_PROJECT_NAME}_TEST_LIB ${CMAKE_PROJECT_NAME}_LIB)
else()
  set(${CMAKE_PROJECT_NAME}_TEST_LIB ${CMAKE_PROJECT_NAME})
endif()

#
# Create a test executable per test source file and register its tests
#

foreach(file ${test_sources})
  string(REGEX REPLACE "(.*/)([a-zA-Z0-9_ ]+)(\.cpp)" "\\2" test_name ${file})
  add_executable(${test_name}_Tests ${file})

  target_compile_features(${test_name}_Tests PUBLIC cxx_std_${${CMAKE_PROJECT_NAME}_CXX_STANDARD})

  target_link_libraries(
    ${test_name}_Tests
    PRIVATE
      ${${CMAKE_PROJECT_NAME}_TEST_FRAMEWORK_LIBRARIES}
      ${${CMAKE_PROJECT_NAME}_TEST_LIB}
  )

  #
  # Register the individual test cases with CTest
  #

  if(${CMAKE_PROJECT_NAME}_USE_GTEST)
    gtest_discover_tests(${test_name}_Tests)
  else()
    catch_discover_tests(${test_name}_Tests)
  endif()
endforeach()

verbose_message("Finished adding unit tests for ${CMAKE_PROJECT_NAME}.")
