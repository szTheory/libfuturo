cmake_minimum_required(VERSION 3.25)

function(macos_host_value report key output_value output_count)
  set(_value "")
  set(_count 0)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^${key}=(.*)$")
      set(_value "${CMAKE_MATCH_1}")
      math(EXPR _count "${_count} + 1")
    endif()
  endforeach()
  set("${output_value}" "${_value}" PARENT_SCOPE)
  set("${output_count}" "${_count}" PARENT_SCOPE)
endfunction()

function(macos_host_line_present report expected output_present)
  set(_present FALSE)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line STREQUAL "${expected}")
      set(_present TRUE)
      break()
    endif()
  endforeach()
  set("${output_present}" "${_present}" PARENT_SCOPE)
endfunction()

function(macos_host_ctest_line_present log expected output_present)
  set(_present FALSE)
  string(REPLACE "\r" "" _normalized "${log}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line STREQUAL "${expected}" OR
       _line MATCHES "^[0-9]+: ${expected}$")
      set(_present TRUE)
      break()
    endif()
  endforeach()
  set("${output_present}" "${_present}" PARENT_SCOPE)
endfunction()

function(macos_host_report_proof report artifact_root output_proof output_detail)
  set(_proof FALSE)
  set(_detail "host-report-format-invalid")

  macos_host_value("${report}" "format" _format _format_count)
  if(NOT _format_count EQUAL 1 OR
     NOT _format STREQUAL "libfuturo-relocation-macos-host-v1")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-report-format-invalid" PARENT_SCOPE)
    return()
  endif()

  set(_repeatable_keys macos-host-artifact macos-host-ctest-test
    isolation_stage installed_file_sha256 success-marker)
  set(_seen_keys)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^([^=]+)=")
      set(_key "${CMAKE_MATCH_1}")
      list(FIND _repeatable_keys "${_key}" _repeatable_index)
      if(_repeatable_index EQUAL -1)
        list(FIND _seen_keys "${_key}" _seen_index)
        if(NOT _seen_index EQUAL -1)
          set("${output_proof}" FALSE PARENT_SCOPE)
          set("${output_detail}" "host-report-duplicate-field" PARENT_SCOPE)
          return()
        endif()
        list(APPEND _seen_keys "${_key}")
      endif()
    endif()
  endforeach()

  set(_required_fields
    source_commit source_worktree dependency_origin dependency_commit
    muhtari_dependency_origin muhtari_dependency_commit
    muhtari-fixture-bytes muhtari-fixture-sha256 muhtari-fixture-provenance
    muhtari-fixture-generator macos-host
    macos-host-package-resolution macos-host-ctest-result
    macos-host-ctest-exit macos-host-ctest-signal macos-host-ctest-timed-out
    macos-host-ctest-inventory-ref macos-host-ctest-inventory-sha256
    macos-host-ctest-junit-ref macos-host-ctest-junit-sha256
    macos-host-ctest-log-ref macos-host-ctest-log-sha256
    macos-host-ctest-process-facts-ref macos-host-ctest-process-facts-sha256
    macos-host-marker macos-host-production-view-marker
    macos-host-open-retry-marker macos-host-cli-retry-marker
    macos-host-tracer-marker macos-host-content-marker macos-host-input-marker
    macos-host-timing-marker macos-host-display-marker
    macos-host-audio-test-marker macos-host-audio-marker
    macos-host-audio-evidence
    macos-host-lifecycle-close-marker macos-host-lifecycle-quit-marker
    macos-host-lifecycle-error-marker macos-host-lifecycle-marker)
  foreach(_field IN LISTS _required_fields)
    macos_host_value("${report}" "${_field}" _field_value _field_count)
    if(NOT _field_count EQUAL 1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-required-field-missing-or-duplicate" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  macos_host_value("${report}" "source_commit" _source_commit _unused)
  macos_host_value("${report}" "source_worktree" _source_worktree _unused)
  macos_host_value("${report}" "dependency_origin" _dependency_origin _unused)
  macos_host_value("${report}" "dependency_commit" _dependency_commit _unused)
  macos_host_value("${report}" "muhtari_dependency_origin" _muhtari_origin _unused)
  macos_host_value("${report}" "muhtari_dependency_commit" _muhtari_commit _unused)
  string(LENGTH "${_source_commit}" _source_commit_length)
  if(NOT _source_commit MATCHES "^[0-9a-f]+$" OR
     NOT _source_commit_length EQUAL 40 OR
     NOT _source_worktree MATCHES "^(clean|dirty)$" OR
     NOT _dependency_origin STREQUAL "https://github.com/szTheory/nesturbator.git" OR
     NOT _dependency_commit STREQUAL "2338608ab184f040620a30d17756f5e06a42d4e3" OR
     NOT _muhtari_origin STREQUAL "https://github.com/szTheory/muhtari.git" OR
     NOT _muhtari_commit STREQUAL "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-source-or-pin-identity-invalid" PARENT_SCOPE)
    return()
  endif()

  macos_host_value("${report}" "muhtari-fixture-bytes" _fixture_bytes _unused)
  macos_host_value("${report}" "muhtari-fixture-sha256" _fixture_hash _unused)
  macos_host_value("${report}" "muhtari-fixture-provenance" _fixture_provenance _unused)
  macos_host_value("${report}" "muhtari-fixture-generator" _fixture_generator _unused)
  macos_host_line_present("${report}"
    "muhtari-fixture-generation: checked=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass"
    _fixture_generation_present)
  macos_host_value("${report}" "macos-host" _host_route_result _unused)
  string(LENGTH "${_fixture_hash}" _fixture_hash_length)
  if(NOT _fixture_bytes STREQUAL "16512" OR
     NOT _fixture_hash MATCHES "^sha256:[0-9a-f]+$" OR
     NOT _fixture_hash_length EQUAL 71 OR
     NOT _fixture_provenance STREQUAL
       "project-authored-C-generator license=Apache-2.0 output=build-only" OR
     NOT _fixture_generator MATCHES "^C17 Apple clang version " OR
     NOT _fixture_generation_present OR
     NOT _host_route_result STREQUAL "passed")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-diagnostic-provenance-invalid" PARENT_SCOPE)
    return()
  endif()

  macos_host_value("${report}" "macos-host-package-resolution" _package_resolution _unused)
  if(NOT _package_resolution STREQUAL
     "libfuturo,nesturbator,muhtari:relocated")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-package-resolution-missing" PARENT_SCOPE)
    return()
  endif()

  set(_expected_tests host_tracer host_content host_input host_input_session
    host_timing host_display host_audio native_window_smoke native_smoke_cleanup_controls
    native_smoke_protocol_controls native_open_retry native_lifecycle)
  set(_reported_tests)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^macos-host-ctest-test=([^|]+)[|]([^|]+)$")
      set(_test_name "${CMAKE_MATCH_1}")
      set(_test_status "${CMAKE_MATCH_2}")
      if(_test_status STREQUAL "disabled")
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-ctest-inventory-disabled" PARENT_SCOPE)
        return()
      elseif(_test_status STREQUAL "skipped")
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-junit-result-skipped" PARENT_SCOPE)
        return()
      elseif(_test_status STREQUAL "cancelled")
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-junit-result-cancelled" PARENT_SCOPE)
        return()
      elseif(NOT _test_status STREQUAL "passed")
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-junit-result-failed" PARENT_SCOPE)
        return()
      endif()
      list(FIND _expected_tests "${_test_name}" _expected_test_index)
      if(_expected_test_index EQUAL -1)
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-ctest-inventory-unexpected-test" PARENT_SCOPE)
        return()
      endif()
      list(FIND _reported_tests "${_test_name}" _reported_test_index)
      if(NOT _reported_test_index EQUAL -1)
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-ctest-inventory-duplicate-test" PARENT_SCOPE)
        return()
      endif()
      list(APPEND _reported_tests "${_test_name}")
    endif()
  endforeach()
  list(LENGTH _reported_tests _reported_test_count)
  list(LENGTH _expected_tests _expected_test_count)
  if(NOT _reported_test_count EQUAL _expected_test_count)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-inventory-required-set-mismatch" PARENT_SCOPE)
    return()
  endif()
  if(NOT "${_reported_tests}" STREQUAL "${_expected_tests}")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-inventory-order-mismatch" PARENT_SCOPE)
    return()
  endif()

  macos_host_value("${report}" "macos-host-ctest-result" _host_ctest_result _unused)
  macos_host_value("${report}" "macos-host-ctest-exit" _host_ctest_exit _unused)
  macos_host_value("${report}" "macos-host-ctest-signal" _host_ctest_signal _unused)
  macos_host_value("${report}" "macos-host-ctest-timed-out" _host_ctest_timed_out _unused)
  if(NOT _host_ctest_result STREQUAL "passed")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-result-not-passed" PARENT_SCOPE)
    return()
  endif()
  if(NOT _host_ctest_exit STREQUAL "0")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-process-nonzero" PARENT_SCOPE)
    return()
  endif()
  if(NOT _host_ctest_timed_out STREQUAL "no")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-process-timeout" PARENT_SCOPE)
    return()
  endif()
  if(NOT _host_ctest_signal STREQUAL "none")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-process-cancelled" PARENT_SCOPE)
    return()
  endif()

  set(_expected_stages
    "macos-host-configure checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
    "macos-host-build checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed"
    "macos-host checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed")
  foreach(_stage IN LISTS _expected_stages)
    macos_host_line_present("${report}" "isolation_stage=${_stage}" _stage_present)
    if(NOT _stage_present)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-isolation-stage-missing" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  set(_marker_checks
    "macos-host-marker|installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass"
    "macos-host-production-view-marker|installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass"
    "macos-host-open-retry-marker|installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass"
    "macos-host-cli-retry-marker|installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass"
    "macos-host-tracer-marker|host_tracer: profile=muhtari-ntsc-v1 startup=partial steady=pass pcm=pass immutable=pass capacity=801 serialized=pass overlap=pass ownership=pass destroy=once result=pass"
    "macos-host-content-marker|host_content: sizes=empty,1,max-minus-one,max,max-plus-one nonregular=directory,fifo unreadable=pass truncation=pass growth=pass allocation=pass eintr=pass cleanup=pass result=pass"
    "macos-host-input-marker|host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=pass"
    "macos-host-timing-marker|host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one rational=long-ordinal overload=skip duplicate=single max-inflight=1 sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once overflow=checked catchup-control=detected wrong-order-control=detected stale-callbacks=filtered audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass guest=continued pcm=valid muted-advances=3 unmuted-advances=2 deadlines=1-4 stop-controls=detected result=pass"
    "macos-host-display-marker|host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass"
    "macos-host-audio-test-marker|host_audio: pool=capacity5 frames=54,800,801 bounds=checked drop=newest tokens=duplicate,stale rejected retirement=concurrent lock-free=10/10 manual=s16-input,float32-render-mono-48000 blocks=54,800,801 order=pass mute-output=silent,restored-source restore-transition=bounded,stable-after=2-of-3-blocks duplicate=stable completion=retired callback=pool-only close=lease-drained forbidden-controls=guest,player-stop-rejected result=pass"
    "macos-host-lifecycle-close-marker|installed_macos_host: lifecycle=close phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass"
    "macos-host-lifecycle-quit-marker|installed_macos_host: lifecycle=quit phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass"
    "macos-host-lifecycle-error-marker|installed_macos_host: lifecycle=close phase=load-error owner-drained=pass main-sentinel=pass error-suppressed=pass destroy=once result=pass"
    "macos-host-lifecycle-marker|native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass")
  foreach(_marker_record IN LISTS _marker_checks)
    string(REPLACE "|" ";" _marker_columns "${_marker_record}")
    list(GET _marker_columns 0 _field)
    list(GET _marker_columns 1 _expected)
    macos_host_value("${report}" "${_field}" _actual _unused)
    if(NOT _actual STREQUAL _expected)
      if(_field STREQUAL "macos-host-marker")
        set(_detail "host-native-window-marker-missing")
      else()
        set(_detail "host-required-marker-missing")
      endif()
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "${_detail}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  macos_host_value("${report}" "macos-host-audio-marker"
    _audio_marker _audio_marker_count)
  if(NOT _audio_marker_count EQUAL 1 OR
     NOT _audio_marker MATCHES
       "^installed_macos_host: audio=system source=s16-native,mono,48000 output-rate=[1-9][0-9]* output-channels=[1-9][0-9]* dataPlayedBack=[1-9][0-9]* pool-drops=[0-9]+ prime-delay-ms=[0-9]+ player-stopped=true engine-stopped=true result=pass$")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-audio-marker-invalid" PARENT_SCOPE)
    return()
  endif()
  macos_host_value("${report}" "macos-host-audio-evidence"
    _audio_evidence_summary _audio_evidence_summary_count)
  if(NOT _audio_evidence_summary_count EQUAL 1 OR
     NOT _audio_evidence_summary STREQUAL
       "system-path,completion,format,player-stop,engine-stop:validated")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-audio-evidence-summary-invalid" PARENT_SCOPE)
    return()
  endif()

  set(_artifact_kinds libfuturo_archive nesturbator_archive muhtari_archive
    diagnostic_fixture host_executable host_tracer_executable
    host_content_executable host_input_executable
    host_input_session_executable host_timing_executable host_display_executable
    host_audio_executable
    package_resolution ctest_inventory ctest_junit ctest_log ctest_process_facts)
  set(_artifact_seen)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^macos-host-artifact=([^|]+)[|]([^|]+)[|](sha256:[0-9a-f]+)$")
      set(_kind "${CMAKE_MATCH_1}")
      set(_relative_ref "${CMAKE_MATCH_2}")
      set(_expected_hash "${CMAKE_MATCH_3}")
      list(FIND _artifact_kinds "${_kind}" _kind_index)
      if(_kind_index EQUAL -1)
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-evidence-artifact-unexpected-${_kind}" PARENT_SCOPE)
        return()
      endif()
      list(FIND _artifact_seen "${_kind}" _seen_index)
      if(NOT _seen_index EQUAL -1)
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-evidence-artifact-duplicate" PARENT_SCOPE)
        return()
      endif()
      if(IS_ABSOLUTE "${_relative_ref}" OR "${_relative_ref}" MATCHES "(^|/)\\.\\.(/|$)")
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-evidence-artifact-ref-unsafe" PARENT_SCOPE)
        return()
      endif()
      string(LENGTH "${_expected_hash}" _expected_hash_length)
      if(NOT _expected_hash MATCHES "^sha256:[0-9a-f]+$" OR
         NOT _expected_hash_length EQUAL 71)
        set("${output_proof}" FALSE PARENT_SCOPE)
        set("${output_detail}" "host-evidence-artifact-digest-invalid" PARENT_SCOPE)
        return()
      endif()
      set(_artifact_path_${_kind} "${artifact_root}/${_relative_ref}")
      set(_artifact_hash_${_kind} "${_expected_hash}")
      list(APPEND _artifact_seen "${_kind}")
    elseif(_line MATCHES "^macos-host-artifact=")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-evidence-artifact-malformed" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  foreach(_kind IN LISTS _artifact_kinds)
    list(FIND _artifact_seen "${_kind}" _artifact_index)
    if(_artifact_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-evidence-artifact-set-incomplete" PARENT_SCOPE)
      return()
    endif()
    if(NOT EXISTS "${_artifact_path_${_kind}}" OR
       IS_DIRECTORY "${_artifact_path_${_kind}}")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-evidence-artifact-missing" PARENT_SCOPE)
      return()
    endif()
    file(SHA256 "${_artifact_path_${_kind}}" _actual_hash)
    if(NOT "sha256:${_actual_hash}" STREQUAL "${_artifact_hash_${_kind}}")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-evidence-artifact-digest-mismatch-${_kind}" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  foreach(_archive_kind libfuturo_archive nesturbator_archive muhtari_archive)
    if(NOT EXISTS "${_artifact_path_${_archive_kind}}")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-moved-archive-identity-missing" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  foreach(_artifact_kind host_executable host_tracer_executable
      host_content_executable host_input_executable host_input_session_executable
      host_timing_executable host_display_executable host_audio_executable)
    if(NOT EXISTS "${_artifact_path_${_artifact_kind}}")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-executable-identity-missing" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  foreach(_archive_pair
      "lib/liblibfuturo.a|libfuturo_archive"
      "lib/libnesturbator.a|nesturbator_archive"
      "lib/libmuhtari.a|muhtari_archive")
    string(REPLACE "|" ";" _archive_columns "${_archive_pair}")
    list(GET _archive_columns 0 _installed_path)
    list(GET _archive_columns 1 _artifact_kind)
    set(_installed_matches 0)
    foreach(_line IN LISTS _lines)
      if(_line MATCHES "^installed_file_sha256=${_installed_path} sha256:([0-9a-f]+)$")
        string(LENGTH "${CMAKE_MATCH_1}" _installed_hash_length)
        if(NOT _installed_hash_length EQUAL 64)
          set("${output_proof}" FALSE PARENT_SCOPE)
          set("${output_detail}" "host-moved-archive-identity-invalid" PARENT_SCOPE)
          return()
        endif()
        math(EXPR _installed_matches "${_installed_matches} + 1")
        if(NOT "sha256:${CMAKE_MATCH_1}" STREQUAL "${_artifact_hash_${_artifact_kind}}")
          set("${output_proof}" FALSE PARENT_SCOPE)
          set("${output_detail}" "host-moved-archive-identity-mismatch" PARENT_SCOPE)
          return()
        endif()
      endif()
    endforeach()
    if(NOT _installed_matches EQUAL 1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-moved-archive-identity-missing" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  macos_host_value("${report}" "muhtari-fixture-sha256" _fixture_hash _unused)
  if(NOT _fixture_hash STREQUAL "${_artifact_hash_diagnostic_fixture}")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-diagnostic-fixture-identity-mismatch" PARENT_SCOPE)
    return()
  endif()

  file(READ "${_artifact_path_package_resolution}" _package_evidence)
  if(NOT _package_evidence MATCHES "^format=libfuturo-host-package-resolution-v1\nlibfuturo=lib/cmake/libfuturo\nnesturbator=lib/cmake/nesturbator\nmuhtari=lib/cmake/muhtari\n$")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-package-resolution-evidence-invalid" PARENT_SCOPE)
    return()
  endif()

  set(_reported_local_path FALSE)
  if("${report}" MATCHES "(^|[=| ])/(Users|private/tmp|private/var|tmp)/")
    set(_reported_local_path TRUE)
  endif()
  if(_reported_local_path)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-report-absolute-local-path" PARENT_SCOPE)
    return()
  endif()

  macos_host_value("${report}" "macos-host-ctest-inventory-ref" _inventory_ref _unused)
  macos_host_value("${report}" "macos-host-ctest-inventory-sha256" _inventory_hash _unused)
  macos_host_value("${report}" "macos-host-ctest-junit-ref" _junit_ref _unused)
  macos_host_value("${report}" "macos-host-ctest-junit-sha256" _junit_hash _unused)
  macos_host_value("${report}" "macos-host-ctest-log-ref" _log_ref _unused)
  macos_host_value("${report}" "macos-host-ctest-log-sha256" _log_hash _unused)
  macos_host_value("${report}" "macos-host-ctest-process-facts-ref" _process_ref _unused)
  macos_host_value("${report}" "macos-host-ctest-process-facts-sha256" _process_hash _unused)
  if(NOT _inventory_hash STREQUAL _artifact_hash_ctest_inventory OR
     NOT _junit_hash STREQUAL _artifact_hash_ctest_junit OR
     NOT _log_hash STREQUAL _artifact_hash_ctest_log OR
     NOT _process_hash STREQUAL _artifact_hash_ctest_process_facts)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-evidence-artifact-digest-mismatch-record-field" PARENT_SCOPE)
    return()
  endif()

  foreach(_reference_pair
      "${_inventory_ref}|ctest_inventory"
      "${_junit_ref}|ctest_junit"
      "${_log_ref}|ctest_log"
      "${_process_ref}|ctest_process_facts")
    string(REPLACE "|" ";" _columns "${_reference_pair}")
    list(GET _columns 0 _reference)
    list(GET _columns 1 _reference_kind)
    if(NOT "${artifact_root}/${_reference}" STREQUAL "${_artifact_path_${_reference_kind}}")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-evidence-artifact-ref-mismatch" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  file(READ "${_artifact_path_ctest_inventory}" _inventory)
  string(JSON _inventory_kind ERROR_VARIABLE _inventory_kind_error
    GET "${_inventory}" kind)
  string(JSON _inventory_count ERROR_VARIABLE _inventory_count_error
    LENGTH "${_inventory}" tests)
  if(NOT _inventory_kind_error STREQUAL "NOTFOUND" OR
     NOT _inventory_kind STREQUAL "ctestInfo" OR
     NOT _inventory_count_error STREQUAL "NOTFOUND" OR
     NOT _inventory_count EQUAL _expected_test_count)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-inventory-required-set-mismatch" PARENT_SCOPE)
    return()
  endif()
  set(_inventory_names)
  math(EXPR _inventory_last "${_inventory_count} - 1")
  foreach(_index RANGE 0 ${_inventory_last})
    string(JSON _inventory_name ERROR_VARIABLE _name_error
      GET "${_inventory}" tests ${_index} name)
    if(NOT _name_error STREQUAL "NOTFOUND")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-ctest-inventory-required-set-mismatch" PARENT_SCOPE)
      return()
    endif()
    list(FIND _expected_tests "${_inventory_name}" _expected_index)
    if(_expected_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-ctest-inventory-unexpected-test" PARENT_SCOPE)
      return()
    endif()
    list(FIND _inventory_names "${_inventory_name}" _existing_index)
    if(NOT _existing_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-ctest-inventory-duplicate-test" PARENT_SCOPE)
      return()
    endif()
    list(APPEND _inventory_names "${_inventory_name}")
    string(JSON _properties_count ERROR_VARIABLE _properties_error
      LENGTH "${_inventory}" tests ${_index} properties)
    if(_properties_error STREQUAL "NOTFOUND" AND _properties_count GREATER 0)
      math(EXPR _properties_last "${_properties_count} - 1")
      foreach(_property_index RANGE 0 ${_properties_last})
        string(JSON _property_name ERROR_VARIABLE _property_name_error
          GET "${_inventory}" tests ${_index} properties ${_property_index} name)
        if(_property_name_error STREQUAL "NOTFOUND" AND
           _property_name STREQUAL "DISABLED")
          string(JSON _disabled ERROR_VARIABLE _disabled_error
            GET "${_inventory}" tests ${_index} properties ${_property_index} value)
          if(_disabled_error STREQUAL "NOTFOUND" AND _disabled)
            set("${output_proof}" FALSE PARENT_SCOPE)
            set("${output_detail}" "host-ctest-inventory-disabled" PARENT_SCOPE)
            return()
          endif()
        endif()
      endforeach()
    endif()
  endforeach()
  if(NOT "${_inventory_names}" STREQUAL "${_expected_tests}")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-inventory-order-mismatch" PARENT_SCOPE)
    return()
  endif()

  file(READ "${_artifact_path_ctest_junit}" _junit)
  if(_junit MATCHES "<failure" OR _junit MATCHES "<error" OR
     _junit MATCHES "<skipped")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-junit-result-not-complete" PARENT_SCOPE)
    return()
  endif()
  string(REGEX MATCH "<testsuite[ >][^>]*>" _suite_header "${_junit}")
  if(NOT _suite_header MATCHES "tests=\"${_expected_test_count}\"" OR
     NOT _suite_header MATCHES "failures=\"0\"" OR
     NOT _suite_header MATCHES "disabled=\"0\"" OR
     NOT _suite_header MATCHES "skipped=\"0\"")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-junit-result-not-complete" PARENT_SCOPE)
    return()
  endif()
  string(REGEX MATCHALL "<testcase[^>]*>" _junit_cases "${_junit}")
  set(_junit_names)
  foreach(_case IN LISTS _junit_cases)
    if(NOT _case MATCHES "name=\"([^\"]+)\"")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-junit-result-malformed" PARENT_SCOPE)
      return()
    endif()
    set(_junit_name "${CMAKE_MATCH_1}")
    if(NOT _case MATCHES "status=\"run\"")
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-junit-result-not-complete" PARENT_SCOPE)
      return()
    endif()
    list(FIND _expected_tests "${_junit_name}" _expected_index)
    if(_expected_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-junit-unexpected-test" PARENT_SCOPE)
      return()
    endif()
    list(FIND _junit_names "${_junit_name}" _existing_index)
    if(NOT _existing_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-junit-duplicate-test" PARENT_SCOPE)
      return()
    endif()
    list(APPEND _junit_names "${_junit_name}")
  endforeach()
  list(LENGTH _junit_names _junit_count)
  if(NOT _junit_count EQUAL _expected_test_count)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-junit-result-not-complete" PARENT_SCOPE)
    return()
  endif()
  if(NOT "${_junit_names}" STREQUAL "${_expected_tests}")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-junit-order-mismatch" PARENT_SCOPE)
    return()
  endif()

  file(READ "${_artifact_path_ctest_log}" _ctest_log)
  foreach(_marker_record IN LISTS _marker_checks)
    string(REPLACE "|" ";" _marker_columns "${_marker_record}")
    list(GET _marker_columns 1 _expected_marker)
    string(FIND "${_ctest_log}" "${_expected_marker}" _marker_index)
    if(_marker_index EQUAL -1)
      set("${output_proof}" FALSE PARENT_SCOPE)
      set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  macos_host_value("${report}" "macos-host-production-view-marker"
    _production_view_marker _unused)
  macos_host_ctest_line_present("${_ctest_log}" "${_production_view_marker}"
    _production_view_log_marker_present)
  if(NOT _production_view_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
    return()
  endif()
  macos_host_ctest_line_present("${_ctest_log}" "8: ${_audio_marker}"
    _audio_log_marker_present)
  if(NOT _audio_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-audio-marker-not-bound-to-smoke" PARENT_SCOPE)
    return()
  endif()
  macos_host_line_present("${_ctest_log}"
    "9: native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass"
    _cleanup_controls_log_marker_present)
  if(NOT _cleanup_controls_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
    return()
  endif()
  macos_host_line_present("${_ctest_log}"
    "10: native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass"
    _protocol_controls_log_marker_present)
  if(NOT _protocol_controls_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
    return()
  endif()
  macos_host_value("${report}" "macos-host-open-retry-marker"
    _open_retry_marker _unused)
  macos_host_line_present("${_ctest_log}" "11: ${_open_retry_marker}"
    _open_retry_log_marker_present)
  if(NOT _open_retry_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
    return()
  endif()
  macos_host_value("${report}" "macos-host-cli-retry-marker"
    _cli_retry_marker _unused)
  macos_host_line_present("${_ctest_log}" "11: ${_cli_retry_marker}"
    _cli_retry_log_marker_present)
  if(NOT _cli_retry_log_marker_present)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-log-marker-missing" PARENT_SCOPE)
    return()
  endif()

  file(READ "${_artifact_path_ctest_process_facts}" _process_facts)
  macos_host_value("${_process_facts}" "ctest_pid" _ctest_pid _unused)
  macos_host_value("${_process_facts}" "exit_status" _process_exit _unused)
  macos_host_value("${_process_facts}" "signal" _process_signal _unused)
  macos_host_value("${_process_facts}" "timed_out" _process_timeout _unused)
  if(NOT _ctest_pid MATCHES "^[1-9][0-9]*$" OR
     NOT _process_exit STREQUAL "0" OR
     NOT _process_signal STREQUAL "none" OR
     NOT _process_timeout STREQUAL "no")
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-process-facts-invalid" PARENT_SCOPE)
    return()
  endif()
  if(NOT _process_exit STREQUAL _host_ctest_exit OR
     NOT _process_signal STREQUAL _host_ctest_signal OR
     NOT _process_timeout STREQUAL _host_ctest_timed_out)
    set("${output_proof}" FALSE PARENT_SCOPE)
    set("${output_detail}" "host-ctest-process-facts-mismatch" PARENT_SCOPE)
    return()
  endif()

  set("${output_proof}" TRUE PARENT_SCOPE)
  set("${output_detail}" "macos-host-evidence-complete" PARENT_SCOPE)
endfunction()

function(macos_host_assert_control name report artifact_root expected_detail expected_result)
  macos_host_report_proof("${report}" "${artifact_root}" _proof _detail)
  if(expected_result STREQUAL "accept")
    if(NOT _proof OR NOT _detail STREQUAL "macos-host-evidence-complete")
      message(FATAL_ERROR
        "macos-host evidence control '${name}' rejected its valid report: ${_detail}")
    endif()
  else()
    if(_proof OR NOT _detail STREQUAL "${expected_detail}")
      message(FATAL_ERROR
        "macos-host evidence control '${name}' expected ${expected_detail}, got ${_detail}")
    endif()
  endif()
endfunction()

function(macos_host_add_control_artifact root kind relative_ref content report_out)
  set(_path "${root}/${relative_ref}")
  get_filename_component(_parent "${_path}" DIRECTORY)
  file(MAKE_DIRECTORY "${_parent}")
  file(WRITE "${_path}" "${content}")
  file(SHA256 "${_path}" _hash)
  set(_line "macos-host-artifact=${kind}|${relative_ref}|sha256:${_hash}\n")
  set("${report_out}" "${_line}" PARENT_SCOPE)
endfunction()

function(macos_host_replace_control_artifact root report kind content report_out)
  string(REPLACE "\r" "" _normalized "${report}")
  string(REPLACE "\n" ";" _lines "${_normalized}")
  set(_old_record "")
  set(_relative_ref "")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^macos-host-artifact=${kind}[|]([^|]+)[|]sha256:([0-9a-f]+)$")
      set(_old_record "${_line}")
      set(_relative_ref "${CMAKE_MATCH_1}")
      break()
    endif()
  endforeach()
  if(_old_record STREQUAL "")
    message(FATAL_ERROR "control fixture artifact '${kind}' is missing")
  endif()
  set(_path "${root}/${_relative_ref}")
  file(WRITE "${_path}" "${content}")
  file(SHA256 "${_path}" _new_hash)
  set(_new_record "macos-host-artifact=${kind}|${_relative_ref}|sha256:${_new_hash}")
  string(REPLACE "${_old_record}" "${_new_record}" _updated "${report}")

  if(kind STREQUAL "ctest_inventory")
    set(_digest_field macos-host-ctest-inventory-sha256)
  elseif(kind STREQUAL "ctest_junit")
    set(_digest_field macos-host-ctest-junit-sha256)
  elseif(kind STREQUAL "ctest_log")
    set(_digest_field macos-host-ctest-log-sha256)
  elseif(kind STREQUAL "ctest_process_facts")
    set(_digest_field macos-host-ctest-process-facts-sha256)
  else()
    set(_digest_field "")
  endif()
  if(NOT _digest_field STREQUAL "")
    macos_host_value("${report}" "${_digest_field}" _old_digest _unused)
    string(REPLACE "${_digest_field}=${_old_digest}"
      "${_digest_field}=sha256:${_new_hash}" _updated "${_updated}")
  endif()
  set("${report_out}" "${_updated}" PARENT_SCOPE)
endfunction()

function(macos_host_control_report root output_report)
  file(MAKE_DIRECTORY "${root}")
  set(_names host_tracer host_content host_input host_input_session host_timing
    host_display host_audio native_window_smoke native_smoke_cleanup_controls
    native_smoke_protocol_controls native_open_retry native_lifecycle)
  set(_inventory_tests "")
  set(_junit_cases "")
  set(_log "")
  foreach(_name IN LISTS _names)
    string(APPEND _inventory_tests "{\"name\":\"${_name}\",\"properties\":[]},")
    string(APPEND _junit_cases "<testcase name=\"${_name}\" status=\"run\" time=\"0.1\"/>\n")
  endforeach()
  string(REGEX REPLACE ",$" "" _inventory_tests "${_inventory_tests}")
  set(_inventory "{\"kind\":\"ctestInfo\",\"tests\":[${_inventory_tests}]}\n")
  set(_junit "<testsuites><testsuite tests=\"12\" failures=\"0\" disabled=\"0\" skipped=\"0\">\n${_junit_cases}</testsuite></testsuites>\n")
  set(_process "format=libfuturo-host-ctest-process-v1\nctest_pid=1234\nexit_status=0\nsignal=none\ntimed_out=no\n")
  set(_resolution "format=libfuturo-host-package-resolution-v1\nlibfuturo=lib/cmake/libfuturo\nnesturbator=lib/cmake/nesturbator\nmuhtari=lib/cmake/muhtari\n")
  set(_markers
    "8: installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass\n"
    "8: installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass\n"
    "11: installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass\n"
    "11: installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass\n"
    "1: host_tracer: profile=muhtari-ntsc-v1 startup=partial steady=pass pcm=pass immutable=pass capacity=801 serialized=pass overlap=pass ownership=pass destroy=once result=pass\n"
    "2: host_content: sizes=empty,1,max-minus-one,max,max-plus-one nonregular=directory,fifo unreadable=pass truncation=pass growth=pass allocation=pass eintr=pass cleanup=pass result=pass\n"
    "3: host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=pass\n"
    "5: host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one rational=long-ordinal overload=skip duplicate=single max-inflight=1 sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once overflow=checked catchup-control=detected wrong-order-control=detected stale-callbacks=filtered audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass guest=continued pcm=valid muted-advances=3 unmuted-advances=2 deadlines=1-4 stop-controls=detected result=pass\n"
    "6: host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass\n"
    "7: host_audio: pool=capacity5 frames=54,800,801 bounds=checked drop=newest tokens=duplicate,stale rejected retirement=concurrent lock-free=10/10 manual=s16-input,float32-render-mono-48000 blocks=54,800,801 order=pass mute-output=silent,restored-source restore-transition=bounded,stable-after=2-of-3-blocks duplicate=stable completion=retired callback=pool-only close=lease-drained forbidden-controls=guest,player-stop-rejected result=pass\n"
    "8: installed_macos_host: audio=system source=s16-native,mono,48000 output-rate=48000 output-channels=2 dataPlayedBack=1 pool-drops=0 prime-delay-ms=41 player-stopped=true engine-stopped=true result=pass\n"
    "9: native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass\n"
    "10: native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass\n"
    "12: installed_macos_host: lifecycle=close phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass\n"
    "12: installed_macos_host: lifecycle=quit phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass\n"
    "12: installed_macos_host: lifecycle=close phase=load-error owner-drained=pass main-sentinel=pass error-suppressed=pass destroy=once result=pass\n"
    "12: native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass\n")
  string(JOIN "" _log ${_markers})

  set(_report
    "format=libfuturo-relocation-macos-host-v1\n"
    "source_commit=0123456789abcdef0123456789abcdef01234567\n"
    "source_worktree=dirty\n"
    "dependency_origin=https://github.com/szTheory/nesturbator.git\n"
    "dependency_commit=2338608ab184f040620a30d17756f5e06a42d4e3\n"
    "muhtari_dependency_origin=https://github.com/szTheory/muhtari.git\n"
    "muhtari_dependency_commit=d5fd241e3f4d701d73867cc2e465c56a6fe6793d\n"
    "muhtari-fixture-bytes=16512\n"
    "muhtari-fixture-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
    "muhtari-fixture-provenance=project-authored-C-generator license=Apache-2.0 output=build-only\n"
    "muhtari-fixture-generator=C17 Apple clang version 21.0.0\n"
    "muhtari-fixture-generation: checked=16512 source=project-authored-C-generator license=Apache-2.0 output=build-only result=pass\n"
    "macos-host=passed\n"
    "macos-host-package-resolution=libfuturo,nesturbator,muhtari:relocated\n"
    "macos-host-ctest-result=passed\n"
    "macos-host-ctest-exit=0\n"
    "macos-host-ctest-signal=none\n"
    "macos-host-ctest-timed-out=no\n"
    "macos-host-ctest-inventory-ref=relocation-reports/host-artifacts/control/ctest-inventory.json\n"
    "macos-host-ctest-junit-ref=relocation-reports/host-artifacts/control/ctest-junit.xml\n"
    "macos-host-ctest-log-ref=relocation-reports/host-artifacts/control/ctest-log.txt\n"
    "macos-host-ctest-process-facts-ref=relocation-reports/host-artifacts/control/process-facts.txt\n"
    "macos-host-marker=installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass\n"
    "macos-host-production-view-marker=installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass\n"
    "macos-host-open-retry-marker=installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass\n"
    "macos-host-cli-retry-marker=installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass\n"
    "macos-host-tracer-marker=host_tracer: profile=muhtari-ntsc-v1 startup=partial steady=pass pcm=pass immutable=pass capacity=801 serialized=pass overlap=pass ownership=pass destroy=once result=pass\n"
    "macos-host-content-marker=host_content: sizes=empty,1,max-minus-one,max,max-plus-one nonregular=directory,fifo unreadable=pass truncation=pass growth=pass allocation=pass eintr=pass cleanup=pass result=pass\n"
    "macos-host-input-marker=host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=pass\n"
    "macos-host-timing-marker=host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one rational=long-ordinal overload=skip duplicate=single max-inflight=1 sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once overflow=checked catchup-control=detected wrong-order-control=detected stale-callbacks=filtered audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass guest=continued pcm=valid muted-advances=3 unmuted-advances=2 deadlines=1-4 stop-controls=detected result=pass\n"
    "macos-host-display-marker=host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass\n"
    "macos-host-audio-test-marker=host_audio: pool=capacity5 frames=54,800,801 bounds=checked drop=newest tokens=duplicate,stale rejected retirement=concurrent lock-free=10/10 manual=s16-input,float32-render-mono-48000 blocks=54,800,801 order=pass mute-output=silent,restored-source restore-transition=bounded,stable-after=2-of-3-blocks duplicate=stable completion=retired callback=pool-only close=lease-drained forbidden-controls=guest,player-stop-rejected result=pass\n"
    "macos-host-audio-marker=installed_macos_host: audio=system source=s16-native,mono,48000 output-rate=48000 output-channels=2 dataPlayedBack=1 pool-drops=0 prime-delay-ms=41 player-stopped=true engine-stopped=true result=pass\n"
    "macos-host-audio-evidence=system-path,completion,format,player-stop,engine-stop:validated\n"
    "macos-host-lifecycle-close-marker=installed_macos_host: lifecycle=close phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass\n"
    "macos-host-lifecycle-quit-marker=installed_macos_host: lifecycle=quit phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass\n"
    "macos-host-lifecycle-error-marker=installed_macos_host: lifecycle=close phase=load-error owner-drained=pass main-sentinel=pass error-suppressed=pass destroy=once result=pass\n"
    "macos-host-lifecycle-marker=native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass\n")
  foreach(_name IN LISTS _names)
    string(APPEND _report "macos-host-ctest-test=${_name}|passed\n")
  endforeach()
  foreach(_stage macos-host-configure macos-host-build macos-host)
    string(APPEND _report "isolation_stage=${_stage} checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\n")
  endforeach()

  set(_artifacts
    "libfuturo_archive|relocation-artifacts/control/liblibfuturo.a|fake libfuturo archive\n"
    "nesturbator_archive|relocation-artifacts/control/libnesturbator.a|fake nesturbator archive\n"
    "muhtari_archive|relocation-artifacts/control/libmuhtari.a|fake muhtari archive\n"
    "diagnostic_fixture|relocation-reports/host-artifacts/control/diagnostic.a78|fixture bytes\n"
    "host_executable|relocation-reports/host-artifacts/control/installed_macos_host|host bytes\n"
    "host_tracer_executable|relocation-reports/host-artifacts/control/host_tracer|tracer bytes\n"
    "host_content_executable|relocation-reports/host-artifacts/control/host_content|content bytes\n"
    "host_input_executable|relocation-reports/host-artifacts/control/host_input|input bytes\n"
    "host_input_session_executable|relocation-reports/host-artifacts/control/host_input_session|input session bytes\n"
    "host_timing_executable|relocation-reports/host-artifacts/control/host_timing|timing bytes\n"
    "host_display_executable|relocation-reports/host-artifacts/control/host_display|display bytes\n"
    "host_audio_executable|relocation-reports/host-artifacts/control/host_audio|audio bytes\n"
    "package_resolution|relocation-reports/host-artifacts/control/package-resolution.txt|${_resolution}"
    "ctest_inventory|relocation-reports/host-artifacts/control/ctest-inventory.json|${_inventory}"
    "ctest_junit|relocation-reports/host-artifacts/control/ctest-junit.xml|${_junit}"
    "ctest_log|relocation-reports/host-artifacts/control/ctest-log.txt|${_log}"
    "ctest_process_facts|relocation-reports/host-artifacts/control/process-facts.txt|${_process}")
  set(_artifact_lines "")
  foreach(_artifact IN LISTS _artifacts)
    string(REPLACE "|" ";" _columns "${_artifact}")
    list(GET _columns 0 _kind)
    list(GET _columns 1 _ref)
    list(GET _columns 2 _content)
    macos_host_add_control_artifact("${root}" "${_kind}" "${_ref}"
      "${_content}" _line)
    string(APPEND _artifact_lines "${_line}")
    if(_kind STREQUAL "libfuturo_archive")
      file(SHA256 "${root}/${_ref}" _lf_hash)
      string(APPEND _report "installed_file_sha256=lib/liblibfuturo.a sha256:${_lf_hash}\n")
    elseif(_kind STREQUAL "nesturbator_archive")
      file(SHA256 "${root}/${_ref}" _nest_hash)
      string(APPEND _report "installed_file_sha256=lib/libnesturbator.a sha256:${_nest_hash}\n")
    elseif(_kind STREQUAL "muhtari_archive")
      file(SHA256 "${root}/${_ref}" _mu_hash)
      string(APPEND _report "installed_file_sha256=lib/libmuhtari.a sha256:${_mu_hash}\n")
    elseif(_kind STREQUAL "diagnostic_fixture")
      file(SHA256 "${root}/${_ref}" _fixture_hash)
      string(REPLACE
        "muhtari-fixture-sha256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        "muhtari-fixture-sha256=sha256:${_fixture_hash}"
        _report "${_report}")
    elseif(_kind STREQUAL "ctest_inventory")
      file(SHA256 "${root}/${_ref}" _hash)
      string(APPEND _report "macos-host-ctest-inventory-sha256=sha256:${_hash}\n")
    elseif(_kind STREQUAL "ctest_junit")
      file(SHA256 "${root}/${_ref}" _hash)
      string(APPEND _report "macos-host-ctest-junit-sha256=sha256:${_hash}\n")
    elseif(_kind STREQUAL "ctest_log")
      file(SHA256 "${root}/${_ref}" _hash)
      string(APPEND _report "macos-host-ctest-log-sha256=sha256:${_hash}\n")
    elseif(_kind STREQUAL "ctest_process_facts")
      file(SHA256 "${root}/${_ref}" _hash)
      string(APPEND _report "macos-host-ctest-process-facts-sha256=sha256:${_hash}\n")
    endif()
  endforeach()
  string(APPEND _report "${_artifact_lines}")
  set("${output_report}" "${_report}" PARENT_SCOPE)
endfunction()

function(macos_host_run_controls)
  set(_root "${CMAKE_CURRENT_BINARY_DIR}/macos-host-evidence-controls")
  file(REMOVE_RECURSE "${_root}")
  set(_artifact_root "${_root}")
  macos_host_control_report("${_root}" _valid_report)
  macro(reset_valid_host_control)
    file(REMOVE_RECURSE "${_root}")
    macos_host_control_report("${_root}" _valid_report)
  endmacro()
  macos_host_assert_control("complete-valid-report" "${_valid_report}"
    "${_artifact_root}" "" accept)
  macos_host_assert_control("missing-report" "" "${_artifact_root}"
    host-report-format-invalid reject)
  macos_host_assert_control("headless-only" "format=libfuturo-relocation-save-restart-v1\nsave-restart=pass\n"
    "${_artifact_root}" host-report-format-invalid reject)
  reset_valid_host_control()
  set(_missing_registration "${_valid_report}")
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-inventory.json"
    _inventory)
  reset_valid_host_control()
  string(REPLACE
    "{\"name\":\"host_display\",\"properties\":[]},"
    ""
    _inventory_missing "${_inventory}")
  macos_host_replace_control_artifact("${_root}" "${_missing_registration}"
    ctest_inventory "${_inventory_missing}" _missing_registration)
  macos_host_assert_control("missing-registration" "${_missing_registration}"
    "${_artifact_root}" host-ctest-inventory-required-set-mismatch reject)
  reset_valid_host_control()
  string(REPLACE
    "macos-host-ctest-test=host_tracer|passed\nmacos-host-ctest-test=host_content|passed\n"
    "macos-host-ctest-test=host_content|passed\nmacos-host-ctest-test=host_tracer|passed\n"
    _report_reordered_tests "${_valid_report}")
  macos_host_assert_control("reordered-report-test-rows"
    "${_report_reordered_tests}" "${_artifact_root}"
    host-ctest-inventory-order-mismatch reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-inventory.json"
    _inventory)
  string(REPLACE
    "{\"name\":\"host_tracer\",\"properties\":[]},{\"name\":\"host_content\",\"properties\":[]}"
    "{\"name\":\"host_content\",\"properties\":[]},{\"name\":\"host_tracer\",\"properties\":[]}"
    _inventory_reordered_tests "${_inventory}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_inventory "${_inventory_reordered_tests}" _inventory_reordered_report)
  macos_host_assert_control("reordered-inventory-tests"
    "${_inventory_reordered_report}" "${_artifact_root}"
    host-ctest-inventory-order-mismatch reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-junit.xml"
    _junit)
  string(REPLACE
    "<testcase name=\"host_tracer\" status=\"run\" time=\"0.1\"/>\n<testcase name=\"host_content\" status=\"run\" time=\"0.1\"/>\n"
    "<testcase name=\"host_content\" status=\"run\" time=\"0.1\"/>\n<testcase name=\"host_tracer\" status=\"run\" time=\"0.1\"/>\n"
    _junit_reordered_tests "${_junit}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_junit "${_junit_reordered_tests}" _junit_reordered_report)
  macos_host_assert_control("reordered-junit-tests"
    "${_junit_reordered_report}" "${_artifact_root}"
    host-junit-order-mismatch reject)
  reset_valid_host_control()
  string(REPLACE
    "macos-host-marker=installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass"
    "macos-host-marker=missing"
    _missing_native_marker "${_valid_report}")
  macos_host_assert_control("missing-native-marker" "${_missing_native_marker}"
    "${_artifact_root}" host-native-window-marker-missing reject)
  reset_valid_host_control()
  string(REGEX REPLACE
    "macos-host-production-view-marker=[^\n]*\n" ""
    _missing_production_view_marker "${_valid_report}")
  macos_host_assert_control("missing-production-view-report-marker"
    "${_missing_production_view_marker}" "${_artifact_root}"
    host-required-field-missing-or-duplicate reject)
  reset_valid_host_control()
  string(REPLACE
    "macos-host-production-view-marker=installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass"
    "macos-host-production-view-marker=missing"
    _changed_production_view_marker "${_valid_report}")
  macos_host_assert_control("changed-production-view-report-marker"
    "${_changed_production_view_marker}" "${_artifact_root}"
    host-required-marker-missing reject)
  reset_valid_host_control()
  string(REGEX REPLACE "macos-host-audio-marker=[^\n]*\n" ""
    _missing_audio_marker "${_valid_report}")
  macos_host_assert_control("missing-live-audio-marker"
    "${_missing_audio_marker}" "${_artifact_root}"
    host-required-field-missing-or-duplicate reject)
  reset_valid_host_control()
  string(REPLACE
    "source=s16-native,mono,48000 output-rate=48000"
    "source=s16-native,stereo,48000 output-rate=48000"
    _audio_wrong_source "${_valid_report}")
  macos_host_assert_control("altered-audio-source-format"
    "${_audio_wrong_source}" "${_artifact_root}"
    host-audio-marker-invalid reject)
  reset_valid_host_control()
  string(REPLACE
    "source=s16-native,mono,48000 output-rate=48000"
    "source=s16-native,mono,48000 output-rate=0"
    _audio_zero_rate "${_valid_report}")
  macos_host_assert_control("zero-audio-output-rate"
    "${_audio_zero_rate}" "${_artifact_root}"
    host-audio-marker-invalid reject)
  reset_valid_host_control()
  string(REPLACE "dataPlayedBack=1" "dataPlayedBack=0"
    _audio_zero_completion "${_valid_report}")
  macos_host_assert_control("zero-audio-completion-count"
    "${_audio_zero_completion}" "${_artifact_root}"
    host-audio-marker-invalid reject)
  reset_valid_host_control()
  string(REPLACE "player-stopped=true" "player-stopped=false"
    _audio_player_running "${_valid_report}")
  macos_host_assert_control("player-stop-omitted"
    "${_audio_player_running}" "${_artifact_root}"
    host-audio-marker-invalid reject)
  reset_valid_host_control()
  string(REPLACE "engine-stopped=true" "engine-stopped=false"
    _audio_engine_running "${_valid_report}")
  macos_host_assert_control("engine-stop-omitted"
    "${_audio_engine_running}" "${_artifact_root}"
    host-audio-marker-invalid reject)
  reset_valid_host_control()
  string(REPLACE "output-rate=48000" "output-rate=44100"
    _audio_identity_mismatch "${_valid_report}")
  macos_host_assert_control("live-audio-marker-unbound"
    "${_audio_identity_mismatch}" "${_artifact_root}"
    host-audio-marker-not-bound-to-smoke reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _production_view_log)
  string(REPLACE
    "8: installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass\n"
    ""
    _missing_production_view_log "${_production_view_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_missing_production_view_log}"
    _missing_production_view_log_report)
  macos_host_assert_control("missing-production-view-log-marker"
    "${_missing_production_view_log_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _cleanup_controls_log)
  string(REPLACE
    "9: native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass\n"
    ""
    _missing_cleanup_controls_log "${_cleanup_controls_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_missing_cleanup_controls_log}"
    _missing_cleanup_controls_log_report)
  macos_host_assert_control("missing-cleanup-controls-log-marker"
    "${_missing_cleanup_controls_log_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _protocol_controls_log)
  string(REPLACE
    "10: native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass\n"
    ""
    _missing_protocol_controls_log "${_protocol_controls_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_missing_protocol_controls_log}"
    _missing_protocol_controls_log_report)
  macos_host_assert_control("missing-protocol-controls-log-marker"
    "${_missing_protocol_controls_log_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _cleanup_wrong_test_log)
  string(REPLACE
    "9: native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass\n"
    "7: native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass\n"
    _cleanup_wrong_test_log "${_cleanup_wrong_test_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_cleanup_wrong_test_log}" _cleanup_wrong_test_report)
  macos_host_assert_control("cleanup-marker-wrong-test"
    "${_cleanup_wrong_test_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _protocol_wrong_test_log)
  string(REPLACE
    "10: native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass\n"
    "8: native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass\n"
    _protocol_wrong_test_log "${_protocol_wrong_test_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_protocol_wrong_test_log}" _protocol_wrong_test_report)
  macos_host_assert_control("protocol-marker-wrong-test"
    "${_protocol_wrong_test_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-log.txt"
    _retry_log)
  string(REPLACE
    "11: installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass\n"
    "8: installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass\n"
    _retry_wrong_test_log "${_retry_log}")
  string(REPLACE
    "11: installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass\n"
    "8: installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass\n"
    _retry_wrong_test_log "${_retry_wrong_test_log}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_log "${_retry_wrong_test_log}" _retry_wrong_test_report)
  macos_host_assert_control("retry-markers-wrong-test"
    "${_retry_wrong_test_report}" "${_artifact_root}"
    host-ctest-log-marker-missing reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/process-facts.txt"
    _process)
  string(REPLACE "exit_status=0" "exit_status=8" _process_nonzero "${_process}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_process_facts "${_process_nonzero}" _nonzero)
  string(REPLACE "macos-host-ctest-exit=0" "macos-host-ctest-exit=8"
    _nonzero "${_nonzero}")
  macos_host_assert_control("nonzero-child" "${_nonzero}" "${_artifact_root}"
    host-ctest-process-nonzero reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/process-facts.txt"
    _process)
  string(REPLACE "timed_out=no" "timed_out=yes" _process_timeout "${_process}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_process_facts "${_process_timeout}" _timeout)
  string(REPLACE "macos-host-ctest-timed-out=no" "macos-host-ctest-timed-out=yes"
    _timeout "${_timeout}")
  macos_host_assert_control("timeout" "${_timeout}" "${_artifact_root}"
    host-ctest-process-timeout reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/process-facts.txt"
    _process)
  string(REPLACE "signal=none" "signal=TERM" _process_cancelled "${_process}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_process_facts "${_process_cancelled}" _cancelled)
  string(REPLACE "macos-host-ctest-signal=none" "macos-host-ctest-signal=TERM"
    _cancelled "${_cancelled}")
  macos_host_assert_control("cancelled" "${_cancelled}" "${_artifact_root}"
    host-ctest-process-cancelled reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-junit.xml"
    _junit)
  string(REPLACE "host_display\" status=\"run" "host_display\" status=\"skipped"
    _junit_skipped "${_junit}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_junit "${_junit_skipped}" _skipped)
  macos_host_assert_control("skipped" "${_skipped}" "${_artifact_root}"
    host-junit-result-not-complete reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/ctest-inventory.json"
    _inventory)
  string(REPLACE
    "{\"name\":\"host_display\",\"properties\":[]}"
    "{\"name\":\"host_display\",\"properties\":[{\"name\":\"DISABLED\",\"value\":true}]}"
    _inventory_disabled "${_inventory}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_inventory "${_inventory_disabled}" _disabled)
  macos_host_assert_control("disabled" "${_disabled}" "${_artifact_root}"
    host-ctest-inventory-disabled reject)
  reset_valid_host_control()
  string(REPLACE
    "macos-host-artifact=host_display_executable|relocation-reports/host-artifacts/control/host_display|sha256:"
    "macos-host-artifact=host_display_executable|relocation-reports/host-artifacts/control/host_display|sha256:"
    _evidence_free "${_valid_report}")
  string(REGEX REPLACE "macos-host-artifact=host_display_executable[^\n]*\n" ""
    _evidence_free "${_evidence_free}")
  macos_host_assert_control("evidence-free" "${_evidence_free}"
    "${_artifact_root}" host-evidence-artifact-set-incomplete reject)
  reset_valid_host_control()
  file(SHA256
    "${_root}/relocation-artifacts/control/liblibfuturo.a" _archive_hash)
  string(REPLACE
    "macos-host-artifact=libfuturo_archive|relocation-artifacts/control/liblibfuturo.a|sha256:${_archive_hash}"
    "macos-host-artifact=libfuturo_archive|relocation-artifacts/control/liblibfuturo.a|sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    _wrong_archive "${_valid_report}")
  macos_host_assert_control("wrong-archive-identity" "${_wrong_archive}"
    "${_artifact_root}" host-evidence-artifact-digest-mismatch-libfuturo_archive reject)
  reset_valid_host_control()
  string(REGEX REPLACE
    "macos-host-artifact=libfuturo_archive[^\n]*\n" ""
    _missing_archive "${_valid_report}")
  macos_host_assert_control("missing-archive-identity" "${_missing_archive}"
    "${_artifact_root}" host-evidence-artifact-set-incomplete reject)
  reset_valid_host_control()
  string(REGEX REPLACE
    "macos-host-artifact=host_executable[^\n]*\n" ""
    _missing_executable "${_valid_report}")
  macos_host_assert_control("missing-executable-identity" "${_missing_executable}"
    "${_artifact_root}" host-evidence-artifact-set-incomplete reject)
  reset_valid_host_control()
  file(SHA256
    "${_root}/relocation-reports/host-artifacts/control/installed_macos_host"
    _host_executable_hash)
  string(REPLACE
    "macos-host-artifact=host_executable|relocation-reports/host-artifacts/control/installed_macos_host|sha256:${_host_executable_hash}"
    "macos-host-artifact=host_executable|relocation-reports/host-artifacts/control/installed_macos_host|sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    _wrong_executable "${_valid_report}")
  macos_host_assert_control("wrong-executable-identity" "${_wrong_executable}"
    "${_artifact_root}" host-evidence-artifact-digest-mismatch-host_executable reject)
  reset_valid_host_control()
  string(REPLACE "muhtari_dependency_commit=d5fd241e3f4d701d73867cc2e465c56a6fe6793d"
    "muhtari_dependency_commit=0000000000000000000000000000000000000000"
    _wrong_pin "${_valid_report}")
  macos_host_assert_control("wrong-source-pin" "${_wrong_pin}"
    "${_artifact_root}" host-source-or-pin-identity-invalid reject)
  reset_valid_host_control()
  string(REPLACE "source_commit=0123456789abcdef0123456789abcdef01234567"
    "source_commit=wrong" _wrong_source "${_valid_report}")
  macos_host_assert_control("wrong-source-identity" "${_wrong_source}"
    "${_artifact_root}" host-source-or-pin-identity-invalid reject)
  reset_valid_host_control()
  string(REPLACE "macos-host-ctest-result=passed" "macos-host-ctest-result=unsupported"
    _unsupported "${_valid_report}")
  macos_host_assert_control("unexpected-unsupported" "${_unsupported}"
    "${_artifact_root}" host-ctest-result-not-passed reject)
  reset_valid_host_control()
  string(REPLACE "macos-host-package-resolution=libfuturo,nesturbator,muhtari:relocated"
    "macos-host-package-resolution=headless-only" _missing_package "${_valid_report}")
  macos_host_assert_control("missing-package-resolution" "${_missing_package}"
    "${_artifact_root}" host-package-resolution-missing reject)
  reset_valid_host_control()
  string(REGEX REPLACE "isolation_stage=macos-host-build[^\n]*\n" ""
    _missing_stage "${_valid_report}")
  macos_host_assert_control("missing-isolation-stage" "${_missing_stage}"
    "${_artifact_root}" host-isolation-stage-missing reject)
  reset_valid_host_control()
  string(REGEX REPLACE
    "macos-host-artifact=ctest_log[^\n]*"
    "macos-host-artifact=ctest_log|/Users/user/ctest-log.txt|sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    _absolute_path "${_valid_report}")
  macos_host_assert_control("absolute-path" "${_absolute_path}"
    "${_artifact_root}" host-evidence-artifact-ref-unsafe reject)
  reset_valid_host_control()
  file(READ "${_root}/relocation-reports/host-artifacts/control/process-facts.txt"
    _process)
  string(REPLACE "ctest_pid=1234" "ctest_pid=1234garbage"
    _process_bad_pid "${_process}")
  macos_host_replace_control_artifact("${_root}" "${_valid_report}"
    ctest_process_facts "${_process_bad_pid}" _bad_pid)
  macos_host_assert_control("pid-trailing-garbage" "${_bad_pid}"
    "${_artifact_root}" host-ctest-process-facts-invalid reject)
  reset_valid_host_control()
  string(APPEND _valid_report "source_commit=ffffffffffffffffffffffffffffffffffffffff\n")
  macos_host_assert_control("duplicate-conflicting-field" "${_valid_report}"
    "${_artifact_root}" host-report-duplicate-field reject)
  message(STATUS
    "macos_host_evidence_controls: cases=complete,missing-registration,reordered-report-tests,reordered-inventory-tests,reordered-junit-tests,missing-report,native-marker,missing-cleanup-marker,missing-protocol-marker,cleanup-marker-wrong-test,protocol-marker-wrong-test,retry-markers-wrong-test,audio-missing-format-completion-player-stop-engine-stop-identity,nonzero,timeout,cancelled,skipped,disabled,evidence-free,wrong-pin,wrong-source,package-resolution,artifact-identities,isolation-stage,headless-only,unsupported,duplicate,absolute-path,pid-trailing-garbage result=pass")
endfunction()

if(DEFINED MACOS_HOST_EVIDENCE_MODE AND
   MACOS_HOST_EVIDENCE_MODE STREQUAL "actual")
  foreach(_required_var MACOS_HOST_REPORT MACOS_HOST_ARTIFACT_ROOT)
    if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
      message(FATAL_ERROR "${_required_var} is required for native host evidence validation")
    endif()
  endforeach()
  if(NOT EXISTS "${MACOS_HOST_REPORT}" OR IS_DIRECTORY "${MACOS_HOST_REPORT}")
    message(FATAL_ERROR "macos host evidence report is missing")
  endif()
  file(READ "${MACOS_HOST_REPORT}" _host_report)
  macos_host_report_proof("${_host_report}" "${MACOS_HOST_ARTIFACT_ROOT}"
    _host_proof _host_detail)
  if(NOT _host_proof)
    message(FATAL_ERROR "macos host evidence rejected: ${_host_detail}")
  endif()
  message(STATUS "macos_host_evidence: ${_host_detail}")
endif()
