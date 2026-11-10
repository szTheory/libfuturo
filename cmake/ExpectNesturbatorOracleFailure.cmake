if(NOT DEFINED NESTURBATOR_SESSION_EXE OR
   NESTURBATOR_SESSION_EXE STREQUAL "")
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: session executable was not provided")
endif()
if(NOT EXISTS "${NESTURBATOR_SESSION_EXE}")
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: executable does not exist: ${NESTURBATOR_SESSION_EXE}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}"
  RESULT_VARIABLE normal_result
  OUTPUT_VARIABLE normal_stdout
  ERROR_VARIABLE normal_stderr
  TIMEOUT 10
)
if(NOT "${normal_result}" STREQUAL "0")
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: normal positive invocation failed with '${normal_result}'\n${normal_stdout}\n${normal_stderr}")
endif()
set(normal_output "${normal_stdout}\n${normal_stderr}")
string(FIND
  "${normal_output}"
  "nesturbator_session: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom load,input,frame,av,close result=pass"
  normal_marker
)
if(normal_marker EQUAL -1)
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: normal positive invocation omitted its exact success marker\n${normal_output}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --wrong-expected-video
  RESULT_VARIABLE wrong_result
  OUTPUT_VARIABLE wrong_stdout
  ERROR_VARIABLE wrong_stderr
  TIMEOUT 10
)
if(NOT "${wrong_result}" STREQUAL "1")
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: wrong expectation returned '${wrong_result}', expected ordinary mismatch exit 1\n${wrong_stdout}\n${wrong_stderr}")
endif()
set(wrong_output "${wrong_stdout}\n${wrong_stderr}")
string(FIND
  "${wrong_output}"
  "nesturbator_session: video mismatch row=0 pixel=0 channel=R expected=0x68 actual=0x69"
  mismatch_marker
)
if(mismatch_marker EQUAL -1)
  message(FATAL_ERROR
    "nesturbator_oracle_negative_control: wrong expectation did not report the exact literal RGB mismatch\n${wrong_output}")
endif()

message(STATUS
  "nesturbator_oracle_negative_control: detected expected RGB mismatch (normal exit 0, wrong exit 1)")
