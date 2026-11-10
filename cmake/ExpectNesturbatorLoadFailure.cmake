if(NOT DEFINED NESTURBATOR_LOAD_CORPUS_EXE OR
   NOT EXISTS "${NESTURBATOR_LOAD_CORPUS_EXE}")
  message(FATAL_ERROR "nesturbator load corpus executable is missing")
endif()

execute_process(
  COMMAND "${NESTURBATOR_LOAD_CORPUS_EXE}" --tracer
  RESULT_VARIABLE tracer_result
  OUTPUT_VARIABLE tracer_stdout
  ERROR_VARIABLE tracer_stderr
  TIMEOUT 15
)
set(tracer_output "${tracer_stdout}${tracer_stderr}")
set(tracer_marker
  "nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=tracer assertions=complete cleanup=complete result=pass")
if(NOT "${tracer_result}" STREQUAL "0" OR
   NOT "${tracer_output}" MATCHES "${tracer_marker}")
  message(FATAL_ERROR
    "normal tracer child failed (result=${tracer_result}):\n${tracer_output}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_LOAD_CORPUS_EXE}" --wrong-status
  RESULT_VARIABLE wrong_status_result
  OUTPUT_VARIABLE wrong_status_stdout
  ERROR_VARIABLE wrong_status_stderr
  TIMEOUT 15
)
set(wrong_status_output "${wrong_status_stdout}${wrong_status_stderr}")
if(NOT "${wrong_status_result}" STREQUAL "1" OR
   NOT "${wrong_status_output}" MATCHES
       "load_corpus: status_mismatch case=H01-01 expected=0 actual=1")
  set(wrong_status_valid FALSE)
else()
  set(wrong_status_valid TRUE)
endif()

execute_process(
  COMMAND "${NESTURBATOR_LOAD_CORPUS_EXE}" --diverge-state
  RESULT_VARIABLE diverge_result
  OUTPUT_VARIABLE diverge_stdout
  ERROR_VARIABLE diverge_stderr
  TIMEOUT 15
)
set(diverge_output "${diverge_stdout}${diverge_stderr}")
if(NOT "${diverge_result}" STREQUAL "1" OR
   NOT "${diverge_output}" MATCHES
       "load_corpus: preservation_mismatch case=H01-01 field=media_bytes offset=0")
  set(diverge_valid FALSE)
else()
  set(diverge_valid TRUE)
endif()
if(NOT wrong_status_valid OR NOT diverge_valid)
  message(FATAL_ERROR
    "calibration children did not produce the planned ordinary comparisons:\nwrong-status result=${wrong_status_result}:\n${wrong_status_output}\ndivergence result=${diverge_result}:\n${diverge_output}")
endif()

message(STATUS
  "nesturbator_load_oracle_controls: normal=pass wrong-status=ordinary-mismatch divergence=media-bytes offset=0 result=pass")
