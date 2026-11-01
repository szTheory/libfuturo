if(NOT DEFINED SYNTHETIC_SESSION_EXE OR SYNTHETIC_SESSION_EXE STREQUAL "")
  message(FATAL_ERROR "oracle_negative_control: synthetic_session executable was not provided")
endif()
if(NOT EXISTS "${SYNTHETIC_SESSION_EXE}")
  message(FATAL_ERROR "oracle_negative_control: executable does not exist: ${SYNTHETIC_SESSION_EXE}")
endif()

execute_process(
  COMMAND "${SYNTHETIC_SESSION_EXE}"
  RESULT_VARIABLE normal_result
  OUTPUT_VARIABLE normal_stdout
  ERROR_VARIABLE normal_stderr
  TIMEOUT 5
)
if(NOT "${normal_result}" STREQUAL "0")
  message(FATAL_ERROR
    "oracle_negative_control: normal positive invocation failed with '${normal_result}'\n${normal_stdout}\n${normal_stderr}"
  )
endif()
set(normal_output "${normal_stdout}\n${normal_stderr}")
string(FIND "${normal_output}" "synthetic_session: three literal session rows passed" normal_marker)
if(normal_marker EQUAL -1)
  message(FATAL_ERROR
    "oracle_negative_control: normal positive invocation omitted its success marker\n${normal_output}"
  )
endif()

execute_process(
  COMMAND "${SYNTHETIC_SESSION_EXE}" --wrong-expected-video
  RESULT_VARIABLE wrong_result
  OUTPUT_VARIABLE wrong_stdout
  ERROR_VARIABLE wrong_stderr
  TIMEOUT 5
)
if(NOT "${wrong_result}" STREQUAL "1")
  message(FATAL_ERROR
    "oracle_negative_control: wrong expectation returned '${wrong_result}', expected ordinary mismatch exit 1\n${wrong_stdout}\n${wrong_stderr}"
  )
endif()
set(wrong_output "${wrong_stdout}\n${wrong_stderr}")
string(FIND
  "${wrong_output}"
  "synthetic_session: video mismatch at row 2 pixel 3 expected=13 actual=12"
  mismatch_marker
)
if(mismatch_marker EQUAL -1)
  message(FATAL_ERROR
    "oracle_negative_control: wrong expectation did not report the exact video mismatch\n${wrong_output}"
  )
endif()

message(STATUS "oracle_negative_control: detected expected video mismatch (normal exit 0, wrong exit 1)")
