cmake_minimum_required(VERSION 3.25)

get_filename_component(_project_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

function(require_file relative_path description)
  if(NOT EXISTS "${_project_root}/${relative_path}")
    message(FATAL_ERROR
      "contract traceability: ${description} is missing: ${relative_path}")
  endif()
endfunction()

function(require_text relative_path marker description)
  require_file("${relative_path}" "${description}")
  file(READ "${_project_root}/${relative_path}" _content)
  string(FIND "${_content}" "${marker}" _marker_index)
  if(_marker_index EQUAL -1)
    message(FATAL_ERROR
      "contract traceability: ${description} is missing '${marker}' in ${relative_path}")
  endif()
endfunction()

set(_obligations
  LC-LIFE-01
  LC-OWN-01
  LC-LOAD-01
  LC-INPUT-01
  LC-TIME-01
  LC-LIMIT-01
  LC-ERROR-01
  LC-HOST-01
)

foreach(_path IN ITEMS
    docs/contract.md
    include/libfuturo/libfuturo.h
    docs/synthetic-profile.md
    docs/nesturbator-profile.md
    examples/synthetic/main.c)
  require_file("${_path}" "shared contract reference target")
endforeach()
foreach(_path IN ITEMS
    docs/muhtari-profile.md
    docs/muhtari-snapshot-fixture.md
    examples/muhtari/main.c
    tests/installed-consumer/muhtari_session.c)
  require_file("${_path}" "Muhtari format/cadence reference target")
endforeach()
foreach(_path IN ITEMS
    src/muhtari_adapter.c
    tests/installed-consumer/muhtari_snapshot.c
    tests/installed-consumer/muhtari_snapshot_oracle.h
    tests/installed-consumer/muhtari_snapshot_host.h
    tests/installed-consumer/muhtari_snapshot_faults.h
    tests/installed-consumer/CMakeLists.txt
    tests/installed-consumer/relocate-muhtari-api8.sh
    cmake/ValidateMuhtariApi8Results.cmake
    scripts/check-muhtari-api8.sh)
  require_file("${_path}" "API 8 public-route reference target")
endforeach()

foreach(_obligation IN LISTS _obligations)
  foreach(_path IN ITEMS
      docs/contract.md
      include/libfuturo/libfuturo.h
      docs/synthetic-profile.md
      docs/nesturbator-profile.md
      examples/synthetic/main.c)
    require_text("${_path}" "${_obligation}" "${_obligation} mapping")
  endforeach()
endforeach()

foreach(_keyword IN ITEMS "RFC 2119" "RFC 8174" MUST "MUST NOT" SHOULD
    "SHOULD NOT" MAY)
  require_text("docs/contract.md" "${_keyword}" "normative keyword definition")
endforeach()

# Keep these focused references tied to existing executable checks. The
# contract file links each obligation to the relevant function or CTest.
require_text("tests/synthetic_boundaries.c" "test_allocator_lifecycle"
  "lifecycle assertion")
require_text("tests/synthetic_session.c" "media output survives destruction"
  "host-owned lifetime assertion")
require_text("tests/synthetic_boundaries.c"
  "test_capability_and_synthetic_load_boundaries" "load transition assertion")
require_text("tests/synthetic_session.c" "valid output and guest-time metadata"
  "input and time assertion")
require_text("tests/synthetic_boundaries.c" "test_work_and_lifetime_boundaries"
  "work limit assertion")
require_text("tests/nesturbator_session.c" "exercise_load_failure_cases"
  "real profile error assertion")
require_text("tests/nesturbator_session.c" "exercise_frame_failures"
  "real profile frame assertion")
require_text("cmake/ExpectNesturbatorSaveRestart.cmake"
  "old-commit-old-ack-fresh-restorer" "durable host save assertion")
require_text("tests/conformance.c" "LC-LOAD-01"
  "load-preservation conformance assertion")
require_text("tests/conformance.c" "LC-TIME-01"
  "guest-time conformance assertion")
require_text("cmake/ExpectConformanceFailure.cmake"
  "unsupported-load-preservation expected=LF_OK observed=LF_INVALID_ARGUMENT"
  "load-preservation negative control")
require_text("cmake/ExpectConformanceFailure.cmake"
  "guest-unit-accounting expected=requested:1,actual:1,cumulative:1"
  "guest-time negative control")
require_text("src/synthetic.c" "LF_CONFORMANCE_VARIANT_CLEAR_ON_UNSUPPORTED_LOAD"
  "private unsupported-load variant")
require_text("src/synthetic.c" "LF_CONFORMANCE_VARIANT_DOUBLE_GUEST_UNITS"
  "private guest-time variant")
require_text("CMakeLists.txt" "add_custom_target(conformance"
  "grouped conformance target")

# INDEX8 and cadence are profile declarations rather than new LC obligations.
# Keep their shared wording tied to the actual profile, example, consumer, and
# the existing profiles' explicit undeclared-cadence assertions.
require_text("docs/contract.md" "LF_VIDEO_INDEX8"
  "raw indexed-byte contract")
require_text("docs/contract.md" "means cadence is undeclared or inapplicable"
  "undeclared cadence contract")
require_text("docs/muhtari-profile.md" "39375000/656711"
  "Muhtari exact cadence declaration")
require_text("examples/muhtari/main.c" "profile.video_format != LF_VIDEO_INDEX8"
  "public example indexed-format assertion")
require_text("examples/muhtari/main.c" "expected_samples[2] = {54U, 801U}"
  "public example startup and steady sample assertion")
require_text("tests/installed-consumer/muhtari_session.c"
  "profile->video_format == LF_VIDEO_INDEX8"
  "installed Muhtari indexed-format assertion")
require_text("tests/installed-consumer/muhtari_session.c"
  "profile->frame_rate_numerator == 39375000U"
  "installed Muhtari exact-cadence assertion")
require_text("tests/installed-consumer/muhtari_session.c"
  "indexed_image_matches" "installed raw-index image assertion")
require_text("tests/conformance.c" "profile.frame_rate_numerator != 0U"
  "existing profiles undeclared-cadence assertion")
require_text("tests/conformance.c" "LF_VIDEO_RGB24"
  "existing real profile format assertion")

# Snapshot contract and refusal rules are tied to the public declarations,
# profile postconditions, and the generated real-core continuation controls.
require_text("docs/contract.md" "LC-SNAPSHOT-01"
  "snapshot ownership and capability contract")
require_text("docs/contract.md"
  "requires its explicit configuration ID"
  "API 8 configuration-specific capability query")
require_text("docs/contract.md" "LC-SNAPSHOT-05"
  "snapshot persistence boundary contract")
require_text("include/libfuturo/libfuturo.h" "lf_get_snapshot_size"
  "public snapshot declarations")
require_text("include/libfuturo/libfuturo.h" "LF_INVALID_ARGUMENT"
  "public unloaded snapshot status")
require_text("include/libfuturo/libfuturo.h"
  "battery-backed MMC1 content with SHA-256 digest"
  "public battery-backed snapshot route")
require_text("include/libfuturo/libfuturo.h"
  "qualified battery-free fresh-process exception"
  "public qualified fresh-process exception")
require_text("include/libfuturo/libfuturo.h"
  "separate battery-backed fresh-process exception applies only"
  "public exact battery-backed fresh-process boundary")
require_text("include/libfuturo/libfuturo.h"
  "40,976-byte"
  "public generated battery fixture extent")
require_text("include/libfuturo/libfuturo.h"
  "preserve the selected R3 bytes and host acknowledgment"
  "public battery-backed save custody")
require_text("include/libfuturo/libfuturo.h"
  "Stable identity must match the LFSNAP2 envelope"
  "public cross-process stable identity fields")
require_text("include/libfuturo/libfuturo.h"
  "successful-load epoch rejects snapshots from stale successful loads"
  "public same-instance load-epoch limit")
require_text("include/libfuturo/libfuturo.h" "not cross-process identity"
  "public load-epoch identity boundary")
require_text("include/libfuturo/libfuturo.h" "host owns checkpoint I/O"
  "public host-owned checkpoint I/O")
require_text("docs/contract.md"
  "stable identity includes the `LFSNAP2` envelope version"
  "normative stable snapshot identity")
require_text("docs/contract.md" "not cross-process identity"
  "normative load-epoch identity boundary")
require_text("docs/contract.md" "owns the checkpoint path"
  "normative host-owned checkpoint I/O")
require_text("docs/contract.md"
  "The exact battery-backed fresh-process exception is separately qualified only"
  "normative exact battery-backed fresh-process boundary")
require_text("docs/contract.md"
  "remains local to each instance and is not compared across processes"
  "normative process-local epoch boundary")
require_text("docs/contract.md"
  "Only an explicit successful R2 commit"
  "normative verified selected-save acknowledgment")
require_text("docs/contract.md"
  "does not qualify physical hardware or a browser runtime"
  "normative local consumer qualification boundary")
require_text("docs/nesturbator-profile.md"
  "The battery-free route's stable identity is:"
  "Nesturbator battery-free stable identity")
require_text("docs/nesturbator-profile.md"
  "The separate Phase 14 battery-backed fresh-process identity is:"
  "Nesturbator exact battery-backed fresh-process identity")
require_text("docs/nesturbator-profile.md"
  "B's refusal baseline and generation remain local to B"
  "Nesturbator process-local refusal generation")
require_text("docs/nesturbator-profile.md" "successful-load epoch"
  "Nesturbator successful-load epoch boundary")
require_text("docs/nesturbator-profile.md"
  "Machine snapshot capture and restore" "Nesturbator snapshot profile rules")
require_text("docs/nesturbator-profile.md" "128 MiB"
  "Nesturbator snapshot extent limit")
require_text("docs/contract.md" "profile-defined core media-change token"
  "profile-defined shared media generation rule")
require_text("docs/contract.md" "failed pre-rename staging write"
  "prior selected-save recovery obligation")
require_text("docs/nesturbator-profile.md" "increases by exactly one"
  "changed-byte restore generation rule")
require_text("docs/nesturbator-profile.md" "does not increase"
  "identical-byte restore generation rule")
require_text("docs/nesturbator-profile.md"
  "`LF_UNSUPPORTED` for other battery-backed content"
  "exact profile qualification boundary")
require_text("docs/nesturbator-save-fixture.md"
  "same-successful-load-session" "fixture snapshot session boundary")
require_text("docs/nesturbator-save-fixture.md"
  "### Fresh-process battery-backed A/B qualification"
  "fixture A/B route description")
require_text("docs/nesturbator-save-fixture.md"
  "2,144,280 cumulative NES half-master ticks"
  "independent literal progress oracle")
require_text("docs/nesturbator-save-fixture.md"
  "799 mono signed-16 audio samples all equal to zero"
  "independent literal audio oracle")
require_text("docs/nesturbator-save-fixture.md"
  "[0x03, 0x00, ...]" "complete battery media oracle")
require_text("tests/nesturbator_save_oracle.h"
  "LF_BATTERY_SNAPSHOT_REPLAY_TICKS UINT64_C(2144280)"
  "source battery replay oracle literal")
require_text("tests/nesturbator_save_oracle.h"
  "LF_BATTERY_SNAPSHOT_REPLAY_AUDIO_SAMPLES 799U"
  "source battery audio oracle literal")
require_text("tests/nesturbator_session.c"
  "exercise_battery_snapshot_recovery"
  "source battery snapshot recovery assertion")
require_text("tests/installed-consumer/nesturbator_session.c"
  "exercise_installed_battery_snapshot_recovery"
  "installed battery snapshot recovery assertion")
require_text("tests/nesturbator_session.c"
  "--snapshot-battery-process-capture"
  "source battery fresh-process handler")
require_text("tests/installed-consumer/nesturbator_session.c"
  "--snapshot-battery-process-capture"
  "installed battery fresh-process handler")
require_text("CMakeLists.txt"
  "nesturbator_battery_fresh_process_snapshot"
  "required source battery fresh-process CTest")
require_text("CMakeLists.txt"
  "-DSOURCE_MODE=battery"
  "source battery route mode")
require_text("scripts/check.sh"
  "source_battery_fresh_process_snapshot|required"
  "required source battery evidence row")
require_text("scripts/check.sh"
  "installed_consumer_battery_fresh_process_snapshot|required"
  "required relocated installed battery evidence row")
require_text("scripts/check.sh"
  "--battery-fresh-process-snapshot"
  "canonical relocated installed battery route")
foreach(_consumer IN ITEMS
    tests/nesturbator_session.c
    tests/installed-consumer/nesturbator_session.c)
  require_text("${_consumer}"
    "refusal-vector=continuation,media,generation,selected-save,ack"
    "source/installed refusal and host acknowledgment assertion")
  require_text("${_consumer}" "battery_snapshot_advance_literal"
    "source/installed independent literal replay assertion")
endforeach()
require_text("tests/nesturbator_session.c"
  "snapshot envelope rejection preserves literal continuation"
  "snapshot refusal continuation assertion")
require_text("tests/nesturbator_session.c" "native_payload_corrupt"
  "native snapshot payload refusal case")
require_text("tests/nesturbator_session.c" "content_digest"
  "native snapshot content identity refusal case")
require_text("src/nesturbator_adapter.c"
  "LF_SNAPSHOT_CONTENT_DIGEST_OFFSET"
  "native snapshot content identity preflight field")
require_text("tests/nesturbator_session.c"
  "snapshot short capacity after reload preserves canaries and progress"
  "snapshot reload capacity assertion")
require_text("tests/nesturbator_session.c"
  "snapshot wrong continuation oracle" "snapshot negative oracle control")
require_text("tests/nesturbator_snapshot_capability_controls.c"
  "run_snapshot_process_capture(checkpoint_path)"
  "actual A handler capability control")
require_text("tests/nesturbator_snapshot_capability_controls.c"
  "run_snapshot_process_restore(checkpoint_path, 0)"
  "actual B handler capability control")
require_text("tests/nesturbator_snapshot_capability_controls.c"
  "denied A did not fail before all snapshot operations"
  "denied A zero-snapshot-call assertion")
require_text("tests/nesturbator_snapshot_capability_controls.c"
  "denied B did not fail before all snapshot operations"
  "denied B zero-snapshot-call assertion")
require_text("CMakeLists.txt"
  "add_required_consumer_test(nesturbator_source_snapshot_capability_controls"
  "required source capability-control registration")
require_text("CMakeLists.txt"
  "add_required_consumer_test(nesturbator_installed_snapshot_capability_controls"
  "required installed capability-control registration")
require_text("scripts/check.sh"
  "nesturbator_source_snapshot_capability_controls"
  "canonical required source capability control")
require_text("scripts/check.sh"
  "nesturbator_installed_snapshot_capability_controls"
  "canonical required installed capability control")
require_text("scripts/check.sh"
  "snapshot_capability_controls: route=source entries=A,B denied=zero-snapshot-calls result=pass"
  "canonical source capability-control marker")
require_text("scripts/check.sh"
  "snapshot_capability_controls: route=installed entries=A,B denied=zero-snapshot-calls result=pass"
  "canonical installed capability-control marker")

# API 8's exact profile exception is connected to the real public adapter,
# source and moved-installed consumers, and current route validator. These
# checks extend the traceability surface without weakening API 7 assertions.
foreach(_claim IN ITEMS
    "API 8 Muhtari exception"
    "d58f125297c4d63a7a8108112a5eafff6f53a76a"
    "muhtari-ntsc-v2"
    "136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e"
    "captures R2 after"
    "SaveKey page write pending"
    "Receiver generation is compared only"
    "pre-rename staging-write failure")
  require_text("docs/contract.md" "${_claim}" "API 8 public contract")
endforeach()
require_text("include/libfuturo/libfuturo.h"
  "separate API 8 battery-backed exception" "API 8 public declaration boundary")
require_text("include/libfuturo/libfuturo.h"
  "136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e"
  "API 8 exact fixture identity")
require_text("include/libfuturo/libfuturo.h"
  "frame 2 while the SaveKey write to aggregate offset 2051 is pending"
  "API 8 pending-boundary declaration")
require_text("include/libfuturo/libfuturo.h"
  "muhtari-ntsc-battery-diagnostic configuration; the NULL selector returns"
  "API 8 explicit capability selector")
require_text("docs/muhtari-profile.md"
  "LIBFUTURO_MUHTARI_API_REVISION=8" "API 8 explicit selector")
require_text("docs/muhtari-profile.md"
  "libfuturo_MUHTARI_SOURCE_REVISION" "exported API 8 package identity")
require_text("docs/muhtari-profile.md"
  "API 7 remains the existing/default API selection"
  "API 7 default selection preservation")
require_text("docs/muhtari-profile.md"
  "base package still has Muhtari disabled by default"
  "default-off base package preservation")
require_text("docs/muhtari-snapshot-fixture.md"
  "The source and moved-installed public routes each run a fresh-process A/B"
  "API 8 source and moved-installed proof")
require_text("docs/muhtari-snapshot-fixture.md"
  "checksum-valid native semantic-invalid state"
  "API 8 native semantic refusal")
require_text("docs/muhtari-snapshot-fixture.md"
  "they do not establish crash, abrupt-exit"
  "API 8 crash-recovery boundary")

foreach(_symbol IN ITEMS
    muhtari_get_versions
    muhtari_create
    muhtari_destroy
    muhtari_get_info
    muhtari_run_frame
    muhtari_state_size
    muhtari_save_state
    muhtari_load_state
    muhtari_get_battery
    muhtari_load
    muhtari_set_input_ex)
  require_text("src/muhtari_adapter.c" "${_symbol}"
    "integrated API 8 adapter entry ${_symbol}")
endforeach()
file(READ "${_project_root}/src/muhtari_adapter.c" _muhtari_adapter)
foreach(_symbol IN ITEMS
    "muhtari_probe("
    "muhtari_get_hsc_rom("
    "muhtari_power_cycle("
    "core_status = muhtari_set_input("
    "muhtari_get_memory("
    "muhtari_get_counters(")
  string(FIND "${_muhtari_adapter}" "${_symbol}" _excluded_symbol_index)
  if(NOT _excluded_symbol_index EQUAL -1)
    message(FATAL_ERROR
      "API 8 adapter must keep the documented opt-out ${_symbol} unwrapped")
  endif()
endforeach()
require_text("tests/installed-consumer/muhtari_snapshot.c"
  "muhtari_api8_snapshot_contract" "API 8 public snapshot assertion")
require_text("tests/installed-consumer/muhtari_snapshot_faults.h"
  "LF_MUHTARI_FAULT_NATIVE_SEMANTIC_INVALID"
  "API 8 checksum-valid semantic-invalid mutation")
require_text("tests/installed-consumer/muhtari_snapshot.c"
  "event=pre-rename-failure-preserved-r3"
  "API 8 host-save custody and failure assertion")
require_text("tests/installed-consumer/muhtari_snapshot_oracle.h"
  "LF_MUHTARI_SNAPSHOT_R2_SAVEKEY_VALUE UINT8_C(0xFF)"
  "API 8 R2 pending SaveKey literal")
require_text("tests/installed-consumer/muhtari_snapshot_oracle.h"
  "LF_MUHTARI_SNAPSHOT_R3_SAVEKEY_VALUE UINT8_C(0x5A)"
  "API 8 R3 publication literal")
require_text("CMakeLists.txt" "NAME muhtari_api8_source_fresh_process"
  "API 8 source fresh-process registration")
require_text("tests/installed-consumer/CMakeLists.txt"
  "muhtari_api8_installed_fresh_process"
  "API 8 moved-installed fresh-process registration")
require_text("CMakeLists.txt" "NAME muhtari_api8_relocated_consumer"
  "API 8 moved-prefix consumer route")
require_text("cmake/ValidateMuhtariApi8Results.cmake"
  "snapshot_boundary|R2-frame2-pending-savekey-write"
  "API 8 exact pending-boundary result validation")
require_text("cmake/ValidateMuhtariApi8Results.cmake"
  "api8_validate_pair" "API 8 independent route report validation")
require_text("scripts/check-muhtari-api8.sh"
  "RESULT_CASES=muhtari-api8-actual" "API 8 production result validation")

message(STATUS
  "contract traceability: shared obligations, snapshot identity/epoch/capability controls, battery limits, and literal consumer evidence are linked")

include("${CMAKE_CURRENT_LIST_DIR}/ValidateMuhtariDocs.cmake")
