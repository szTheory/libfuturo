# API 8 route evidence is intentionally separate from the legacy API 7 validator.

function(api8_unique_value report key output_value output_ok)
  string(REPLACE "\r" "" _lines "${report}")
  string(REPLACE "\n" ";" _lines "${_lines}")
  set(_count 0)
  set(_value "")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^${key}=(.*)$")
      math(EXPR _count "${_count} + 1")
      set(_value "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  if(_count EQUAL 1)
    set(_ok TRUE)
  else()
    set(_ok FALSE)
  endif()
  set("${output_value}" "${_value}" PARENT_SCOPE)
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
endfunction()

function(api8_artifact_matches root report key_ref key_hash output_ok)
  api8_unique_value("${report}" "${key_ref}" _relative _ref_unique)
  api8_unique_value("${report}" "${key_hash}" _expected _hash_unique)
  set(_ok FALSE)
  if(_ref_unique AND _hash_unique)
    string(FIND "${_relative}" ".." _traversal)
    if(NOT IS_ABSOLUTE "${_relative}" AND _traversal EQUAL -1 AND
        "${_expected}" MATCHES "^sha256:[0-9a-f]+$")
      set(_root "${root}")
      cmake_path(ABSOLUTE_PATH _root NORMALIZE OUTPUT_VARIABLE _root_abs)
      set(_candidate "${_root_abs}/${_relative}")
      if(EXISTS "${_candidate}" AND NOT IS_DIRECTORY "${_candidate}")
        file(REAL_PATH "${_candidate}" _candidate_real)
        string(FIND "${_candidate_real}" "${_root_abs}/" _inside)
        if(_inside EQUAL 0)
          file(SHA256 "${_candidate_real}" _actual_hash)
          if("sha256:${_actual_hash}" STREQUAL "${_expected}")
            set(_ok TRUE)
          endif()
        endif()
      endif()
    endif()
  endif()
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
endfunction()

function(api8_report_value_matches report key expected output_ok)
  api8_unique_value("${report}" "${key}" _value _unique)
  if(_unique AND "${_value}" STREQUAL "${expected}")
    set(_ok TRUE)
  else()
    set(_ok FALSE)
  endif()
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
endfunction()

function(api8_report_has_once report fragment output_ok)
  string(REGEX MATCHALL "${fragment}" _matches "${report}")
  list(LENGTH _matches _count)
  if(_count EQUAL 1)
    set(_ok TRUE)
  else()
    set(_ok FALSE)
  endif()
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
endfunction()

function(api8_event_matches report expression output_line output_count)
  string(REGEX MATCHALL "${expression}" _matches "${report}")
  list(LENGTH _matches _count)
  if(_count GREATER 0)
    list(GET _matches 0 _line)
  else()
    set(_line "")
  endif()
  set("${output_line}" "${_line}" PARENT_SCOPE)
  set("${output_count}" "${_count}" PARENT_SCOPE)
endfunction()

function(api8_validate_route root report_path expected_route expected_run_id output_ok output_reason)
  set(_ok TRUE)
  set(_reason "accepted")
  if(NOT EXISTS "${report_path}" OR IS_DIRECTORY "${report_path}")
    set(_ok FALSE)
    set(_reason "report-missing")
  else()
    file(REAL_PATH "${root}" _root_real)
    file(REAL_PATH "${report_path}" _report_real)
    string(FIND "${_report_real}" "${_root_real}/" _inside)
    if(NOT _inside EQUAL 0)
      set(_ok FALSE)
      set(_reason "report-outside-evidence-root")
    endif()
  endif()
  if(_ok)
    file(READ "${report_path}" _report)
    foreach(_pair IN ITEMS
        "format|libfuturo-muhtari-api8-route-v1"
        "route|${expected_route}"
        "run_id|${expected_run_id}"
        "result|pass"
        "platform|Darwin"
        "architecture|arm64"
        "api_revision|8"
        "api_abi|1"
        "behavior_revision|6"
        "state_format|1"
        "muhtari_version|0.11.1"
        "muhtari_source_revision|d58f125297c4d63a7a8108112a5eafff6f53a76a"
        "profile|muhtari-ntsc-v2"
        "configuration|muhtari-ntsc-battery-diagnostic"
        "effective_options|none"
        "snapshot_boundary|R2-frame2-pending-savekey-write"
        "replay_boundary|R3-frame3-savekey-published"
        "replay_savekey_offset|2051"
        "replay_frame|3"
        "replay_video_sha256|59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225"
        "replay_pcm_sha256|09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f"
        "replay_battery|full-span-r3"
        "replay_battery_sha256|495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583"
        "snapshot_r2_battery_sha256|036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64"
        "ctest_exit_status|0"
        "ctest_signal|none"
        "ctest_timed_out|no")
      string(REPLACE "|" ";" _parts "${_pair}")
      list(GET _parts 0 _key)
      list(GET _parts 1 _expected)
      api8_report_value_matches("${_report}" "${_key}" "${_expected}" _field_ok)
      if(NOT _field_ok)
        set(_ok FALSE)
        set(_reason "identity-or-status-${_key}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    foreach(_key IN ITEMS source_commit source_worktree_fingerprint build_fingerprint fixture_bytes
        fixture_sha256 checkpoint_bytes checkpoint_sha256)
      api8_unique_value("${_report}" "${_key}" _value _unique)
      if(NOT _unique OR "${_value}" STREQUAL "")
        set(_ok FALSE)
        set(_reason "missing-or-duplicate-${_key}")
        break()
      endif()
    endforeach()
    foreach(_key IN ITEMS source_worktree_fingerprint build_fingerprint fixture_sha256 checkpoint_sha256)
      api8_unique_value("${_report}" "${_key}" _value _unique)
      if(NOT _value MATCHES "^sha256:[0-9a-f]+$")
        set(_ok FALSE)
        set(_reason "malformed-hash-${_key}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    if(expected_route STREQUAL "source")
      set(_expected_report_path "${root}/source-route.report")
    else()
      set(_expected_report_path "${root}/installed-route.report")
    endif()
    file(REAL_PATH "${_expected_report_path}" _expected_report_real)
    file(REAL_PATH "${report_path}" _actual_report_real)
    if(NOT _actual_report_real STREQUAL _expected_report_real)
      set(_ok FALSE)
      set(_reason "route-report-path-mismatch")
    endif()
  endif()
  if(_ok)
    foreach(_spec IN ITEMS
        "fixture_generator_ref|fixture_generator_sha256"
        "fixture_base_ref|fixture_base_sha256"
        "consumer_source_ref|consumer_source_sha256"
        "snapshot_oracle_ref|snapshot_oracle_sha256"
        "libfuturo_ref|libfuturo_sha256"
        "nesturbator_ref|nesturbator_sha256"
        "muhtari_ref|muhtari_sha256"
        "consumer_ref|consumer_sha256"
        "supervisor_ref|supervisor_sha256"
        "process_tree_helper_ref|process_tree_helper_sha256"
        "oracle_controls_ref|oracle_controls_sha256"
        "ctest_inventory_ref|ctest_inventory_sha256"
        "ctest_junit_ref|ctest_junit_sha256"
        "ctest_log_ref|ctest_log_sha256"
        "ctest_process_facts_ref|ctest_process_facts_sha256"
        "package_resolution_ref|package_resolution_sha256"
        "link_audit_ref|link_audit_sha256")
      string(REPLACE "|" ";" _parts "${_spec}")
      list(GET _parts 0 _ref_key)
      list(GET _parts 1 _hash_key)
      api8_artifact_matches("${root}" "${_report}" "${_ref_key}" "${_hash_key}" _artifact_ok)
      if(NOT _artifact_ok)
        set(_ok FALSE)
        set(_reason "artifact-${_ref_key}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok AND expected_route STREQUAL "installed")
    foreach(_spec IN ITEMS
        "libfuturo_config_ref|libfuturo_config_sha256"
        "muhtari_config_ref|muhtari_config_sha256"
        "nesturbator_config_ref|nesturbator_config_sha256")
      string(REPLACE "|" ";" _parts "${_spec}")
      list(GET _parts 0 _ref_key)
      list(GET _parts 1 _hash_key)
      api8_artifact_matches("${root}" "${_report}" "${_ref_key}" "${_hash_key}" _artifact_ok)
      if(NOT _artifact_ok)
        set(_ok FALSE)
        set(_reason "artifact-${_ref_key}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    foreach(_name IN ITEMS ctest_inventory ctest_junit ctest_log ctest_process_facts)
      api8_unique_value("${_report}" "${_name}_ref" _ref _unique)
      if(NOT _unique)
        set(_ok FALSE)
        set(_reason "duplicate-${_name}-reference")
        break()
      endif()
      file(READ "${root}/${_ref}" _artifact)
      if(_name STREQUAL "ctest_inventory")
        string(JSON _kind ERROR_VARIABLE _json_error GET "${_artifact}" kind)
        if(NOT _json_error STREQUAL "NOTFOUND" OR NOT _kind STREQUAL "ctestInfo")
          set(_ok FALSE)
          set(_reason "invalid-ctest-inventory")
        endif()
      elseif(_name STREQUAL "ctest_junit")
        if(NOT _artifact MATCHES "<testsuite" OR
            _artifact MATCHES "failures=\"[1-9]" OR
            _artifact MATCHES "skipped=\"[1-9]" OR
            _artifact MATCHES "disabled=\"[1-9]")
          set(_ok FALSE)
          set(_reason "junit-not-complete-passing")
        endif()
      elseif(_name STREQUAL "ctest_log")
        if(NOT _artifact MATCHES "100% tests passed" OR
            NOT _artifact MATCHES "muhtari_api8_${expected_route}_oracle_controls: frame,video,audio,media,capability denied result=pass")
          set(_ok FALSE)
          set(_reason "ctest-log-or-wrong-oracle-control")
        endif()
      else()
        if(NOT _artifact MATCHES "exit_status=0" OR
            NOT _artifact MATCHES "signal=none" OR
            NOT _artifact MATCHES "timed_out=no")
          set(_ok FALSE)
          set(_reason "ctest-process-not-successful")
        endif()
      endif()
      if(NOT _ok)
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    if(expected_route STREQUAL "installed")
      set(_tests muhtari_api8_profile muhtari_api8_fixture_boundary
        muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract
        muhtari_api8_installed_fresh_process muhtari_api8_installed_oracle_controls)
    else()
      set(_tests muhtari_api8_profile muhtari_api8_fixture_boundary
        muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract
        muhtari_api8_source_fresh_process muhtari_api8_source_oracle_controls
        muhtari_api8_supervisor_controls)
    endif()
    api8_unique_value("${_report}" "ctest_inventory_ref" _inventory_ref _unique)
    file(READ "${root}/${_inventory_ref}" _inventory)
    api8_unique_value("${_report}" "ctest_junit_ref" _junit_ref _unique)
    file(READ "${root}/${_junit_ref}" _junit)
    api8_unique_value("${_report}" "ctest_log_ref" _log_ref _unique)
    file(READ "${root}/${_log_ref}" _log)
    foreach(_test IN LISTS _tests)
      string(JSON _count ERROR_VARIABLE _tests_error LENGTH "${_inventory}" tests)
      set(_found FALSE)
      if(_tests_error STREQUAL "NOTFOUND" AND _count GREATER 0)
        math(EXPR _last "${_count} - 1")
        set(_matches 0)
        foreach(_index RANGE 0 ${_last})
          string(JSON _actual_name GET "${_inventory}" tests ${_index} name)
          if(_actual_name STREQUAL "${_test}")
            math(EXPR _matches "${_matches} + 1")
            set(_enabled TRUE)
            string(JSON _property_count ERROR_VARIABLE _properties_error
              LENGTH "${_inventory}" tests ${_index} properties)
            if(_properties_error STREQUAL "NOTFOUND" AND _property_count GREATER 0)
              math(EXPR _property_last "${_property_count} - 1")
              foreach(_property_index RANGE 0 ${_property_last})
                string(JSON _property_name GET "${_inventory}" tests ${_index}
                  properties ${_property_index} name)
                if(_property_name STREQUAL "DISABLED")
                  string(JSON _disabled GET "${_inventory}" tests ${_index}
                    properties ${_property_index} value)
                  if(_disabled)
                    set(_enabled FALSE)
                  endif()
                endif()
              endforeach()
            endif()
            if(_enabled)
              set(_found TRUE)
            endif()
          endif()
        endforeach()
        if(NOT _matches EQUAL 1)
          set(_found FALSE)
        endif()
      endif()
      if(NOT _found OR NOT _junit MATCHES "name=\"${_test}\"" OR
          NOT _log MATCHES "${_test}")
        set(_ok FALSE)
        set(_reason "test-not-registered-executed-passing-${_test}")
        break()
      endif()
      api8_report_has_once("${_report}" "test_result=${_test}\\|passed" _result_once)
      if(NOT _result_once)
        set(_ok FALSE)
        set(_reason "test-result-missing-or-duplicate-${_test}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok AND expected_route STREQUAL "installed")
    api8_report_value_matches("${_report}" isolation
      "checkout,build unavailable during downstream configure,build,ctest" _isolation_ok)
    if(NOT _isolation_ok)
      set(_ok FALSE)
      set(_reason "installed-isolation-not-proven")
    endif()
  endif()
  if(_ok)
    api8_unique_value("${_report}" "package_resolution_ref" _resolution_ref _resolution_unique)
    api8_unique_value("${_report}" "link_audit_ref" _audit_ref _audit_unique)
    file(READ "${root}/${_resolution_ref}" _resolution)
    file(READ "${root}/${_audit_ref}" _audit)
    if(expected_route STREQUAL "installed")
      if(NOT _audit MATCHES "resolution=only-moved-prefix" OR
          NOT _audit MATCHES "source-and-build-fallback=unavailable" OR
          NOT _audit MATCHES "libfuturo=lib/liblibfuturo[.]a" OR
          NOT _audit MATCHES "nesturbator=lib/libnesturbator[.]a" OR
          NOT _audit MATCHES "muhtari=lib/libmuhtari[.]a")
        set(_ok FALSE)
        set(_reason "installed-package-resolution-or-link-audit-invalid")
      endif()
    elseif(NOT _resolution MATCHES "resolution=source-build-targets-only" OR
        NOT _audit MATCHES "liblibfuturo[.]a" OR
        NOT _audit MATCHES "libnesturbator[.]a" OR
        NOT _audit MATCHES "libmuhtari[.]a")
      set(_ok FALSE)
      set(_reason "source-package-resolution-or-link-audit-invalid")
    endif()
  endif()
  if(_ok)
    set(_ordered
      "lifecycle_event=verified_lifecycle=event=selected-save-commit-r3"
      "lifecycle_event=verified_lifecycle=event=checkpoint-close"
      "lifecycle_event=verified_lifecycle=event=instance-destroyed"
      "lifecycle_event=verified_lifecycle=event=a-exit status=0"
      "behavior_event=event=b-start"
      "lifecycle_event=verified_lifecycle=event=checkpoint-reopened"
      "lifecycle_event=verified_lifecycle=event=selected-save-imported-r3"
      "lifecycle_event=verified_lifecycle=event=battery-restore-r2"
      "lifecycle_event=verified_lifecycle=event=pre-rename-failure-preserved-r3"
      "lifecycle_event=verified_lifecycle=event=save-r2-readback-acknowledged"
      "lifecycle_event=verified_lifecycle=process_b_pass="
      "lifecycle_event=verified_lifecycle=event=b-exit status=0")
    set(_previous -1)
    foreach(_fragment IN LISTS _ordered)
      string(FIND "${_report}" "${_fragment}" _at)
      if(_at LESS 0 OR _at LESS_EQUAL _previous)
        set(_ok FALSE)
        set(_reason "lifecycle-missing-duplicate-or-reordered")
        break()
      endif()
      set(_previous "${_at}")
    endforeach()
  endif()
  if(_ok)
    set(_refusals zero_extent null_zero_extent truncated_header truncated_native_payload
      trailing_byte malformed_magic malformed_version malformed_header header_integrity
      zero_total_extent overflow_total_extent inconsistent_total_extent zero_native_extent
      overflow_native_extent inconsistent_native_extent malformed_content_extent
      wrong_libfuturo_build wrong_core_build wrong_native_format wrong_core_abi
      wrong_behavior_revision wrong_api_revision wrong_profile wrong_configuration
      wrong_options wrong_content_digest native_corruption native_semantic_invalid
      same_length_content)
    foreach(_name IN LISTS _refusals)
      string(REGEX MATCHALL
        "lifecycle_event=verified_lifecycle=event=battery-b-refusal name=${_name} [^\n]*result=pass"
        _events "${_report}")
      list(LENGTH _events _event_count)
      if(NOT _event_count EQUAL 1)
        set(_ok FALSE)
        set(_reason "refusal-missing-or-duplicate-${_name}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    foreach(_fragment IN ITEMS
        "before-positive-advance=pass"
        "selected-r3-preserved=pass"
        "stage-cleanup=pass"
        "readback=exact"
        "guest-media=r3 host-ack=r2"
        "result=pass"
        "frame=3 video=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225"
        "pcm=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f"
        "battery=full-span-r3 host-save=r2 result=pass"
        "event=supervisor-success route=${expected_route} result=pass")
      string(FIND "${_report}" "${_fragment}" _found)
      if(_found LESS 0)
        set(_ok FALSE)
        set(_reason "behavior-proof-missing-${_fragment}")
        break()
      endif()
    endforeach()
  endif()
  if(_ok)
    foreach(_event IN ITEMS
        "event=supervisor-start route=${expected_route}"
        "event=a-start" "event=a-exit status=0" "event=b-start"
        "event=b-exit status=0" "event=checkpoint-close"
        "event=checkpoint-reopened" "event=selected-save-commit-r3"
        "event=selected-save-imported-r3" "event=battery-restore-r2"
        "event=pre-rename-failure-preserved-r3"
        "event=save-r2-readback-acknowledged" "event=guest-r3-host-save-r2"
        "event=supervisor-success route=${expected_route} result=pass")
      set(_exit_name "")
      set(_dual_event "")
      if(_event STREQUAL "event=a-exit status=0")
        set(_exit_name a)
      elseif(_event STREQUAL "event=b-exit status=0")
        set(_exit_name b)
      elseif(_event STREQUAL "event=checkpoint-close")
        set(_dual_event checkpoint-close)
      endif()
      if(_exit_name)
        string(REGEX MATCHALL "behavior_event=event=${_exit_name}-exit status=0[^\n]*"
          _behavior_exit "${_report}")
        string(REGEX MATCHALL "lifecycle_event=verified_lifecycle=event=${_exit_name}-exit status=0[^\n]*"
          _lifecycle_exit "${_report}")
        list(LENGTH _behavior_exit _behavior_exit_count)
        list(LENGTH _lifecycle_exit _lifecycle_exit_count)
        if(NOT _behavior_exit_count EQUAL 1 OR
           NOT _lifecycle_exit_count EQUAL 1)
          set(_ok FALSE)
          set(_reason "behavior-and-lifecycle-${_exit_name}-exit-missing-or-duplicate")
          break()
        endif()
      elseif(_dual_event)
        string(REGEX MATCHALL "behavior_event=event=${_dual_event} bytes=[0-9]+ sha256=[0-9a-f]+[^\n]*"
          _behavior_dual_event "${_report}")
        string(REGEX MATCHALL "lifecycle_event=verified_lifecycle=event=${_dual_event} bytes=[0-9]+ sha256=[0-9a-f]+[^\n]*"
          _lifecycle_dual_event "${_report}")
        list(LENGTH _behavior_dual_event _behavior_dual_event_count)
        list(LENGTH _lifecycle_dual_event _lifecycle_dual_event_count)
        if(NOT _behavior_dual_event_count EQUAL 1 OR
           NOT _lifecycle_dual_event_count EQUAL 1)
          set(_ok FALSE)
          set(_reason "behavior-and-lifecycle-${_dual_event}-missing-or-duplicate")
          break()
        endif()
      else()
        string(REGEX MATCHALL "(behavior_event|lifecycle_event)=[^\n]*${_event}[^\n]*"
          _event_matches "${_report}")
        list(LENGTH _event_matches _event_count)
        if(NOT _event_count EQUAL 1)
          set(_ok FALSE)
          set(_reason "event-missing-or-duplicate-${_event}")
          break()
        endif()
      endif()
    endforeach()
  endif()
  if(_ok)
    string(REGEX MATCHALL "lifecycle_event=verified_lifecycle=event=instance-destroyed[^\n]*"
      _destroy_events "${_report}")
    list(LENGTH _destroy_events _destroy_count)
    if(NOT _destroy_count EQUAL 2)
      set(_ok FALSE)
      set(_reason "instance-destroyed-event-count")
    endif()
  endif()
  if(_ok)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=checkpoint-close bytes=[0-9]+ sha256=[0-9a-f]+"
      _close_line _close_count)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=checkpoint-reopened bytes=[0-9]+ sha256=[0-9a-f]+"
      _reopen_line _reopen_count)
    if(NOT _close_count EQUAL 1 OR NOT _reopen_count EQUAL 1 OR
        NOT _close_line MATCHES "bytes=([0-9]+) sha256=([0-9a-f]+)$")
      set(_ok FALSE)
      set(_reason "checkpoint-close-or-reopen-identity-missing")
    else()
      set(_checkpoint_bytes_from_event "${CMAKE_MATCH_1}")
      set(_checkpoint_hash_from_event "${CMAKE_MATCH_2}")
      api8_unique_value("${_report}" checkpoint_bytes _reported_checkpoint_bytes _checkpoint_bytes_unique)
      api8_unique_value("${_report}" checkpoint_sha256 _reported_checkpoint_hash _checkpoint_hash_unique)
      if(NOT _reopen_line MATCHES "bytes=${_checkpoint_bytes_from_event} sha256=${_checkpoint_hash_from_event}$" OR
          NOT _checkpoint_bytes_unique OR NOT _checkpoint_hash_unique OR
          NOT _reported_checkpoint_bytes STREQUAL _checkpoint_bytes_from_event OR
          NOT _reported_checkpoint_hash STREQUAL "sha256:${_checkpoint_hash_from_event}")
        set(_ok FALSE)
        set(_reason "checkpoint-close-reopen-report-mismatch")
      endif()
    endif()
  endif()
  if(_ok)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=selected-save-commit-r3 bytes=[0-9]+ sha256=[0-9a-f]+ ack-save-sha256=[0-9a-f]+ generation=[0-9]+ readback=exact result=pass"
      _r3_line _r3_count)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=selected-save-imported-r3 sha256=[0-9a-f]+ bytes=[0-9]+ generation=0 before-positive-advance=pass result=pass"
      _import_line _import_count)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=pre-rename-failure-preserved-r3 sha256=[0-9a-f]+ bytes=[0-9]+ stage-cleanup=pass result=pass"
      _replace_line _replace_count)
    if(NOT _r3_count EQUAL 1 OR NOT _import_count EQUAL 1 OR NOT _replace_count EQUAL 1 OR
        NOT _r3_line MATCHES "sha256=([0-9a-f]+) ack-save-sha256=([0-9a-f]+)" OR
        NOT CMAKE_MATCH_1 STREQUAL CMAKE_MATCH_2)
      set(_ok FALSE)
      set(_reason "selected-save-r3-ack-or-import-identity-invalid")
    else()
      set(_r3_digest "${CMAKE_MATCH_1}")
      if(NOT _import_line MATCHES "sha256=${_r3_digest} " OR
          NOT _replace_line MATCHES "sha256=${_r3_digest} ")
        set(_ok FALSE)
        set(_reason "selected-save-r3-import-or-replacement-mismatch")
      endif()
    endif()
  endif()
  if(_ok)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=battery-restore-r2 bytes=[0-9]+ generation=1 selected-r3-preserved=pass result=pass"
      _restore_line _restore_count)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=save-r2-readback-acknowledged sha256=[0-9a-f]+ ack-save-sha256=[0-9a-f]+ bytes=[0-9]+ generation=1 readback=exact result=pass"
      _r2_commit_line _r2_commit_count)
    api8_event_matches("${_report}"
      "lifecycle_event=verified_lifecycle=event=guest-r3-host-save-r2 sha256=[0-9a-f]+ generation=1 guest-media=r3 host-ack=r2 result=pass"
      _guest_line _guest_count)
    if(NOT _restore_count EQUAL 1 OR NOT _r2_commit_count EQUAL 1 OR NOT _guest_count EQUAL 1 OR
        NOT _r2_commit_line MATCHES "sha256=([0-9a-f]+) ack-save-sha256=([0-9a-f]+)" OR
        NOT CMAKE_MATCH_1 STREQUAL CMAKE_MATCH_2)
      set(_ok FALSE)
      set(_reason "b-local-r2-generation-or-ack-invalid")
    else()
      set(_r2_digest "${CMAKE_MATCH_1}")
      if(NOT _guest_line MATCHES "sha256=${_r2_digest} ")
        set(_ok FALSE)
        set(_reason "b-local-r2-readback-and-guest-identity-mismatch")
      endif()
    endif()
  endif()
  if(_ok)
    string(FIND "${report_path}" "/" _slash)
    get_filename_component(_report_name "${report_path}" NAME)
    set(_identity_path "${root}/${expected_route}-route-report-identity.txt")
    if(NOT EXISTS "${_identity_path}" OR IS_DIRECTORY "${_identity_path}")
      set(_ok FALSE)
      set(_reason "report-identity-file-missing")
    else()
      file(READ "${_identity_path}" _identity)
      file(SHA256 "${report_path}" _digest)
      if(NOT _identity STREQUAL "report_sha256=sha256:${_digest}\n")
        set(_ok FALSE)
        set(_reason "report-identity-digest-mismatch")
      endif()
    endif()
  endif()
  if(_ok)
    if(_report MATCHES "(/Users/|/private/tmp/|/tmp/|[A-Za-z]:[/\\\\])")
      set(_ok FALSE)
      set(_reason "private-path-in-report")
    endif()
  endif()
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
  set("${output_reason}" "${_reason}" PARENT_SCOPE)
endfunction()

function(api8_validate_pair root source_report installed_report run_id output_ok output_reason)
  api8_validate_route("${root}" "${source_report}" source "${run_id}" _source_ok _source_reason)
  api8_validate_route("${root}" "${installed_report}" installed "${run_id}" _installed_ok _installed_reason)
  set(_ok TRUE)
  set(_reason accepted)
  if(NOT _source_ok)
    set(_ok FALSE)
    set(_reason "source-${_source_reason}")
  elseif(NOT _installed_ok)
    set(_ok FALSE)
    set(_reason "installed-${_installed_reason}")
  else()
    file(READ "${source_report}" _source)
    file(READ "${installed_report}" _installed)
    foreach(_key IN ITEMS source_commit source_worktree_fingerprint build_fingerprint run_id platform
        architecture api_revision api_abi behavior_revision state_format muhtari_version
        muhtari_source_revision profile configuration effective_options snapshot_boundary
        replay_boundary replay_savekey_offset replay_frame
        replay_video_sha256 replay_pcm_sha256 replay_battery replay_battery_sha256
        snapshot_r2_battery_sha256 fixture_generator_sha256 fixture_base_sha256
        consumer_source_sha256 snapshot_oracle_sha256 supervisor_sha256
        process_tree_helper_sha256 oracle_controls_sha256 fixture_bytes fixture_sha256)
      api8_unique_value("${_source}" "${_key}" _source_value _source_unique)
      api8_unique_value("${_installed}" "${_key}" _installed_value _installed_unique)
      if(NOT _source_unique OR NOT _installed_unique OR
          NOT "${_source_value}" STREQUAL "${_installed_value}")
        set(_ok FALSE)
        set(_reason "source-installed-identity-mismatch-${_key}")
        break()
      endif()
    endforeach()
  endif()
  set("${output_ok}" "${_ok}" PARENT_SCOPE)
  set("${output_reason}" "${_reason}" PARENT_SCOPE)
endfunction()

function(api8_create_smoke_fixture root route report_path)
  set(_route_root "${root}/${route}")
  file(MAKE_DIRECTORY "${_route_root}/artifacts")
  set(_checkpoint_bytes 46176)
  set(_checkpoint_digest "3333333333333333333333333333333333333333333333333333333333333333")
  if(route STREQUAL "installed")
    set(_checkpoint_bytes 46177)
    set(_checkpoint_digest "4444444444444444444444444444444444444444444444444444444444444444")
  endif()
  set(_artifact_names fixture_generator fixture_base libfuturo nesturbator muhtari
    consumer consumer_source snapshot_oracle supervisor process_tree_helper oracle_controls ctest_inventory ctest_junit
    ctest_log ctest_process_facts package_resolution link_audit)
  if(route STREQUAL "installed")
    list(APPEND _artifact_names libfuturo_config muhtari_config nesturbator_config)
  endif()
  foreach(_name IN LISTS _artifact_names)
    if(_name STREQUAL "ctest_inventory")
      set(_contents "{\"kind\":\"ctestInfo\",\"tests\":[{\"name\":\"muhtari_api8_profile\"},{\"name\":\"muhtari_api8_fixture_boundary\"},{\"name\":\"muhtari_api8_fixture_oracle_controls\"},{\"name\":\"muhtari_api8_snapshot_contract\"},{\"name\":\"muhtari_api8_${route}_fresh_process\"},{\"name\":\"muhtari_api8_${route}_oracle_controls\"}")
      if(route STREQUAL "source")
        string(APPEND _contents ",{\"name\":\"muhtari_api8_supervisor_controls\"}")
      endif()
      string(APPEND _contents "]}")
    elseif(_name STREQUAL "ctest_junit")
      if(route STREQUAL "source")
        set(_contents "<testsuite tests=\"7\" failures=\"0\" skipped=\"0\" disabled=\"0\"><testcase name=\"muhtari_api8_profile\"/><testcase name=\"muhtari_api8_fixture_boundary\"/><testcase name=\"muhtari_api8_fixture_oracle_controls\"/><testcase name=\"muhtari_api8_snapshot_contract\"/><testcase name=\"muhtari_api8_source_fresh_process\"/><testcase name=\"muhtari_api8_source_oracle_controls\"/><testcase name=\"muhtari_api8_supervisor_controls\"/></testsuite>")
      else()
        set(_contents "<testsuite tests=\"6\" failures=\"0\" skipped=\"0\" disabled=\"0\"><testcase name=\"muhtari_api8_profile\"/><testcase name=\"muhtari_api8_fixture_boundary\"/><testcase name=\"muhtari_api8_fixture_oracle_controls\"/><testcase name=\"muhtari_api8_snapshot_contract\"/><testcase name=\"muhtari_api8_installed_fresh_process\"/><testcase name=\"muhtari_api8_installed_oracle_controls\"/></testsuite>")
      endif()
    elseif(_name STREQUAL "ctest_log")
      set(_contents "100% tests passed, 0 tests failed\nmuhtari_api8_profile muhtari_api8_fixture_boundary muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract muhtari_api8_${route}_fresh_process muhtari_api8_${route}_oracle_controls muhtari_api8_supervisor_controls\nmuhtari_api8_${route}_oracle_controls: frame,video,audio,media,capability denied result=pass")
    elseif(_name STREQUAL "ctest_process_facts")
      set(_contents "exit_status=0\nsignal=none\ntimed_out=no\n")
    elseif(_name STREQUAL "package_resolution")
      if(route STREQUAL "installed")
        set(_contents "libfuturo-archive=lib/liblibfuturo.a\nnesturbator-archive=lib/libnesturbator.a\nmuhtari-enabled=TRUE\nmuhtari-api=8\nmuhtari-version=0.11.1\nmuhtari-source=d58f125297c4d63a7a8108112a5eafff6f53a76a\n")
      else()
        set(_contents "resolution=source-build-targets-only\n")
      endif()
    elseif(_name STREQUAL "link_audit")
      if(route STREQUAL "installed")
        set(_contents "libfuturo=lib/liblibfuturo.a\nnesturbator=lib/libnesturbator.a\nmuhtari=lib/libmuhtari.a\nresolution=only-moved-prefix\nsource-and-build-fallback=unavailable-during-configure-build-ctest\n")
      else()
        set(_contents "liblibfuturo.a libnesturbator.a libmuhtari.a\n")
      endif()
    elseif(_name MATCHES "^(fixture_generator|fixture_base|consumer_source|snapshot_oracle|supervisor|process_tree_helper|oracle_controls)$")
      set(_contents "controlled shared API 8 source ${_name}\n")
    else()
      set(_contents "controlled artifact ${route} ${_name}\n")
    endif()
    file(WRITE "${_route_root}/artifacts/${_name}.dat" "${_contents}")
    file(SHA256 "${_route_root}/artifacts/${_name}.dat" _hash)
    set("_ref_${_name}" "${route}/artifacts/${_name}.dat")
    set("_hash_${_name}" "sha256:${_hash}")
  endforeach()
  set(_report "format=libfuturo-muhtari-api8-route-v1\nroute=${route}\nrun_id=api8-smoke\nresult=pass\nsource_commit=0123456789abcdef0123456789abcdef01234567\nsource_worktree_fingerprint=sha256:1111111111111111111111111111111111111111111111111111111111111111\nbuild_fingerprint=sha256:4444444444444444444444444444444444444444444444444444444444444444\nplatform=Darwin\narchitecture=arm64\napi_revision=8\napi_abi=1\nbehavior_revision=6\nstate_format=1\nmuhtari_version=0.11.1\nmuhtari_source_revision=d58f125297c4d63a7a8108112a5eafff6f53a76a\nprofile=muhtari-ntsc-v2\nconfiguration=muhtari-ntsc-battery-diagnostic\nfixture_bytes=16512\nfixture_sha256=sha256:2222222222222222222222222222222222222222222222222222222222222222\nfixture_generator_ref=${_ref_fixture_generator}\nfixture_generator_sha256=${_hash_fixture_generator}\nfixture_base_ref=${_ref_fixture_base}\nfixture_base_sha256=${_hash_fixture_base}\ncheckpoint_bytes=46176\ncheckpoint_sha256=sha256:3333333333333333333333333333333333333333333333333333333333333333\nlibfuturo_ref=${_ref_libfuturo}\nlibfuturo_sha256=${_hash_libfuturo}\nnesturbator_ref=${_ref_nesturbator}\nnesturbator_sha256=${_hash_nesturbator}\nmuhtari_ref=${_ref_muhtari}\nmuhtari_sha256=${_hash_muhtari}\nconsumer_ref=${_ref_consumer}\nconsumer_sha256=${_hash_consumer}\nsupervisor_ref=${_ref_supervisor}\nsupervisor_sha256=${_hash_supervisor}\nprocess_tree_helper_ref=${_ref_process_tree_helper}\nprocess_tree_helper_sha256=${_hash_process_tree_helper}\noracle_controls_ref=${_ref_oracle_controls}\noracle_controls_sha256=${_hash_oracle_controls}\nctest_inventory_ref=${_ref_ctest_inventory}\nctest_inventory_sha256=${_hash_ctest_inventory}\nctest_junit_ref=${_ref_ctest_junit}\nctest_junit_sha256=${_hash_ctest_junit}\nctest_log_ref=${_ref_ctest_log}\nctest_log_sha256=${_hash_ctest_log}\nctest_process_facts_ref=${_ref_ctest_process_facts}\nctest_process_facts_sha256=${_hash_ctest_process_facts}\npackage_resolution_ref=${_ref_package_resolution}\npackage_resolution_sha256=${_hash_package_resolution}\nlink_audit_ref=${_ref_link_audit}\nlink_audit_sha256=${_hash_link_audit}\nctest_exit_status=0\nctest_signal=none\nctest_timed_out=no\nisolation=checkout,build unavailable during downstream configure,build,ctest\n")
  string(REPLACE
    "checkpoint_bytes=46176\ncheckpoint_sha256=sha256:3333333333333333333333333333333333333333333333333333333333333333"
    "checkpoint_bytes=${_checkpoint_bytes}\ncheckpoint_sha256=sha256:${_checkpoint_digest}"
    _report "${_report}")
  string(APPEND _report "effective_options=none\nsnapshot_boundary=R2-frame2-pending-savekey-write\nreplay_boundary=R3-frame3-savekey-published\nreplay_savekey_offset=2051\nreplay_frame=3\nreplay_video_sha256=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225\nreplay_pcm_sha256=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f\nreplay_battery=full-span-r3\nreplay_battery_sha256=495ead1f5e803049666b25490aa47495e529eda7c8516eb3513947b403b4a583\nsnapshot_r2_battery_sha256=036d171c7642abeb0acc3670afc5a67422bf028b0086d0d8720a95985fdfdb64\nconsumer_source_ref=${_ref_consumer_source}\nconsumer_source_sha256=${_hash_consumer_source}\nsnapshot_oracle_ref=${_ref_snapshot_oracle}\nsnapshot_oracle_sha256=${_hash_snapshot_oracle}\n")
  if(route STREQUAL "installed")
    string(APPEND _report "libfuturo_config_ref=${_ref_libfuturo_config}\nlibfuturo_config_sha256=${_hash_libfuturo_config}\nmuhtari_config_ref=${_ref_muhtari_config}\nmuhtari_config_sha256=${_hash_muhtari_config}\nnesturbator_config_ref=${_ref_nesturbator_config}\nnesturbator_config_sha256=${_hash_nesturbator_config}\n")
  endif()
  foreach(_name IN ITEMS muhtari_api8_profile muhtari_api8_fixture_boundary
      muhtari_api8_fixture_oracle_controls muhtari_api8_snapshot_contract
      muhtari_api8_${route}_fresh_process muhtari_api8_${route}_oracle_controls)
    string(APPEND _report "test_result=${_name}|passed\n")
  endforeach()
  if(route STREQUAL "source")
    string(APPEND _report "test_result=muhtari_api8_supervisor_controls|passed\n")
  endif()
  set(_r3_digest "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  set(_r2_digest "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  string(APPEND _report "behavior_event=event=supervisor-start route=${route}\nbehavior_event=event=a-start\n")
  set(_ordered "selected-save-commit-r3" "checkpoint-close" "instance-destroyed"
    "a-exit status=0" "behavior_event=event=b-start" "checkpoint-reopened"
    "selected-save-imported-r3" "battery-restore-r2" "pre-rename-failure-preserved-r3"
    "save-r2-readback-acknowledged" "guest-r3-host-save-r2" "instance-destroyed"
    "process_b_pass=" "b-exit status=0")
  foreach(_event IN LISTS _ordered)
    if(_event STREQUAL "behavior_event=event=b-start")
      string(APPEND _report "${_event}\n")
    elseif(_event STREQUAL "a-exit status=0" OR _event STREQUAL "b-exit status=0")
      string(APPEND _report "behavior_event=event=${_event}\n")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=${_event}\n")
    elseif(_event STREQUAL "selected-save-commit-r3")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=selected-save-commit-r3 bytes=35176 sha256=${_r3_digest} ack-save-sha256=${_r3_digest} generation=4153 readback=exact result=pass\n")
    elseif(_event STREQUAL "checkpoint-close")
      string(APPEND _report "behavior_event=event=checkpoint-close bytes=${_checkpoint_bytes} sha256=${_checkpoint_digest}\n")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=checkpoint-close bytes=${_checkpoint_bytes} sha256=${_checkpoint_digest}\n")
    elseif(_event STREQUAL "checkpoint-reopened")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=${_event} bytes=${_checkpoint_bytes} sha256=${_checkpoint_digest}\n")
    elseif(_event STREQUAL "selected-save-imported-r3")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=selected-save-imported-r3 sha256=${_r3_digest} bytes=35176 generation=0 before-positive-advance=pass result=pass\n")
    elseif(_event STREQUAL "battery-restore-r2")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=battery-restore-r2 bytes=34816 generation=1 selected-r3-preserved=pass result=pass\n")
    elseif(_event STREQUAL "pre-rename-failure-preserved-r3")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=pre-rename-failure-preserved-r3 sha256=${_r3_digest} bytes=35176 stage-cleanup=pass result=pass\n")
    elseif(_event STREQUAL "save-r2-readback-acknowledged")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=save-r2-readback-acknowledged sha256=${_r2_digest} ack-save-sha256=${_r2_digest} bytes=35176 generation=1 readback=exact result=pass\n")
    elseif(_event STREQUAL "guest-r3-host-save-r2")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=guest-r3-host-save-r2 sha256=${_r2_digest} generation=1 guest-media=r3 host-ack=r2 result=pass\n")
    elseif(_event STREQUAL "instance-destroyed")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=instance-destroyed\n")
    elseif(_event MATCHES "^(a-exit|b-exit)")
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=${_event}\n")
    elseif(_event MATCHES "^process_b_pass=")
      string(APPEND _report "lifecycle_event=verified_lifecycle=process_b_pass=muhtari_api8_process_b: loads=1 frame=3 video=59b78332303fa3c631ae7cd522ad45627f739b49a48e8c0b0c07f45ea79bd225 pcm=09474df08fabeb22495ea69a6becd73374879d6840862382d0691c6e7a13a13f battery=full-span-r3 host-save=r2 result=pass\n")
    else()
      string(APPEND _report "lifecycle_event=verified_lifecycle=event=${_event} before-positive-advance=pass selected-r3-preserved=pass stage-cleanup=pass readback=exact guest-media=r3 host-ack=r2 result=pass\n")
    endif()
  endforeach()
  foreach(_name IN ITEMS zero_extent null_zero_extent truncated_header truncated_native_payload
      trailing_byte malformed_magic malformed_version malformed_header header_integrity
      zero_total_extent overflow_total_extent inconsistent_total_extent zero_native_extent
      overflow_native_extent inconsistent_native_extent malformed_content_extent
      wrong_libfuturo_build wrong_core_build wrong_native_format wrong_core_abi
      wrong_behavior_revision wrong_api_revision wrong_profile wrong_configuration
      wrong_options wrong_content_digest native_corruption native_semantic_invalid
      same_length_content)
    string(APPEND _report "lifecycle_event=verified_lifecycle=event=battery-b-refusal name=${_name} status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n")
  endforeach()
  string(APPEND _report "behavior_event=event=supervisor-success route=${route} result=pass\n")
  file(WRITE "${report_path}" "${_report}")
  file(SHA256 "${report_path}" _report_hash)
  file(WRITE "${root}/${route}-route-report-identity.txt" "report_sha256=sha256:${_report_hash}\n")
endfunction()
