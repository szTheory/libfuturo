foreach(required_var NESTURBATOR_SESSION_EXE SOURCE_LIBFUTURO_ARCHIVE
    SOURCE_NESTURBATOR_ARCHIVE SOURCE_SUPERVISOR SOURCE_PROCESS_HELPER
    SOURCE_ROOT SOURCE_REPORT SOURCE_COMMIT SOURCE_LIBFUTURO_BUILD_ID)
  if(NOT DEFINED ${required_var} OR "${${required_var}}" STREQUAL "")
    message(FATAL_ERROR
      "nesturbator_fresh_process_snapshot: ${required_var} was not provided")
  endif()
endforeach()
file(REMOVE "${SOURCE_REPORT}")
if(NOT DEFINED SOURCE_MODE OR "${SOURCE_MODE}" STREQUAL "")
  set(SOURCE_MODE "battery-free")
endif()
set(supervisor_mode_arg "")
if(SOURCE_MODE STREQUAL "battery")
  set(supervisor_mode_arg "--battery")
elseif(NOT SOURCE_MODE STREQUAL "battery-free")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: unsupported source mode '${SOURCE_MODE}'")
endif()

if(NOT EXISTS "${NESTURBATOR_SESSION_EXE}")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: executable does not exist: ${NESTURBATOR_SESSION_EXE}")
endif()
foreach(artifact SOURCE_LIBFUTURO_ARCHIVE SOURCE_NESTURBATOR_ARCHIVE
    SOURCE_SUPERVISOR SOURCE_PROCESS_HELPER)
  if(NOT EXISTS "${${artifact}}")
    message(FATAL_ERROR
      "nesturbator_fresh_process_snapshot: ${artifact} is missing: ${${artifact}}")
  endif()
endforeach()

if(NOT EXISTS "${SOURCE_SUPERVISOR}")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: shared supervisor does not exist: ${SOURCE_SUPERVISOR}")
endif()

execute_process(
  COMMAND /bin/sh "${SOURCE_SUPERVISOR}" "${NESTURBATOR_SESSION_EXE}"
    "${supervisor_mode_arg}"
  RESULT_VARIABLE supervisor_result
  OUTPUT_VARIABLE supervisor_output
  ERROR_VARIABLE supervisor_error
  TIMEOUT 105
)
if(NOT "${supervisor_result}" STREQUAL "0")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: supervisor failed (${supervisor_result})\n${supervisor_output}\n${supervisor_error}")
endif()
if(NOT "${supervisor_output}" MATCHES "event=supervisor-success")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: supervisor success evidence is missing\n${supervisor_output}\n${supervisor_error}")
endif()
if(SOURCE_MODE STREQUAL "battery" AND NOT "${supervisor_output}" MATCHES
    "event=battery-save-custody-r3-imported-r2-restored-r2-committed")
  message(FATAL_ERROR
    "nesturbator_battery_fresh_process_snapshot: battery save custody evidence is missing\n${supervisor_output}")
endif()

string(REPLACE "\r" "" supervisor_output "${supervisor_output}")
string(REPLACE "\n" ";" supervisor_lines "${supervisor_output}")
set(snapshot_identity "")
set(snapshot_events "")
set(snapshot_event_count 0)
set(snapshot_battery_baseline_generation "")
foreach(line IN LISTS supervisor_lines)
  if(line MATCHES "^event=snapshot-identity (.+)$")
    if(NOT snapshot_identity STREQUAL "")
      message(FATAL_ERROR
        "nesturbator_fresh_process_snapshot: duplicate runtime identity event")
    endif()
    set(snapshot_identity "${CMAKE_MATCH_1}")
  endif()
  if(line MATCHES "^event=")
    string(APPEND snapshot_events "fresh-process-event=${line}\n")
    math(EXPR snapshot_event_count "${snapshot_event_count} + 1")
  endif()
  if(line MATCHES "^event=battery-b-refusal-baseline generation=([1-9][0-9]*) media=R2 selected-save=R3 result=pass$")
    if(NOT snapshot_battery_baseline_generation STREQUAL "")
      message(FATAL_ERROR
        "nesturbator_battery_fresh_process_snapshot: duplicate battery generation baseline")
    endif()
    set(snapshot_battery_baseline_generation "${CMAKE_MATCH_1}")
  endif()
endforeach()
set(expected_content_bytes 24592)
if(SOURCE_MODE STREQUAL "battery")
  if(snapshot_battery_baseline_generation STREQUAL "")
    message(FATAL_ERROR
      "nesturbator_battery_fresh_process_snapshot: battery generation baseline is missing")
  endif()
  set(expected_content_bytes 40976)
endif()
if(snapshot_identity STREQUAL "" OR NOT snapshot_identity MATCHES
    "^envelope-version=2 header-bytes=388 total-bytes=[0-9]+ native-bytes=[0-9]+ state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=${SOURCE_LIBFUTURO_BUILD_ID} profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=${expected_content_bytes} content-sha256=[0-9a-f]+$")
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: runtime identity is missing or mismatched\n${supervisor_output}")
endif()

foreach(artifact SOURCE_LIBFUTURO_ARCHIVE SOURCE_NESTURBATOR_ARCHIVE
    NESTURBATOR_SESSION_EXE SOURCE_SUPERVISOR SOURCE_PROCESS_HELPER)
  file(SHA256 "${${artifact}}" ${artifact}_SHA256)
endforeach()
string(LENGTH "${SOURCE_COMMIT}" source_commit_length)
if(NOT SOURCE_COMMIT MATCHES "^[0-9a-f]+$" OR
   NOT source_commit_length EQUAL 40)
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: source commit is not a full Git revision")
endif()
execute_process(
  COMMAND git -C "${SOURCE_ROOT}" rev-parse HEAD
  RESULT_VARIABLE source_git_result
  OUTPUT_VARIABLE actual_source_commit
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
)
if(NOT source_git_result EQUAL 0 OR
   NOT actual_source_commit STREQUAL SOURCE_COMMIT)
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: source commit does not match the current checkout")
endif()

string(REGEX MATCH "total-bytes=([0-9]+)" _total_match "${snapshot_identity}")
set(snapshot_bytes "${CMAKE_MATCH_1}")
string(REGEX MATCH "native-bytes=([0-9]+)" _native_match "${snapshot_identity}")
set(snapshot_native_bytes "${CMAKE_MATCH_1}")
string(REGEX MATCH "content-sha256=([0-9a-f]+)" _content_match
  "${snapshot_identity}")
set(snapshot_content_digest "${CMAKE_MATCH_1}")
if(SOURCE_MODE STREQUAL "battery" AND NOT snapshot_content_digest STREQUAL
    "2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
  message(FATAL_ERROR
    "nesturbator_battery_fresh_process_snapshot: generated battery fixture digest is mismatched")
endif()
set(snapshot_checkpoint_digest "")
set(snapshot_wrong_oracle_status "")
foreach(line IN LISTS supervisor_lines)
  if(line MATCHES "^event=checkpoint-close bytes=([0-9]+) sha256=([0-9a-f]+)$")
    set(snapshot_close_bytes "${CMAKE_MATCH_1}")
    set(snapshot_checkpoint_digest "${CMAKE_MATCH_2}")
  elseif(line MATCHES "^event=b-wrong-oracle-rejected status=([1-9][0-9]*)$")
    set(snapshot_wrong_oracle_status "${CMAKE_MATCH_1}")
  endif()
endforeach()
string(LENGTH "${snapshot_content_digest}" snapshot_content_digest_length)
string(LENGTH "${snapshot_checkpoint_digest}" snapshot_checkpoint_digest_length)
if(NOT snapshot_bytes MATCHES "^[0-9]+$" OR
   NOT snapshot_native_bytes MATCHES "^[0-9]+$" OR
   NOT snapshot_content_digest MATCHES "^[0-9a-f]+$" OR
   NOT snapshot_content_digest_length EQUAL 64 OR
   NOT snapshot_close_bytes STREQUAL snapshot_bytes OR
   NOT snapshot_checkpoint_digest MATCHES "^[0-9a-f]+$" OR
   NOT snapshot_checkpoint_digest_length EQUAL 64 OR
   (SOURCE_MODE STREQUAL "battery-free" AND NOT snapshot_wrong_oracle_status STREQUAL "1"))
  message(FATAL_ERROR
    "nesturbator_fresh_process_snapshot: checkpoint or wrong-oracle evidence is incomplete")
endif()
set(wrong_oracle_report_fields "")
if(SOURCE_MODE STREQUAL "battery-free")
  string(CONCAT wrong_oracle_report_fields
    "fresh-process-wrong-oracle=rejected\n"
    "fresh-process-wrong-oracle-status=${snapshot_wrong_oracle_status}\n")
endif()
set(battery_report_fields "")
set(battery_source_identity_fields "")
if(SOURCE_MODE STREQUAL "battery")
  execute_process(
    COMMAND git -C "${SOURCE_ROOT}" status --porcelain=v1 --untracked-files=all
    RESULT_VARIABLE source_status_result
    OUTPUT_VARIABLE source_status_output
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  string(RANDOM LENGTH 16 ALPHABET 0123456789abcdef source_diff_nonce)
  set(source_diff_path "${SOURCE_REPORT}.tracked-diff-${source_diff_nonce}")
  execute_process(
    COMMAND git -C "${SOURCE_ROOT}" diff --binary HEAD --
    RESULT_VARIABLE source_diff_result
    OUTPUT_FILE "${source_diff_path}"
    ERROR_QUIET
  )
  if(NOT source_status_result EQUAL 0 OR NOT source_diff_result EQUAL 0 OR
     NOT EXISTS "${source_diff_path}")
    file(REMOVE "${source_diff_path}")
    message(FATAL_ERROR
      "nesturbator_battery_fresh_process_snapshot: source worktree identity is unavailable")
  endif()
  file(SHA256 "${source_diff_path}" source_worktree_fingerprint)
  file(REMOVE "${source_diff_path}")
  set(source_worktree "clean")
  if(NOT source_status_output STREQUAL "")
    set(source_worktree "dirty")
  endif()
  string(CONCAT battery_source_identity_fields
    "source_worktree=${source_worktree}\n"
    "source_worktree_fingerprint=sha256:${source_worktree_fingerprint}\n")
  string(CONCAT battery_report_fields
    "battery-fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9\n"
    "battery-fresh-process-route=Darwin/arm64 source-build\n"
    "battery-fresh-process-save-custody=R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack\n"
    "battery-fresh-process-result=R2-captured,R3-committed-and-imported-before-advance,R2-restored,full-media-and-save-custody,replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,refusal-baseline-generation=${snapshot_battery_baseline_generation} result=pass\n")
endif()
set(source_report_format "libfuturo-source-fresh-process-snapshot-v1")
if(SOURCE_MODE STREQUAL "battery")
  set(source_report_format "libfuturo-source-battery-fresh-process-snapshot-v1")
endif()
string(CONCAT source_report
  "format=${source_report_format}\n"
  "source_commit=${SOURCE_COMMIT}\n"
  "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
  "${battery_source_identity_fields}"
  "fresh-process-source-commit=${SOURCE_COMMIT}\n"
  "fresh-process-core-release=v0.1.12\n"
  "fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
  "fresh-process-libfuturo-build-id=${SOURCE_LIBFUTURO_BUILD_ID}\n"
  "fresh-process-target=Darwin/arm64\n"
  "fresh-process-route=Darwin/arm64 source-build\n"
  "fresh-process-status=passed\n"
  "fresh-process-a-exit=0\n"
  "fresh-process-b-exit=0\n"
  "${wrong_oracle_report_fields}"
  "fresh-process-checkpoint-bytes=${snapshot_bytes}\n"
  "fresh-process-checkpoint-sha256=sha256:${snapshot_checkpoint_digest}\n"
  "fresh-process-content-sha256=sha256:${snapshot_content_digest}\n"
  "fresh-process-runtime-identity=${snapshot_identity}\n"
  "fresh-process-event-count=${snapshot_event_count}\n"
  "fresh-process-result=separate-A-and-B,close-exit-before-restore,literal-continuation result=pass\n"
  "${battery_report_fields}"
  "fresh-process-libfuturo-artifact-sha256=sha256:${SOURCE_LIBFUTURO_ARCHIVE_SHA256}\n"
  "fresh-process-core-artifact-sha256=sha256:${SOURCE_NESTURBATOR_ARCHIVE_SHA256}\n"
  "fresh-process-consumer-artifact-sha256=sha256:${NESTURBATOR_SESSION_EXE_SHA256}\n"
  "fresh-process-supervisor-artifact-sha256=sha256:${SOURCE_SUPERVISOR_SHA256}\n"
  "fresh-process-helper-artifact-sha256=sha256:${SOURCE_PROCESS_HELPER_SHA256}\n"
  "${snapshot_events}")
file(WRITE "${SOURCE_REPORT}" "${source_report}")
message(STATUS "${supervisor_output}")
if(SOURCE_MODE STREQUAL "battery")
  message(STATUS "nesturbator_battery_fresh_process_snapshot: result=pass")
endif()
