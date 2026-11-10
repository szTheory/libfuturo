cmake_minimum_required(VERSION 3.25)

foreach(_required_var IN ITEMS MUHTARI_SESSION_EXE MUHTARI_HOST_EXE
    MUHTARI_TEST_ROOT)
  if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
    message(FATAL_ERROR
      "muhtari_example: required variable ${_required_var} is missing")
  endif()
endforeach()
foreach(_executable IN ITEMS "${MUHTARI_SESSION_EXE}" "${MUHTARI_HOST_EXE}")
  if(NOT EXISTS "${_executable}")
    message(FATAL_ERROR
      "muhtari_example: required executable is missing: ${_executable}")
  endif()
endforeach()

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _scratch_suffix)
set(_scratch_root "${MUHTARI_TEST_ROOT}/muhtari-example-${_scratch_suffix}")
if(EXISTS "${_scratch_root}")
  message(FATAL_ERROR "muhtari_example: unique scratch directory already exists")
endif()
file(MAKE_DIRECTORY "${_scratch_root}")
set(_fixture_path "${_scratch_root}/owned-diagnostic.a78")

macro(fail_example message_text)
  file(REMOVE_RECURSE "${_scratch_root}")
  message(FATAL_ERROR "${message_text}")
endmacro()

execute_process(
  COMMAND "${MUHTARI_SESSION_EXE}" --emit-fixture "${_fixture_path}"
  RESULT_VARIABLE _fixture_result
  OUTPUT_VARIABLE _fixture_stdout
  ERROR_VARIABLE _fixture_stderr
  TIMEOUT 15
)
set(_fixture_output "${_fixture_stdout}\n${_fixture_stderr}")
set(_fixture_marker
  "muhtari_fixture: bytes=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass")
string(FIND "${_fixture_output}" "${_fixture_marker}" _fixture_marker_index)
if(NOT "${_fixture_result}" STREQUAL "0" OR _fixture_marker_index EQUAL -1)
  fail_example(
    "muhtari_example: owned fixture generation failed or provenance marker was missing\n${_fixture_output}")
endif()
if(NOT EXISTS "${_fixture_path}")
  fail_example("muhtari_example: fixture emitter did not create its output")
endif()
file(SIZE "${_fixture_path}" _fixture_size)
file(SHA256 "${_fixture_path}" _fixture_sha256)
if(NOT _fixture_size EQUAL 16512 OR NOT _fixture_sha256 STREQUAL
    "783bcf1c6dd15433451c4d05f03bf8b7cd4d1923fb24cc50ee80548a5a904256")
  fail_example(
    "muhtari_example: generated fixture bytes or SHA-256 did not match the owned diagnostic")
endif()

execute_process(
  COMMAND "${MUHTARI_HOST_EXE}" "${_fixture_path}"
  RESULT_VARIABLE _example_result
  OUTPUT_VARIABLE _example_stdout
  ERROR_VARIABLE _example_stderr
  TIMEOUT 30
)
set(_example_output "${_example_stdout}\n${_example_stderr}")
set(_example_marker
  "muhtari_host: profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k intervals=partial-54,steady-801 video=INDEX8 raw=yes ownership=host result=pass")
string(FIND "${_example_output}" "${_example_marker}" _example_marker_index)
if(NOT "${_example_result}" STREQUAL "0" OR _example_marker_index EQUAL -1)
  fail_example(
    "muhtari_example: public Muhtari example failed or exact completion marker was missing\n${_example_output}")
endif()

file(REMOVE_RECURSE "${_scratch_root}")
message(STATUS
  "muhtari_example: fixture=owned-a78-linear-16k bytes=16512 sha256=783bcf1c6dd15433451c4d05f03bf8b7cd4d1923fb24cc50ee80548a5a904256 source=project-authored-C-generator license=Apache-2.0 example=partial-and-steady-public-session result=pass")
