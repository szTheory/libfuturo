if(NOT DEFINED NESTURBATOR_SESSION_EXE OR
   NESTURBATOR_SESSION_EXE STREQUAL "")
  message(FATAL_ERROR
    "nesturbator_save_restart: session executable was not provided")
endif()
if(NOT EXISTS "${NESTURBATOR_SESSION_EXE}")
  message(FATAL_ERROR
    "nesturbator_save_restart: executable does not exist: ${NESTURBATOR_SESSION_EXE}")
endif()

string(RANDOM LENGTH 16 ALPHABET 0123456789abcdef save_suffix)
set(save_scratch_dir
    "${CMAKE_CURRENT_BINARY_DIR}/nesturbator-save-${save_suffix}")
if(EXISTS "${save_scratch_dir}")
  message(FATAL_ERROR
    "nesturbator_save_restart: unique scratch directory already exists")
endif()
file(MAKE_DIRECTORY "${save_scratch_dir}")
if(NOT IS_DIRECTORY "${save_scratch_dir}")
  message(FATAL_ERROR
    "nesturbator_save_restart: could not create scratch directory")
endif()
set(fixture_path "${save_scratch_dir}/generated-mmc1-battery.nes")
set(save_work_dir "${save_scratch_dir}/storage")
file(MAKE_DIRECTORY "${save_work_dir}")
if(NOT IS_DIRECTORY "${save_work_dir}")
  file(REMOVE_RECURSE "${save_scratch_dir}")
  message(FATAL_ERROR
    "nesturbator_save_restart: could not create storage directory")
endif()
set(save_path "${save_work_dir}/save.bin")
macro(fail_save_test failure_message)
  file(REMOVE_RECURSE "${save_scratch_dir}")
  message(FATAL_ERROR "${failure_message}")
endmacro()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --emit-save-fixture "${fixture_path}"
  RESULT_VARIABLE fixture_result
  OUTPUT_VARIABLE fixture_stdout
  ERROR_VARIABLE fixture_stderr
  TIMEOUT 10
)
if(NOT "${fixture_result}" STREQUAL "0")
  fail_save_test(
    "nesturbator_save_restart: fixture generation failed with '${fixture_result}'\n${fixture_stdout}\n${fixture_stderr}")
endif()
set(fixture_output "${fixture_stdout}\n${fixture_stderr}")
set(expected_fixture_marker
  "nesturbator_session: emitted generated-mmc1-battery bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
string(FIND "${fixture_output}" "${expected_fixture_marker}" fixture_marker)
if(fixture_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: required generated fixture digest marker is missing or incorrect\n${fixture_output}")
endif()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E sha256sum "${fixture_path}"
  RESULT_VARIABLE hash_result
  OUTPUT_VARIABLE hash_stdout
  ERROR_VARIABLE hash_stderr
  TIMEOUT 10
)
string(FIND "${hash_stdout}"
  "2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9"
  hash_marker)
if(NOT "${hash_result}" STREQUAL "0" OR hash_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: generated fixture file digest did not match its exact marker\n${hash_stdout}\n${hash_stderr}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --save-writer "${save_work_dir}"
  RESULT_VARIABLE writer_result
  OUTPUT_VARIABLE writer_stdout
  ERROR_VARIABLE writer_stderr
  TIMEOUT 20
)
set(writer_output "${writer_stdout}\n${writer_stderr}")
string(FIND "${writer_output}"
  "nesturbator_save_writer: guest-byte=3 generation=3 committed-payload=exact idempotent-commit=byte-identical result=pass"
  writer_marker)
if(NOT "${writer_result}" STREQUAL "0" OR writer_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: successful writer or exact acknowledgment marker failed\n${writer_output}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --save-restorer "${save_path}"
  RESULT_VARIABLE committed_restorer_result
  OUTPUT_VARIABLE committed_restorer_stdout
  ERROR_VARIABLE committed_restorer_stderr
  TIMEOUT 20
)
set(committed_restorer_output
  "${committed_restorer_stdout}\n${committed_restorer_stderr}")
string(FIND "${committed_restorer_output}"
  "nesturbator_save_restorer: imported-byte=3 continuation=4"
  committed_restorer_marker)
if(NOT "${committed_restorer_result}" STREQUAL "0" OR
   committed_restorer_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: fresh restorer could not recover the successful commit\n${committed_restorer_output}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --save-failed-writer "${save_path}"
  RESULT_VARIABLE failure_result
  OUTPUT_VARIABLE failure_stdout
  ERROR_VARIABLE failure_stderr
  TIMEOUT 20
)
set(failure_output "${failure_stdout}\n${failure_stderr}")
string(FIND "${failure_output}"
  "nesturbator_save_failure_writer: prefix-write=failed-before-rename host-ack=previous-exact previous-payload=exact previous-generation=3 attempted-generation=1 stage-cleanup=pass result=pass"
  failure_marker)
if(NOT "${failure_result}" STREQUAL "0" OR failure_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: injected failure did not preserve the prior file and acknowledgment\n${failure_output}")
endif()

execute_process(
  COMMAND "${NESTURBATOR_SESSION_EXE}" --save-restorer "${save_path}"
  RESULT_VARIABLE restorer_result
  OUTPUT_VARIABLE restorer_stdout
  ERROR_VARIABLE restorer_stderr
  TIMEOUT 20
)
set(restorer_output "${restorer_stdout}\n${restorer_stderr}")
string(FIND "${restorer_output}"
  "nesturbator_save_restorer: imported-byte=3 continuation=4"
  restorer_marker)
if(NOT "${restorer_result}" STREQUAL "0" OR restorer_marker EQUAL -1)
  fail_save_test(
    "nesturbator_save_restart: fresh restorer did not recover the prior committed save\n${restorer_output}")
endif()

file(REMOVE_RECURSE "${save_scratch_dir}")
message(STATUS
  "nesturbator_save_restart: fixture-digest=sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 result=pass")
message(STATUS
  "nesturbator_save_restart: real-save-restart=writer,committed-fresh-restorer,failed-update,fresh-restorer result=pass")
message(STATUS
  "nesturbator_save_restart: failed-write-recovery=old-commit-old-ack-fresh-restorer result=pass")
