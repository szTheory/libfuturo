cmake_minimum_required(VERSION 3.25)
project(libfuturo VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
include(CTest)

include(cmake/NesturbatorProbe.cmake)

set(_required_tests "${CMAKE_BINARY_DIR}/required-tests.txt")
set(_required_targets "${CMAKE_BINARY_DIR}/required-targets.txt")
file(WRITE "${_required_tests}" "")
file(WRITE "${_required_targets}" "libfuturo\n")

function(add_required_consumer_test test_name target_name)
  add_test(NAME "${test_name}" COMMAND "$<TARGET_FILE:${target_name}>")
  set_tests_properties("${test_name}" PROPERTIES TIMEOUT 30)
  file(APPEND "${_required_tests}" "${test_name}\n")
  file(APPEND "${_required_targets}" "${target_name}\n")
endfunction()

find_package(Git QUIET)
set(LIBFUTURO_BUILD_ID "unversioned")
if(GIT_FOUND)
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" rev-parse --short=12 HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    RESULT_VARIABLE _git_result
    OUTPUT_VARIABLE _git_revision
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(_git_result EQUAL 0 AND NOT _git_revision STREQUAL "")
    set(LIBFUTURO_BUILD_ID "${_git_revision}")
    execute_process(
      COMMAND "${GIT_EXECUTABLE}" status --porcelain
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      RESULT_VARIABLE _git_status_result
      OUTPUT_VARIABLE _git_status
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )
    if(_git_status_result EQUAL 0 AND NOT _git_status STREQUAL "")
      string(APPEND LIBFUTURO_BUILD_ID "-dirty")
    endif()
  endif()
endif()

add_library(libfuturo STATIC src/synthetic.c)
target_include_directories(libfuturo PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
)
target_compile_definitions(libfuturo PRIVATE "LF_BUILD_ID=\"${LIBFUTURO_BUILD_ID}\"")

add_executable(synthetic_host examples/synthetic/main.c)
target_link_libraries(synthetic_host PRIVATE libfuturo)
add_required_consumer_test(synthetic_tracer synthetic_host)

add_executable(synthetic_session tests/synthetic_session.c)
target_link_libraries(synthetic_session PRIVATE libfuturo)
add_required_consumer_test(synthetic_session synthetic_session)
add_test(
  NAME oracle_negative_control
  COMMAND "${CMAKE_COMMAND}"
    "-DSYNTHETIC_SESSION_EXE=$<TARGET_FILE:synthetic_session>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectOracleFailure.cmake"
)
file(APPEND "${_required_tests}" "oracle_negative_control\n")
set_tests_properties(oracle_negative_control PROPERTIES TIMEOUT 15)

add_executable(synthetic_boundaries tests/synthetic_boundaries.c)
target_link_libraries(synthetic_boundaries PRIVATE libfuturo)
add_required_consumer_test(synthetic_boundaries synthetic_boundaries)

add_executable(nesturbator_probe tests/nesturbator_probe.c)
target_link_libraries(nesturbator_probe PRIVATE nesturbator::nesturbator)
target_compile_definitions(nesturbator_probe PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_probe nesturbator_probe)
set_tests_properties(nesturbator_probe PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_probe: source=2338608ab184f040620a30d17756f5e06a42d4e3 lifecycle=create,destroy result=pass"
  TIMEOUT 15
)

file(STRINGS "${_required_tests}" _registered_required_tests)
foreach(test_name IN LISTS _registered_required_tests)
  get_property(_test_timeout_is_set TEST "${test_name}" PROPERTY TIMEOUT SET)
  if(NOT _test_timeout_is_set)
    message(FATAL_ERROR
      "Required CTest '${test_name}' must have an explicit execution timeout")
  endif()
  get_property(_test_timeout TEST "${test_name}" PROPERTY TIMEOUT)
  if(NOT _test_timeout MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR
      "Required CTest '${test_name}' has invalid execution timeout '${_test_timeout}'")
  endif()
endforeach()

set(_owned_c_targets
  libfuturo synthetic_host synthetic_session synthetic_boundaries nesturbator_probe
)
foreach(target_name IN LISTS _owned_c_targets)
  target_compile_options("${target_name}" PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer
  )
endforeach()
target_link_options(synthetic_host PRIVATE -fsanitize=address,undefined)
target_link_options(synthetic_session PRIVATE -fsanitize=address,undefined)
target_link_options(synthetic_boundaries PRIVATE -fsanitize=address,undefined)
target_link_options(nesturbator_probe PRIVATE -fsanitize=address,undefined)
