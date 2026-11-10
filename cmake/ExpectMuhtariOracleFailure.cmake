if(DEFINED MUHTARI_SAVE_EXE AND NOT MUHTARI_SAVE_EXE STREQUAL "")
  if(NOT EXISTS "${MUHTARI_SAVE_EXE}")
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: required consumer executable is unavailable")
  endif()
  if(NOT DEFINED MUHTARI_SAVE_FIXTURE OR
     NOT EXISTS "${MUHTARI_SAVE_FIXTURE}")
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: pinned save fixture is missing")
  endif()

  execute_process(
    COMMAND "${MUHTARI_SAVE_EXE}" --oracle-positive "${MUHTARI_SAVE_FIXTURE}"
    RESULT_VARIABLE normal_result
    OUTPUT_VARIABLE normal_stdout
    ERROR_VARIABLE normal_stderr
    TIMEOUT 30
  )
  if(NOT "${normal_result}" STREQUAL "0")
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: normal save comparator failed with '${normal_result}'\n${normal_stdout}\n${normal_stderr}")
  endif()
  set(normal_output "${normal_stdout}\n${normal_stderr}")
  string(FIND "${normal_output}"
    "muhtari_save_oracle: normal full-span progress=1/1 result=pass"
    normal_marker)
  if(normal_marker EQUAL -1)
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: normal invocation omitted its exact positive marker\n${normal_output}")
  endif()

  execute_process(
    COMMAND "${MUHTARI_SAVE_EXE}" --wrong-save-oracle "${MUHTARI_SAVE_FIXTURE}"
    RESULT_VARIABLE wrong_result
    OUTPUT_VARIABLE wrong_stdout
    ERROR_VARIABLE wrong_stderr
    TIMEOUT 30
  )
  if(NOT "${wrong_result}" STREQUAL "1")
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: altered save oracle returned '${wrong_result}', expected ordinary mismatch exit 1\n${wrong_stdout}\n${wrong_stderr}")
  endif()
  set(wrong_output "${wrong_stdout}\n${wrong_stderr}")
  string(FIND "${wrong_output}"
    "muhtari_save_oracle: full-span mismatch expected=2/2 actual=1/1"
    mismatch_marker)
  if(mismatch_marker EQUAL -1)
    message(FATAL_ERROR
      "muhtari_save_oracle_negative_control: altered save oracle omitted the exact ordinary full-span mismatch\n${wrong_output}")
  endif()

  message(STATUS
    "muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1")
  return()
endif()

if(NOT DEFINED MUHTARI_SESSION_EXE OR MUHTARI_SESSION_EXE STREQUAL "")
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: session executable was not provided")
endif()
if(NOT EXISTS "${MUHTARI_SESSION_EXE}")
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: required session executable is unavailable")
endif()

execute_process(
  COMMAND "${MUHTARI_SESSION_EXE}"
  RESULT_VARIABLE normal_result
  OUTPUT_VARIABLE normal_stdout
  ERROR_VARIABLE normal_stderr
  TIMEOUT 20
)
if(NOT "${normal_result}" STREQUAL "0")
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: normal positive invocation failed with '${normal_result}'\n${normal_stdout}\n${normal_stderr}")
endif()
set(normal_output "${normal_stdout}\n${normal_stderr}")
string(FIND "${normal_output}"
  "muhtari_session: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass"
  normal_marker)
if(normal_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: normal invocation omitted its exact positive marker\n${normal_output}")
endif()

execute_process(
  COMMAND "${MUHTARI_SESSION_EXE}" --wrong-index-oracle
  RESULT_VARIABLE wrong_result
  OUTPUT_VARIABLE wrong_stdout
  ERROR_VARIABLE wrong_stderr
  TIMEOUT 20
)
if(NOT "${wrong_result}" STREQUAL "1")
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: wrong-index child returned '${wrong_result}', expected ordinary mismatch exit 1\n${wrong_stdout}\n${wrong_stderr}")
endif()
set(wrong_output "${wrong_stdout}\n${wrong_stderr}")
string(FIND "${wrong_output}"
  "muhtari_oracle: index mismatch"
  mismatch_marker)
if(mismatch_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_oracle_negative_control: wrong-index child omitted the exact ordinary index-mismatch diagnostic\n${wrong_output}")
endif()

message(STATUS
  "muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1")
