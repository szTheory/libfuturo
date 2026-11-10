cmake_minimum_required(VERSION 3.25)
include("${CMAKE_CURRENT_LIST_DIR}/CheckMacOSHostEvidence.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/ValidateMuhtariApi8Results.cmake")

function(evaluate_result applicability outcome registered enabled executed proof report output_accepted output_required_pass)
  if(NOT applicability MATCHES "^(required|advisory|unsupported)$")
    message(FATAL_ERROR "invalid result applicability '${applicability}'")
  endif()
  if(NOT outcome MATCHES "^(passed|failed|skipped|cancelled|missing)$")
    message(FATAL_ERROR "invalid result outcome '${outcome}'")
  endif()

  set(_required_pass FALSE)
  if(applicability STREQUAL "required")
    if(outcome STREQUAL "passed" AND registered AND enabled AND executed
       AND proof AND report)
      set(_required_pass TRUE)
    endif()
    set(_accepted "${_required_pass}")
  else()
    # Optional applicability remains visible, but can never count as required proof.
    set(_accepted TRUE)
  endif()

  set("${output_accepted}" "${_accepted}" PARENT_SCOPE)
  set("${output_required_pass}" "${_required_pass}" PARENT_SCOPE)
endfunction()

function(assert_control name applicability outcome registered enabled executed proof report expected)
  evaluate_result("${applicability}" "${outcome}" "${registered}" "${enabled}"
    "${executed}" "${proof}" "${report}" _accepted _required_pass)
  if(expected STREQUAL "accept")
    if(NOT _accepted)
      message(FATAL_ERROR "required-result control '${name}' was unexpectedly rejected")
    endif()
  elseif(_accepted)
    message(FATAL_ERROR "required-result control '${name}' was unexpectedly accepted")
  endif()
  if(applicability STREQUAL "required" AND expected STREQUAL "accept"
     AND NOT _required_pass)
    message(FATAL_ERROR "required-result control '${name}' did not count as required proof")
  endif()
  if(applicability STREQUAL "required" AND expected STREQUAL "reject"
     AND _required_pass)
    message(FATAL_ERROR "required-result control '${name}' counted as required proof")
  endif()
endfunction()

function(consumer_report_value report key output_value)
  set(_value "")
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line MATCHES "^${key}=(.*)$")
      set(_value "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  set("${output_value}" "${_value}" PARENT_SCOPE)
endfunction()

function(consumer_report_unique_value report key output_value output_unique)
  set(_value "")
  set(_count 0)
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line MATCHES "^${key}=(.*)$")
      math(EXPR _count "${_count} + 1")
      set(_value "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  if(_count EQUAL 1)
    set(_unique TRUE)
  else()
    set(_unique FALSE)
  endif()
  set("${output_value}" "${_value}" PARENT_SCOPE)
  set("${output_unique}" "${_unique}" PARENT_SCOPE)
endfunction()

function(consumer_report_exact_line_count report expected_line output_count)
  set(_count 0)
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line STREQUAL "${expected_line}")
      math(EXPR _count "${_count} + 1")
    endif()
  endforeach()
  set("${output_count}" "${_count}" PARENT_SCOPE)
endfunction()

function(consumer_report_keys_are_unique report output_unique)
  set(_unique TRUE)
  foreach(_key IN LISTS ARGN)
    consumer_report_unique_value("${report}" "${_key}" _value _key_unique)
    if(NOT _key_unique)
      set(_unique FALSE)
    endif()
  endforeach()
  set("${output_unique}" "${_unique}" PARENT_SCOPE)
endfunction()

function(consumer_report_has_line report expected_line output_present)
  set(_present FALSE)
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line STREQUAL "${expected_line}")
      set(_present TRUE)
      break()
    endif()
  endforeach()
  set("${output_present}" "${_present}" PARENT_SCOPE)
endfunction()

function(fresh_process_expected_events output_events)
  set(_events
    event=supervisor-start
    event=a-start
    event=a-exit
    event=checkpoint-close
    event=snapshot-identity
    event=instance-destroyed
    event=a-success-closed-and-destroyed
    event=b-start
    event=b-exit)
  set(_cases
    valid_exact_extent empty_extent truncated_header truncated_snapshot
    oversized_extent extent_overflow encoded_total_overflow
    declared_total_mismatch native_extent_mismatch bad_magic bad_header_extent
    unsupported_version native_state_format core_abi behavior_revision
    core_build libfuturo_build profile configuration options content_extent
    frame_overflow pending_input continuation_flags native_payload_corrupt
    content_digest)
  foreach(_case IN LISTS _cases)
    list(APPEND _events "snapshot-case:${_case}")
  endforeach()
  list(APPEND _events
    event=snapshot-content-control
    event=checkpoint-reopened
    event=b-success
    event=b-wrong-oracle-start
    event=b-wrong-oracle-rejected
    event=supervisor-success)
  set("${output_events}" "${_events}" PARENT_SCOPE)
endfunction()

function(fresh_process_control_report route output_report)
  fresh_process_expected_events(_events)
  list(LENGTH _events _event_count)
  set(_digest "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  set(_content_digest "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
  set(_lib_build "sha256:${_digest}")
  set(_identity
    "envelope-version=2 header-bytes=388 total-bytes=5290 native-bytes=4902 state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=${_lib_build} profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=24592 content-sha256=${_content_digest}")
  set(_generic
    "source_commit=0123456789abcdef0123456789abcdef01234567\ndependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n")
  if(route STREQUAL "source")
    set(_format "libfuturo-source-fresh-process-snapshot-v1")
    set(_route "Darwin/arm64 source-build")
  else()
    set(_format "libfuturo-relocation-fresh-process-snapshot-v1")
    set(_route "Darwin/arm64 relocated-package-and-consumer")
    string(APPEND _generic
      "consumer_executable_sha256=sha256:${_digest}\n"
      "fresh-process-consumer-executable-sha256=sha256:${_digest}\n"
      "installed_file_sha256=lib/liblibfuturo.a sha256:${_digest}\n"
      "installed_file_sha256=lib/libnesturbator.a sha256:${_digest}\n"
      "installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets.cmake sha256:${_digest}\n"
      "installed_file_sha256=lib/cmake/nesturbator/nesturbatorTargets.cmake sha256:${_digest}\n")
  endif()
  string(CONCAT _report
    "format=${_format}\n${_generic}"
    "fresh-process-source-commit=0123456789abcdef0123456789abcdef01234567\n"
    "fresh-process-core-release=v0.1.12\n"
    "fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "fresh-process-libfuturo-build-id=${_lib_build}\n"
    "fresh-process-target=Darwin/arm64\n"
    "fresh-process-route=${_route}\n"
    "fresh-process-status=passed\n"
    "fresh-process-a-exit=0\n"
    "fresh-process-b-exit=0\n"
    "fresh-process-wrong-oracle=rejected\n"
    "fresh-process-wrong-oracle-status=1\n"
    "fresh-process-checkpoint-bytes=5290\n"
    "fresh-process-checkpoint-sha256=sha256:${_digest}\n"
    "fresh-process-content-sha256=sha256:${_content_digest}\n"
    "fresh-process-runtime-identity=${_identity}\n"
    "fresh-process-event-count=${_event_count}\n"
    "fresh-process-result=separate-A-and-B,close-exit-before-restore,literal-continuation result=pass\n"
    "fresh-process-libfuturo-artifact-sha256=sha256:${_digest}\n"
    "fresh-process-core-artifact-sha256=sha256:${_digest}\n"
    "fresh-process-consumer-artifact-sha256=sha256:${_digest}\n"
    "fresh-process-supervisor-artifact-sha256=sha256:${_digest}\n"
    "fresh-process-helper-artifact-sha256=sha256:${_digest}\n")
  if(route STREQUAL "installed")
    string(APPEND _report
      "fresh-process-package-libfuturo-config-sha256=sha256:${_digest}\n"
      "fresh-process-package-core-config-sha256=sha256:${_digest}\n")
  endif()
  foreach(_event IN LISTS _events)
    if(_event MATCHES "^snapshot-case:(.+)$")
      set(_case "${CMAKE_MATCH_1}")
      if(_case STREQUAL "valid_exact_extent")
        set(_status "ok")
      elseif(_case STREQUAL "oversized_extent" OR _case STREQUAL "extent_overflow" OR
          _case STREQUAL "encoded_total_overflow")
        set(_status "limit-exceeded")
      else()
        set(_status "invalid-argument")
      endif()
      if(route STREQUAL "source")
        if(_case STREQUAL "valid_exact_extent" OR _case STREQUAL "native_payload_corrupt")
          set(_suffix " native_attempt_delta=1")
        else()
          set(_suffix " native_attempt_delta=0")
        endif()
      else()
        set(_suffix " route=public-api")
      endif()
      string(APPEND _report
        "fresh-process-event=event=snapshot-case name=${_case} status=${_status} result=pass continuation=literal${_suffix}\n")
    elseif(_event STREQUAL "event=checkpoint-close" OR
        _event STREQUAL "event=checkpoint-reopened")
      string(APPEND _report
        "fresh-process-event=${_event} bytes=5290 sha256=${_digest}\n")
    elseif(_event STREQUAL "event=snapshot-identity")
      string(APPEND _report "fresh-process-event=${_event} ${_identity}\n")
    elseif(_event STREQUAL "event=snapshot-content-control")
      string(APPEND _report
        "fresh-process-event=event=snapshot-content-control bytes=24592 same_length=pass different_sha256=pass battery_free=pass profile=nesturbator-ntsc-v1 configuration=nesturbator-default route_eligible=pass\n")
    elseif(_event STREQUAL "event=a-exit" OR _event STREQUAL "event=b-exit")
      string(APPEND _report "fresh-process-event=${_event} status=0\n")
    elseif(_event STREQUAL "event=b-wrong-oracle-rejected")
      string(APPEND _report "fresh-process-event=${_event} status=1\n")
    else()
      string(APPEND _report "fresh-process-event=${_event}\n")
    endif()
  endforeach()
  set("${output_report}" "${_report}" PARENT_SCOPE)
endfunction()

function(fresh_process_event_sequence_matches report output_matches)
  fresh_process_expected_events(_expected)
  set(_actual "")
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line MATCHES "^fresh-process-event=event=snapshot-case name=([a-z0-9_]+) ")
      list(APPEND _actual "snapshot-case:${CMAKE_MATCH_1}")
    elseif(_line MATCHES "^fresh-process-event=(event=[^ ]+)")
      list(APPEND _actual "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  if(_actual STREQUAL _expected)
    set(_matches TRUE)
  else()
    set(_matches FALSE)
  endif()
  set("${output_matches}" "${_matches}" PARENT_SCOPE)
endfunction()

function(fresh_process_report_proof report route output_proof output_detail)
  set(_proof FALSE)
  set(_detail "fresh-process-proof-missing")
  consumer_report_value("${report}" "format" _format)
  consumer_report_value("${report}" "source_commit" _source_commit)
  consumer_report_value("${report}" "dependency_commit" _dependency_commit)
  consumer_report_value("${report}" "fresh-process-source-commit" _fresh_source_commit)
  consumer_report_value("${report}" "fresh-process-core-release" _release)
  consumer_report_value("${report}" "fresh-process-core-source-revision" _core_revision)
  consumer_report_value("${report}" "fresh-process-libfuturo-build-id" _libfuturo_build_id)
  consumer_report_value("${report}" "fresh-process-target" _target)
  consumer_report_value("${report}" "fresh-process-route" _reported_route)
  consumer_report_value("${report}" "fresh-process-status" _status)
  consumer_report_value("${report}" "fresh-process-a-exit" _a_exit)
  consumer_report_value("${report}" "fresh-process-b-exit" _b_exit)
  consumer_report_value("${report}" "fresh-process-wrong-oracle" _wrong_oracle)
  consumer_report_value("${report}" "fresh-process-wrong-oracle-status" _wrong_oracle_status)
  consumer_report_value("${report}" "fresh-process-checkpoint-bytes" _checkpoint_bytes)
  consumer_report_value("${report}" "fresh-process-checkpoint-sha256" _checkpoint_hash)
  consumer_report_value("${report}" "fresh-process-content-sha256" _content_hash)
  consumer_report_value("${report}" "fresh-process-runtime-identity" _identity)
  consumer_report_value("${report}" "fresh-process-event-count" _event_count)
  consumer_report_value("${report}" "fresh-process-result" _result)
  consumer_report_value("${report}" "fresh-process-libfuturo-artifact-sha256" _libfuturo_hash)
  consumer_report_value("${report}" "fresh-process-core-artifact-sha256" _core_hash)
  consumer_report_value("${report}" "fresh-process-consumer-artifact-sha256" _consumer_hash)
  consumer_report_value("${report}" "fresh-process-supervisor-artifact-sha256" _supervisor_hash)
  consumer_report_value("${report}" "fresh-process-helper-artifact-sha256" _helper_hash)
  consumer_report_keys_are_unique("${report}" _keys_unique
    format source_commit dependency_commit fresh-process-source-commit
    fresh-process-core-release fresh-process-core-source-revision
    fresh-process-libfuturo-build-id
    fresh-process-target fresh-process-route fresh-process-status
    fresh-process-a-exit fresh-process-b-exit fresh-process-wrong-oracle
    fresh-process-wrong-oracle-status fresh-process-checkpoint-bytes
    fresh-process-checkpoint-sha256 fresh-process-content-sha256
    fresh-process-runtime-identity fresh-process-event-count fresh-process-result
    fresh-process-libfuturo-artifact-sha256 fresh-process-core-artifact-sha256
    fresh-process-consumer-artifact-sha256 fresh-process-supervisor-artifact-sha256
    fresh-process-helper-artifact-sha256)
  consumer_report_value("${report}" "fresh-process-event-count" _event_count)
  fresh_process_expected_events(_expected_events)
  list(LENGTH _expected_events _expected_event_count)
  fresh_process_event_sequence_matches("${report}" _events_match)
  consumer_report_exact_line_count("${report}"
    "fresh-process-event=event=a-exit status=0" _a_exit_event_count)
  consumer_report_exact_line_count("${report}"
    "fresh-process-event=event=b-exit status=0" _b_exit_event_count)
  consumer_report_exact_line_count("${report}"
    "fresh-process-event=event=b-wrong-oracle-rejected status=1"
    _wrong_oracle_event_count)
  consumer_report_exact_line_count("${report}"
    "fresh-process-event=event=a-success-closed-and-destroyed"
    _a_close_destroy_event_count)

  set(_expected_format "")
  set(_expected_route "")
  if(route STREQUAL "source")
    set(_expected_format "libfuturo-source-fresh-process-snapshot-v1")
    set(_expected_route "Darwin/arm64 source-build")
  elseif(route STREQUAL "installed")
    set(_expected_format "libfuturo-relocation-fresh-process-snapshot-v1")
    set(_expected_route "Darwin/arm64 relocated-package-and-consumer")
  else()
    message(FATAL_ERROR "unknown fresh-process report route '${route}'")
  endif()

  set(_close_count 0)
  set(_reopen_count 0)
  set(_content_control_count 0)
  set(_close_bytes "")
  set(_close_hash "")
  set(_reopen_bytes "")
  set(_reopen_hash "")
  set(_identity_event "")
  set(_case_count 0)
  set(_case_rows_valid TRUE)
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  set(_cases
    valid_exact_extent empty_extent truncated_header truncated_snapshot
    oversized_extent extent_overflow encoded_total_overflow
    declared_total_mismatch native_extent_mismatch bad_magic bad_header_extent
    unsupported_version native_state_format core_abi behavior_revision
    core_build libfuturo_build profile configuration options content_extent
    frame_overflow pending_input continuation_flags native_payload_corrupt
    content_digest)
  foreach(_line IN LISTS _report_lines)
    if(_line MATCHES "^fresh-process-event=event=checkpoint-close bytes=([0-9]+) sha256=([0-9a-f]+)$")
      math(EXPR _close_count "${_close_count} + 1")
      set(_close_bytes "${CMAKE_MATCH_1}")
      set(_close_hash "${CMAKE_MATCH_2}")
    elseif(_line MATCHES "^fresh-process-event=event=checkpoint-reopened bytes=([0-9]+) sha256=([0-9a-f]+)$")
      math(EXPR _reopen_count "${_reopen_count} + 1")
      set(_reopen_bytes "${CMAKE_MATCH_1}")
      set(_reopen_hash "${CMAKE_MATCH_2}")
    elseif(_line STREQUAL "fresh-process-event=event=snapshot-content-control bytes=24592 same_length=pass different_sha256=pass battery_free=pass profile=nesturbator-ntsc-v1 configuration=nesturbator-default route_eligible=pass")
      math(EXPR _content_control_count "${_content_control_count} + 1")
    elseif(_line MATCHES "^fresh-process-event=event=snapshot-identity (.+)$")
      set(_identity_event "${CMAKE_MATCH_1}")
    elseif(_line MATCHES "^fresh-process-event=event=snapshot-case name=([a-z0-9_]+) status=([a-z-]+) result=pass continuation=literal(.*)$")
      math(EXPR _case_count "${_case_count} + 1")
      set(_case_name "${CMAKE_MATCH_1}")
      set(_case_status "${CMAKE_MATCH_2}")
      set(_case_suffix "${CMAKE_MATCH_3}")
      if(_case_name STREQUAL "valid_exact_extent")
        set(_expected_case_status "ok")
      elseif(_case_name STREQUAL "oversized_extent" OR
          _case_name STREQUAL "extent_overflow" OR
          _case_name STREQUAL "encoded_total_overflow")
        set(_expected_case_status "limit-exceeded")
      else()
        set(_expected_case_status "invalid-argument")
      endif()
      if(NOT _case_name IN_LIST _cases OR
         NOT _case_status STREQUAL _expected_case_status)
        set(_case_rows_valid FALSE)
      elseif(route STREQUAL "source")
        if(_case_name STREQUAL "valid_exact_extent" OR
           _case_name STREQUAL "native_payload_corrupt")
          if(NOT _case_suffix STREQUAL " native_attempt_delta=1")
            set(_case_rows_valid FALSE)
          endif()
        elseif(NOT _case_suffix STREQUAL " native_attempt_delta=0")
          set(_case_rows_valid FALSE)
        endif()
      elseif(NOT _case_suffix STREQUAL " route=public-api")
        set(_case_rows_valid FALSE)
      endif()
    endif()
  endforeach()

  set(_identity_valid FALSE)
  set(_identity_regex_valid FALSE)
  if(_identity MATCHES "^envelope-version=2 header-bytes=388 total-bytes=([0-9]+) native-bytes=([0-9]+) state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=(sha256:[0-9a-f]+) profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=24592 content-sha256=([0-9a-f]+)$")
    set(_identity_regex_valid TRUE)
    set(_identity_total_bytes "${CMAKE_MATCH_1}")
    set(_identity_native_bytes "${CMAKE_MATCH_2}")
    set(_identity_libfuturo_build_id "${CMAKE_MATCH_3}")
    set(_identity_content_hash "${CMAKE_MATCH_4}")
    string(LENGTH "${_identity_libfuturo_build_id}" _identity_lib_build_length)
    string(LENGTH "${_identity_content_hash}" _identity_content_length)
    if(NOT _identity_lib_build_length EQUAL 71 OR
       NOT _identity_content_length EQUAL 64)
      set(_identity_regex_valid FALSE)
    endif()
  endif()
  if(_identity STREQUAL _identity_event AND _identity_regex_valid)
    math(EXPR _expected_native_bytes "${_identity_total_bytes} - 388")
    if(_identity_total_bytes STREQUAL _checkpoint_bytes AND
       _identity_native_bytes STREQUAL "${_expected_native_bytes}" AND
       _identity_libfuturo_build_id STREQUAL _libfuturo_build_id AND
       "sha256:${_identity_content_hash}" STREQUAL _content_hash)
      set(_identity_valid TRUE)
    endif()
  endif()

  string(LENGTH "${_checkpoint_hash}" _checkpoint_hash_length)
  string(LENGTH "${_content_hash}" _content_hash_length)
  string(LENGTH "${_libfuturo_build_id}" _libfuturo_build_id_length)
  string(LENGTH "${_source_commit}" _source_commit_length)
  string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
  string(LENGTH "${_core_hash}" _core_hash_length)
  string(LENGTH "${_consumer_hash}" _consumer_hash_length)
  string(LENGTH "${_supervisor_hash}" _supervisor_hash_length)
  string(LENGTH "${_helper_hash}" _helper_hash_length)
  string(REPLACE "sha256:" "" _checkpoint_hash_hex "${_checkpoint_hash}")
  if(route STREQUAL "installed")
    set(_installed_libfuturo_hash "")
    set(_installed_core_hash "")
    set(_installed_libfuturo_config_hash "")
    set(_installed_core_config_hash "")
    set(_installed_libfuturo_count 0)
    set(_installed_core_count 0)
    set(_installed_libfuturo_config_count 0)
    set(_installed_core_config_count 0)
    foreach(_line IN LISTS _report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_libfuturo_count "${_installed_libfuturo_count} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        set(_installed_core_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_core_count "${_installed_core_count} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets[.]cmake sha256:([0-9a-f]+)$")
        set(_installed_libfuturo_config_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_libfuturo_config_count "${_installed_libfuturo_config_count} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/cmake/nesturbator/nesturbatorTargets[.]cmake sha256:([0-9a-f]+)$")
        set(_installed_core_config_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_core_config_count "${_installed_core_config_count} + 1")
      endif()
    endforeach()
    consumer_report_value("${report}" "fresh-process-package-libfuturo-config-sha256" _libfuturo_config_hash)
    consumer_report_value("${report}" "fresh-process-package-core-config-sha256" _core_config_hash)
    consumer_report_value("${report}" "fresh-process-consumer-executable-sha256" _fresh_consumer_executable_hash)
    consumer_report_keys_are_unique("${report}" _package_keys_unique
      fresh-process-package-libfuturo-config-sha256
      fresh-process-package-core-config-sha256
      fresh-process-consumer-executable-sha256)
    if(NOT _package_keys_unique)
      set(_keys_unique FALSE)
    endif()
    string(LENGTH "${_libfuturo_config_hash}" _libfuturo_config_hash_length)
    string(LENGTH "${_core_config_hash}" _core_config_hash_length)
    string(LENGTH "${_installed_libfuturo_hash}" _installed_libfuturo_hash_length)
    string(LENGTH "${_installed_core_hash}" _installed_core_hash_length)
    string(LENGTH "${_installed_libfuturo_config_hash}" _installed_libfuturo_config_hash_length)
    string(LENGTH "${_installed_core_config_hash}" _installed_core_config_hash_length)
    string(LENGTH "${_fresh_consumer_executable_hash}" _fresh_consumer_executable_hash_length)
    if(NOT _installed_libfuturo_hash_length EQUAL 64 OR
       NOT _installed_core_hash_length EQUAL 64 OR
       NOT _installed_libfuturo_config_hash_length EQUAL 64 OR
       NOT _installed_core_config_hash_length EQUAL 64 OR
       NOT _libfuturo_hash STREQUAL "sha256:${_installed_libfuturo_hash}" OR
       NOT _core_hash STREQUAL "sha256:${_installed_core_hash}" OR
       NOT _libfuturo_config_hash STREQUAL "sha256:${_installed_libfuturo_config_hash}" OR
       NOT _core_config_hash STREQUAL "sha256:${_installed_core_config_hash}" OR
       NOT _consumer_hash STREQUAL _fresh_consumer_executable_hash OR
       NOT _installed_libfuturo_count EQUAL 1 OR
       NOT _installed_core_count EQUAL 1 OR
       NOT _installed_libfuturo_config_count EQUAL 1 OR
       NOT _installed_core_config_count EQUAL 1 OR
       NOT _libfuturo_config_hash_length EQUAL 71 OR
       NOT _core_config_hash_length EQUAL 71 OR
       NOT _fresh_consumer_executable_hash_length EQUAL 71)
      set(_package_artifacts_valid FALSE)
    else()
      set(_package_artifacts_valid TRUE)
    endif()
  else()
    set(_package_artifacts_valid TRUE)
  endif()
  set(_source_artifacts_valid TRUE)
  if(route STREQUAL "source" AND RESULT_CASES STREQUAL "actual")
    set(_source_libfuturo_path "${RESULT_BASE_DIR}/liblibfuturo_test.a")
    set(_source_core_path "${RESULT_BASE_DIR}/_deps/nesturbator-build/libnesturbator.a")
    set(_source_consumer_path "${RESULT_BASE_DIR}/nesturbator_session")
    set(_source_supervisor_path "${PRIVATE_ROOT}/tests/nesturbator_fresh_process_supervisor.sh")
    set(_source_helper_path "${PRIVATE_ROOT}/scripts/process-tree-cleanup.sh")
    foreach(_artifact_path IN ITEMS _source_libfuturo_path _source_core_path
        _source_consumer_path _source_supervisor_path _source_helper_path)
      if(NOT EXISTS "${${_artifact_path}}")
        set(_source_artifacts_valid FALSE)
      endif()
    endforeach()
    if(_source_artifacts_valid)
      file(SHA256 "${_source_libfuturo_path}" _actual_libfuturo_hash)
      file(SHA256 "${_source_core_path}" _actual_core_hash)
      file(SHA256 "${_source_consumer_path}" _actual_consumer_hash)
      file(SHA256 "${_source_supervisor_path}" _actual_supervisor_hash)
      file(SHA256 "${_source_helper_path}" _actual_helper_hash)
      if(NOT _libfuturo_hash STREQUAL "sha256:${_actual_libfuturo_hash}" OR
         NOT _core_hash STREQUAL "sha256:${_actual_core_hash}" OR
         NOT _consumer_hash STREQUAL "sha256:${_actual_consumer_hash}" OR
         NOT _supervisor_hash STREQUAL "sha256:${_actual_supervisor_hash}" OR
         NOT _helper_hash STREQUAL "sha256:${_actual_helper_hash}")
        set(_source_artifacts_valid FALSE)
      endif()
    endif()
  endif()

  if(_format STREQUAL _expected_format AND
     _source_commit MATCHES "^[0-9a-f]+$" AND _source_commit_length EQUAL 40 AND
     _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3" AND
     _fresh_source_commit STREQUAL _source_commit AND
     _release STREQUAL "v0.1.12" AND
     _core_revision STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3" AND
     _libfuturo_build_id MATCHES "^sha256:[0-9a-f]+$" AND _libfuturo_build_id_length EQUAL 71 AND
     _target STREQUAL "Darwin/arm64" AND _reported_route STREQUAL _expected_route AND
     _status STREQUAL "passed" AND _a_exit STREQUAL "0" AND _b_exit STREQUAL "0" AND
     _wrong_oracle STREQUAL "rejected" AND _wrong_oracle_status STREQUAL "1" AND
     _checkpoint_bytes MATCHES "^[0-9]+$" AND _checkpoint_bytes GREATER 388 AND
     _checkpoint_hash MATCHES "^sha256:[0-9a-f]+$" AND _checkpoint_hash_length EQUAL 71 AND
     _content_hash MATCHES "^sha256:[0-9a-f]+$" AND _content_hash_length EQUAL 71 AND
     _event_count STREQUAL "${_expected_event_count}" AND _events_match AND
     _a_exit_event_count EQUAL 1 AND _b_exit_event_count EQUAL 1 AND
     _wrong_oracle_event_count EQUAL 1 AND _a_close_destroy_event_count EQUAL 1 AND
     _case_count EQUAL 26 AND _case_rows_valid AND
     _close_count EQUAL 1 AND _reopen_count EQUAL 1 AND
     _close_bytes STREQUAL _checkpoint_bytes AND _reopen_bytes STREQUAL _checkpoint_bytes AND
     _close_hash STREQUAL _checkpoint_hash_hex AND
     _reopen_hash STREQUAL _checkpoint_hash_hex AND
     _content_control_count EQUAL 1 AND _identity_valid AND _package_artifacts_valid AND _source_artifacts_valid AND
     _result STREQUAL "separate-A-and-B,close-exit-before-restore,literal-continuation result=pass" AND
     _libfuturo_hash MATCHES "^sha256:[0-9a-f]+$" AND _libfuturo_hash_length EQUAL 71 AND
     _core_hash MATCHES "^sha256:[0-9a-f]+$" AND _core_hash_length EQUAL 71 AND
     _consumer_hash MATCHES "^sha256:[0-9a-f]+$" AND _consumer_hash_length EQUAL 71 AND
     _supervisor_hash MATCHES "^sha256:[0-9a-f]+$" AND _supervisor_hash_length EQUAL 71 AND
     _helper_hash MATCHES "^sha256:[0-9a-f]+$" AND _helper_hash_length EQUAL 71 AND
     _keys_unique)
    set(_proof TRUE)
    set(_detail "fresh-process-lifecycle-runtime-checkpoint-artifacts-complete")
  elseif(NOT _events_match OR NOT _case_rows_valid OR NOT _content_control_count EQUAL 1)
    set(_detail "fresh-process-events-refusal-matrix-or-content-control-missing-reordered-or-wrong")
  elseif(NOT _identity_valid OR NOT _checkpoint_hash MATCHES "^sha256:[0-9a-f]+$")
    set(_detail "fresh-process-runtime-identity-checkpoint-extent-or-digest-mismatch")
  elseif(NOT _package_artifacts_valid OR NOT _source_artifacts_valid OR _libfuturo_hash_length LESS 71 OR
      _core_hash_length LESS 71 OR _consumer_hash_length LESS 71)
    set(_detail "fresh-process-library-core-consumer-or-package-artifact-hash-missing-or-wrong")
  elseif(NOT _status STREQUAL "passed" OR NOT _a_exit STREQUAL "0" OR
      NOT _b_exit STREQUAL "0" OR NOT _wrong_oracle STREQUAL "rejected")
    set(_detail "fresh-process-child-failed-skipped-timeout-cancelled-or-oracle-accepted")
  else()
    set(_detail "fresh-process-pin-target-route-result-or-report-identity-mismatch")
  endif()
  set("${output_proof}" "${_proof}" PARENT_SCOPE)
  set("${output_detail}" "${_detail}" PARENT_SCOPE)
endfunction()

function(battery_fresh_process_report_proof report route output_proof output_detail)
  set(_proof FALSE)
  set(_detail "battery-fresh-process-proof-incomplete")
  set(_hash_pattern "^sha256:[0-9a-f]+$")
  set(_fixture_digest "2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
  set(_core_revision "2338608ab184f040620a30d17756f5e06a42d4e3")
  set(_runtime_prefix "nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3")

  if(route STREQUAL "source")
    set(_route_prefix "fresh-process")
    set(_event_key "fresh-process-event")
    set(_expected_format "libfuturo-source-battery-fresh-process-snapshot-v1")
    set(_expected_route "Darwin/arm64 source-build")
    set(_expected_result
      "R2-captured,R3-committed-and-imported-before-advance,R2-restored,full-media-and-save-custody result=pass")
    set(_expected_save_custody
      "R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack")
    set(_unique_keys
      format source_commit dependency_commit source_worktree source_worktree_fingerprint
      fresh-process-source-commit fresh-process-core-release
      fresh-process-core-source-revision fresh-process-libfuturo-build-id
      fresh-process-target fresh-process-route fresh-process-status
      fresh-process-a-exit fresh-process-b-exit fresh-process-checkpoint-bytes
      fresh-process-checkpoint-sha256 fresh-process-content-sha256
      fresh-process-runtime-identity fresh-process-event-count fresh-process-result
      battery-fixture battery-fresh-process-route battery-fresh-process-save-custody
      battery-fresh-process-result fresh-process-libfuturo-artifact-sha256
      fresh-process-core-artifact-sha256 fresh-process-consumer-artifact-sha256
      fresh-process-supervisor-artifact-sha256 fresh-process-helper-artifact-sha256)
  elseif(route STREQUAL "installed")
    set(_route_prefix "installed-battery-fresh-process")
    set(_event_key "installed-battery-fresh-process-event")
    set(_expected_format "libfuturo-relocation-battery-fresh-process-snapshot-v1")
    set(_expected_route "Darwin/arm64 moved-prefix-only")
    set(_expected_result
      "separate-A-and-B,close-exit-before-import-and-restore,R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack,literal-full-span-replay,wrong-oracle-controls=progress-video-audio-full-media result=pass")
    set(_expected_save_custody "")
    set(_unique_keys
      format run_id source_commit source_worktree dependency_commit
      installed-battery-fresh-process-source-commit
      installed-battery-fresh-process-source-worktree
      installed-battery-fresh-process-source-worktree-fingerprint
      installed-battery-fresh-process-core-release
      installed-battery-fresh-process-core-source-revision
      installed-battery-fresh-process-profile
      installed-battery-fresh-process-effective-configuration
      installed-battery-fresh-process-fixture
      installed-battery-fresh-process-route
      installed-battery-fresh-process-status
      installed-battery-fresh-process-child-exit
      installed-battery-fresh-process-elapsed-seconds
      installed-battery-fresh-process-a-exit
      installed-battery-fresh-process-b-exit
      installed-battery-fresh-process-checkpoint-bytes
      installed-battery-fresh-process-checkpoint-sha256
      installed-battery-fresh-process-runtime-identity
      installed-battery-fresh-process-event-count
      installed-battery-fresh-process-junit
      installed-battery-fresh-process-relocated-libfuturo-archive-sha256
      installed-battery-fresh-process-relocated-core-archive-sha256
      installed-battery-fresh-process-consumer-executable-sha256
      installed-battery-fresh-process-supervisor-sha256
      installed-battery-fresh-process-helper-sha256
      installed-battery-fresh-process-libfuturo-package-targets-sha256
      installed-battery-fresh-process-core-package-targets-sha256
      installed-battery-fresh-process-wrong-oracle-controls
      installed-battery-fresh-process-result
      consumer_executable_sha256)
  else()
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "unknown-battery-fresh-process-route" PARENT_SCOPE)
    return()
  endif()

  consumer_report_keys_are_unique("${report}" _keys_unique ${_unique_keys})
  foreach(_key IN LISTS _unique_keys)
    consumer_report_unique_value("${report}" "${_key}" _v_${_key} _u_${_key})
  endforeach()

  set(_source_commit "${_v_source_commit}")
  set(_worktree "${_v_source_worktree}")
  if(route STREQUAL "source")
    set(_reported_commit "${_v_fresh-process-source-commit}")
    set(_reported_worktree "${_worktree}")
    set(_core_release "${_v_fresh-process-core-release}")
    set(_core_revision_value "${_v_fresh-process-core-source-revision}")
    set(_build_id "${_v_fresh-process-libfuturo-build-id}")
    set(_target "${_v_fresh-process-target}")
    set(_reported_route "${_v_fresh-process-route}")
    set(_status "${_v_fresh-process-status}")
    set(_child_exit "0")
    set(_a_exit "${_v_fresh-process-a-exit}")
    set(_b_exit "${_v_fresh-process-b-exit}")
    set(_checkpoint_bytes "${_v_fresh-process-checkpoint-bytes}")
    set(_checkpoint_hash "${_v_fresh-process-checkpoint-sha256}")
    set(_content_hash "${_v_fresh-process-content-sha256}")
    set(_identity "${_v_fresh-process-runtime-identity}")
    set(_event_count "${_v_fresh-process-event-count}")
    set(_result "${_v_battery-fresh-process-result}")
    set(_fixture "${_v_battery-fixture}")
    set(_reported_battery_route "${_v_battery-fresh-process-route}")
    set(_save_custody "${_v_battery-fresh-process-save-custody}")
    set(_libfuturo_hash "${_v_fresh-process-libfuturo-artifact-sha256}")
    set(_core_hash "${_v_fresh-process-core-artifact-sha256}")
    set(_consumer_hash "${_v_fresh-process-consumer-artifact-sha256}")
    set(_supervisor_hash "${_v_fresh-process-supervisor-artifact-sha256}")
    set(_helper_hash "${_v_fresh-process-helper-artifact-sha256}")
    set(_worktree_fingerprint "${_v_source_worktree_fingerprint}")
    set(_reported_worktree_fingerprint "${_worktree_fingerprint}")
    set(_wrong_oracle_controls "")
  else()
    set(_reported_commit "${_v_installed-battery-fresh-process-source-commit}")
    set(_reported_worktree "${_v_installed-battery-fresh-process-source-worktree}")
    set(_core_release "${_v_installed-battery-fresh-process-core-release}")
    set(_core_revision_value "${_v_installed-battery-fresh-process-core-source-revision}")
    set(_build_id "")
    set(_target "Darwin/arm64")
    set(_reported_route "${_v_installed-battery-fresh-process-route}")
    set(_status "${_v_installed-battery-fresh-process-status}")
    set(_child_exit "${_v_installed-battery-fresh-process-child-exit}")
    set(_a_exit "${_v_installed-battery-fresh-process-a-exit}")
    set(_b_exit "${_v_installed-battery-fresh-process-b-exit}")
    set(_checkpoint_bytes "${_v_installed-battery-fresh-process-checkpoint-bytes}")
    set(_checkpoint_hash "${_v_installed-battery-fresh-process-checkpoint-sha256}")
    set(_content_hash "sha256:${_fixture_digest}")
    set(_identity "${_v_installed-battery-fresh-process-runtime-identity}")
    set(_event_count "${_v_installed-battery-fresh-process-event-count}")
    set(_result "${_v_installed-battery-fresh-process-result}")
    set(_fixture "${_v_installed-battery-fresh-process-fixture}")
    set(_reported_battery_route "${_reported_route}")
    set(_save_custody "${_expected_save_custody}")
    set(_libfuturo_hash "${_v_installed-battery-fresh-process-relocated-libfuturo-archive-sha256}")
    set(_core_hash "${_v_installed-battery-fresh-process-relocated-core-archive-sha256}")
    set(_consumer_hash "${_v_installed-battery-fresh-process-consumer-executable-sha256}")
    set(_supervisor_hash "${_v_installed-battery-fresh-process-supervisor-sha256}")
    set(_helper_hash "${_v_installed-battery-fresh-process-helper-sha256}")
    set(_worktree_fingerprint "${_v_installed-battery-fresh-process-source-worktree-fingerprint}")
    set(_reported_worktree_fingerprint "${_worktree_fingerprint}")
    set(_profile "${_v_installed-battery-fresh-process-profile}")
    set(_configuration "${_v_installed-battery-fresh-process-effective-configuration}")
    set(_wrong_oracle_controls "${_v_installed-battery-fresh-process-wrong-oracle-controls}")
  endif()

  set(_identity_valid FALSE)
  if(_identity MATCHES
      "^envelope-version=2 header-bytes=388 total-bytes=([0-9]+) native-bytes=([0-9]+) state-format=3 core-abi=1 behavior-revision=9 core-build=${_runtime_prefix} libfuturo-build=sha256:([0-9a-f]+) profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=40976 content-sha256=${_fixture_digest}$")
    set(_identity_total "${CMAKE_MATCH_1}")
    set(_identity_native "${CMAKE_MATCH_2}")
    set(_identity_build_hash "${CMAKE_MATCH_3}")
    string(LENGTH "${_identity_build_hash}" _identity_build_hash_length)
    math(EXPR _identity_expected_total "388 + ${_identity_native}")
    if(_identity_total STREQUAL "${_identity_expected_total}" AND
       _identity_total STREQUAL _checkpoint_bytes AND
       _identity_build_hash_length EQUAL 64)
      set(_identity_valid TRUE)
    endif()
  endif()

  set(_checkpoint_hex "")
  if(_checkpoint_hash MATCHES "^sha256:([0-9a-f]+)$")
    set(_checkpoint_hex "${CMAKE_MATCH_1}")
  endif()
  string(LENGTH "${_checkpoint_hex}" _checkpoint_hash_length)
  string(LENGTH "${_worktree_fingerprint}" _worktree_fingerprint_length)
  string(REGEX REPLACE "^sha256:" "" _worktree_fingerprint_hex
    "${_worktree_fingerprint}")
  string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
  string(REGEX REPLACE "^sha256:" "" _libfuturo_hash_hex "${_libfuturo_hash}")
  string(LENGTH "${_core_hash}" _core_hash_length)
  string(REGEX REPLACE "^sha256:" "" _core_hash_hex "${_core_hash}")
  string(LENGTH "${_consumer_hash}" _consumer_hash_length)
  string(LENGTH "${_supervisor_hash}" _supervisor_hash_length)
  string(LENGTH "${_helper_hash}" _helper_hash_length)
  if(route STREQUAL "installed")
    string(REGEX REPLACE "^sha256:" "" _libfuturo_targets_hash_hex
      "${_v_installed-battery-fresh-process-libfuturo-package-targets-sha256}")
    string(REGEX REPLACE "^sha256:" "" _core_targets_hash_hex
      "${_v_installed-battery-fresh-process-core-package-targets-sha256}")
  endif()

  set(_actual_events "")
  set(_baseline_generation "")
  set(_oracle_save_hash "")
  string(REPLACE "\r" "" _report_lines "${report}")
  string(REPLACE "\n" ";" _report_lines "${_report_lines}")
  foreach(_line IN LISTS _report_lines)
    if(_line MATCHES "^${_event_key}=(.*)$")
      set(_event "${CMAKE_MATCH_1}")
      if(route STREQUAL "source")
        if(NOT _event MATCHES "^event=(.*)$")
          set(_event "invalid-source-event-encoding")
        else()
          set(_event "${CMAKE_MATCH_1}")
        endif()
      endif()
      list(APPEND _actual_events "${_event}")
      if(_event MATCHES "^battery-b-refusal-baseline generation=([1-9][0-9]*) media=R2 selected-save=R3 result=pass$")
        set(_baseline_generation "${CMAKE_MATCH_1}")
      elseif(_event MATCHES "^oracle-selected-save-copied sha256=([0-9a-f]+)$")
        set(_oracle_save_hash "${CMAKE_MATCH_1}")
      endif()
    endif()
  endforeach()
  if(route STREQUAL "source")
    set(_expected_result
      "R2-captured,R3-committed-and-imported-before-advance,R2-restored,full-media-and-save-custody,replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,refusal-baseline-generation=${_baseline_generation} result=pass")
  else()
    set(_expected_result
      "separate-A-and-B,close-exit-before-import-and-restore,R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack,literal-replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,wrong-oracle-controls=progress-video-audio-full-media,refusal-baseline-generation=${_baseline_generation} result=pass")
  endif()

  set(_expected_events
    supervisor-start a-start "a-exit status=0"
    "checkpoint-close bytes=${_checkpoint_bytes} sha256=${_checkpoint_hex}"
    "snapshot-identity ${_identity}"
    instance-destroyed a-success-closed-and-destroyed)
  if(route STREQUAL "installed")
    string(LENGTH "${_oracle_save_hash}" _oracle_save_hash_length)
    if(NOT _oracle_save_hash_length EQUAL 64)
      set(_oracle_save_hash "invalid")
    endif()
    list(APPEND _expected_events "oracle-selected-save-copied sha256=${_oracle_save_hash}")
  endif()
  list(APPEND _expected_events
    b-start "b-exit status=0"
    "checkpoint-reopened bytes=${_checkpoint_bytes} sha256=${_checkpoint_hex}"
    b-success)
  set(_refusal_cases
    zero_extent null_zero_extent truncated_header truncated_native_payload
    trailing_byte malformed_magic malformed_version malformed_header
    malformed_total_length malformed_native_length malformed_content_extent
    wrong_core_build wrong_libfuturo_build wrong_native_format wrong_core_abi
    wrong_behavior_revision wrong_profile wrong_configuration wrong_options
    wrong_content_digest native_corruption repeated_invalid_candidate
    repeated_invalid_candidate)
  foreach(_case IN LISTS _refusal_cases)
    list(APPEND _expected_events
      "battery-b-refusal name=${_case} status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass")
  endforeach()
  if(NOT _baseline_generation STREQUAL "")
    list(APPEND _expected_events
      "battery-b-refusal-baseline generation=${_baseline_generation} media=R2 selected-save=R3 result=pass")
  else()
    list(APPEND _expected_events "invalid-battery-refusal-baseline")
  endif()
  list(APPEND _expected_events battery-save-custody-r3-imported-r2-restored-r2-committed)
  if(route STREQUAL "installed")
    list(APPEND _expected_events
      battery-oracle-controls-start
      "battery-oracle-baseline result=pass frame=3 ticks=2144280 rgb=5a5a5a audio=799 full-media=pass"
      "battery-oracle-control name=progress expected=progress actual=progress result=pass"
      "battery-oracle-control name=video expected=video actual=video result=pass"
      "battery-oracle-control name=audio expected=audio actual=audio result=pass"
      "battery-oracle-control name=media expected=media actual=media result=pass"
      battery-oracle-controls-pass)
  endif()
  list(APPEND _expected_events supervisor-success)
  list(LENGTH _actual_events _actual_event_count)
  list(LENGTH _expected_events _expected_event_count)
  if(_actual_events STREQUAL _expected_events AND
     _event_count STREQUAL "${_expected_event_count}")
    set(_events_valid TRUE)
  else()
    set(_events_valid FALSE)
  endif()

  set(_expected_fixture
    "generated-battery-mmc1-v1 bytes=40976 sha256=${_fixture_digest}")
  set(_expected_battery_route "Darwin/arm64 source-build")
  if(route STREQUAL "installed")
    set(_expected_battery_route "${_expected_route}")
  endif()
  set(_common_valid FALSE)
  string(LENGTH "${_source_commit}" _source_commit_length)
  if(_keys_unique AND _v_format STREQUAL _expected_format AND
     _source_commit MATCHES "^[0-9a-f]+$" AND _source_commit_length EQUAL 40 AND
     _reported_commit STREQUAL _source_commit AND
     _reported_worktree STREQUAL _worktree AND
     _reported_worktree_fingerprint STREQUAL _worktree_fingerprint AND
     _v_dependency_commit STREQUAL _core_revision AND
     _core_release STREQUAL "v0.1.12" AND
     _core_revision_value STREQUAL _core_revision AND
     _worktree MATCHES "^(clean|dirty)$" AND
     _worktree_fingerprint MATCHES "^sha256:[0-9a-f]+$" AND
     _worktree_fingerprint_length EQUAL 71 AND
     _target STREQUAL "Darwin/arm64" AND _reported_route STREQUAL _expected_route AND
     _status STREQUAL "passed" AND _child_exit STREQUAL "0" AND
     _a_exit STREQUAL "0" AND _b_exit STREQUAL "0" AND
     _checkpoint_bytes MATCHES "^[0-9]+$" AND _checkpoint_bytes GREATER 388 AND
     _checkpoint_hash_length EQUAL 64 AND _content_hash STREQUAL "sha256:${_fixture_digest}" AND
     _identity_valid AND _event_count STREQUAL "${_expected_event_count}" AND
     _events_valid AND _fixture STREQUAL _expected_fixture AND
     _reported_battery_route STREQUAL _expected_battery_route AND
     _result STREQUAL _expected_result AND
     _libfuturo_hash MATCHES "${_hash_pattern}" AND _libfuturo_hash_length EQUAL 71 AND
     _core_hash MATCHES "${_hash_pattern}" AND _core_hash_length EQUAL 71 AND
     _consumer_hash MATCHES "${_hash_pattern}" AND _consumer_hash_length EQUAL 71 AND
     _supervisor_hash MATCHES "${_hash_pattern}" AND _supervisor_hash_length EQUAL 71 AND
     _helper_hash MATCHES "${_hash_pattern}" AND _helper_hash_length EQUAL 71)
    set(_common_valid TRUE)
  endif()

  if(route STREQUAL "source")
    if(NOT _build_id STREQUAL "sha256:${_identity_build_hash}" OR
       NOT _v_battery-fresh-process-route STREQUAL "Darwin/arm64 source-build" OR
       NOT _save_custody STREQUAL _expected_save_custody OR
       NOT _v_fresh-process-result STREQUAL
         "separate-A-and-B,close-exit-before-restore,literal-continuation result=pass")
      set(_common_valid FALSE)
    endif()
  else()
    string(LENGTH "${_v_installed-battery-fresh-process-elapsed-seconds}" _elapsed_length)
    string(LENGTH "${_v_installed-battery-fresh-process-libfuturo-package-targets-sha256}" _libfuturo_package_hash_length)
    string(LENGTH "${_v_installed-battery-fresh-process-core-package-targets-sha256}" _core_package_hash_length)
    if(NOT _v_installed-battery-fresh-process-junit MATCHES
         "^relocate-[A-Za-z0-9._-]+-battery-fresh-process[.]junit[.]xml$" OR
       NOT _v_installed-battery-fresh-process-elapsed-seconds MATCHES "^[0-9]+$" OR
       NOT _profile STREQUAL "nesturbator-ntsc-v1" OR
       NOT _configuration STREQUAL "nesturbator-default" OR
       NOT _v_installed-battery-fresh-process-wrong-oracle-controls STREQUAL
         "progress,video,audio,full-media independently rejected after passing baseline" OR
       NOT _libfuturo_package_hash_length EQUAL 71 OR
       NOT _core_package_hash_length EQUAL 71 OR
       NOT _v_consumer_executable_sha256 STREQUAL _consumer_hash OR
       NOT _common_valid)
      set(_common_valid FALSE)
    endif()
  endif()

  if(_common_valid AND route STREQUAL "installed")
    set(_reported_installed_files 0)
    set(_installed_rows_valid TRUE)
    set(_installed_libfuturo_hash "")
    set(_installed_core_hash "")
    set(_installed_libfuturo_targets_hash "")
    set(_installed_core_targets_hash "")
    foreach(_line IN LISTS _report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        if(NOT _installed_libfuturo_hash STREQUAL "")
          set(_installed_rows_valid FALSE)
        endif()
        set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
        math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        if(NOT _installed_core_hash STREQUAL "")
          set(_installed_rows_valid FALSE)
        endif()
        set(_installed_core_hash "${CMAKE_MATCH_1}")
        math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets[.]cmake sha256:([0-9a-f]+)$")
        if(NOT _installed_libfuturo_targets_hash STREQUAL "")
          set(_installed_rows_valid FALSE)
        endif()
        set(_installed_libfuturo_targets_hash "${CMAKE_MATCH_1}")
        math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/cmake/nesturbator/nesturbatorTargets[.]cmake sha256:([0-9a-f]+)$")
        if(NOT _installed_core_targets_hash STREQUAL "")
          set(_installed_rows_valid FALSE)
        endif()
        set(_installed_core_targets_hash "${CMAKE_MATCH_1}")
        math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
      endif()
    endforeach()
    if(NOT _installed_rows_valid OR NOT _reported_installed_files EQUAL 4 OR
       NOT _installed_libfuturo_hash STREQUAL "${_libfuturo_hash_hex}" OR
       NOT _installed_core_hash STREQUAL "${_core_hash_hex}" OR
       NOT _installed_libfuturo_targets_hash STREQUAL
         "${_libfuturo_targets_hash_hex}" OR
       NOT _installed_core_targets_hash STREQUAL
         "${_core_targets_hash_hex}")
      set(_common_valid FALSE)
    endif()
  endif()

  if(_common_valid AND RESULT_CASES STREQUAL "actual")
    if(route STREQUAL "source")
      set(_artifact_paths
        "fresh-process-libfuturo-artifact-sha256|${RESULT_BASE_DIR}/liblibfuturo_test.a"
        "fresh-process-core-artifact-sha256|${RESULT_BASE_DIR}/_deps/nesturbator-build/libnesturbator.a"
        "fresh-process-consumer-artifact-sha256|${RESULT_BASE_DIR}/nesturbator_session"
        "fresh-process-supervisor-artifact-sha256|${PRIVATE_ROOT}/tests/nesturbator_fresh_process_supervisor.sh"
        "fresh-process-helper-artifact-sha256|${PRIVATE_ROOT}/scripts/process-tree-cleanup.sh")
      foreach(_artifact IN LISTS _artifact_paths)
        string(REPLACE "|" ";" _artifact_columns "${_artifact}")
        list(GET _artifact_columns 0 _artifact_key)
        list(GET _artifact_columns 1 _artifact_path)
        if(NOT EXISTS "${_artifact_path}" OR IS_DIRECTORY "${_artifact_path}")
          set(_common_valid FALSE)
        else()
          file(SHA256 "${_artifact_path}" _actual_hash)
          consumer_report_unique_value("${report}" "${_artifact_key}" _reported_hash _hash_unique)
          if(NOT _hash_unique OR NOT _reported_hash STREQUAL "sha256:${_actual_hash}")
            set(_common_valid FALSE)
          endif()
        endif()
      endforeach()
      execute_process(COMMAND git -C "${PRIVATE_ROOT}" rev-parse HEAD
        RESULT_VARIABLE _git_commit_status OUTPUT_VARIABLE _current_commit
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
      execute_process(COMMAND git -C "${PRIVATE_ROOT}" status --porcelain=v1 --untracked-files=all
        RESULT_VARIABLE _git_status_result OUTPUT_VARIABLE _git_status
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
      string(RANDOM LENGTH 16 ALPHABET 0123456789abcdef _diff_nonce)
      set(_diff_path "${RESULT_BASE_DIR}/.required-result-source-diff-${_diff_nonce}")
      execute_process(COMMAND git -C "${PRIVATE_ROOT}" diff --binary HEAD --
        RESULT_VARIABLE _git_diff_status OUTPUT_FILE "${_diff_path}" ERROR_QUIET)
      if(_git_diff_status EQUAL 0 AND EXISTS "${_diff_path}")
        file(SHA256 "${_diff_path}" _current_fingerprint)
        file(REMOVE "${_diff_path}")
      else()
        set(_current_fingerprint "")
      endif()
      set(_current_worktree "clean")
      if(NOT _git_status STREQUAL "")
        set(_current_worktree "dirty")
      endif()
      if(NOT _git_commit_status EQUAL 0 OR NOT _git_status_result EQUAL 0 OR
         NOT _current_commit STREQUAL _source_commit OR
         NOT _current_worktree STREQUAL _worktree OR
         NOT _current_fingerprint STREQUAL "${_worktree_fingerprint_hex}")
        set(_common_valid FALSE)
      endif()
    else()
      set(_junit_ref "${_v_installed-battery-fresh-process-junit}")
      if(NOT _junit_ref MATCHES "^relocate-[A-Za-z0-9._-]+-battery-fresh-process[.]junit[.]xml$")
        set(_common_valid FALSE)
      else()
        set(_junit_path "${RESULT_BASE_DIR}/relocation-reports/${_junit_ref}")
        if(NOT EXISTS "${_junit_path}" OR IS_DIRECTORY "${_junit_path}")
          set(_common_valid FALSE)
        else()
          file(READ "${_junit_path}" _battery_junit)
          junit_test_state(TRUE "${_battery_junit}"
            nesturbator_installed_battery_fresh_process_snapshot
            _battery_junit_seen _battery_junit_status _battery_junit_failure)
          if(NOT _battery_junit_seen OR NOT _battery_junit_status STREQUAL "run" OR
             NOT _battery_junit_failure STREQUAL "")
            set(_common_valid FALSE)
          endif()
        endif()
      endif()
      set(_reported_installed_files 0)
      set(_installed_rows_valid TRUE)
      set(_installed_libfuturo_hash "")
      set(_installed_core_hash "")
      set(_installed_libfuturo_targets_hash "")
      set(_installed_core_targets_hash "")
      foreach(_line IN LISTS _report_lines)
        if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
          if(NOT _installed_libfuturo_hash STREQUAL "")
            set(_installed_rows_valid FALSE)
          endif()
          set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
          math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
        elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
          if(NOT _installed_core_hash STREQUAL "")
            set(_installed_rows_valid FALSE)
          endif()
          set(_installed_core_hash "${CMAKE_MATCH_1}")
          math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
        elseif(_line MATCHES "^installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets[.]cmake sha256:([0-9a-f]+)$")
          if(NOT _installed_libfuturo_targets_hash STREQUAL "")
            set(_installed_rows_valid FALSE)
          endif()
          set(_installed_libfuturo_targets_hash "${CMAKE_MATCH_1}")
          math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
        elseif(_line MATCHES "^installed_file_sha256=lib/cmake/nesturbator/nesturbatorTargets[.]cmake sha256:([0-9a-f]+)$")
          if(NOT _installed_core_targets_hash STREQUAL "")
            set(_installed_rows_valid FALSE)
          endif()
          set(_installed_core_targets_hash "${CMAKE_MATCH_1}")
          math(EXPR _reported_installed_files "${_reported_installed_files} + 1")
        endif()
      endforeach()
      if(NOT _installed_rows_valid OR NOT _reported_installed_files EQUAL 4 OR
         NOT _installed_libfuturo_hash STREQUAL "${_libfuturo_hash_hex}" OR
         NOT _installed_core_hash STREQUAL "${_core_hash_hex}" OR
         NOT _installed_libfuturo_targets_hash STREQUAL
           "${_libfuturo_targets_hash_hex}" OR
         NOT _installed_core_targets_hash STREQUAL
           "${_core_targets_hash_hex}")
        set(_common_valid FALSE)
      endif()
    endif()
  endif()

  if(_common_valid)
    set(_proof TRUE)
    set(_detail "battery-fresh-process-lifecycle-runtime-save-and-artifact-identities-complete")
  elseif(NOT _events_valid)
    set(_detail "battery-fresh-process-events-refusal-vector-or-lifecycle-order-missing-or-wrong")
  elseif(NOT _identity_valid OR NOT _checkpoint_hash_length EQUAL 64)
    set(_detail "battery-fresh-process-runtime-identity-checkpoint-extent-or-digest-mismatch")
  elseif(NOT _keys_unique)
    set(_detail "battery-fresh-process-duplicate-or-missing-identity-key")
  elseif(NOT _status STREQUAL "passed" OR NOT _child_exit STREQUAL "0" OR
      NOT _a_exit STREQUAL "0" OR NOT _b_exit STREQUAL "0")
    set(_detail "battery-fresh-process-child-failed-skipped-timeout-or-cancelled")
  else()
    set(_detail "battery-fresh-process-pin-route-save-marker-or-artifact-identity-mismatch")
  endif()
  set("${output_proof}" "${_proof}" PARENT_SCOPE)
  set("${output_detail}" "${_detail}" PARENT_SCOPE)
endfunction()

function(battery_fresh_process_control_report route output_report)
  set(_digest "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  set(_content_digest "2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
  set(_source_commit "0123456789abcdef0123456789abcdef01234567")
  set(_fingerprint "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
  set(_checkpoint_bytes 13496)
  set(_checkpoint_hash "f806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d")
  set(_identity
    "envelope-version=2 header-bytes=388 total-bytes=13496 native-bytes=13108 state-format=3 core-abi=1 behavior-revision=9 core-build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 libfuturo-build=sha256:${_digest} profile=nesturbator-ntsc-v1 configuration=nesturbator-default options=nesturbator-options-none-v1 content-bytes=40976 content-sha256=${_content_digest}")
  set(_events
    supervisor-start a-start "a-exit status=0"
    "checkpoint-close bytes=${_checkpoint_bytes} sha256=${_checkpoint_hash}"
    "snapshot-identity ${_identity}"
    instance-destroyed a-success-closed-and-destroyed)
  if(route STREQUAL "installed")
    list(APPEND _events "oracle-selected-save-copied sha256=${_digest}")
  endif()
  list(APPEND _events
    b-start "b-exit status=0"
    "checkpoint-reopened bytes=${_checkpoint_bytes} sha256=${_checkpoint_hash}"
    b-success)
  set(_refusal_cases
    zero_extent null_zero_extent truncated_header truncated_native_payload
    trailing_byte malformed_magic malformed_version malformed_header
    malformed_total_length malformed_native_length malformed_content_extent
    wrong_core_build wrong_libfuturo_build wrong_native_format wrong_core_abi
    wrong_behavior_revision wrong_profile wrong_configuration wrong_options
    wrong_content_digest native_corruption repeated_invalid_candidate
    repeated_invalid_candidate)
  foreach(_case IN LISTS _refusal_cases)
    list(APPEND _events
      "battery-b-refusal name=${_case} status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass")
  endforeach()
  list(APPEND _events
    "battery-b-refusal-baseline generation=4 media=R2 selected-save=R3 result=pass"
    battery-save-custody-r3-imported-r2-restored-r2-committed)
  if(route STREQUAL "installed")
    list(APPEND _events
      battery-oracle-controls-start
      "battery-oracle-baseline result=pass frame=3 ticks=2144280 rgb=5a5a5a audio=799 full-media=pass"
      "battery-oracle-control name=progress expected=progress actual=progress result=pass"
      "battery-oracle-control name=video expected=video actual=video result=pass"
      "battery-oracle-control name=audio expected=audio actual=audio result=pass"
      "battery-oracle-control name=media expected=media actual=media result=pass"
      battery-oracle-controls-pass)
  endif()
  list(APPEND _events supervisor-success)
  list(LENGTH _events _event_count)

  if(route STREQUAL "source")
    set(_event_key "fresh-process-event")
    string(CONCAT _report
      "format=libfuturo-source-battery-fresh-process-snapshot-v1\n"
      "source_commit=${_source_commit}\n"
      "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
      "source_worktree=dirty\n"
      "source_worktree_fingerprint=${_fingerprint}\n"
      "fresh-process-source-commit=${_source_commit}\n"
      "fresh-process-core-release=v0.1.12\n"
      "fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
      "fresh-process-libfuturo-build-id=sha256:${_digest}\n"
      "fresh-process-target=Darwin/arm64\n"
      "fresh-process-route=Darwin/arm64 source-build\n"
      "fresh-process-status=passed\n"
      "fresh-process-a-exit=0\n"
      "fresh-process-b-exit=0\n"
      "fresh-process-checkpoint-bytes=${_checkpoint_bytes}\n"
      "fresh-process-checkpoint-sha256=sha256:${_checkpoint_hash}\n"
      "fresh-process-content-sha256=sha256:${_content_digest}\n"
      "fresh-process-runtime-identity=${_identity}\n"
      "fresh-process-event-count=${_event_count}\n"
      "fresh-process-result=separate-A-and-B,close-exit-before-restore,literal-continuation result=pass\n"
      "battery-fixture=generated-battery-mmc1-v1 bytes=40976 sha256=${_content_digest}\n"
      "battery-fresh-process-route=Darwin/arm64 source-build\n"
      "battery-fresh-process-save-custody=R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack\n"
      "battery-fresh-process-result=R2-captured,R3-committed-and-imported-before-advance,R2-restored,full-media-and-save-custody,replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,refusal-baseline-generation=4 result=pass\n"
      "fresh-process-libfuturo-artifact-sha256=sha256:${_digest}\n"
      "fresh-process-core-artifact-sha256=sha256:${_digest}\n"
      "fresh-process-consumer-artifact-sha256=sha256:${_digest}\n"
      "fresh-process-supervisor-artifact-sha256=sha256:${_digest}\n"
      "fresh-process-helper-artifact-sha256=sha256:${_digest}\n")
  else()
    set(_event_key "installed-battery-fresh-process-event")
    string(CONCAT _report
      "format=libfuturo-relocation-battery-fresh-process-snapshot-v1\n"
      "run_id=libfuturo-relocate.control123\n"
      "source_commit=${_source_commit}\n"
      "source_worktree=dirty\n"
      "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
      "consumer_executable_sha256=sha256:${_digest}\n"
      "installed-battery-fresh-process-source-commit=${_source_commit}\n"
      "installed-battery-fresh-process-source-worktree=dirty\n"
      "installed-battery-fresh-process-source-worktree-fingerprint=${_fingerprint}\n"
      "installed-battery-fresh-process-core-release=v0.1.12\n"
      "installed-battery-fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
      "installed-battery-fresh-process-profile=nesturbator-ntsc-v1\n"
      "installed-battery-fresh-process-effective-configuration=nesturbator-default\n"
      "installed-battery-fresh-process-fixture=generated-battery-mmc1-v1 bytes=40976 sha256=${_content_digest}\n"
      "installed-battery-fresh-process-route=Darwin/arm64 moved-prefix-only\n"
      "installed-battery-fresh-process-status=passed\n"
      "installed-battery-fresh-process-child-exit=0\n"
      "installed-battery-fresh-process-elapsed-seconds=1\n"
      "installed-battery-fresh-process-a-exit=0\n"
      "installed-battery-fresh-process-b-exit=0\n"
      "installed-battery-fresh-process-checkpoint-bytes=${_checkpoint_bytes}\n"
      "installed-battery-fresh-process-checkpoint-sha256=sha256:${_checkpoint_hash}\n"
      "installed-battery-fresh-process-runtime-identity=${_identity}\n"
      "installed-battery-fresh-process-event-count=${_event_count}\n"
      "installed-battery-fresh-process-junit=relocate-libfuturo-relocate.control123-battery-fresh-process.junit.xml\n")
    foreach(_artifact_field IN ITEMS
        relocated-libfuturo-archive relocated-core-archive consumer-executable
        supervisor helper libfuturo-package-targets core-package-targets)
      if(_artifact_field STREQUAL "relocated-libfuturo-archive")
        set(_artifact_value "${_digest}")
      elseif(_artifact_field STREQUAL "relocated-core-archive")
        set(_artifact_value "${_digest}")
      elseif(_artifact_field STREQUAL "consumer-executable")
        set(_artifact_value "${_digest}")
      elseif(_artifact_field STREQUAL "supervisor")
        set(_artifact_value "${_digest}")
      elseif(_artifact_field STREQUAL "helper")
        set(_artifact_value "${_digest}")
      elseif(_artifact_field STREQUAL "libfuturo-package-targets")
        set(_artifact_value "${_digest}")
      else()
        set(_artifact_value "${_digest}")
      endif()
      string(APPEND _report
        "installed-battery-fresh-process-${_artifact_field}-sha256=sha256:${_artifact_value}\n")
    endforeach()
    string(APPEND _report
      "installed-battery-fresh-process-wrong-oracle-controls=progress,video,audio,full-media independently rejected after passing baseline\n"
      "installed-battery-fresh-process-result=separate-A-and-B,close-exit-before-import-and-restore,R3-imported-before-advance,R2-restored,R3-preserved-through-prefailure,R2-readback-before-ack,literal-replay=frame3,ticks2144280,video=5a5a5a,audio=799-silence,media=full-8192,wrong-oracle-controls=progress-video-audio-full-media,refusal-baseline-generation=4 result=pass\n"
      "installed_file_sha256=lib/liblibfuturo.a sha256:${_digest}\n"
      "installed_file_sha256=lib/libnesturbator.a sha256:${_digest}\n"
      "installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets.cmake sha256:${_digest}\n"
      "installed_file_sha256=lib/cmake/nesturbator/nesturbatorTargets.cmake sha256:${_digest}\n")
  endif()
  foreach(_event IN LISTS _events)
    if(route STREQUAL "source")
      string(APPEND _report "${_event_key}=event=${_event}\n")
    else()
      string(APPEND _report "${_event_key}=${_event}\n")
    endif()
  endforeach()
  set("${output_report}" "${_report}" PARENT_SCOPE)
endfunction()

function(battery_fresh_process_identity_pair_proof source_report installed_report output_valid)
  consumer_report_unique_value("${source_report}" source_commit
    _source_commit _source_commit_unique)
  consumer_report_unique_value("${source_report}" source_worktree
    _source_worktree _source_worktree_unique)
  consumer_report_unique_value("${source_report}" source_worktree_fingerprint
    _source_fingerprint _source_fingerprint_unique)
  consumer_report_unique_value("${installed_report}" source_commit
    _installed_commit _installed_commit_unique)
  consumer_report_unique_value("${installed_report}" source_worktree
    _installed_worktree _installed_worktree_unique)
  consumer_report_unique_value("${installed_report}"
    installed-battery-fresh-process-source-worktree-fingerprint
    _installed_fingerprint _installed_fingerprint_unique)
  set(_valid FALSE)
  if(_source_commit_unique AND _source_worktree_unique AND
     _source_fingerprint_unique AND _installed_commit_unique AND
     _installed_worktree_unique AND _installed_fingerprint_unique AND
     _source_commit STREQUAL _installed_commit AND
     _source_worktree STREQUAL _installed_worktree AND
     _source_fingerprint STREQUAL _installed_fingerprint)
    set(_valid TRUE)
  endif()
  set("${output_valid}" "${_valid}" PARENT_SCOPE)
endfunction()

function(battery_fresh_process_report_path_proof report_path report output_valid)
  consumer_report_unique_value("${report}" run_id _run_id _run_id_unique)
  consumer_report_unique_value("${report}"
    installed-battery-fresh-process-junit _junit_ref _junit_unique)
  set(_valid FALSE)
  if(report_path MATCHES "^relocation-reports/relocate-([A-Za-z0-9._-]+)[.]txt$")
    set(_path_run_id "${CMAKE_MATCH_1}")
    set(_expected_junit "relocate-${_path_run_id}-battery-fresh-process.junit.xml")
    if(_run_id_unique AND _junit_unique AND
       _run_id STREQUAL _path_run_id AND
       _junit_ref STREQUAL _expected_junit)
      set(_valid TRUE)
    endif()
  endif()
  set("${output_valid}" "${_valid}" PARENT_SCOPE)
endfunction()

function(consumer_report_proof consumer_name report output_proof output_detail)
  set(_proof FALSE)
  set(_detail "required-consumer-proof-missing")
  consumer_report_value("${report}" "format" _format)
  if(consumer_name STREQUAL "installed_consumer_save_restart")
    consumer_report_value("${report}" "save-restart" _save_restart)
    if(_format STREQUAL "libfuturo-relocation-save-restart-v1"
       AND _save_restart STREQUAL "writer,committed-fresh-restorer,failed-update,fresh-restorer result=pass")
      set(_proof TRUE)
      set(_detail "save-restart-proof-complete")
    endif()
  elseif(consumer_name STREQUAL "installed_consumer_snapshot")
    consumer_report_value("${report}" "source_commit" _source_commit)
    consumer_report_value("${report}" "dependency_commit" _dependency_commit)
    consumer_report_value("${report}" "snapshot-source-commit" _snapshot_source_commit)
    consumer_report_value("${report}" "snapshot-core-source-revision" _core_revision)
    consumer_report_value("${report}" "snapshot-profile" _profile)
    consumer_report_value("${report}" "snapshot-effective-configuration" _configuration)
    consumer_report_value("${report}" "snapshot-fixture" _fixture)
    consumer_report_value("${report}" "snapshot-route" _route)
    consumer_report_value("${report}" "snapshot-child-exit" _child_exit)
    consumer_report_value("${report}" "snapshot-result-marker" _result_marker)
    consumer_report_value("${report}" "snapshot-consumer-marker" _consumer_marker)
    consumer_report_value("${report}" "snapshot-relocated-libfuturo-archive-sha256" _libfuturo_hash)
    consumer_report_value("${report}" "snapshot-relocated-core-archive-sha256" _core_hash)
    consumer_report_value("${report}" "snapshot-consumer-executable-sha256" _executable_hash)
    consumer_report_value("${report}" "consumer_executable_sha256" _reported_executable_hash)
    consumer_report_has_line("${report}"
      "isolation_stage=installed-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _snapshot_stage)
    set(_installed_libfuturo_hash "")
    set(_installed_core_hash "")
    # CMake runs ranlib on macOS static archives during installation, so the
    # moved archive is bound to its exact post-install identity below rather
    # than to the pre-install build archive bytes.
    string(REPLACE "\r" "" _snapshot_report_lines "${report}")
    string(REPLACE "\n" ";" _snapshot_report_lines "${_snapshot_report_lines}")
    foreach(_line IN LISTS _snapshot_report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        set(_installed_core_hash "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    string(LENGTH "${_source_commit}" _source_commit_length)
    string(LENGTH "${_snapshot_source_commit}" _snapshot_source_commit_length)
    string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
    string(LENGTH "${_core_hash}" _core_hash_length)
    string(LENGTH "${_executable_hash}" _executable_hash_length)
    string(LENGTH "${_reported_executable_hash}" _reported_executable_hash_length)
    string(LENGTH "${_installed_libfuturo_hash}" _installed_libfuturo_hash_length)
    string(LENGTH "${_installed_core_hash}" _installed_core_hash_length)
    set(_snapshot_marker_expected
      "nesturbator_snapshot_installed_consumer: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 configuration=nesturbator-default fixture=generated-battery-free-nrom-v1 replay=frame3,ticks2144304,av-literal refusals=5,continuation-preserved result=pass")
    set(_snapshot_result_expected
      "source:2338608ab184f040620a30d17756f5e06a42d4e3 profile:nesturbator-ntsc-v1 configuration:nesturbator-default fixture:generated-battery-free-nrom-v1 child-exit:0 result:pass")
    if(_format STREQUAL "libfuturo-relocation-save-restart-v1"
       AND _child_exit STREQUAL "0"
       AND _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       AND _core_revision STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       AND _profile STREQUAL "nesturbator-ntsc-v1"
       AND _configuration STREQUAL "nesturbator-default"
       AND _fixture STREQUAL "generated-battery-free-nrom-v1 bytes=24592"
       AND _route STREQUAL "Darwin/arm64 moved-prefix-only"
       AND _source_commit MATCHES "^[0-9a-f]+$"
       AND _source_commit_length EQUAL 40
       AND _snapshot_source_commit STREQUAL _source_commit
       AND _snapshot_source_commit_length EQUAL 40
       AND _consumer_marker STREQUAL _snapshot_marker_expected
       AND _result_marker STREQUAL _snapshot_result_expected
       AND _snapshot_stage
       AND _libfuturo_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _libfuturo_hash_length EQUAL 71
       AND _libfuturo_hash STREQUAL "sha256:${_installed_libfuturo_hash}"
       AND _core_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _core_hash_length EQUAL 71
       AND _core_hash STREQUAL "sha256:${_installed_core_hash}"
       AND _executable_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _executable_hash_length EQUAL 71
       AND _executable_hash STREQUAL _reported_executable_hash
       AND _reported_executable_hash_length EQUAL 71
       AND _installed_libfuturo_hash_length EQUAL 64
       AND _installed_core_hash_length EQUAL 64)
      set(_proof TRUE)
      set(_detail "snapshot-pin-profile-fixture-child-and-installed-artifacts-complete")
    elseif(NOT _child_exit STREQUAL "0")
      set(_detail "snapshot-child-nonzero-timeout-or-cancelled")
    elseif(NOT _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       OR NOT _core_revision STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3")
      set(_detail "snapshot-core-source-pin-missing-or-wrong")
    elseif(NOT _consumer_marker STREQUAL _snapshot_marker_expected
       OR NOT _result_marker STREQUAL _snapshot_result_expected)
      set(_detail "snapshot-result-marker-missing-or-wrong")
    elseif(NOT _snapshot_stage)
      set(_detail "snapshot-isolated-child-stage-missing")
    elseif(NOT _installed_libfuturo_hash_length EQUAL 64
       OR NOT _installed_core_hash_length EQUAL 64
       OR NOT _executable_hash_length EQUAL 71)
      set(_detail "snapshot-installed-artifact-identity-missing")
    else()
      set(_detail "snapshot-format-profile-configuration-fixture-or-identity-mismatch")
    endif()
  elseif(consumer_name STREQUAL "source_fresh_process_snapshot")
    fresh_process_report_proof("${report}" source _proof _detail)
  elseif(consumer_name STREQUAL "installed_consumer_fresh_process_snapshot")
    fresh_process_report_proof("${report}" installed _proof _detail)
  elseif(consumer_name STREQUAL "source_battery_fresh_process_snapshot")
    battery_fresh_process_report_proof("${report}" source _proof _detail)
  elseif(consumer_name STREQUAL "installed_consumer_battery_fresh_process_snapshot")
    battery_fresh_process_report_proof("${report}" installed _proof _detail)
  elseif(consumer_name STREQUAL "installed_consumer_battery_snapshot")
    set(_battery_keys_unique TRUE)
    consumer_report_keys_are_unique("${report}" _battery_keys_unique
      format source_commit source_worktree_fingerprint dependency_commit consumer_executable_sha256
      battery-snapshot-source-commit battery-snapshot-source-worktree
      battery-snapshot-source-worktree-fingerprint battery-snapshot-core-release
      battery-snapshot-core-source-revision battery-snapshot-profile
      battery-snapshot-effective-configuration battery-snapshot-fixture
      battery-snapshot-fixture-bytes battery-snapshot-fixture-sha256
      battery-snapshot-route battery-snapshot-build-id
      battery-snapshot-api-revision battery-snapshot-behavior-revision
      battery-snapshot-state-format-version battery-snapshot-test-inventory
      battery-snapshot-result battery-snapshot-stage-exit
      battery-snapshot-stage-elapsed-seconds battery-snapshot-recovery-status
      battery-snapshot-recovery-exit battery-snapshot-recovery-marker
      battery-snapshot-oracle-control-status battery-snapshot-oracle-control-exit
      battery-snapshot-oracle-control-marker
      battery-snapshot-relocated-libfuturo-archive-sha256
      battery-snapshot-relocated-core-archive-sha256
      battery-snapshot-consumer-executable-sha256)
    consumer_report_value("${report}" "format" _format)
    consumer_report_value("${report}" "source_commit" _source_commit)
    consumer_report_value("${report}" "source_worktree_fingerprint" _reported_worktree_fingerprint)
    consumer_report_value("${report}" "dependency_commit" _dependency_commit)
    consumer_report_value("${report}" "consumer_executable_sha256" _reported_executable_hash)
    consumer_report_value("${report}" "battery-snapshot-source-commit" _snapshot_source_commit)
    consumer_report_value("${report}" "battery-snapshot-source-worktree" _worktree)
    consumer_report_value("${report}" "battery-snapshot-source-worktree-fingerprint" _worktree_fingerprint)
    consumer_report_value("${report}" "battery-snapshot-core-release" _release)
    consumer_report_value("${report}" "battery-snapshot-core-source-revision" _core_revision)
    consumer_report_value("${report}" "battery-snapshot-profile" _profile)
    consumer_report_value("${report}" "battery-snapshot-effective-configuration" _configuration)
    consumer_report_value("${report}" "battery-snapshot-fixture" _fixture)
    consumer_report_value("${report}" "battery-snapshot-fixture-bytes" _fixture_bytes)
    consumer_report_value("${report}" "battery-snapshot-fixture-sha256" _fixture_hash)
    consumer_report_value("${report}" "battery-snapshot-route" _route)
    consumer_report_value("${report}" "battery-snapshot-build-id" _build_id)
    consumer_report_value("${report}" "battery-snapshot-api-revision" _api_revision)
    consumer_report_value("${report}" "battery-snapshot-behavior-revision" _behavior_revision)
    consumer_report_value("${report}" "battery-snapshot-state-format-version" _state_format)
    consumer_report_value("${report}" "battery-snapshot-test-inventory" _inventory)
    consumer_report_value("${report}" "battery-snapshot-result" _stage_result)
    consumer_report_value("${report}" "battery-snapshot-stage-exit" _stage_exit)
    consumer_report_value("${report}" "battery-snapshot-stage-elapsed-seconds" _stage_elapsed)
    consumer_report_value("${report}" "battery-snapshot-recovery-status" _recovery_status)
    consumer_report_value("${report}" "battery-snapshot-recovery-exit" _recovery_exit)
    consumer_report_value("${report}" "battery-snapshot-recovery-marker" _recovery_marker)
    consumer_report_value("${report}" "battery-snapshot-oracle-control-status" _oracle_status)
    consumer_report_value("${report}" "battery-snapshot-oracle-control-exit" _oracle_exit)
    consumer_report_value("${report}" "battery-snapshot-oracle-control-marker" _oracle_marker)
    consumer_report_value("${report}" "battery-snapshot-relocated-libfuturo-archive-sha256" _libfuturo_hash)
    consumer_report_value("${report}" "battery-snapshot-relocated-core-archive-sha256" _core_hash)
    consumer_report_value("${report}" "battery-snapshot-consumer-executable-sha256" _executable_hash)
    set(_installed_libfuturo_hash "")
    set(_installed_core_hash "")
    set(_installed_libfuturo_count 0)
    set(_installed_core_count 0)
    string(REPLACE "\r" "" _battery_report_lines "${report}")
    string(REPLACE "\n" ";" _battery_report_lines "${_battery_report_lines}")
    foreach(_line IN LISTS _battery_report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_libfuturo_count "${_installed_libfuturo_count} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        set(_installed_core_hash "${CMAKE_MATCH_1}")
        math(EXPR _installed_core_count "${_installed_core_count} + 1")
      endif()
    endforeach()
    consumer_report_exact_line_count("${report}"
      "isolation_stage=installed-battery-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _battery_stage_count)
    set(_recovery_marker_expected
      "nesturbator_battery_snapshot: route=installed source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass")
    set(_oracle_marker_expected
      "nesturbator_battery_snapshot_oracle_control: route=installed progress,video,audio,media=rejected result=pass")
    string(LENGTH "${_source_commit}" _source_commit_length)
    string(LENGTH "${_snapshot_source_commit}" _snapshot_source_commit_length)
    string(LENGTH "${_worktree_fingerprint}" _worktree_fingerprint_length)
    string(LENGTH "${_fixture_hash}" _fixture_hash_length)
    string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
    string(LENGTH "${_core_hash}" _core_hash_length)
    string(LENGTH "${_executable_hash}" _executable_hash_length)
    string(LENGTH "${_reported_executable_hash}" _reported_executable_hash_length)
    string(LENGTH "${_installed_libfuturo_hash}" _installed_libfuturo_hash_length)
    string(LENGTH "${_installed_core_hash}" _installed_core_hash_length)
    if(_battery_keys_unique
       AND _format STREQUAL "libfuturo-relocation-save-restart-v1"
       AND _source_commit MATCHES "^[0-9a-f]+$" AND _source_commit_length EQUAL 40
       AND _snapshot_source_commit STREQUAL _source_commit
       AND _snapshot_source_commit_length EQUAL 40
       AND _worktree MATCHES "^(clean|dirty)$"
       AND _worktree_fingerprint MATCHES "^sha256:[0-9a-f]+$"
       AND _worktree_fingerprint_length EQUAL 71
       AND _worktree_fingerprint STREQUAL _reported_worktree_fingerprint
       AND _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       AND _release STREQUAL "v0.1.12"
       AND _core_revision STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       AND _profile STREQUAL "nesturbator-ntsc-v1"
       AND _configuration STREQUAL "nesturbator-default"
       AND _fixture STREQUAL "generated-battery-mmc1-v1"
       AND _fixture_bytes STREQUAL "40976"
       AND _fixture_hash STREQUAL "sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9"
       AND _fixture_hash_length EQUAL 71
       AND _route STREQUAL "Darwin/arm64 moved-prefix-only"
       AND _build_id STREQUAL "nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3"
       AND _api_revision STREQUAL "1"
       AND _behavior_revision STREQUAL "9"
       AND _state_format STREQUAL "3"
       AND _inventory STREQUAL "exact"
       AND _stage_result STREQUAL "passed" AND _stage_exit STREQUAL "0"
       AND _stage_elapsed MATCHES "^[0-9]+$"
       AND _recovery_status STREQUAL "passed" AND _recovery_exit STREQUAL "0"
       AND _recovery_marker STREQUAL _recovery_marker_expected
       AND _oracle_status STREQUAL "passed" AND _oracle_exit STREQUAL "0"
       AND _oracle_marker STREQUAL _oracle_marker_expected
       AND _battery_stage_count EQUAL 1
       AND _libfuturo_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _libfuturo_hash_length EQUAL 71
       AND _libfuturo_hash STREQUAL "sha256:${_installed_libfuturo_hash}"
       AND _installed_libfuturo_count EQUAL 1 AND _installed_libfuturo_hash_length EQUAL 64
       AND _core_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _core_hash_length EQUAL 71
       AND _core_hash STREQUAL "sha256:${_installed_core_hash}"
       AND _installed_core_count EQUAL 1 AND _installed_core_hash_length EQUAL 64
       AND _executable_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _executable_hash_length EQUAL 71
       AND _executable_hash STREQUAL _reported_executable_hash
       AND _reported_executable_hash_length EQUAL 71)
      set(_proof TRUE)
      set(_detail "battery-snapshot-pin-fixture-recovery-oracle-and-installed-identities-complete")
    elseif(NOT _battery_keys_unique)
      set(_detail "battery-snapshot-duplicate-or-missing-identity-or-child-field")
    elseif(NOT _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       OR NOT _core_revision STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3"
       OR NOT _release STREQUAL "v0.1.12")
      set(_detail "battery-snapshot-core-release-or-source-pin-missing-or-wrong")
    elseif(NOT _recovery_marker STREQUAL _recovery_marker_expected
       OR NOT _oracle_marker STREQUAL _oracle_marker_expected)
      set(_detail "battery-snapshot-recovery-or-oracle-marker-missing-or-wrong")
    elseif(NOT _battery_stage_count EQUAL 1)
      set(_detail "battery-snapshot-isolated-child-stage-missing-or-duplicated")
    elseif(NOT _recovery_status STREQUAL "passed" OR NOT _recovery_exit STREQUAL "0"
       OR NOT _oracle_status STREQUAL "passed" OR NOT _oracle_exit STREQUAL "0"
       OR NOT _stage_result STREQUAL "passed" OR NOT _stage_exit STREQUAL "0")
      set(_detail "battery-snapshot-child-failed-skipped-timeout-or-cancelled")
    elseif(NOT _installed_libfuturo_count EQUAL 1 OR NOT _installed_core_count EQUAL 1
       OR NOT _executable_hash_length EQUAL 71)
      set(_detail "battery-snapshot-installed-artifact-identity-missing-or-duplicated")
    else()
      set(_detail "battery-snapshot-source-profile-fixture-format-or-identity-mismatch")
    endif()
  elseif(consumer_name STREQUAL "installed_consumer_load_refusal")
    # The relocation producer records load-refusal=passed only after its child
    # CTest matches the exact installed-load success marker and the isolated
    # stage returns zero.
    consumer_report_value("${report}" "load-refusal" _load_refusal)
    consumer_report_value("${report}" "load-refusal-exit" _load_exit)
    consumer_report_value("${report}" "load-refusal-executable-sha256" _load_hash)
    consumer_report_value("${report}" "load-refusal-elapsed-seconds" _load_elapsed)
    consumer_report_has_line("${report}"
      "isolation_stage=load-refusal checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _load_stage_present)
    set(_libfuturo_hash "")
    set(_nesturbator_hash "")
    string(REPLACE "\r" "" _report_lines "${report}")
    string(REPLACE "\n" ";" _report_lines "${_report_lines}")
    foreach(_line IN LISTS _report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_libfuturo_hash "${CMAKE_MATCH_1}")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        set(_nesturbator_hash "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    string(LENGTH "${_load_hash}" _load_hash_length)
    string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
    string(LENGTH "${_nesturbator_hash}" _nesturbator_hash_length)
    if(_format STREQUAL "libfuturo-relocation-save-restart-v1"
       AND _load_refusal STREQUAL "passed"
       AND _load_exit STREQUAL "0"
       AND _load_stage_present
       AND _load_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _load_hash_length EQUAL 71
       AND _load_elapsed MATCHES "^[0-9]+$"
       AND _libfuturo_hash_length EQUAL 64
       AND _nesturbator_hash_length EQUAL 64)
      set(_proof TRUE)
      set(_detail "load-refusal-marker-child-isolation-identities-complete")
    elseif(NOT _load_refusal STREQUAL "passed")
      set(_detail "load-refusal-marker-missing")
    elseif(NOT _load_exit STREQUAL "0")
      set(_detail "load-refusal-child-nonzero")
    elseif(NOT _load_hash_length EQUAL 71 OR NOT _libfuturo_hash_length EQUAL 64
       OR NOT _nesturbator_hash_length EQUAL 64)
      set(_detail "load-refusal-artifact-identity-missing")
    else()
      set(_detail "load-refusal-stage-or-cost-missing")
    endif()
  elseif(consumer_name STREQUAL "installed_muhtari_session")
    consumer_report_value("${report}" "muhtari-session" _session)
    consumer_report_value("${report}" "muhtari-session-exit" _exit)
    consumer_report_value("${report}" "muhtari-session-executable-sha256" _hash)
    consumer_report_value("${report}" "muhtari-session-elapsed-seconds" _elapsed)
    consumer_report_value("${report}" "muhtari-session-marker" _marker)
    consumer_report_value("${report}" "muhtari-load-refusal" _refusal)
    consumer_report_value("${report}" "muhtari-load-refusal-exit" _refusal_exit)
    consumer_report_value("${report}" "muhtari-load-refusal-executable-sha256" _refusal_hash)
    consumer_report_value("${report}" "muhtari-load-refusal-elapsed-seconds" _refusal_elapsed)
    consumer_report_value("${report}" "muhtari-load-refusal-marker" _refusal_marker)
    consumer_report_value("${report}" "muhtari-frame-boundaries" _boundaries)
    consumer_report_value("${report}" "muhtari-frame-boundaries-exit" _boundaries_exit)
    consumer_report_value("${report}" "muhtari-frame-boundaries-executable-sha256" _boundaries_hash)
    consumer_report_value("${report}" "muhtari-frame-boundaries-elapsed-seconds" _boundaries_elapsed)
    consumer_report_value("${report}" "muhtari-frame-boundaries-marker" _boundaries_marker)
    consumer_report_value("${report}" "muhtari-oracle-negative-control" _oracle_control)
    consumer_report_value("${report}" "muhtari-oracle-negative-control-exit" _oracle_exit)
    consumer_report_value("${report}" "muhtari-oracle-negative-control-executable-sha256" _oracle_hash)
    consumer_report_value("${report}" "muhtari-oracle-negative-control-elapsed-seconds" _oracle_elapsed)
    consumer_report_value("${report}" "muhtari-oracle-negative-control-marker" _oracle_marker)
    consumer_report_value("${report}" "muhtari_plain_link" _plain_link)
    consumer_report_value("${report}" "muhtari_plain_executable_sha256" _plain_hash)
    consumer_report_value("${report}" "muhtari-fixture-bytes" _fixture_bytes)
    consumer_report_value("${report}" "muhtari-fixture-sha256" _fixture_hash)
    consumer_report_value("${report}" "muhtari-fixture-provenance" _fixture_provenance)
    consumer_report_value("${report}" "muhtari-fixture-generator" _fixture_generator)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-session checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _stage_present)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-fixture-generation checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _fixture_stage_present)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-load-refusal checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _refusal_stage_present)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-frame-boundaries checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _boundaries_stage_present)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-oracle-negative-control checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _oracle_stage_present)
    consumer_report_has_line("${report}" "success-marker=muhtari_installed_consumer"
      _success_marker_present)
    consumer_report_has_line("${report}" "muhtari-version=0.10.0"
      _version_present)
    consumer_report_has_line("${report}"
      "muhtari-fixture-generation: checked=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass"
      _fixture_marker_present)
    set(_core_hashes 0)
    set(_libfuturo_archive_hash "")
    set(_nesturbator_archive_hash "")
    set(_muhtari_archive_hash "")
    string(REPLACE "\r" "" _report_lines "${report}")
    string(REPLACE "\n" ";" _report_lines "${_report_lines}")
    foreach(_line IN LISTS _report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_libfuturo_archive_hash "${CMAKE_MATCH_1}")
        math(EXPR _core_hashes "${_core_hashes} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/libnesturbator[.]a sha256:([0-9a-f]+)$")
        set(_nesturbator_archive_hash "${CMAKE_MATCH_1}")
        math(EXPR _core_hashes "${_core_hashes} + 1")
      elseif(_line MATCHES "^installed_file_sha256=lib/libmuhtari[.]a sha256:([0-9a-f]+)$")
        set(_muhtari_archive_hash "${CMAKE_MATCH_1}")
        math(EXPR _core_hashes "${_core_hashes} + 1")
      endif()
    endforeach()
    string(LENGTH "${_hash}" _hash_length)
    string(LENGTH "${_plain_hash}" _plain_hash_length)
    string(LENGTH "${_fixture_hash}" _fixture_hash_length)
    string(LENGTH "${_refusal_hash}" _refusal_hash_length)
    string(LENGTH "${_boundaries_hash}" _boundaries_hash_length)
    string(LENGTH "${_oracle_hash}" _oracle_hash_length)
    string(LENGTH "${_libfuturo_archive_hash}" _libfuturo_archive_hash_length)
    string(LENGTH "${_nesturbator_archive_hash}" _nesturbator_archive_hash_length)
    string(LENGTH "${_muhtari_archive_hash}" _muhtari_archive_hash_length)
    set(_refusal_expected_marker
      "cases:8 histories:loaded,unloaded continuation:3 allocation-ordinals:measured default-reset:pass")
    set(_boundaries_expected_marker
      "muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass")
    set(_oracle_expected_marker
      "muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1")
    if((_format STREQUAL "libfuturo-relocation-save-restart-v1"
         OR _format STREQUAL "libfuturo-relocation-muhtari-session-v1")
       AND _session STREQUAL "passed" AND _exit STREQUAL "0"
       AND _hash MATCHES "^sha256:[0-9a-f]+$" AND _hash_length EQUAL 71
       AND _elapsed MATCHES "^[0-9]+$"
       AND _marker STREQUAL "muhtari_session: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass"
       AND _plain_link STREQUAL "no-sanitizer-runtime-required:pass"
       AND _plain_hash MATCHES "^sha256:[0-9a-f]+$" AND _plain_hash_length EQUAL 71
       AND _fixture_bytes STREQUAL "16512"
       AND _fixture_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _fixture_hash_length EQUAL 71
       AND _fixture_provenance STREQUAL "project-authored-C-generator license=Apache-2.0 output=build-only"
       AND _fixture_generator MATCHES "^C17 Apple clang version "
       AND _refusal STREQUAL "passed" AND _refusal_exit STREQUAL "0"
       AND _refusal_hash STREQUAL _hash AND _refusal_hash_length EQUAL 71
       AND _refusal_elapsed MATCHES "^[0-9]+$"
       AND _refusal_marker STREQUAL "cases:8 histories:loaded,unloaded continuation:3 allocation-ordinals:measured default-reset:pass"
       AND _boundaries STREQUAL "passed" AND _boundaries_exit STREQUAL "0"
       AND _boundaries_hash STREQUAL _hash AND _boundaries_hash_length EQUAL 71
       AND _boundaries_elapsed MATCHES "^[0-9]+$"
       AND _boundaries_marker STREQUAL _boundaries_expected_marker
       AND _oracle_control STREQUAL "passed" AND _oracle_exit STREQUAL "0"
       AND _oracle_hash STREQUAL _hash AND _oracle_hash_length EQUAL 71
       AND _oracle_elapsed MATCHES "^[0-9]+$"
       AND _oracle_marker STREQUAL _oracle_expected_marker
       AND _stage_present AND _fixture_stage_present AND _success_marker_present
       AND _refusal_stage_present AND _boundaries_stage_present AND _oracle_stage_present
       AND _fixture_marker_present AND _version_present AND _core_hashes EQUAL 3
       AND _libfuturo_archive_hash_length EQUAL 64
       AND _nesturbator_archive_hash_length EQUAL 64
       AND _muhtari_archive_hash_length EQUAL 64)
      set(_proof TRUE)
      set(_detail "muhtari-normal-refusal-boundary-control-identities-complete")
    elseif(NOT _session STREQUAL "passed" OR NOT _success_marker_present)
      set(_detail "muhtari-session-marker-missing")
    elseif(NOT _exit STREQUAL "0")
      set(_detail "muhtari-session-child-nonzero")
    elseif(NOT _refusal_exit STREQUAL "0" OR NOT _boundaries_exit STREQUAL "0"
       OR NOT _oracle_exit STREQUAL "0")
      set(_detail "muhtari-child-nonzero-timeout-or-cancelled")
    elseif(NOT _stage_present OR NOT _fixture_stage_present
       OR NOT _refusal_stage_present OR NOT _boundaries_stage_present
       OR NOT _oracle_stage_present OR NOT _elapsed MATCHES "^[0-9]+$"
       OR NOT _refusal_elapsed MATCHES "^[0-9]+$"
       OR NOT _boundaries_elapsed MATCHES "^[0-9]+$"
       OR NOT _oracle_elapsed MATCHES "^[0-9]+$")
      set(_detail "muhtari-stage-or-child-cost-missing")
    elseif(NOT _version_present OR NOT _fixture_marker_present
       OR NOT (_fixture_hash_length EQUAL 71)
       OR NOT (_fixture_bytes STREQUAL "16512")
       OR _fixture_generator STREQUAL "")
      set(_detail "muhtari-fixture-or-package-version-missing")
    elseif(_core_hashes LESS 3 OR NOT (_hash_length EQUAL 71)
       OR NOT (_plain_hash_length EQUAL 71)
       OR NOT (_refusal_hash_length EQUAL 71)
       OR NOT (_boundaries_hash_length EQUAL 71)
       OR NOT (_oracle_hash_length EQUAL 71)
       OR NOT (_libfuturo_archive_hash_length EQUAL 64)
       OR NOT (_nesturbator_archive_hash_length EQUAL 64)
       OR NOT (_muhtari_archive_hash_length EQUAL 64))
      set(_detail "muhtari-session-artifact-identity-missing")
    elseif(NOT _refusal STREQUAL "passed" OR NOT _boundaries STREQUAL "passed"
       OR NOT _oracle_control STREQUAL "passed")
      set(_detail "muhtari-required-refusal-boundary-or-control-proof-missing")
    else()
      set(_detail "muhtari-normal-link-or-marker-incomplete")
    endif()
  elseif(consumer_name STREQUAL "installed_muhtari_save_restart")
    consumer_report_value("${report}" "muhtari_dependency_commit" _source_pin)
    consumer_report_value("${report}" "muhtari-save-fixture-source-commit" _fixture_source)
    consumer_report_value("${report}" "muhtari-save-fixture-license" _fixture_license)
    consumer_report_value("${report}" "muhtari-save-fixture-bytes" _fixture_bytes)
    consumer_report_value("${report}" "muhtari-save-fixture-sha256" _fixture_hash)
    consumer_report_value("${report}" "muhtari-save-restart" _save_result)
    consumer_report_value("${report}" "muhtari-save-writer" _writer)
    consumer_report_value("${report}" "muhtari-save-writer-exit" _writer_exit)
    consumer_report_value("${report}" "muhtari-save-writer-elapsed-seconds" _writer_elapsed)
    consumer_report_value("${report}" "muhtari-save-writer-marker" _writer_marker)
    consumer_report_value("${report}" "muhtari-save-fresh-restorer" _restorer)
    consumer_report_value("${report}" "muhtari-save-restorer-exit" _restorer_exit)
    consumer_report_value("${report}" "muhtari-save-restorer-elapsed-seconds" _restorer_elapsed)
    consumer_report_value("${report}" "muhtari-save-restorer-marker" _restorer_marker)
    consumer_report_value("${report}" "muhtari-save-rejections-marker" _rejection_marker)
    consumer_report_value("${report}" "muhtari-save-failed-update" _failure)
    consumer_report_value("${report}" "muhtari-save-failed-update-exit" _failure_exit)
    consumer_report_value("${report}" "muhtari-save-failed-update-elapsed-seconds" _failure_elapsed)
    consumer_report_value("${report}" "muhtari-save-failure-marker" _failure_marker)
    consumer_report_value("${report}" "muhtari-save-recovery" _recovery)
    consumer_report_value("${report}" "muhtari-save-recovery-exit" _recovery_exit)
    consumer_report_value("${report}" "muhtari-save-recovery-elapsed-seconds" _recovery_elapsed)
    consumer_report_value("${report}" "muhtari-save-recovery-marker" _recovery_marker)
    consumer_report_value("${report}" "muhtari-save-executable-sha256" _executable_hash)
    consumer_report_value("${report}" "muhtari-save-libfuturo-archive-sha256" _libfuturo_hash)
    consumer_report_value("${report}" "muhtari-save-core-archive-sha256" _core_hash)
    consumer_report_value("${report}" "muhtari-save-oracle-negative-control" _oracle_control)
    consumer_report_value("${report}" "muhtari-save-oracle-negative-control-exit" _oracle_exit)
    consumer_report_value("${report}" "muhtari-save-oracle-negative-control-elapsed-seconds" _oracle_elapsed)
    consumer_report_value("${report}" "muhtari-save-oracle-negative-control-executable-sha256" _oracle_executable_hash)
    consumer_report_value("${report}" "muhtari-save-oracle-negative-control-marker" _oracle_marker)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-save-writer checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _writer_stage)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-save-fresh-restorer checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _restorer_stage)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-save-failed-update checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _failure_stage)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-save-recovery checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _recovery_stage)
    consumer_report_has_line("${report}"
      "isolation_stage=muhtari-save-oracle-negative-control checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
      _oracle_stage)
    set(_writer_marker_expected
      "muhtari_save_writer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 license=MIT extent=34816 progress=1/1 committed=rename-readback generation=core-token-only")
    set(_restorer_marker_expected
      "muhtari_save_restorer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 configuration=muhtari-ntsc-battery-diagnostic media=muhtari-battery-v1 extent=34816 import=before-guest-work restored=1/1 continuation=2/2 result=pass")
    set(_rejection_marker_expected
      "muhtari_save_rejections: cases=10 invalid-imports=0 unchanged-live-span=34816 valid-import=before-guest-work result=pass")
    set(_failure_marker_expected
      "muhtari_save_failure_writer: prefix-write=failed-before-rename committed-file=previous-exact host-ack=previous-exact previous=1/1 attempted=2/2 generation-ack=preserved stage-cleanup=pass result=pass")
    set(_recovery_marker_expected
      "muhtari_save_recovery: prior-commit=1/1 recovered=1/1 continuation=2/2 process=fresh result=pass")
    set(_oracle_marker_expected
      "muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1")
    set(_writer_marker_present FALSE)
    set(_restorer_marker_present FALSE)
    set(_rejection_marker_present FALSE)
    set(_failure_marker_present FALSE)
    set(_recovery_marker_present FALSE)
    set(_oracle_marker_present FALSE)
    if(_writer_marker STREQUAL _writer_marker_expected)
      set(_writer_marker_present TRUE)
    endif()
    if(_restorer_marker STREQUAL _restorer_marker_expected)
      set(_restorer_marker_present TRUE)
    endif()
    if(_rejection_marker STREQUAL _rejection_marker_expected)
      set(_rejection_marker_present TRUE)
    endif()
    if(_failure_marker STREQUAL _failure_marker_expected)
      set(_failure_marker_present TRUE)
    endif()
    if(_recovery_marker STREQUAL _recovery_marker_expected)
      set(_recovery_marker_present TRUE)
    endif()
    if(_oracle_marker STREQUAL _oracle_marker_expected)
      set(_oracle_marker_present TRUE)
    endif()
    set(_installed_libfuturo_hash "")
    set(_installed_muhtari_hash "")
    string(REPLACE "\r" "" _report_lines "${report}")
    string(REPLACE "\n" ";" _report_lines "${_report_lines}")
    foreach(_line IN LISTS _report_lines)
      if(_line MATCHES "^installed_file_sha256=lib/liblibfuturo[.]a sha256:([0-9a-f]+)$")
        set(_installed_libfuturo_hash "${CMAKE_MATCH_1}")
      elseif(_line MATCHES "^installed_file_sha256=lib/libmuhtari[.]a sha256:([0-9a-f]+)$")
        set(_installed_muhtari_hash "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    string(LENGTH "${_fixture_hash}" _fixture_hash_length)
    string(LENGTH "${_executable_hash}" _executable_hash_length)
    string(LENGTH "${_libfuturo_hash}" _libfuturo_hash_length)
    string(LENGTH "${_core_hash}" _core_hash_length)
    string(LENGTH "${_installed_libfuturo_hash}" _installed_libfuturo_hash_length)
    string(LENGTH "${_installed_muhtari_hash}" _installed_muhtari_hash_length)
    if(_source_pin STREQUAL "d5fd241e3f4d701d73867cc2e465c56a6fe6793d"
       AND _fixture_source STREQUAL "4642ded6d026f456acf798a43efb081b76987018"
       AND _fixture_license STREQUAL "MIT" AND _fixture_bytes STREQUAL "16512"
       AND _fixture_hash STREQUAL "sha256:10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4"
       AND _save_result STREQUAL "writer,committed-fresh-restorer,failed-update,fresh-recovery result=pass"
       AND _writer STREQUAL "passed" AND _writer_exit STREQUAL "0"
       AND _writer_elapsed MATCHES "^[0-9]+$" AND _writer_marker_present
       AND _restorer STREQUAL "passed" AND _restorer_exit STREQUAL "0"
       AND _restorer_elapsed MATCHES "^[0-9]+$" AND _restorer_marker_present
       AND _rejection_marker_present
       AND _failure STREQUAL "passed" AND _failure_exit STREQUAL "0"
       AND _failure_elapsed MATCHES "^[0-9]+$" AND _failure_marker_present
       AND _recovery STREQUAL "passed" AND _recovery_exit STREQUAL "0"
       AND _recovery_elapsed MATCHES "^[0-9]+$" AND _recovery_marker_present
       AND _oracle_control STREQUAL "passed" AND _oracle_exit STREQUAL "0"
       AND _oracle_elapsed MATCHES "^[0-9]+$" AND _oracle_marker_present
       AND _oracle_executable_hash STREQUAL _executable_hash
       AND _writer_stage AND _restorer_stage AND _failure_stage AND _recovery_stage
       AND _oracle_stage
       AND _executable_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _executable_hash_length EQUAL 71
       AND _libfuturo_hash MATCHES "^sha256:[0-9a-f]+$"
       AND _libfuturo_hash_length EQUAL 71
       AND _core_hash MATCHES "^sha256:[0-9a-f]+$" AND _core_hash_length EQUAL 71
       AND _installed_libfuturo_hash_length EQUAL 64
       AND _installed_muhtari_hash_length EQUAL 64
       AND _libfuturo_hash STREQUAL "sha256:${_installed_libfuturo_hash}"
       AND _core_hash STREQUAL "sha256:${_installed_muhtari_hash}"
       AND (_format STREQUAL "libfuturo-relocation-save-restart-v1"
         OR _format STREQUAL "libfuturo-relocation-muhtari-save-restart-v1"))
      set(_proof TRUE)
      set(_detail "muhtari-save-source-fixture-four-stages-installed-identities-complete")
    elseif(NOT _source_pin STREQUAL "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
      set(_detail "muhtari-save-source-pin-missing-or-wrong")
    elseif(NOT _writer_exit STREQUAL "0" OR NOT _restorer_exit STREQUAL "0"
       OR NOT _failure_exit STREQUAL "0" OR NOT _recovery_exit STREQUAL "0"
       OR NOT _oracle_exit STREQUAL "0")
      set(_detail "muhtari-save-child-nonzero-timeout-or-cancelled")
    elseif(NOT _writer_stage OR NOT _restorer_stage OR NOT _failure_stage
       OR NOT _recovery_stage OR NOT _writer_marker_present
       OR NOT _restorer_marker_present OR NOT _rejection_marker_present
       OR NOT _failure_marker_present OR NOT _recovery_marker_present
       OR NOT _oracle_stage OR NOT _oracle_marker_present)
      set(_detail "muhtari-save-stage-or-marker-incomplete")
    elseif(NOT _executable_hash_length EQUAL 71
       OR NOT _libfuturo_hash_length EQUAL 71 OR NOT _core_hash_length EQUAL 71
       OR NOT _installed_libfuturo_hash_length EQUAL 64
       OR NOT _installed_muhtari_hash_length EQUAL 64)
      set(_detail "muhtari-save-installed-artifact-identity-missing")
    else()
      set(_detail "muhtari-save-fixture-or-child-proof-incomplete")
    endif()
  elseif(consumer_name STREQUAL "installed_macos_host")
    if(DEFINED MACOS_HOST_ARTIFACT_ROOT)
      macos_host_report_proof("${report}" "${MACOS_HOST_ARTIFACT_ROOT}"
        _proof _detail)
    else()
      set(_proof FALSE)
      set(_detail "host-evidence-artifact-root-missing")
    endif()
  else()
    set(_detail "unknown-consumer-name")
  endif()
  set("${output_proof}" "${_proof}" PARENT_SCOPE)
  set("${output_detail}" "${_detail}" PARENT_SCOPE)
endfunction()

function(assert_consumer_control name consumer_name report expected)
  consumer_report_proof("${consumer_name}" "${report}" _proof _detail)
  if(expected STREQUAL "accept" AND NOT _proof)
    message(FATAL_ERROR
      "consumer-result control '${name}' was unexpectedly rejected: ${_detail}")
  elseif(expected STREQUAL "reject" AND _proof)
    message(FATAL_ERROR
      "consumer-result control '${name}' was unexpectedly accepted: ${_detail}")
  endif()
endfunction()

function(assert_battery_identity_pair_control name source_report installed_report expected)
  battery_fresh_process_identity_pair_proof("${source_report}"
    "${installed_report}" _pair_valid)
  if(expected STREQUAL "accept" AND NOT _pair_valid)
    message(FATAL_ERROR
      "battery identity-pair control '${name}' was unexpectedly rejected")
  elseif(expected STREQUAL "reject" AND _pair_valid)
    message(FATAL_ERROR
      "battery identity-pair control '${name}' was unexpectedly accepted")
  endif()
endfunction()

function(assert_battery_report_path_control name report_path report expected)
  battery_fresh_process_report_path_proof("${report_path}" "${report}"
    _path_valid)
  if(expected STREQUAL "accept" AND NOT _path_valid)
    message(FATAL_ERROR
      "battery report-path control '${name}' was unexpectedly rejected")
  elseif(expected STREQUAL "reject" AND _path_valid)
    message(FATAL_ERROR
      "battery report-path control '${name}' was unexpectedly accepted")
  endif()
endfunction()

function(assert_battery_report_mutation name consumer_name report old_fragment new_fragment)
  string(REPLACE "${old_fragment}" "${new_fragment}" _mutated_report "${report}")
  if(_mutated_report STREQUAL "${report}")
    message(FATAL_ERROR
      "battery mutation control '${name}' did not change its positive report")
  endif()
  assert_consumer_control("${name}" "${consumer_name}" "${_mutated_report}" reject)
endfunction()

if(RESULT_CASES STREQUAL "muhtari-api8-validator-smoke")
  string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _smoke_nonce)
  set(_smoke_root "${CMAKE_CURRENT_BINARY_DIR}/muhtari-api8-validator-smoke-${_smoke_nonce}")
  file(MAKE_DIRECTORY "${_smoke_root}")
  api8_create_smoke_fixture("${_smoke_root}" source
    "${_smoke_root}/source-route.report")
  api8_create_smoke_fixture("${_smoke_root}" installed
    "${_smoke_root}/installed-route.report")
  api8_validate_pair("${_smoke_root}"
    "${_smoke_root}/source-route.report"
    "${_smoke_root}/installed-route.report" api8-smoke _smoke_valid _smoke_reason)
  if(NOT _smoke_valid)
    message(FATAL_ERROR "API 8 validator smoke rejected its positive pair: ${_smoke_reason}")
  endif()
  api8_validate_pair("${_smoke_root}"
    "${_smoke_root}/source-route.report"
    "${_smoke_root}/missing-installed-route.report" api8-smoke _missing_valid _missing_reason)
  if(_missing_valid)
    message(FATAL_ERROR "API 8 validator smoke accepted a pair with an absent installed route")
  endif()
  message(STATUS "muhtari_api8_validator_smoke: positive source-and-installed pair accepted; smoke does not qualify")
  file(REMOVE_RECURSE "${_smoke_root}")
  return()
elseif(RESULT_CASES STREQUAL "muhtari-api8-actual")
  foreach(_required_var API8_EVIDENCE_ROOT API8_RUN_ID API8_SOURCE_REPORT
      API8_INSTALLED_REPORT API8_RESULT_OUTPUT)
    if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
      message(FATAL_ERROR "${_required_var} is required for API 8 actual result validation")
    endif()
  endforeach()
  api8_validate_pair("${API8_EVIDENCE_ROOT}" "${API8_SOURCE_REPORT}"
    "${API8_INSTALLED_REPORT}" "${API8_RUN_ID}" _api8_valid _api8_reason)
  file(WRITE "${API8_RESULT_OUTPUT}"
    "kind|name|applicability|outcome|detail|registered|enabled|executed|proof|result_ref\n")
  if(_api8_valid)
    foreach(_route IN ITEMS source installed)
      set(_route_report "${API8_EVIDENCE_ROOT}/${_route}-route.report")
      file(RELATIVE_PATH _route_ref "${API8_EVIDENCE_ROOT}" "${_route_report}")
      file(SHA256 "${_route_report}" _route_digest)
      file(APPEND "${API8_RESULT_OUTPUT}"
        "required|${_route}_muhtari_api8_fresh_process|required|passed|report_sha256=sha256:${_route_digest};route-bound-artifacts-and-current-ctest|TRUE|TRUE|TRUE|TRUE|${_route_ref},${_route}-route-report-identity.txt\n")
    endforeach()
    message(STATUS "muhtari_api8_actual_results: source and installed routes independently verified result=qualification")
  else()
    file(APPEND "${API8_RESULT_OUTPUT}"
      "required|source_muhtari_api8_fresh_process|required|failed|${_api8_reason}|TRUE|TRUE|FALSE|FALSE|${API8_SOURCE_REPORT}\n")
    file(APPEND "${API8_RESULT_OUTPUT}"
      "required|installed_muhtari_api8_fresh_process|required|failed|${_api8_reason}|TRUE|TRUE|FALSE|FALSE|${API8_INSTALLED_REPORT}\n")
    message(FATAL_ERROR "API 8 actual result validation failed: ${_api8_reason}")
  endif()
  return()
endif()

if(RESULT_CASES STREQUAL "all")
  assert_control(baseline required passed TRUE TRUE TRUE TRUE TRUE accept)
  assert_control(missing_registration required missing FALSE FALSE FALSE FALSE FALSE reject)
  assert_control(missing_report required passed TRUE TRUE TRUE TRUE FALSE reject)
  assert_control(disabled required skipped TRUE FALSE FALSE FALSE TRUE reject)
  assert_control(failure required failed TRUE TRUE TRUE FALSE TRUE reject)
  assert_control(skip required skipped TRUE TRUE TRUE FALSE TRUE reject)
  assert_control(cancellation required cancelled TRUE TRUE FALSE FALSE TRUE reject)
  assert_control(evidence_free required passed TRUE TRUE TRUE FALSE TRUE reject)
  assert_control(advisory_pass advisory passed TRUE TRUE TRUE TRUE TRUE accept)
  assert_control(advisory_failure advisory failed TRUE TRUE TRUE FALSE TRUE accept)
  assert_control(unsupported_missing unsupported missing FALSE FALSE FALSE FALSE FALSE accept)
  set(MACOS_HOST_ARTIFACT_ROOT
    "${CMAKE_CURRENT_BINARY_DIR}/macos-host-evidence-controls")
  macos_host_run_controls()
  set(_save_consumer_report
    "format=libfuturo-relocation-save-restart-v1\nsave-restart=writer,committed-fresh-restorer,failed-update,fresh-restorer result=pass\n")
  set(_load_consumer_report
    "${_save_consumer_report}load-refusal=passed\nload-refusal-exit=0\nload-refusal-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nload-refusal-elapsed-seconds=4\nisolation_stage=load-refusal checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\ninstalled_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libnesturbator.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_consumer_control(save_restart_row installed_consumer_save_restart
    "${_save_consumer_report}" accept)
  assert_consumer_control(load_complete installed_consumer_load_refusal
    "${_load_consumer_report}" accept)
  assert_consumer_control(load_missing_marker installed_consumer_load_refusal
    "${_save_consumer_report}" reject)
  assert_consumer_control(load_nonzero_child installed_consumer_load_refusal
    "${_load_consumer_report}load-refusal-exit=8\n" reject)
  assert_consumer_control(load_timeout installed_consumer_load_refusal
    "${_load_consumer_report}load-refusal=timed-out\nload-refusal-exit=124\n" reject)
  assert_consumer_control(load_cancelled installed_consumer_load_refusal
    "${_load_consumer_report}load-refusal=cancelled\nload-refusal-exit=143\n" reject)
  assert_consumer_control(save_only_is_not_load installed_consumer_load_refusal
    "${_save_consumer_report}" reject)
  assert_consumer_control(complete_save_row installed_consumer_save_restart
    "${_load_consumer_report}" accept)
  assert_consumer_control(unknown_consumer unknown_required_consumer
    "${_load_consumer_report}" reject)
  set(_muhtari_consumer_report
    "format=libfuturo-relocation-muhtari-session-v1\nmuhtari-session=passed\nmuhtari-session-exit=0\nmuhtari-session-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-session-elapsed-seconds=4\nmuhtari-session-marker=muhtari_session: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass\nmuhtari-load-refusal=passed\nmuhtari-load-refusal-exit=0\nmuhtari-load-refusal-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-load-refusal-elapsed-seconds=4\nmuhtari-load-refusal-marker=cases:8 histories:loaded,unloaded continuation:3 allocation-ordinals:measured default-reset:pass\nmuhtari-frame-boundaries=passed\nmuhtari-frame-boundaries-exit=0\nmuhtari-frame-boundaries-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-frame-boundaries-elapsed-seconds=4\nmuhtari-frame-boundaries-marker=muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass\nmuhtari-oracle-negative-control=passed\nmuhtari-oracle-negative-control-exit=0\nmuhtari-oracle-negative-control-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-oracle-negative-control-elapsed-seconds=4\nmuhtari-oracle-negative-control-marker=muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1\nmuhtari_plain_link=no-sanitizer-runtime-required:pass\nmuhtari_plain_executable_sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-fixture-bytes=16512\nmuhtari-fixture-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-fixture-provenance=project-authored-C-generator license=Apache-2.0 output=build-only\nmuhtari-fixture-generator=C17 Apple clang version 21.0.0\nisolation_stage=muhtari-session checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-fixture-generation checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-load-refusal checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-frame-boundaries checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-oracle-negative-control checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nsuccess-marker=muhtari_installed_consumer\nmuhtari-version=0.10.0\nmuhtari-fixture-generation: checked=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass\ninstalled_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libnesturbator.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libmuhtari.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_consumer_control(muhtari_complete installed_muhtari_session
    "${_muhtari_consumer_report}" accept)
  assert_consumer_control(muhtari_missing_marker installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-session-marker=corrupt\n" reject)
  assert_consumer_control(muhtari_nonzero_child installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-session-exit=8\n" reject)
  assert_consumer_control(muhtari_missing_normal_link installed_muhtari_session
    "${_muhtari_consumer_report}muhtari_plain_link=missing\n" reject)
  assert_consumer_control(muhtari_legacy_only installed_muhtari_session
    "${_save_consumer_report}" reject)
  assert_consumer_control(muhtari_missing_normal installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-session=missing\n" reject)
  assert_consumer_control(muhtari_missing_refusal installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-load-refusal=missing\n" reject)
  assert_consumer_control(muhtari_missing_boundaries installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-frame-boundaries=missing\n" reject)
  assert_consumer_control(muhtari_missing_oracle_control installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-oracle-negative-control=missing\n" reject)
  string(REPLACE
    "installed_file_sha256=lib/libmuhtari.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _muhtari_without_archive "${_muhtari_consumer_report}")
  assert_consumer_control(muhtari_missing_archive_identity installed_muhtari_session
    "${_muhtari_without_archive}" reject)
  assert_consumer_control(muhtari_nonzero_boundary_child installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-frame-boundaries-exit=8\n" reject)
  assert_consumer_control(muhtari_timeout_boundary_child installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-frame-boundaries=timed-out\nmuhtari-frame-boundaries-exit=124\n" reject)
  assert_consumer_control(muhtari_cancelled_boundary_child installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-frame-boundaries=cancelled\nmuhtari-frame-boundaries-exit=143\n" reject)
  assert_consumer_control(muhtari_unexpected_unsupported installed_muhtari_session
    "${_muhtari_consumer_report}muhtari-frame-boundaries=unsupported\n" reject)
  set(_muhtari_save_report
    "format=libfuturo-relocation-save-restart-v1\nmuhtari_dependency_commit=d5fd241e3f4d701d73867cc2e465c56a6fe6793d\nmuhtari-save-fixture-source-commit=4642ded6d026f456acf798a43efb081b76987018\nmuhtari-save-fixture-license=MIT\nmuhtari-save-fixture-bytes=16512\nmuhtari-save-fixture-sha256=sha256:10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4\nmuhtari-save-writer=passed\nmuhtari-save-writer-exit=0\nmuhtari-save-writer-elapsed-seconds=2\nmuhtari-save-writer-marker=muhtari_save_writer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 license=MIT extent=34816 progress=1/1 committed=rename-readback generation=core-token-only\nmuhtari-save-fresh-restorer=passed\nmuhtari-save-restorer-exit=0\nmuhtari-save-restorer-elapsed-seconds=3\nmuhtari-save-restorer-marker=muhtari_save_restorer: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d fixture=4642ded6d026f456acf798a43efb081b76987018@10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4 configuration=muhtari-ntsc-battery-diagnostic media=muhtari-battery-v1 extent=34816 import=before-guest-work restored=1/1 continuation=2/2 result=pass\nmuhtari-save-rejections-marker=muhtari_save_rejections: cases=10 invalid-imports=0 unchanged-live-span=34816 valid-import=before-guest-work result=pass\nmuhtari-save-failed-update=passed\nmuhtari-save-failed-update-exit=0\nmuhtari-save-failed-update-elapsed-seconds=4\nmuhtari-save-failure-marker=muhtari_save_failure_writer: prefix-write=failed-before-rename committed-file=previous-exact host-ack=previous-exact previous=1/1 attempted=2/2 generation-ack=preserved stage-cleanup=pass result=pass\nmuhtari-save-recovery=passed\nmuhtari-save-recovery-exit=0\nmuhtari-save-recovery-elapsed-seconds=5\nmuhtari-save-recovery-marker=muhtari_save_recovery: prior-commit=1/1 recovered=1/1 continuation=2/2 process=fresh result=pass\nmuhtari-save-restart=writer,committed-fresh-restorer,failed-update,fresh-recovery result=pass\nmuhtari-save-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-save-libfuturo-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-save-core-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nisolation_stage=muhtari-save-writer checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-save-fresh-restorer checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-save-failed-update checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\nisolation_stage=muhtari-save-recovery checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\ninstalled_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libmuhtari.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  string(APPEND _muhtari_save_report
    "muhtari-save-oracle-negative-control=passed\nmuhtari-save-oracle-negative-control-exit=0\nmuhtari-save-oracle-negative-control-elapsed-seconds=3\nmuhtari-save-oracle-negative-control-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nmuhtari-save-oracle-negative-control-marker=muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1\nisolation_stage=muhtari-save-oracle-negative-control checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\n")
  assert_consumer_control(muhtari_save_complete installed_muhtari_save_restart
    "${_muhtari_save_report}" accept)
  assert_consumer_control(muhtari_save_missing_marker installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-recovery-marker=missing\n" reject)
  assert_consumer_control(muhtari_save_wrong_source_pin installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari_dependency_commit=wrong\n" reject)
  string(REPLACE
    "installed_file_sha256=lib/libmuhtari.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _muhtari_save_without_archive "${_muhtari_save_report}")
  assert_consumer_control(muhtari_save_missing_archive_identity
    installed_muhtari_save_restart "${_muhtari_save_without_archive}" reject)
  string(REPLACE
    "muhtari-save-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _muhtari_save_without_executable "${_muhtari_save_report}")
  assert_consumer_control(muhtari_save_missing_executable_identity
    installed_muhtari_save_restart "${_muhtari_save_without_executable}" reject)
  assert_consumer_control(muhtari_save_missing_oracle_control
    installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-oracle-negative-control=missing\n" reject)
  assert_consumer_control(muhtari_save_wrong_oracle_marker
    installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-oracle-negative-control-marker=wrong\n" reject)
  assert_consumer_control(muhtari_save_oracle_nonzero_child
    installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-oracle-negative-control-exit=143\n" reject)
  assert_consumer_control(muhtari_save_nonzero_child installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-failed-update-exit=8\n" reject)
  assert_consumer_control(muhtari_save_cancelled_child installed_muhtari_save_restart
    "${_muhtari_save_report}muhtari-save-recovery=cancelled\nmuhtari-save-recovery-exit=143\n" reject)
  set(_snapshot_consumer_report
    "format=libfuturo-relocation-save-restart-v1\nsource_commit=0123456789abcdef0123456789abcdef01234567\ndependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\nconsumer_executable_sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsnapshot-source-commit=0123456789abcdef0123456789abcdef01234567\nsnapshot-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\nsnapshot-profile=nesturbator-ntsc-v1\nsnapshot-effective-configuration=nesturbator-default\nsnapshot-fixture=generated-battery-free-nrom-v1 bytes=24592\nsnapshot-route=Darwin/arm64 moved-prefix-only\nsnapshot-child-exit=0\nsnapshot-result-marker=source:2338608ab184f040620a30d17756f5e06a42d4e3 profile:nesturbator-ntsc-v1 configuration:nesturbator-default fixture:generated-battery-free-nrom-v1 child-exit:0 result:pass\nsnapshot-consumer-marker=nesturbator_snapshot_installed_consumer: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 configuration=nesturbator-default fixture=generated-battery-free-nrom-v1 replay=frame3,ticks2144304,av-literal refusals=5,continuation-preserved result=pass\nsnapshot-relocated-libfuturo-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsnapshot-relocated-core-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nsnapshot-consumer-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nisolation_stage=installed-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\ninstalled_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libnesturbator.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_consumer_control(snapshot_complete installed_consumer_snapshot
    "${_snapshot_consumer_report}" accept)
  assert_consumer_control(snapshot_missing_marker installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-result-marker=missing\n" reject)
  assert_consumer_control(snapshot_wrong_core_pin installed_consumer_snapshot
    "${_snapshot_consumer_report}dependency_commit=wrong\n" reject)
  assert_consumer_control(snapshot_wrong_profile installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-profile=wrong\n" reject)
  assert_consumer_control(snapshot_wrong_configuration installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-effective-configuration=wrong\n" reject)
  assert_consumer_control(snapshot_wrong_fixture installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-fixture=wrong\n" reject)
  assert_consumer_control(snapshot_wrong_format installed_consumer_snapshot
    "${_snapshot_consumer_report}format=wrong\n" reject)
  string(REPLACE
    "isolation_stage=installed-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\n"
    "" _snapshot_without_stage "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_missing_stage installed_consumer_snapshot
    "${_snapshot_without_stage}" reject)
  string(REPLACE
    "installed_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _snapshot_without_libfuturo "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_missing_archive_identity
    installed_consumer_snapshot "${_snapshot_without_libfuturo}" reject)
  string(REPLACE
    "installed_file_sha256=lib/libnesturbator.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _snapshot_without_core "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_missing_core_identity
    installed_consumer_snapshot "${_snapshot_without_core}" reject)
  string(REPLACE
    "snapshot-consumer-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _snapshot_without_executable "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_missing_executable_identity
    installed_consumer_snapshot "${_snapshot_without_executable}" reject)
  string(REPLACE
    "snapshot-relocated-libfuturo-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "snapshot-relocated-libfuturo-archive-sha256=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    _snapshot_wrong_libfuturo_identity "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_wrong_libfuturo_identity
    installed_consumer_snapshot "${_snapshot_wrong_libfuturo_identity}" reject)
  string(REPLACE
    "snapshot-relocated-core-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "snapshot-relocated-core-archive-sha256=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    _snapshot_wrong_core_identity "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_wrong_core_identity
    installed_consumer_snapshot "${_snapshot_wrong_core_identity}" reject)
  string(REPLACE
    "snapshot-consumer-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "snapshot-consumer-executable-sha256=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    _snapshot_wrong_executable_identity "${_snapshot_consumer_report}")
  assert_consumer_control(snapshot_wrong_executable_identity
    installed_consumer_snapshot "${_snapshot_wrong_executable_identity}" reject)
  assert_consumer_control(snapshot_nonzero_child installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-child-exit=8\n" reject)
  assert_consumer_control(snapshot_timeout_child installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-child-exit=124\n" reject)
  assert_consumer_control(snapshot_cancelled_child installed_consumer_snapshot
    "${_snapshot_consumer_report}snapshot-child-exit=143\n" reject)
  fresh_process_control_report(source _source_fresh_process_report)
  fresh_process_control_report(installed _installed_fresh_process_report)
  assert_consumer_control(fresh_process_source_complete source_fresh_process_snapshot
    "${_source_fresh_process_report}" accept)
  assert_consumer_control(fresh_process_installed_complete
    installed_consumer_fresh_process_snapshot
    "${_installed_fresh_process_report}" accept)
  battery_fresh_process_control_report(source _source_battery_fresh_process_report)
  battery_fresh_process_control_report(installed _installed_battery_fresh_process_report)
  assert_consumer_control(fresh_process_source_battery_complete
    source_battery_fresh_process_snapshot
    "${_source_battery_fresh_process_report}" accept)
  assert_consumer_control(fresh_process_installed_battery_complete
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}" accept)
  string(REPLACE
    "installed-battery-fresh-process-junit=relocate-libfuturo-relocate.control123-battery-fresh-process.junit.xml\n"
    "installed-battery-fresh-process-junit=../../stale.junit.xml\n"
    _battery_fresh_process_traversal_junit "${_installed_battery_fresh_process_report}")
  assert_consumer_control(battery_fresh_process_traversal_junit
    installed_consumer_battery_fresh_process_snapshot
    "${_battery_fresh_process_traversal_junit}" reject)
  assert_battery_identity_pair_control(battery_identity_pair_complete
    "${_source_battery_fresh_process_report}"
    "${_installed_battery_fresh_process_report}" accept)
  string(REPLACE
    "installed-battery-fresh-process-source-worktree-fingerprint=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    "installed-battery-fresh-process-source-worktree-fingerprint=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    _battery_fresh_process_identity_pair_mismatch
    "${_installed_battery_fresh_process_report}")
  assert_battery_identity_pair_control(battery_identity_pair_fingerprint_mismatch
    "${_source_battery_fresh_process_report}"
    "${_battery_fresh_process_identity_pair_mismatch}" reject)
  assert_battery_report_path_control(battery_report_path_complete
    "relocation-reports/relocate-libfuturo-relocate.control123.txt"
    "${_installed_battery_fresh_process_report}" accept)
  assert_battery_report_path_control(battery_report_path_wrong_run_id
    "relocation-reports/relocate-stale.txt"
    "${_installed_battery_fresh_process_report}" reject)
  assert_battery_report_mutation(battery_report_duplicate_run_id
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "run_id=libfuturo-relocate.control123\n"
    "run_id=libfuturo-relocate.control123\nrun_id=libfuturo-relocate.control123\n")

  assert_battery_report_mutation(battery_source_old_battery_free_substitution
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "format=libfuturo-source-battery-fresh-process-snapshot-v1\n"
    "format=libfuturo-source-fresh-process-snapshot-v1\n")
  assert_battery_report_mutation(battery_source_duplicate_identity
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "source_commit=0123456789abcdef0123456789abcdef01234567\n"
    "source_commit=0123456789abcdef0123456789abcdef01234567\nsource_commit=0123456789abcdef0123456789abcdef01234567\n")
  assert_battery_report_mutation(battery_source_missing_success_marker
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=supervisor-success\n" "")
  assert_battery_report_mutation(battery_source_duplicate_event
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=supervisor-success\n"
    "fresh-process-event=event=supervisor-success\nfresh-process-event=event=supervisor-success\n")
  assert_battery_report_mutation(battery_source_duplicate_refusal
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
    "fresh-process-event=event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\nfresh-process-event=event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n")
  assert_battery_report_mutation(battery_source_missing_refusal
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=battery-b-refusal name=truncated_native_payload status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
    "")
  assert_battery_report_mutation(battery_source_missing_close
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=a-success-closed-and-destroyed\n" "")
  assert_battery_report_mutation(battery_source_missing_reopen
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=checkpoint-reopened bytes=13496 sha256=f806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n"
    "")
  assert_battery_report_mutation(battery_source_missing_save_custody
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-event=event=battery-save-custody-r3-imported-r2-restored-r2-committed\n"
    "")
  assert_battery_report_mutation(battery_source_wrong_save_generation
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "refusal-baseline-generation=4" "refusal-baseline-generation=5")
  assert_battery_report_mutation(battery_source_wrong_frame
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "replay=frame3,ticks2144280" "replay=frame4,ticks2144280")
  assert_battery_report_mutation(battery_source_wrong_ticks
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "replay=frame3,ticks2144280" "replay=frame3,ticks2144281")
  assert_battery_report_mutation(battery_source_wrong_video
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "video=5a5a5a" "video=5a5a5b")
  assert_battery_report_mutation(battery_source_wrong_audio
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "audio=799-silence" "audio=798-silence")
  assert_battery_report_mutation(battery_source_wrong_media_span
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "media=full-8192" "media=full-8191")
  assert_battery_report_mutation(battery_source_wrong_pin
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "dependency_commit=1338608ab184f040620a30d17756f5e06a42d4e3\n")
  assert_battery_report_mutation(battery_source_wrong_release
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-core-release=v0.1.12\n" "fresh-process-core-release=v0.1.11\n")
  assert_battery_report_mutation(battery_source_wrong_core_revision
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "fresh-process-core-source-revision=1338608ab184f040620a30d17756f5e06a42d4e3\n")
  assert_battery_report_mutation(battery_source_wrong_build_id
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-libfuturo-build-id=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "fresh-process-libfuturo-build-id=sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_battery_report_mutation(battery_source_wrong_target
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-target=Darwin/arm64\n" "fresh-process-target=Darwin/x86_64\n")
  assert_battery_report_mutation(battery_source_wrong_fixture_extent
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "battery-fixture=generated-battery-mmc1-v1 bytes=40976"
    "battery-fixture=generated-battery-mmc1-v1 bytes=40975")
  assert_battery_report_mutation(battery_source_wrong_fixture_digest
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9"
    "sha256=1282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
  assert_battery_report_mutation(battery_source_wrong_checkpoint_extent
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-checkpoint-bytes=13496\n" "fresh-process-checkpoint-bytes=13497\n")
  assert_battery_report_mutation(battery_source_wrong_checkpoint_digest
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-checkpoint-sha256=sha256:f806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n"
    "fresh-process-checkpoint-sha256=sha256:0806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n")
  assert_battery_report_mutation(battery_source_missing_artifact
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-helper-artifact-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "")
  assert_battery_report_mutation(battery_source_bad_artifact_hash
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-core-artifact-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "fresh-process-core-artifact-sha256=sha256:bad\n")
  foreach(_bad_status IN ITEMS failed skipped cancelled timed-out)
    assert_battery_report_mutation(battery_source_${_bad_status}
      source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
      "fresh-process-status=passed\n" "fresh-process-status=${_bad_status}\n")
  endforeach()
  assert_battery_report_mutation(battery_source_nonzero_a
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-a-exit=0\n" "fresh-process-a-exit=8\n")
  assert_battery_report_mutation(battery_source_nonzero_b
    source_battery_fresh_process_snapshot "${_source_battery_fresh_process_report}"
    "fresh-process-b-exit=0\n" "fresh-process-b-exit=8\n")

  assert_battery_report_mutation(battery_installed_old_battery_free_substitution
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "format=libfuturo-relocation-battery-fresh-process-snapshot-v1\n"
    "format=libfuturo-relocation-fresh-process-snapshot-v1\n")
  assert_battery_report_mutation(battery_installed_duplicate_identity
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "source_commit=0123456789abcdef0123456789abcdef01234567\n"
    "source_commit=0123456789abcdef0123456789abcdef01234567\nsource_commit=0123456789abcdef0123456789abcdef01234567\n")
  assert_battery_report_mutation(battery_installed_missing_success_marker
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=supervisor-success\n" "")
  assert_battery_report_mutation(battery_installed_duplicate_event
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=supervisor-success\n"
    "installed-battery-fresh-process-event=supervisor-success\ninstalled-battery-fresh-process-event=supervisor-success\n")
  assert_battery_report_mutation(battery_installed_duplicate_refusal
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
    "installed-battery-fresh-process-event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\ninstalled-battery-fresh-process-event=battery-b-refusal name=native_corruption status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n")
  assert_battery_report_mutation(battery_installed_missing_refusal
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=battery-b-refusal name=truncated_native_payload status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n"
    "")
  assert_battery_report_mutation(battery_installed_missing_close
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=a-success-closed-and-destroyed\n" "")
  assert_battery_report_mutation(battery_installed_missing_reopen
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=checkpoint-reopened bytes=13496 sha256=f806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n"
    "")
  assert_battery_report_mutation(battery_installed_missing_save_custody
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-event=battery-save-custody-r3-imported-r2-restored-r2-committed\n"
    "")
  assert_battery_report_mutation(battery_installed_wrong_save_generation
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "refusal-baseline-generation=4" "refusal-baseline-generation=5")
  assert_battery_report_mutation(battery_installed_wrong_frame
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "literal-replay=frame3,ticks2144280" "literal-replay=frame4,ticks2144280")
  assert_battery_report_mutation(battery_installed_wrong_ticks
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "literal-replay=frame3,ticks2144280" "literal-replay=frame3,ticks2144281")
  assert_battery_report_mutation(battery_installed_wrong_video
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "video=5a5a5a" "video=5a5a5b")
  assert_battery_report_mutation(battery_installed_wrong_audio
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "audio=799-silence" "audio=798-silence")
  assert_battery_report_mutation(battery_installed_wrong_media_span
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "media=full-8192" "media=full-8191")
  assert_battery_report_mutation(battery_installed_wrong_pin
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "dependency_commit=1338608ab184f040620a30d17756f5e06a42d4e3\n")
  assert_battery_report_mutation(battery_installed_wrong_release
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-core-release=v0.1.12\n"
    "installed-battery-fresh-process-core-release=v0.1.11\n")
  assert_battery_report_mutation(battery_installed_wrong_revision
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "installed-battery-fresh-process-core-source-revision=1338608ab184f040620a30d17756f5e06a42d4e3\n")
  assert_battery_report_mutation(battery_installed_wrong_profile
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-profile=nesturbator-ntsc-v1\n"
    "installed-battery-fresh-process-profile=wrong-profile\n")
  assert_battery_report_mutation(battery_installed_wrong_configuration
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-effective-configuration=nesturbator-default\n"
    "installed-battery-fresh-process-effective-configuration=wrong-config\n")
  assert_battery_report_mutation(battery_installed_wrong_identity_options
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "options=nesturbator-options-none-v1" "options=wrong-options")
  assert_battery_report_mutation(battery_installed_wrong_native_format
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "state-format=3" "state-format=4")
  assert_battery_report_mutation(battery_installed_wrong_fixture_extent
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-fixture=generated-battery-mmc1-v1 bytes=40976"
    "installed-battery-fresh-process-fixture=generated-battery-mmc1-v1 bytes=40975")
  assert_battery_report_mutation(battery_installed_wrong_fixture_digest
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9"
    "sha256=1282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9")
  assert_battery_report_mutation(battery_installed_wrong_route
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-route=Darwin/arm64 moved-prefix-only\n"
    "installed-battery-fresh-process-route=Darwin/x86_64 moved-prefix-only\n")
  assert_battery_report_mutation(battery_installed_wrong_checkpoint_extent
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-checkpoint-bytes=13496\n"
    "installed-battery-fresh-process-checkpoint-bytes=13497\n")
  assert_battery_report_mutation(battery_installed_wrong_checkpoint_digest
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-checkpoint-sha256=sha256:f806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n"
    "installed-battery-fresh-process-checkpoint-sha256=sha256:0806b2600f5ee3eb6c413e59ac6b0ce6fbede6d774aafd46f8046212d86f789d\n")
  assert_battery_report_mutation(battery_installed_wrong_executable
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "consumer_executable_sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "consumer_executable_sha256=sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_battery_report_mutation(battery_installed_wrong_package_artifact
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-libfuturo-package-targets-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "installed-battery-fresh-process-libfuturo-package-targets-sha256=sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  assert_battery_report_mutation(battery_installed_missing_package_row
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed_file_sha256=lib/cmake/libfuturo/libfuturoTargets.cmake sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "")
  foreach(_bad_status IN ITEMS failed skipped cancelled timed-out)
    assert_battery_report_mutation(battery_installed_${_bad_status}
      installed_consumer_battery_fresh_process_snapshot
      "${_installed_battery_fresh_process_report}"
      "installed-battery-fresh-process-status=passed\n"
      "installed-battery-fresh-process-status=${_bad_status}\n")
  endforeach()
  assert_battery_report_mutation(battery_installed_nonzero_child
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-child-exit=0\n"
    "installed-battery-fresh-process-child-exit=8\n")
  assert_battery_report_mutation(battery_installed_nonzero_a
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-a-exit=0\n"
    "installed-battery-fresh-process-a-exit=8\n")
  assert_battery_report_mutation(battery_installed_nonzero_b
    installed_consumer_battery_fresh_process_snapshot
    "${_installed_battery_fresh_process_report}"
    "installed-battery-fresh-process-b-exit=0\n"
    "installed-battery-fresh-process-b-exit=8\n")

  string(REPLACE
    "fresh-process-event=event=supervisor-start\nfresh-process-event=event=a-start\n"
    "fresh-process-event=event=a-start\nfresh-process-event=event=supervisor-start\n"
    _fresh_process_reordered "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_reordered_events source_fresh_process_snapshot
    "${_fresh_process_reordered}" reject)
  string(REPLACE
    "fresh-process-event=event=snapshot-case name=content_digest status=invalid-argument result=pass continuation=literal native_attempt_delta=0\n"
    "" _fresh_process_missing_refusal "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_missing_refusal source_fresh_process_snapshot
    "${_fresh_process_missing_refusal}" reject)
  string(REPLACE
    "fresh-process-event=event=supervisor-success\n"
    "" _fresh_process_missing_marker "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_missing_marker source_fresh_process_snapshot
    "${_fresh_process_missing_marker}" reject)
  string(REPLACE
    "fresh-process-runtime-identity=envelope-version=2"
    "fresh-process-runtime-identity=envelope-version=9"
    _fresh_process_wrong_identity "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_wrong_identity source_fresh_process_snapshot
    "${_fresh_process_wrong_identity}" reject)
  string(REPLACE
    "fresh-process-checkpoint-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "fresh-process-checkpoint-sha256=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    _fresh_process_wrong_checkpoint_hash "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_wrong_checkpoint_hash source_fresh_process_snapshot
    "${_fresh_process_wrong_checkpoint_hash}" reject)
  string(REPLACE "fresh-process-checkpoint-bytes=5290\n"
    "fresh-process-checkpoint-bytes=5291\n" _fresh_process_wrong_extent
    "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_wrong_checkpoint_extent
    source_fresh_process_snapshot "${_fresh_process_wrong_extent}" reject)
  string(REPLACE
    "fresh-process-core-artifact-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "" _fresh_process_missing_artifact "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_missing_artifact source_fresh_process_snapshot
    "${_fresh_process_missing_artifact}" reject)
  string(REPLACE
    "fresh-process-core-artifact-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "fresh-process-core-artifact-sha256=sha256:bad\n"
    _fresh_process_bad_artifact_hash "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_bad_artifact_hash source_fresh_process_snapshot
    "${_fresh_process_bad_artifact_hash}" reject)
  foreach(_bad_status IN ITEMS failed skipped timed-out cancelled)
    string(REPLACE "fresh-process-status=passed\n"
      "fresh-process-status=${_bad_status}\n" _fresh_process_bad_status
      "${_source_fresh_process_report}")
    assert_consumer_control(fresh_process_${_bad_status}
      source_fresh_process_snapshot "${_fresh_process_bad_status}" reject)
  endforeach()
  string(REPLACE "fresh-process-a-exit=0\n" "fresh-process-a-exit=8\n"
    _fresh_process_nonzero "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_nonzero_child source_fresh_process_snapshot
    "${_fresh_process_nonzero}" reject)
  string(REPLACE "fresh-process-wrong-oracle=rejected\n"
    "fresh-process-wrong-oracle=accepted\n" _fresh_process_wrong_oracle
    "${_source_fresh_process_report}")
  assert_consumer_control(fresh_process_wrong_oracle source_fresh_process_snapshot
    "${_fresh_process_wrong_oracle}" reject)
  string(REPLACE
    "fresh-process-package-libfuturo-config-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "fresh-process-package-libfuturo-config-sha256=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\n"
    _fresh_process_wrong_package "${_installed_fresh_process_report}")
  assert_consumer_control(fresh_process_wrong_package_artifact
    installed_consumer_fresh_process_snapshot "${_fresh_process_wrong_package}" reject)
  assert_control(battery_missing_registration required passed
    FALSE FALSE FALSE FALSE FALSE reject)
  assert_control(battery_missing_report required passed
    TRUE TRUE TRUE FALSE FALSE reject)
  set(_battery_consumer_report
    "format=libfuturo-relocation-save-restart-v1\nsource_commit=0123456789abcdef0123456789abcdef01234567\ndependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\nconsumer_executable_sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nbattery-snapshot-source-commit=0123456789abcdef0123456789abcdef01234567\nbattery-snapshot-source-worktree=dirty\nbattery-snapshot-source-worktree-fingerprint=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nbattery-snapshot-core-release=v0.1.12\nbattery-snapshot-core-source-revision=2338608ab184f040620a30d17756f5e06a42d4e3\nbattery-snapshot-profile=nesturbator-ntsc-v1\nbattery-snapshot-effective-configuration=nesturbator-default\nbattery-snapshot-fixture=generated-battery-mmc1-v1\nbattery-snapshot-fixture-bytes=40976\nbattery-snapshot-fixture-sha256=sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9\nbattery-snapshot-route=Darwin/arm64 moved-prefix-only\nbattery-snapshot-build-id=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3\nbattery-snapshot-api-revision=1\nbattery-snapshot-behavior-revision=9\nbattery-snapshot-state-format-version=3\nbattery-snapshot-test-inventory=exact\nbattery-snapshot-result=passed\nbattery-snapshot-stage-exit=0\nbattery-snapshot-stage-elapsed-seconds=1\nbattery-snapshot-recovery-status=passed\nbattery-snapshot-recovery-exit=0\nbattery-snapshot-recovery-marker=nesturbator_battery_snapshot: route=installed source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass\nbattery-snapshot-oracle-control-status=passed\nbattery-snapshot-oracle-control-exit=0\nbattery-snapshot-oracle-control-marker=nesturbator_battery_snapshot_oracle_control: route=installed progress,video,audio,media=rejected result=pass\nbattery-snapshot-relocated-libfuturo-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nbattery-snapshot-relocated-core-archive-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nbattery-snapshot-consumer-executable-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nisolation_stage=installed-battery-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\ninstalled_file_sha256=lib/liblibfuturo.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ninstalled_file_sha256=lib/libnesturbator.a sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")
  string(REPLACE
    "source_commit=0123456789abcdef0123456789abcdef01234567\n"
    "source_commit=0123456789abcdef0123456789abcdef01234567\nsource_worktree_fingerprint=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    _battery_consumer_report "${_battery_consumer_report}")
  assert_consumer_control(battery_complete installed_consumer_battery_snapshot
    "${_battery_consumer_report}" accept)
  foreach(_key IN ITEMS battery-snapshot-result)
    string(REGEX REPLACE "${_key}=[^\n]*\n" "" _battery_without_result
      "${_battery_consumer_report}")
    assert_consumer_control(battery_missing_${_key}
      installed_consumer_battery_snapshot "${_battery_without_result}" reject)
  endforeach()
  macro(assert_battery_field_rejected name key old_value new_value)
    string(REPLACE "${key}=${old_value}\n" "${key}=${new_value}\n"
      _battery_mutated_report "${_battery_consumer_report}")
    assert_consumer_control(${name} installed_consumer_battery_snapshot
      "${_battery_mutated_report}" reject)
  endmacro()
  assert_battery_field_rejected(battery_wrong_core_pin dependency_commit
    2338608ab184f040620a30d17756f5e06a42d4e3 wrong)
  assert_battery_field_rejected(battery_wrong_release battery-snapshot-core-release
    v0.1.12 v0.1.11)
  assert_battery_field_rejected(battery_wrong_profile battery-snapshot-profile
    nesturbator-ntsc-v1 wrong-profile)
  assert_battery_field_rejected(battery_wrong_configuration
    battery-snapshot-effective-configuration nesturbator-default wrong-config)
  assert_battery_field_rejected(battery_wrong_fixture battery-snapshot-fixture
    generated-battery-mmc1-v1 wrong-fixture)
  assert_battery_field_rejected(battery_wrong_fixture_digest
    battery-snapshot-fixture-sha256
    sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9
    sha256:1282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9)
  assert_battery_field_rejected(battery_wrong_fixture_extent
    battery-snapshot-fixture-bytes 40976 40975)
  assert_battery_field_rejected(battery_wrong_target battery-snapshot-route
    "Darwin/arm64 moved-prefix-only" "Linux/x86_64 build-prefix")
  assert_battery_field_rejected(battery_wrong_state_format
    battery-snapshot-state-format-version 3 6)
  assert_battery_field_rejected(battery_wrong_api_revision
    battery-snapshot-api-revision 1 2)
  assert_battery_field_rejected(battery_wrong_behavior_revision
    battery-snapshot-behavior-revision 9 10)
  assert_battery_field_rejected(battery_wrong_build_id battery-snapshot-build-id
    nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 wrong-build)
  assert_battery_field_rejected(battery_wrong_source_commit source_commit
    0123456789abcdef0123456789abcdef01234567 1123456789abcdef0123456789abcdef01234567)
  assert_battery_field_rejected(battery_wrong_source_fingerprint
    battery-snapshot-source-worktree-fingerprint
    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
  assert_battery_field_rejected(battery_wrong_libfuturo_hash
    battery-snapshot-relocated-libfuturo-archive-sha256
    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
  assert_battery_field_rejected(battery_wrong_core_hash
    battery-snapshot-relocated-core-archive-sha256
    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
  assert_battery_field_rejected(battery_wrong_executable_hash
    battery-snapshot-consumer-executable-sha256
    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
  foreach(_key IN ITEMS battery-snapshot-relocated-libfuturo-archive-sha256
      battery-snapshot-relocated-core-archive-sha256
      battery-snapshot-consumer-executable-sha256 consumer_executable_sha256)
    string(REGEX REPLACE "${_key}=[^\n]*\n" "" _battery_without_hash
      "${_battery_consumer_report}")
    assert_consumer_control(battery_missing_${_key}
      installed_consumer_battery_snapshot "${_battery_without_hash}" reject)
  endforeach()
  foreach(_archive IN ITEMS lib/liblibfuturo.a lib/libnesturbator.a)
    string(REGEX REPLACE "installed_file_sha256=${_archive} sha256:[^\n]*\n" ""
      _battery_without_installed_archive "${_battery_consumer_report}")
    assert_consumer_control(battery_missing_${_archive}_installed_record
      installed_consumer_battery_snapshot "${_battery_without_installed_archive}" reject)
  endforeach()
  string(REPLACE
    "isolation_stage=installed-battery-snapshot checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\n"
    "" _battery_without_stage "${_battery_consumer_report}")
  assert_consumer_control(battery_missing_stage installed_consumer_battery_snapshot
    "${_battery_without_stage}" reject)
  macro(assert_battery_marker_fragment_rejected name old_fragment new_fragment)
    string(REPLACE "${old_fragment}" "${new_fragment}"
      _battery_mutated_marker_report "${_battery_consumer_report}")
    assert_consumer_control(${name} installed_consumer_battery_snapshot
      "${_battery_mutated_marker_report}" reject)
  endmacro()
  assert_battery_marker_fragment_rejected(battery_wrong_replay_literal
    "replay=frame3,ticks2144280,rgb5a5a5a,audio799"
    "replay=frame4,ticks2144280,rgb5a5a5a,audio799")
  assert_battery_marker_fragment_rejected(battery_wrong_full_media_literal
    "media=full-span-8192,restored-literal" "media=extent-only")
  assert_battery_marker_fragment_rejected(battery_wrong_generation_delta
    "generation=changed-once,identical-unchanged" "generation=unchanged")
  assert_battery_marker_fragment_rejected(battery_wrong_refusal_vector
    "refusal-vector=continuation,media,generation,selected-save,ack"
    "refusal-vector=continuation-only")
  assert_battery_marker_fragment_rejected(battery_unqualified_route_refusal
    "foreign=altered-mmc1,mmc3-refused" "foreign=not-checked")
  assert_battery_marker_fragment_rejected(battery_wrong_failed_replacement
    "failed-replacement=prior-commit-and-ack-preserved"
    "failed-replacement=not-checked")
  assert_battery_marker_fragment_rejected(battery_wrong_successful_reopen
    "recovery=prior-exact,restored-selected,reopened-exact"
    "recovery=prior-exact,restored-selected")
  foreach(_key IN ITEMS battery-snapshot-recovery-marker
      battery-snapshot-oracle-control-marker)
    string(REGEX REPLACE "${_key}=[^\n]*\n" "" _battery_without_marker
      "${_battery_consumer_report}")
    assert_consumer_control(battery_missing_${_key}
      installed_consumer_battery_snapshot "${_battery_without_marker}" reject)
  endforeach()
  assert_battery_field_rejected(battery_recovery_nonzero_child
    battery-snapshot-recovery-exit 0 8)
  assert_battery_field_rejected(battery_recovery_skipped_child
    battery-snapshot-recovery-status passed skipped)
  assert_battery_field_rejected(battery_oracle_nonzero_child
    battery-snapshot-oracle-control-exit 0 8)
  assert_battery_field_rejected(battery_recovery_timeout_child
    battery-snapshot-recovery-status passed timed-out)
  assert_battery_field_rejected(battery_recovery_cancelled_child
    battery-snapshot-recovery-status passed cancelled)
  assert_battery_field_rejected(battery_oracle_skipped_child
    battery-snapshot-oracle-control-status passed skipped)
  assert_battery_field_rejected(battery_oracle_cancelled_child
    battery-snapshot-oracle-control-status passed cancelled)
  assert_battery_field_rejected(battery_stage_failed
    battery-snapshot-result passed failed)
  assert_battery_marker_fragment_rejected(battery_wrong_oracle_marker
    "nesturbator_battery_snapshot_oracle_control: route=installed progress,video,audio,media=rejected result=pass"
    "nesturbator_battery_snapshot_oracle_control: wrong")
  string(APPEND _battery_consumer_report
    "battery-snapshot-profile=nesturbator-ntsc-v1\n")
  assert_consumer_control(battery_duplicate_identity
    installed_consumer_battery_snapshot "${_battery_consumer_report}" reject)
  string(APPEND _battery_consumer_report
    "battery-snapshot-recovery-exit=0\n")
  assert_consumer_control(battery_duplicate_child_exit
    installed_consumer_battery_snapshot "${_battery_consumer_report}" reject)
  assert_consumer_control(battery_legacy_snapshot_only
    installed_consumer_battery_snapshot "${_snapshot_consumer_report}" reject)
  assert_consumer_control(battery_save_only
    installed_consumer_battery_snapshot "${_save_consumer_report}" reject)
  message(STATUS
    "required_result_validator: controls=required-positive,missing-registration,missing-report,disabled,failed,skipped,cancelled,evidence-free,advisory-pass,advisory-failure,unsupported,distinct-save-load,missing-load-marker,nonzero-child,timeout,cancelled-child,save-only,unknown-consumer,muhtari-complete,muhtari-missing-marker,muhtari-nonzero-child,muhtari-missing-normal-link,muhtari-legacy-only,muhtari-missing-normal,muhtari-missing-refusal,muhtari-missing-boundaries,muhtari-missing-oracle-control,muhtari-missing-archive,muhtari-nonzero-boundary,muhtari-timeout-boundary,muhtari-cancelled-boundary,muhtari-unexpected-unsupported,muhtari-save-complete,muhtari-save-missing-marker,muhtari-save-wrong-source-pin,muhtari-save-missing-archive,muhtari-save-missing-executable,muhtari-save-missing-oracle-control,muhtari-save-wrong-oracle-marker,muhtari-save-oracle-nonzero-child,muhtari-save-nonzero-child,muhtari-save-cancelled-child,snapshot-complete,snapshot-missing-marker,snapshot-wrong-pin-profile-configuration-fixture-format,snapshot-missing-stage-and-archive-executable-identities,snapshot-wrong-libfuturo-identity,snapshot-wrong-core-identity,snapshot-wrong-executable-identity,snapshot-nonzero-timeout-cancelled-child,fresh-process-source-complete,fresh-process-installed-complete,fresh-process-reordered-events,fresh-process-missing-refusal,fresh-process-missing-marker,fresh-process-wrong-identity,fresh-process-wrong-checkpoint-hash,fresh-process-wrong-checkpoint-extent,fresh-process-missing-artifact,fresh-process-bad-artifact-hash,fresh-process-failed,fresh-process-skipped,fresh-process-timeout,fresh-process-cancelled,fresh-process-nonzero-child,fresh-process-wrong-oracle,fresh-process-wrong-package-artifact,battery-complete,missing-registration-report-result,battery-wrong-pin-release-profile-configuration-fixture-digest-extent-target,wrong-state-format-api-behavior-build,wrong-source-commit-fingerprint,wrong-libfuturo-core-executable-hash,missing-source-and-installed-artifact-hashes,wrong-replay-full-media-generation-refusal-native-identity,wrong-failed-replacement-or-successful-reopen,missing-stage-recovery-oracle-marker,wrong-oracle-marker,recovery-nonzero-skipped-timeout-cancelled,oracle-nonzero-skipped-cancelled,stage-failed,duplicate-identity-child-exit,legacy-snapshot-save-only result=pass")
  message(STATUS
    "required_result_validator_battery: routes=source,installed;controls=positive,identity-pair-mismatch,report-path-run-id-junit-traversal,duplicate-identity-event-refusal,missing-marker-refusal-close-reopen-save-custody,wrong-status-exit-pin-release-build-profile-config-options-native-format-fixture-digest-extent-target-checkpoint-digest-extent,replay-frame-ticks-video-audio-media,generation-binding,source-artifact-missing-bad-hash,installed-executable-package-hash-row result=pass")
  return()
endif()

if(NOT RESULT_CASES STREQUAL "actual")
  message(FATAL_ERROR "RESULT_CASES must be 'all' or 'actual'")
endif()

foreach(_required_var RESULT_MANIFEST EXPECTED_MARKERS_FILE CTEST_INVENTORY
    CTEST_JUNIT CTEST_LOG CTEST_PROCESS_FACTS RELOCATION_REPORT RESULT_OUTPUT
    SOURCE_FRESH_PROCESS_REPORT FRESH_PROCESS_RELOCATION_REPORT
    SOURCE_BATTERY_FRESH_PROCESS_REPORT BATTERY_FRESH_PROCESS_RELOCATION_REPORT
    MACOS_HOST_REPORT MACOS_HOST_ARTIFACT_ROOT RESULT_BASE_DIR PRIVATE_ROOT)
  if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
    message(FATAL_ERROR "${_required_var} is required for actual result validation")
  endif()
endforeach()

set(_route_ok TRUE)
set(_ctest_inventory_present FALSE)
set(_ctest_junit_present FALSE)
set(_ctest_log_present FALSE)
set(_consumer_report_present FALSE)
if(EXISTS "${CTEST_INVENTORY}" AND NOT IS_DIRECTORY "${CTEST_INVENTORY}")
  file(READ "${CTEST_INVENTORY}" _inventory)
  string(JSON _inventory_kind ERROR_VARIABLE _inventory_error GET "${_inventory}" kind)
  if(_inventory_error STREQUAL "NOTFOUND" AND _inventory_kind STREQUAL "ctestInfo")
    set(_ctest_inventory_present TRUE)
  endif()
endif()
if(EXISTS "${CTEST_JUNIT}" AND NOT IS_DIRECTORY "${CTEST_JUNIT}")
  file(READ "${CTEST_JUNIT}" _junit)
  if(_junit MATCHES "<testsuite" OR _junit MATCHES "<testsuites")
    set(_ctest_junit_present TRUE)
  endif()
endif()
if(EXISTS "${CTEST_LOG}" AND NOT IS_DIRECTORY "${CTEST_LOG}")
  file(READ "${CTEST_LOG}" _ctest_log)
  set(_ctest_log_present TRUE)
endif()
if(EXISTS "${CTEST_PROCESS_FACTS}" AND NOT IS_DIRECTORY "${CTEST_PROCESS_FACTS}")
  file(STRINGS "${CTEST_PROCESS_FACTS}" _process_facts)
else()
  set(_process_facts "")
endif()

set(_ctest_exit_status "unknown")
set(_ctest_signal "none")
set(_ctest_timed_out "no")
set(_sanitizer_diagnostics "no")
foreach(_fact IN LISTS _process_facts)
  if(_fact MATCHES "^exit_status=([0-9]+)$")
    set(_ctest_exit_status "${CMAKE_MATCH_1}")
  elseif(_fact MATCHES "^signal=([A-Za-z0-9_-]+)$")
    set(_ctest_signal "${CMAKE_MATCH_1}")
  elseif(_fact MATCHES "^timed_out=(yes|no)$")
    set(_ctest_timed_out "${CMAKE_MATCH_1}")
  elseif(_fact MATCHES "^sanitizer_diagnostics=(yes|no)$")
    set(_sanitizer_diagnostics "${CMAKE_MATCH_1}")
  endif()
endforeach()
if(NOT _ctest_inventory_present OR NOT _ctest_log_present
   OR _ctest_exit_status STREQUAL "unknown"
   OR _sanitizer_diagnostics STREQUAL "yes")
  set(_route_ok FALSE)
endif()

file(STRINGS "${RESULT_MANIFEST}" _route_rows)
file(STRINGS "${EXPECTED_MARKERS_FILE}" _expected_markers)
set(_battery_identity_pair_valid FALSE)
if(EXISTS "${SOURCE_BATTERY_FRESH_PROCESS_REPORT}" AND
   NOT IS_DIRECTORY "${SOURCE_BATTERY_FRESH_PROCESS_REPORT}" AND
   EXISTS "${BATTERY_FRESH_PROCESS_RELOCATION_REPORT}" AND
   NOT IS_DIRECTORY "${BATTERY_FRESH_PROCESS_RELOCATION_REPORT}")
  file(READ "${SOURCE_BATTERY_FRESH_PROCESS_REPORT}" _source_battery_report)
  file(READ "${BATTERY_FRESH_PROCESS_RELOCATION_REPORT}" _installed_battery_report)
  battery_fresh_process_identity_pair_proof("${_source_battery_report}"
    "${_installed_battery_report}" _battery_identity_pair_valid)
endif()
file(WRITE "${RESULT_OUTPUT}"
  "kind|name|applicability|outcome|detail|registered|enabled|executed|proof|result_ref\n")
set(_required_rows 0)
set(_failed_required_rows 0)

function(inventory_test_state inventory test_name output_registered output_enabled)
  set(_registered FALSE)
  set(_enabled FALSE)
  if(_ctest_inventory_present)
    string(JSON _test_count ERROR_VARIABLE _tests_error LENGTH "${inventory}" tests)
    if(_tests_error STREQUAL "NOTFOUND" AND _test_count GREATER 0)
      math(EXPR _test_last "${_test_count} - 1")
      foreach(_index RANGE 0 ${_test_last})
        string(JSON _inventory_name GET "${inventory}" tests ${_index} name)
        if(_inventory_name STREQUAL "${test_name}")
          set(_registered TRUE)
          set(_enabled TRUE)
          string(JSON _property_count ERROR_VARIABLE _properties_error
            LENGTH "${inventory}" tests ${_index} properties)
          if(_properties_error STREQUAL "NOTFOUND" AND _property_count GREATER 0)
            math(EXPR _property_last "${_property_count} - 1")
            foreach(_property_index RANGE 0 ${_property_last})
              string(JSON _property_name GET "${inventory}" tests ${_index}
                properties ${_property_index} name)
              if(_property_name STREQUAL "DISABLED")
                string(JSON _disabled GET "${inventory}" tests ${_index}
                  properties ${_property_index} value)
                if(_disabled)
                  set(_enabled FALSE)
                endif()
              endif()
            endforeach()
          endif()
          break()
        endif()
      endforeach()
    endif()
  endif()
  set("${output_registered}" "${_registered}" PARENT_SCOPE)
  set("${output_enabled}" "${_enabled}" PARENT_SCOPE)
endfunction()

function(junit_test_state junit_present junit test_name output_seen output_status output_failure)
  set(_seen FALSE)
  set(_status "")
  set(_failure "")
  if(junit_present)
    string(REPLACE "\r" "" _junit_lines "${junit}")
    string(REPLACE "\n" ";" _junit_lines "${_junit_lines}")
    set(_in_testcase FALSE)
    foreach(_line IN LISTS _junit_lines)
      if(_line MATCHES "<testcase[ ]+name=\"${test_name}\"")
        set(_seen TRUE)
        set(_in_testcase TRUE)
        if(_line MATCHES "status=\"([^\"]+)\"")
          set(_status "${CMAKE_MATCH_1}")
        endif()
      elseif(_in_testcase AND _line MATCHES "<failure[ ]+message=\"([^\"]*)\"")
        set(_failure "${CMAKE_MATCH_1}")
      elseif(_in_testcase AND _line MATCHES "</testcase>")
        set(_in_testcase FALSE)
      endif()
    endforeach()
  endif()
  set("${output_seen}" "${_seen}" PARENT_SCOPE)
  set("${output_status}" "${_status}" PARENT_SCOPE)
  set("${output_failure}" "${_failure}" PARENT_SCOPE)
endfunction()

foreach(_row IN LISTS _route_rows)
  if(_row STREQUAL "")
    continue()
  endif()
  string(REPLACE "|" ";" _columns "${_row}")
  list(LENGTH _columns _column_count)
  if(NOT _column_count EQUAL 3)
    message(FATAL_ERROR "invalid required route manifest row '${_row}'")
  endif()
  list(GET _columns 0 _kind)
  list(GET _columns 1 _name)
  list(GET _columns 2 _applicability)
  if(NOT _applicability MATCHES "^(required|advisory|unsupported)$")
    message(FATAL_ERROR "invalid applicability in route manifest row '${_row}'")
  endif()

  set(_registered FALSE)
  set(_enabled FALSE)
  set(_executed FALSE)
  set(_proof FALSE)
  set(_report FALSE)
  set(_outcome "missing")
  set(_detail "")
  set(_result_ref "")

  if(_kind STREQUAL "ctest")
    inventory_test_state("${_inventory}" "${_name}" _registered _enabled)
    set(_result_ref "ctest-results.junit.xml#${_name}")
    junit_test_state("${_ctest_junit_present}" "${_junit}" "${_name}"
      _junit_seen _junit_status _junit_failure)
    if(_ctest_junit_present)
      set(_report TRUE)
    endif()
    if(_junit_seen)
      set(_executed TRUE)
      if(_junit_status STREQUAL "disabled")
        set(_enabled FALSE)
        set(_executed FALSE)
        set(_outcome "skipped")
        set(_detail "disabled")
      elseif(_junit_status STREQUAL "notrun")
        set(_outcome "skipped")
        set(_detail "skipped")
      elseif(_junit_status STREQUAL "fail")
        set(_outcome "failed")
        if(NOT _junit_failure STREQUAL "")
          set(_detail "${_junit_failure}")
        else()
          set(_detail "failed")
        endif()
      elseif(_junit_status STREQUAL "run")
        set(_outcome "passed")
      endif()
    elseif(_ctest_signal MATCHES "^(INT|TERM|HUP|QUIT|SIGINT|SIGTERM|SIGHUP|SIGQUIT)$")
      set(_outcome "cancelled")
      set(_detail "signal-${_ctest_signal}")
    elseif(_ctest_timed_out STREQUAL "yes")
      set(_outcome "failed")
      set(_detail "parent-timeout")
    elseif(NOT _registered)
      set(_detail "registration-missing")
    elseif(NOT _ctest_junit_present)
      set(_detail "report-missing")
    else()
      set(_detail "case-record-missing")
    endif()

    if(_outcome STREQUAL "passed")
      if(NOT _ctest_log MATCHES "[0-9]+/[0-9]+ Test[ ]+#[0-9]+: ${_name}.*Passed")
        set(_proof FALSE)
        set(_outcome "failed")
        set(_detail "ctest-pass-marker-missing")
      else()
        set(_proof TRUE)
      endif()
    endif()
    foreach(_marker_row IN LISTS _expected_markers)
      string(REPLACE "|" ";" _marker_columns "${_marker_row}")
      list(LENGTH _marker_columns _marker_column_count)
      if(_marker_column_count EQUAL 2)
        list(GET _marker_columns 0 _marker_name)
        list(GET _marker_columns 1 _marker_text)
        if(_marker_name STREQUAL "${_name}")
          string(FIND "${_ctest_log}" "${_marker_text}" _marker_index)
          if(_marker_index EQUAL -1)
            set(_proof FALSE)
            if(_outcome STREQUAL "passed")
              set(_outcome "failed")
              set(_detail "expected-proof-missing")
            endif()
          endif()
        endif()
      endif()
    endforeach()
  elseif(_kind STREQUAL "consumer")
    if(NOT _name STREQUAL "installed_consumer_save_restart"
       AND NOT _name STREQUAL "installed_consumer_snapshot"
       AND NOT _name STREQUAL "source_fresh_process_snapshot"
       AND NOT _name STREQUAL "installed_consumer_fresh_process_snapshot"
       AND NOT _name STREQUAL "source_battery_fresh_process_snapshot"
       AND NOT _name STREQUAL "installed_consumer_battery_fresh_process_snapshot"
       AND NOT _name STREQUAL "installed_consumer_battery_snapshot"
       AND NOT _name STREQUAL "installed_consumer_load_refusal"
       AND NOT _name STREQUAL "installed_muhtari_session"
       AND NOT _name STREQUAL "installed_muhtari_save_restart"
       AND NOT _name STREQUAL "installed_macos_host")
      message(FATAL_ERROR "unknown required consumer result name '${_name}'")
    endif()
    set(_registered TRUE)
    set(_enabled TRUE)
    set(_result_ref "")
    if(_name STREQUAL "installed_macos_host")
      set(_consumer_report_path "${MACOS_HOST_REPORT}")
    elseif(_name STREQUAL "source_fresh_process_snapshot")
      set(_consumer_report_path "${SOURCE_FRESH_PROCESS_REPORT}")
    elseif(_name STREQUAL "installed_consumer_fresh_process_snapshot")
      set(_consumer_report_path "${FRESH_PROCESS_RELOCATION_REPORT}")
    elseif(_name STREQUAL "source_battery_fresh_process_snapshot")
      set(_consumer_report_path "${SOURCE_BATTERY_FRESH_PROCESS_REPORT}")
    elseif(_name STREQUAL "installed_consumer_battery_fresh_process_snapshot")
      set(_consumer_report_path "${BATTERY_FRESH_PROCESS_RELOCATION_REPORT}")
    else()
      set(_consumer_report_path "${RELOCATION_REPORT}")
    endif()
    if(EXISTS "${_consumer_report_path}" AND
       NOT IS_DIRECTORY "${_consumer_report_path}")
      set(_executed TRUE)
      set(_report TRUE)
      file(READ "${_consumer_report_path}" _consumer_report)
      consumer_report_proof("${_name}" "${_consumer_report}" _proof _detail)
      if((_name STREQUAL "source_battery_fresh_process_snapshot" OR
          _name STREQUAL "installed_consumer_battery_fresh_process_snapshot") AND
         NOT _battery_identity_pair_valid)
        set(_proof FALSE)
        set(_detail "battery-source-installed-commit-worktree-or-fingerprint-mismatch")
      endif()
      file(RELATIVE_PATH _result_ref "${RESULT_BASE_DIR}" "${_consumer_report_path}")
      if(_result_ref MATCHES "^([.][.]|/)")
        set(_proof FALSE)
        set(_detail "outside-result-base-report")
      endif()
      if(_proof AND _name STREQUAL "installed_consumer_battery_fresh_process_snapshot")
        battery_fresh_process_report_path_proof("${_result_ref}"
          "${_consumer_report}" _battery_report_path_valid)
        if(NOT _battery_report_path_valid)
          set(_proof FALSE)
          set(_detail "battery-fresh-process-run-id-report-path-or-junit-reference-mismatch")
        endif()
      endif()
      string(FIND "${_consumer_report}" "${PRIVATE_ROOT}" _private_path_index)
      if(NOT _private_path_index EQUAL -1)
        set(_proof FALSE)
        set(_detail "absolute-local-path-in-report")
      endif()
      if(_proof)
        set(_outcome "passed")
      else()
        set(_outcome "failed")
      endif()
    else()
      set(_detail "report-missing")
    endif()
  elseif(_kind STREQUAL "unsupported")
    set(_outcome "missing")
    set(_detail "not-qualified-for-selected-profile")
    set(_result_ref "selected-profile=Darwin-arm64")
  else()
    message(FATAL_ERROR "unsupported route result kind '${_kind}'")
  endif()

  evaluate_result("${_applicability}" "${_outcome}" "${_registered}"
    "${_enabled}" "${_executed}" "${_proof}" "${_report}"
    _accepted _required_pass)
  if(_applicability STREQUAL "required")
    math(EXPR _required_rows "${_required_rows} + 1")
    if(NOT _required_pass)
      math(EXPR _failed_required_rows "${_failed_required_rows} + 1")
      set(_route_ok FALSE)
    endif()
  endif()
  file(APPEND "${RESULT_OUTPUT}"
    "${_kind}|${_name}|${_applicability}|${_outcome}|${_detail}|${_registered}|${_enabled}|${_executed}|${_proof}|${_result_ref}\n")
endforeach()

if(NOT _ctest_exit_status STREQUAL "0")
  set(_route_ok FALSE)
endif()
if(_required_rows EQUAL 0 OR _failed_required_rows GREATER 0)
  set(_route_ok FALSE)
endif()

if(NOT _route_ok)
  message(FATAL_ERROR
    "required result validation failed: required=${_required_rows}, failed=${_failed_required_rows}, ctest_exit=${_ctest_exit_status}, signal=${_ctest_signal}; see ${RESULT_OUTPUT}")
endif()
message(STATUS
  "required_result_validation: required=${_required_rows} passed=${_required_rows} advisory_and_unsupported=separate result=pass")
