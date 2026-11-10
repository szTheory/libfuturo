cmake_minimum_required(VERSION 3.25)

foreach(_name IN ITEMS
    CONFORMANCE_EXE
    CONFORMANCE_LOAD_VARIANT_EXE
    CONFORMANCE_TIME_VARIANT_EXE)
  if(NOT DEFINED ${_name} OR "${${_name}}" STREQUAL "")
    message(FATAL_ERROR "conformance: ${_name} was not provided")
  endif()
  if(NOT EXISTS "${${_name}}")
    message(FATAL_ERROR
      "conformance: ${_name} does not exist: ${${_name}}")
  endif()
endforeach()

execute_process(
  COMMAND "${CONFORMANCE_EXE}"
  RESULT_VARIABLE _normal_result
  OUTPUT_VARIABLE _normal_stdout
  ERROR_VARIABLE _normal_stderr
  TIMEOUT 10
)
if(NOT "${_normal_result}" STREQUAL "0")
  message(FATAL_ERROR
    "conformance: normal implementation failed with '${_normal_result}'\n${_normal_stdout}\n${_normal_stderr}")
endif()
set(_normal_output "${_normal_stdout}\n${_normal_stderr}")
string(FIND "${_normal_output}"
  "conformance: LC-LOAD-01,LC-TIME-01 result=pass" _normal_marker)
if(_normal_marker EQUAL -1)
  message(FATAL_ERROR
    "conformance: normal implementation omitted the positive result marker\n${_normal_output}")
endif()

execute_process(
  COMMAND "${CONFORMANCE_LOAD_VARIANT_EXE}" --check-load-state
  RESULT_VARIABLE _load_result
  OUTPUT_VARIABLE _load_stdout
  ERROR_VARIABLE _load_stderr
  TIMEOUT 10
)
if(NOT "${_load_result}" STREQUAL "1")
  message(FATAL_ERROR
    "conformance: load-state variant returned '${_load_result}', expected assertion exit 1\n${_load_stdout}\n${_load_stderr}")
endif()
set(_load_output "${_load_stdout}\n${_load_stderr}")
string(FIND "${_load_output}"
  "conformance: LC-LOAD-01 failed unsupported-load-preservation expected=LF_OK observed=LF_INVALID_ARGUMENT"
  _load_marker)
if(_load_marker EQUAL -1)
  message(FATAL_ERROR
    "conformance: load-state variant failed outside its intended obligation or omitted the exact mismatch\n${_load_output}")
endif()

execute_process(
  COMMAND "${CONFORMANCE_TIME_VARIANT_EXE}" --check-guest-units
  RESULT_VARIABLE _time_result
  OUTPUT_VARIABLE _time_stdout
  ERROR_VARIABLE _time_stderr
  TIMEOUT 10
)
if(NOT "${_time_result}" STREQUAL "1")
  message(FATAL_ERROR
    "conformance: guest-time variant returned '${_time_result}', expected assertion exit 1\n${_time_stdout}\n${_time_stderr}")
endif()
set(_time_output "${_time_stdout}\n${_time_stderr}")
string(FIND "${_time_output}"
  "conformance: LC-TIME-01 failed guest-unit-accounting expected=requested:1,actual:1,cumulative:1,unit:LF_TIME_SYNTHETIC_STEP observed=requested:1,actual:1,cumulative:2,unit:1"
  _time_marker)
if(_time_marker EQUAL -1)
  message(FATAL_ERROR
    "conformance: guest-time variant failed outside its intended obligation or omitted the exact mismatch\n${_time_output}")
endif()

message(STATUS
  "conformance: positive API assertions pass; isolated load and guest-time violations fail with their exact obligation diagnostics")
