cmake_minimum_required(VERSION 3.25)

if(NOT DEFINED PROJECT_ROOT OR NOT EXISTS "${PROJECT_ROOT}/cmake/ValidateMuhtariApi8Results.cmake")
  message(FATAL_ERROR "PROJECT_ROOT must identify the checkout's API 8 validator")
endif()
include("${PROJECT_ROOT}/cmake/ValidateMuhtariApi8Results.cmake")

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _nonce)
set(_root "${CMAKE_CURRENT_BINARY_DIR}/muhtari-api8-result-controls-${_nonce}")
file(MAKE_DIRECTORY "${_root}/baseline")
set(_source_report "${_root}/source-route.report")
set(_installed_report "${_root}/installed-route.report")
api8_create_smoke_fixture("${_root}" source "${_source_report}")
api8_create_smoke_fixture("${_root}" installed "${_installed_report}")
file(COPY_FILE "${_source_report}" "${_root}/baseline/source-route.report")
file(COPY_FILE "${_installed_report}" "${_root}/baseline/installed-route.report")
file(COPY_FILE "${_root}/source-route-report-identity.txt"
  "${_root}/baseline/source-route-report-identity.txt")
file(COPY_FILE "${_root}/installed-route-report-identity.txt"
  "${_root}/baseline/installed-route-report-identity.txt")
execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_directory
  "${_root}/source/artifacts" "${_root}/baseline/source-artifacts"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_directory
  "${_root}/installed/artifacts" "${_root}/baseline/installed-artifacts"
  COMMAND_ERROR_IS_FATAL ANY)

function(restore_pair)
  foreach(_name IN ITEMS source installed)
    file(COPY_FILE "${_root}/baseline/${_name}-route.report"
      "${_root}/${_name}-route.report")
    file(COPY_FILE "${_root}/baseline/${_name}-route-report-identity.txt"
      "${_root}/${_name}-route-report-identity.txt")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_directory
      "${_root}/baseline/${_name}-artifacts" "${_root}/${_name}/artifacts"
      COMMAND_ERROR_IS_FATAL ANY)
  endforeach()
endfunction()

function(assert_baseline name)
  api8_validate_pair("${_root}" "${_source_report}" "${_installed_report}"
    api8-smoke _valid _reason)
  if(NOT _valid)
    message(FATAL_ERROR "control ${name} has no passing positive baseline: ${_reason}")
  endif()
endfunction()

function(refresh_report_identity route)
  file(SHA256 "${_root}/${route}-route.report" _hash)
  file(WRITE "${_root}/${route}-route-report-identity.txt"
    "report_sha256=sha256:${_hash}\n")
endfunction()

function(expect_rejected name)
  api8_validate_pair("${_root}" "${_source_report}" "${_installed_report}"
    api8-smoke _valid _reason)
  if(_valid)
    message(FATAL_ERROR "control ${name} reached production validator but was accepted")
  endif()
  message(STATUS "api8 evidence mutation rejected: ${name} (${_reason})")
endfunction()

function(mutate_report name route old new)
  restore_pair()
  assert_baseline("${name}")
  set(_path "${_root}/${route}-route.report")
  file(READ "${_path}" _report)
  string(REPLACE "${old}" "${new}" _changed "${_report}")
  if(_changed STREQUAL _report)
    message(FATAL_ERROR "control ${name} could not find its one-field mutation target")
  endif()
  file(WRITE "${_path}" "${_changed}")
  refresh_report_identity("${route}")
  expect_rejected("${name}")
endfunction()

function(mutate_artifact name route artifact_name old new hash_key)
  restore_pair()
  assert_baseline("${name}")
  set(_artifact "${_root}/${route}/artifacts/${artifact_name}.dat")
  file(READ "${_artifact}" _contents)
  string(REPLACE "${old}" "${new}" _changed "${_contents}")
  if(_changed STREQUAL _contents)
    message(FATAL_ERROR "control ${name} could not find its artifact mutation target")
  endif()
  file(WRITE "${_artifact}" "${_changed}")
  file(SHA256 "${_artifact}" _artifact_hash)
  set(_report_path "${_root}/${route}-route.report")
  file(READ "${_report_path}" _report)
  string(REGEX REPLACE "${hash_key}=sha256:[0-9a-f]+"
    "${hash_key}=sha256:${_artifact_hash}" _report "${_report}")
  file(WRITE "${_report_path}" "${_report}")
  refresh_report_identity("${route}")
  expect_rejected("${name}")
endfunction()

function(mutate_artifact_without_report name route artifact_name old new)
  restore_pair()
  assert_baseline("${name}")
  set(_artifact "${_root}/${route}/artifacts/${artifact_name}.dat")
  file(READ "${_artifact}" _contents)
  string(REPLACE "${old}" "${new}" _changed "${_contents}")
  if(_changed STREQUAL _contents)
    message(FATAL_ERROR "control ${name} could not find its artifact mutation target")
  endif()
  file(WRITE "${_artifact}" "${_changed}")
  expect_rejected("${name}")
endfunction()

assert_baseline(initial-positive-pair)

mutate_report(duplicate-route-key source "route=source\n" "route=source\nroute=source\n")
mutate_report(wrong-run-id installed "run_id=api8-smoke\n" "run_id=api8-stale\n")
mutate_report(failed-ctest source "ctest_exit_status=0\n" "ctest_exit_status=8\n")
mutate_report(timed-out-process installed "ctest_timed_out=no\n" "ctest_timed_out=yes\n")
mutate_report(absolute-private-artifact-ref source
  "libfuturo_ref=source/artifacts/libfuturo.dat"
  "libfuturo_ref=/private/tmp/libfuturo.a")
mutate_report(missing-a-exit installed
  "lifecycle_event=verified_lifecycle=event=a-exit status=0\n" "")
mutate_report(reordered-checkpoint-and-import source
  "lifecycle_event=verified_lifecycle=event=selected-save-imported-r3 sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bytes=35176 generation=0 before-positive-advance=pass result=pass\nlifecycle_event=verified_lifecycle=event=battery-restore-r2 bytes=34816 generation=1 selected-r3-preserved=pass result=pass\n"
  "lifecycle_event=verified_lifecycle=event=battery-restore-r2 bytes=34816 generation=1 selected-r3-preserved=pass result=pass\nlifecycle_event=verified_lifecycle=event=selected-save-imported-r3 sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bytes=35176 generation=0 before-positive-advance=pass result=pass\n")
mutate_report(missing-semantic-invalid-refusal installed
  "lifecycle_event=verified_lifecycle=event=battery-b-refusal name=native_semantic_invalid status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
  "")
mutate_report(duplicate-refusal source
  "lifecycle_event=verified_lifecycle=event=battery-b-refusal name=zero_extent status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
  "lifecycle_event=verified_lifecycle=event=battery-b-refusal name=zero_extent status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\nlifecycle_event=verified_lifecycle=event=battery-b-refusal name=zero_extent status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n")
mutate_report(duplicate-test-result installed
  "test_result=muhtari_api8_profile|passed\n"
  "test_result=muhtari_api8_profile|passed\ntest_result=muhtari_api8_profile|passed\n")
mutate_report(wrong-source-installed-fixture-identity installed
  "fixture_sha256=sha256:2222222222222222222222222222222222222222222222222222222222222222\n"
  "fixture_sha256=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
mutate_report(swapped-route source "route=source\n" "route=installed\n")
mutate_report(missing-pre-rename-recovery installed
  "lifecycle_event=verified_lifecycle=event=pre-rename-failure-preserved-r3 sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bytes=35176 stage-cleanup=pass result=pass\n"
  "")
mutate_report(wrong-replay-audio installed
  "pcm=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f"
  "pcm=wrong")
mutate_report(wrong-replay-frame source "frame=3 video=" "frame=4 video=")
mutate_report(wrong-replay-video installed
  "video=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225"
  "video=wrong")
mutate_report(wrong-full-span-literal source
  "battery=full-span-r3" "battery=short-span-r3")
mutate_report(wrong-effective-options installed
  "effective_options=none\n" "effective_options=other\n")
mutate_report(wrong-pending-boundary source
  "snapshot_boundary=R2-frame2-pending-savekey-write\n"
  "snapshot_boundary=R2-frame2-completed-savekey-write\n")
mutate_report(wrong-replay-battery-digest installed
  "replay_battery_sha256=495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583\n"
  "replay_battery_sha256=595ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583\n")

mutate_artifact(missing-current-test-registration source ctest_inventory
  "{\"name\":\"muhtari_api8_source_fresh_process\"}," "" ctest_inventory_sha256)
mutate_artifact(disabled-current-test-registration source ctest_inventory
  "{\"name\":\"muhtari_api8_profile\"}"
  "{\"name\":\"muhtari_api8_profile\",\"properties\":[{\"name\":\"DISABLED\",\"value\":true}]}"
  ctest_inventory_sha256)
mutate_artifact(junit-skipped-current-test installed ctest_junit
  "skipped=\"0\"" "skipped=\"1\"" ctest_junit_sha256)
mutate_artifact(process-timeout-current-test installed ctest_process_facts
  "timed_out=no" "timed_out=yes" ctest_process_facts_sha256)
mutate_artifact(current-log-failure source ctest_log
  "100% tests passed" "90% tests passed" ctest_log_sha256)
mutate_artifact(missing-wrong-oracle-controls installed ctest_log
  "frame,video,audio,media,capability denied" "frame,video" ctest_log_sha256)
mutate_artifact_without_report(current-archive-bytes-mismatch installed muhtari
  "controlled artifact installed muhtari" "altered artifact installed muhtari")
mutate_artifact_without_report(swapped-source-core-archive installed muhtari
  "controlled artifact installed muhtari" "controlled artifact source muhtari")
mutate_artifact_without_report(swapped-source-consumer installed consumer
  "controlled artifact installed consumer" "controlled artifact source consumer")

restore_pair()
assert_baseline(report-identity-hash)
file(WRITE "${_root}/source-route-report-identity.txt" "report_sha256=sha256:bad\n")
expect_rejected(report-identity-hash)

restore_pair()
assert_baseline(final-positive-pair)
api8_validate_pair("${_root}" "${_source_report}"
  "${_root}/missing-installed-route.report" api8-smoke _missing_valid _missing_reason)
if(_missing_valid)
  message(FATAL_ERROR "control missing-installed-report reached production validator but was accepted")
endif()

message(STATUS "muhtari_api8_result_controls: positive pair accepted; evidence mutations rejected result=pass")
file(REMOVE_RECURSE "${_root}")
