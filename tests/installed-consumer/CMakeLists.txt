cmake_minimum_required(VERSION 3.25)
project(libfuturo_installed_consumer LANGUAGES C)
include(CTest)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(NOT DEFINED EXPECTED_INSTALL_PREFIX OR EXPECTED_INSTALL_PREFIX STREQUAL "")
  message(FATAL_ERROR "EXPECTED_INSTALL_PREFIX is required")
endif()
if(NOT DEFINED EXPECTED_MUHTARI_ENABLED)
  set(EXPECTED_MUHTARI_ENABLED OFF)
endif()
if(NOT DEFINED EXPECTED_MUHTARI_API_REVISION)
  if(EXPECTED_MUHTARI_ENABLED)
    set(EXPECTED_MUHTARI_API_REVISION "7")
  else()
    set(EXPECTED_MUHTARI_API_REVISION "0")
  endif()
endif()
if(NOT DEFINED EXPECTED_MUHTARI_VERSION)
  if(EXPECTED_MUHTARI_ENABLED AND
     EXPECTED_MUHTARI_API_REVISION STREQUAL "7")
    set(EXPECTED_MUHTARI_VERSION "0.10.0")
  else()
    set(EXPECTED_MUHTARI_VERSION "")
  endif()
endif()
if(NOT DEFINED EXPECTED_MUHTARI_SOURCE_REVISION)
  if(EXPECTED_MUHTARI_ENABLED AND
     EXPECTED_MUHTARI_API_REVISION STREQUAL "7")
    set(EXPECTED_MUHTARI_SOURCE_REVISION
      "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
  else()
    set(EXPECTED_MUHTARI_SOURCE_REVISION "")
  endif()
endif()
file(REAL_PATH "${EXPECTED_INSTALL_PREFIX}" _expected_prefix)

# A package config must reject a same-named imported core selected from a
# different installation before it exposes libfuturo's imported target.
if(DEFINED LIBFUTURO_PRELOADED_CORE_CONFLICT)
  set(_foreign_core_dir "${CMAKE_BINARY_DIR}/foreign-core")
  file(MAKE_DIRECTORY "${_foreign_core_dir}")
  if(LIBFUTURO_PRELOADED_CORE_CONFLICT STREQUAL "nesturbator")
    set(_foreign_core_archive "${_foreign_core_dir}/libnesturbator.a")
    file(WRITE "${_foreign_core_archive}" "foreign Nesturbator archive\n")
    add_library(nesturbator::nesturbator STATIC IMPORTED GLOBAL)
    set_target_properties(nesturbator::nesturbator PROPERTIES
      IMPORTED_CONFIGURATIONS DEBUG
      IMPORTED_LOCATION_DEBUG "${_foreign_core_archive}")
  elseif(LIBFUTURO_PRELOADED_CORE_CONFLICT STREQUAL "muhtari")
    if(NOT EXPECTED_MUHTARI_ENABLED)
      message(FATAL_ERROR
        "Muhtari target conflict requires an enabled installed package")
    endif()
    include("${_expected_prefix}/lib/cmake/nesturbator/nesturbatorConfig.cmake")
    if(NOT TARGET nesturbator::nesturbator)
      message(FATAL_ERROR
        "could not preload the colocated Nesturbator target for Muhtari conflict control")
    endif()
    set(_foreign_core_archive "${_foreign_core_dir}/libmuhtari.a")
    file(WRITE "${_foreign_core_archive}" "foreign Muhtari archive\n")
    add_library(muhtari::muhtari STATIC IMPORTED GLOBAL)
    set_target_properties(muhtari::muhtari PROPERTIES
      IMPORTED_CONFIGURATIONS DEBUG
      IMPORTED_LOCATION_DEBUG "${_foreign_core_archive}")
  else()
    message(FATAL_ERROR
      "unsupported preloaded core conflict '${LIBFUTURO_PRELOADED_CORE_CONFLICT}'")
  endif()

  find_package(libfuturo CONFIG QUIET
    PATHS "${_expected_prefix}/lib/cmake/libfuturo"
    NO_DEFAULT_PATH)
  if(libfuturo_FOUND)
    message(FATAL_ERROR
      "libfuturo accepted conflicting preloaded ${LIBFUTURO_PRELOADED_CORE_CONFLICT} target")
  endif()
  if(NOT libfuturo_NOT_FOUND_MESSAGE MATCHES
      "does not resolve to the colocated archive")
    message(FATAL_ERROR
      "the ${LIBFUTURO_PRELOADED_CORE_CONFLICT} conflict was not rejected by the identity check: '${libfuturo_NOT_FOUND_MESSAGE}'")
  endif()
  if(NOT libfuturo_NOT_FOUND_MESSAGE MATCHES
      "${LIBFUTURO_PRELOADED_CORE_CONFLICT}::${LIBFUTURO_PRELOADED_CORE_CONFLICT}")
    message(FATAL_ERROR
      "the ${LIBFUTURO_PRELOADED_CORE_CONFLICT} conflict was rejected by the wrong core identity check: '${libfuturo_NOT_FOUND_MESSAGE}'")
  endif()
  message(STATUS
    "core_identity_conflict: core=${LIBFUTURO_PRELOADED_CORE_CONFLICT} rejected=pass")
  return()
endif()

# A package redirect must not be able to replace the core selected by the
# installed libfuturo package config.
file(MAKE_DIRECTORY "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}")
file(WRITE "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/nesturbator-config.cmake"
  "message(FATAL_ERROR \"Nesturbator package redirect was incorrectly selected\")\n")
file(WRITE "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/muhtari-config.cmake"
  "message(FATAL_ERROR \"Muhtari package redirect was incorrectly selected\")\n")

find_package(libfuturo CONFIG REQUIRED
  PATHS "${_expected_prefix}/lib/cmake/libfuturo"
  NO_DEFAULT_PATH
)

if(NOT TARGET libfuturo::libfuturo OR NOT TARGET nesturbator::nesturbator)
  message(FATAL_ERROR "installed package did not provide both declared targets")
endif()
if(EXPECTED_MUHTARI_ENABLED AND NOT libfuturo_MUHTARI_ENABLED)
  message(FATAL_ERROR "installed package did not report Muhtari as enabled")
elseif(NOT EXPECTED_MUHTARI_ENABLED AND libfuturo_MUHTARI_ENABLED)
  message(FATAL_ERROR "installed package enabled Muhtari unexpectedly")
endif()
if(NOT libfuturo_MUHTARI_API_REVISION STREQUAL
   EXPECTED_MUHTARI_API_REVISION OR
   NOT libfuturo_MUHTARI_VERSION STREQUAL EXPECTED_MUHTARI_VERSION OR
   NOT libfuturo_MUHTARI_SOURCE_REVISION STREQUAL
       EXPECTED_MUHTARI_SOURCE_REVISION)
  message(FATAL_ERROR
    "installed libfuturo Muhtari identity differs from expected API=${EXPECTED_MUHTARI_API_REVISION} version=${EXPECTED_MUHTARI_VERSION} source=${EXPECTED_MUHTARI_SOURCE_REVISION}; got API=${libfuturo_MUHTARI_API_REVISION} version=${libfuturo_MUHTARI_VERSION} source=${libfuturo_MUHTARI_SOURCE_REVISION}")
endif()
if(NOT EXPECTED_MUHTARI_ENABLED AND
   (NOT libfuturo_MUHTARI_API_REVISION STREQUAL "0" OR
    NOT libfuturo_MUHTARI_VERSION STREQUAL "" OR
    NOT libfuturo_MUHTARI_SOURCE_REVISION STREQUAL ""))
  message(FATAL_ERROR
    "disabled installed package claims an acquired Muhtari core")
endif()

function(assert_under_prefix candidate description)
  if(NOT EXISTS "${candidate}")
    message(FATAL_ERROR "${description} does not exist: ${candidate}")
  endif()
  file(REAL_PATH "${candidate}" _real_candidate)
  string(FIND "${_real_candidate}" "${_expected_prefix}/" _prefix_index)
  if(NOT _prefix_index EQUAL 0)
    message(FATAL_ERROR
      "${description} escaped the moved prefix: ${_real_candidate}")
  endif()
endfunction()

function(imported_location target output_variable)
  set(_location "")
  foreach(_property IMPORTED_LOCATION IMPORTED_LOCATION_NOCONFIG
      IMPORTED_LOCATION_DEBUG IMPORTED_LOCATION_RELEASE
      IMPORTED_LOCATION_RELWITHDEBINFO IMPORTED_LOCATION_MINSIZEREL)
    get_target_property(_candidate "${target}" "${_property}")
    if(_candidate AND NOT _candidate MATCHES "-NOTFOUND$")
      set(_location "${_candidate}")
      break()
    endif()
  endforeach()
  if(_location STREQUAL "")
    message(FATAL_ERROR "${target} has no imported archive location")
  endif()
  set("${output_variable}" "${_location}" PARENT_SCOPE)
endfunction()

assert_under_prefix("${libfuturo_DIR}/libfuturoConfig.cmake"
  "libfuturo package config")
assert_under_prefix("${nesturbator_DIR}/nesturbatorConfig.cmake"
  "Nesturbator package config")
imported_location(libfuturo::libfuturo _libfuturo_archive)
imported_location(nesturbator::nesturbator _nesturbator_archive)
assert_under_prefix("${_libfuturo_archive}" "libfuturo archive")
assert_under_prefix("${_nesturbator_archive}" "Nesturbator archive")

set(_muhtari_resolution "muhtari-enabled=${libfuturo_MUHTARI_ENABLED}\n")
if(EXPECTED_MUHTARI_ENABLED)
  if(NOT TARGET muhtari::muhtari OR NOT muhtari_FOUND)
    message(FATAL_ERROR "installed package did not provide muhtari::muhtari")
  endif()
  assert_under_prefix("${muhtari_DIR}/muhtariConfig.cmake"
    "Muhtari package config")
  assert_under_prefix("${muhtari_DIR}/muhtariConfigVersion.cmake"
    "Muhtari package version config")
  file(READ "${muhtari_DIR}/muhtariConfigVersion.cmake"
    _muhtari_version_config)
  string(REPLACE "." "\\." _expected_muhtari_version_pattern
    "${EXPECTED_MUHTARI_VERSION}")
  if(NOT muhtari_API_REVISION STREQUAL EXPECTED_MUHTARI_API_REVISION OR
     NOT muhtari_VERSION STREQUAL EXPECTED_MUHTARI_VERSION OR
     NOT muhtari_SOURCE_REVISION STREQUAL
         EXPECTED_MUHTARI_SOURCE_REVISION OR
     NOT _muhtari_version_config MATCHES
       "set\\(PACKAGE_VERSION \\\"${_expected_muhtari_version_pattern}\\\"\\)")
    message(FATAL_ERROR
      "installed Muhtari package metadata differs from the selected API/version/source")
  endif()
  imported_location(muhtari::muhtari _muhtari_archive)
  assert_under_prefix("${_muhtari_archive}" "Muhtari archive")
  assert_under_prefix("${_expected_prefix}/include/muhtari.h"
    "Muhtari public header")
  assert_under_prefix("${_expected_prefix}/share/licenses/muhtari/LICENSE"
    "Muhtari license")
  assert_under_prefix("${_expected_prefix}/share/licenses/muhtari/THIRD-PARTY-NOTICES.md"
    "Muhtari third-party notices")
  file(RELATIVE_PATH _muhtari_archive_relative "${_expected_prefix}"
    "${_muhtari_archive}")
  file(RELATIVE_PATH _muhtari_config_relative "${_expected_prefix}"
    "${muhtari_DIR}/muhtariConfig.cmake")
  file(RELATIVE_PATH _muhtari_version_config_relative "${_expected_prefix}"
    "${muhtari_DIR}/muhtariConfigVersion.cmake")
  set(_muhtari_resolution
    "${_muhtari_resolution}muhtari-api=${muhtari_API_REVISION}\nmuhtari-version=${muhtari_VERSION}\nmuhtari-source=${muhtari_SOURCE_REVISION}\nmuhtari-archive=${_muhtari_archive_relative}\nmuhtari-config=${_muhtari_config_relative}\nmuhtari-version-config=${_muhtari_version_config_relative}\nmuhtari-header=include/muhtari.h\nmuhtari-license=share/licenses/muhtari/LICENSE\nmuhtari-notices=share/licenses/muhtari/THIRD-PARTY-NOTICES.md\n")
endif()

get_target_property(_public_includes libfuturo::libfuturo
  INTERFACE_INCLUDE_DIRECTORIES)
set(_public_include "")
foreach(_include IN LISTS _public_includes)
  assert_under_prefix("${_include}/libfuturo/libfuturo.h"
    "public libfuturo header")
  set(_public_include "${_include}")
endforeach()
if(_public_include STREQUAL "")
  message(FATAL_ERROR "installed target has no public include directory")
endif()

file(RELATIVE_PATH _libfuturo_archive_relative "${_expected_prefix}"
  "${_libfuturo_archive}")
file(RELATIVE_PATH _nesturbator_archive_relative "${_expected_prefix}"
  "${_nesturbator_archive}")
file(RELATIVE_PATH _libfuturo_config_relative "${_expected_prefix}"
  "${libfuturo_DIR}/libfuturoConfig.cmake")
file(RELATIVE_PATH _nesturbator_config_relative "${_expected_prefix}"
  "${nesturbator_DIR}/nesturbatorConfig.cmake")
file(RELATIVE_PATH _public_include_relative "${_expected_prefix}"
  "${_public_include}")
file(WRITE "${CMAKE_BINARY_DIR}/package-resolution.txt"
  "libfuturo-archive=${_libfuturo_archive_relative}\n"
  "nesturbator-archive=${_nesturbator_archive_relative}\n"
  "libfuturo-config=${_libfuturo_config_relative}\n"
  "nesturbator-config=${_nesturbator_config_relative}\n"
  "public-include=${_public_include_relative}\n"
  "${_muhtari_resolution}")

option(LIBFUTURO_CONSUMER_PACKAGE_ONLY
  "Build only a small public package-boundary consumer" OFF)
if(LIBFUTURO_CONSUMER_PACKAGE_ONLY)
  if(EXPECTED_MUHTARI_ENABLED OR libfuturo_MUHTARI_ENABLED)
    message(FATAL_ERROR
      "package-only control expected the default Muhtari-disabled package")
  endif()
  if(TARGET muhtari::muhtari OR muhtari_FOUND)
    message(FATAL_ERROR
      "default installed package exposed a Muhtari imported target")
  endif()
  foreach(_forbidden IN ITEMS
      "${_expected_prefix}/include/muhtari.h"
      "${_expected_prefix}/lib/libmuhtari.a"
      "${_expected_prefix}/lib/cmake/muhtari"
      "${_expected_prefix}/share/licenses/muhtari")
    if(EXISTS "${_forbidden}")
      message(FATAL_ERROR
        "default installed package contains an optional Muhtari artifact: ${_forbidden}")
    endif()
  endforeach()
  get_target_property(_base_link_requirements libfuturo::libfuturo
    INTERFACE_LINK_LIBRARIES)
  if(_base_link_requirements MATCHES "[Mm]uhtari")
    message(FATAL_ERROR
      "default installed package links an optional Muhtari dependency: ${_base_link_requirements}")
  endif()

  add_executable(muhtari_disabled_consumer muhtari_disabled.c)
  target_link_libraries(muhtari_disabled_consumer PRIVATE
    libfuturo::libfuturo)
  target_compile_options(muhtari_disabled_consumer PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG)
  add_test(NAME muhtari_disabled_consumer
    COMMAND "$<TARGET_FILE:muhtari_disabled_consumer>")
  set_tests_properties(muhtari_disabled_consumer PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_disabled: unknown-profile=explicit base-profile=usable result=pass"
    TIMEOUT 30)
  return()
endif()

add_executable(nesturbator_installed_consumer
  nesturbator_session.c
  nesturbator_save_fixture.h
  nesturbator_save_oracle.h
)
target_link_libraries(nesturbator_installed_consumer PRIVATE
  libfuturo::libfuturo
)
target_compile_definitions(nesturbator_installed_consumer PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"2338608ab184f040620a30d17756f5e06a42d4e3\"")
target_compile_options(nesturbator_installed_consumer PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  -fsanitize=address,undefined -fno-omit-frame-pointer
)
target_link_options(nesturbator_installed_consumer PRIVATE
  -fsanitize=address,undefined
)
add_test(NAME nesturbator_installed_snapshot
  COMMAND "$<TARGET_FILE:nesturbator_installed_consumer>" --snapshot-proof)
set_tests_properties(nesturbator_installed_snapshot PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_snapshot_installed_consumer: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 configuration=nesturbator-default fixture=generated-battery-free-nrom-v1 replay=frame3,ticks2144304,av-literal refusals=5,continuation-preserved result=pass"
  TIMEOUT 45)
add_test(NAME nesturbator_installed_battery_snapshot
  COMMAND "$<TARGET_FILE:nesturbator_installed_consumer>" --snapshot-battery)
set_tests_properties(nesturbator_installed_battery_snapshot PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_battery_snapshot: route=installed source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass"
  TIMEOUT 45)
add_test(NAME nesturbator_installed_battery_snapshot_oracle_control
  COMMAND "$<TARGET_FILE:nesturbator_installed_consumer>"
    --snapshot-battery-wrong-expected)
set_tests_properties(nesturbator_installed_battery_snapshot_oracle_control
  PROPERTIES
    PASS_REGULAR_EXPRESSION
      "nesturbator_battery_snapshot_oracle_control: route=installed progress,video,audio,media=rejected result=pass"
    TIMEOUT 45)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/nesturbator_fresh_process_supervisor.sh"
   AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/process-tree-cleanup.sh")
  add_test(NAME nesturbator_installed_battery_fresh_process_snapshot
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/nesturbator_fresh_process_supervisor.sh"
      "$<TARGET_FILE:nesturbator_installed_consumer>" --battery-oracle-controls)
  set_tests_properties(nesturbator_installed_battery_fresh_process_snapshot
    PROPERTIES
      PASS_REGULAR_EXPRESSION
        "event=supervisor-success"
      ENVIRONMENT
        "LF_PROCESS_TREE_HELPER=${CMAKE_CURRENT_SOURCE_DIR}/process-tree-cleanup.sh;LF_FRESH_PROCESS_TIMEOUT_SECONDS=25"
      TIMEOUT 180)
endif()

# A normal downstream link must not need sanitizer runtimes from the installed
# static archive. This target deliberately has no sanitizer compile or link flags.
add_executable(nesturbator_installed_link_check
  nesturbator_session.c
  nesturbator_save_fixture.h
  nesturbator_save_oracle.h
)
target_link_libraries(nesturbator_installed_link_check PRIVATE
  libfuturo::libfuturo
)
target_compile_definitions(nesturbator_installed_link_check PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"2338608ab184f040620a30d17756f5e06a42d4e3\""
)
target_compile_options(nesturbator_installed_link_check PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
)

if(EXPECTED_MUHTARI_ENABLED AND
   EXPECTED_MUHTARI_API_REVISION STREQUAL "7")
  set(_muhtari_source_revision "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
  add_executable(muhtari_installed_consumer
    muhtari_session.c muhtari_fixture.h muhtari_oracle.h)
  target_link_libraries(muhtari_installed_consumer PRIVATE
    libfuturo::libfuturo)
  target_compile_definitions(muhtari_installed_consumer PRIVATE
    "LIBFUTURO_MUHTARI_SOURCE_REVISION=\"${_muhtari_source_revision}\"")
  target_compile_options(muhtari_installed_consumer PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(muhtari_installed_consumer PRIVATE
    -fsanitize=address,undefined)
  add_test(NAME muhtari_installed_consumer
    COMMAND "$<TARGET_FILE:muhtari_installed_consumer>")
  set_tests_properties(muhtari_installed_consumer PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_session: source=${_muhtari_source_revision} profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass"
    TIMEOUT 30)
  add_test(NAME muhtari_installed_load_refusals
    COMMAND "$<TARGET_FILE:muhtari_installed_consumer>" --load-refusals)
  set_tests_properties(muhtari_installed_load_refusals PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_load_refusals: cases=8 histories=loaded,unloaded continuation=3 allocation-ordinals=measured default-reset=pass result=pass"
    TIMEOUT 30)
  add_test(NAME muhtari_installed_frame_boundaries
    COMMAND "$<TARGET_FILE:muhtari_installed_consumer>" --frame-boundaries)
  set_tests_properties(muhtari_installed_frame_boundaries PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass"
    TIMEOUT 90)
  add_test(NAME muhtari_installed_oracle_negative_control
    COMMAND "${CMAKE_COMMAND}"
      "-DMUHTARI_SESSION_EXE=$<TARGET_FILE:muhtari_installed_consumer>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/ExpectMuhtariOracleFailure.cmake")
  set_tests_properties(muhtari_installed_oracle_negative_control PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1"
    TIMEOUT 50)

  # This downstream link intentionally has no sanitizer runtime flags.
  add_executable(muhtari_installed_link_check
    muhtari_session.c muhtari_fixture.h muhtari_oracle.h)
  target_link_libraries(muhtari_installed_link_check PRIVATE
    libfuturo::libfuturo)
  target_compile_definitions(muhtari_installed_link_check PRIVATE
    "LIBFUTURO_MUHTARI_SOURCE_REVISION=\"${_muhtari_source_revision}\"")
  target_compile_options(muhtari_installed_link_check PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG)

  add_executable(muhtari_save_installed_consumer
    muhtari_save.c muhtari_save_oracle.h muhtari_oracle.h)
  target_link_libraries(muhtari_save_installed_consumer PRIVATE
    libfuturo::libfuturo)
  target_compile_definitions(muhtari_save_installed_consumer PRIVATE
    "LIBFUTURO_MUHTARI_SOURCE_REVISION=\"${_muhtari_source_revision}\"")
  target_compile_options(muhtari_save_installed_consumer PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(muhtari_save_installed_consumer PRIVATE
    -fsanitize=address,undefined)
elseif(EXPECTED_MUHTARI_ENABLED AND
       EXPECTED_MUHTARI_API_REVISION STREQUAL "8")
  add_executable(muhtari_api8_consumer
    muhtari_snapshot.c
    muhtari_fixture.h
    muhtari_snapshot_fixture.h
    muhtari_snapshot_oracle.h
    muhtari_snapshot_host.h
    muhtari_snapshot_faults.h)
  target_link_libraries(muhtari_api8_consumer PRIVATE
    libfuturo::libfuturo)
  target_compile_options(muhtari_api8_consumer PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG)
  add_test(NAME muhtari_api8_profile
    COMMAND "$<TARGET_FILE:muhtari_api8_consumer>")
  set_tests_properties(muhtari_api8_profile PROPERTIES
    LABELS "muhtari-api8-profile"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_profile: source=d58f125297c4d63a7a8108112a5eafff6f53a76a version=0.11.1 api=8 abi=1 behavior=6 state-format=1 profile=muhtari-ntsc-v2 fixture=owned-a78-linear-16k input=1 frame=1 video=INDEX8 audio=S16_NATIVE result=pass"
    TIMEOUT 30)
  add_test(NAME muhtari_api8_fixture_boundary
    COMMAND "$<TARGET_FILE:muhtari_api8_consumer>" --fixture-boundary)
  set_tests_properties(muhtari_api8_fixture_boundary PROPERTIES
    LABELS "muhtari-api8-installed;muhtari-api8-fixture"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_fixture_boundary: R2 frame 2 pending page and R3 frame 3 published; full-span literals verified"
    TIMEOUT 30)
  add_test(NAME muhtari_api8_fixture_oracle_controls
    COMMAND "$<TARGET_FILE:muhtari_api8_consumer>" --fixture-oracle-controls)
  set_tests_properties(muhtari_api8_fixture_oracle_controls PROPERTIES
    LABELS "muhtari-api8-installed;muhtari-api8-fixture"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_fixture_oracle_controls: frame,video,audio,battery literals rejected"
    TIMEOUT 30)
  add_test(NAME muhtari_api8_snapshot_contract
    COMMAND "$<TARGET_FILE:muhtari_api8_consumer>" --snapshot-contract)
  set_tests_properties(muhtari_api8_snapshot_contract PROPERTIES
    LABELS "muhtari-api8-installed;muhtari-api8-snapshot"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_snapshot_contract: capability, bounded capture, identity preflight, cross-instance replay, stale-load rejection, and receiver-local battery generation verified"
    TIMEOUT 30)
  add_test(NAME muhtari_api8_installed_fresh_process
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/muhtari_fresh_process_supervisor.sh"
      "$<TARGET_FILE:muhtari_api8_consumer>")
  set_tests_properties(muhtari_api8_installed_fresh_process PROPERTIES
    LABELS "muhtari-api8-installed;muhtari-api8-fresh-process"
    PASS_REGULAR_EXPRESSION
      "event=supervisor-success route=installed result=pass"
    ENVIRONMENT
      "LF_PROCESS_TREE_HELPER=${CMAKE_CURRENT_SOURCE_DIR}/process-tree-cleanup.sh;LF_FRESH_PROCESS_ROUTE=installed;LF_FRESH_PROCESS_TIMEOUT_SECONDS=30"
    TIMEOUT 90)
  add_test(NAME muhtari_api8_installed_oracle_controls
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/muhtari_fresh_process_oracle_controls.sh"
      "$<TARGET_FILE:muhtari_api8_consumer>"
      "${CMAKE_CURRENT_SOURCE_DIR}/muhtari_fresh_process_supervisor.sh")
  set_tests_properties(muhtari_api8_installed_oracle_controls PROPERTIES
    LABELS "muhtari-api8-installed;muhtari-api8-fresh-process"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_installed_oracle_controls: frame,video,audio,media,capability denied result=pass"
    ENVIRONMENT
      "LF_PROCESS_TREE_HELPER=${CMAKE_CURRENT_SOURCE_DIR}/process-tree-cleanup.sh;LF_FRESH_PROCESS_ROUTE=installed;LF_FRESH_PROCESS_TIMEOUT_SECONDS=30"
    TIMEOUT 90)
elseif(EXPECTED_MUHTARI_ENABLED)
  message(FATAL_ERROR
    "unsupported EXPECTED_MUHTARI_API_REVISION '${EXPECTED_MUHTARI_API_REVISION}'")
endif()

add_executable(nesturbator_installed_load
  nesturbator_load.c
  nesturbator_save_fixture.h
  nesturbator_save_oracle.h
)
target_link_libraries(nesturbator_installed_load PRIVATE
  libfuturo::libfuturo
)
target_compile_definitions(nesturbator_installed_load PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"2338608ab184f040620a30d17756f5e06a42d4e3\"")
target_compile_options(nesturbator_installed_load PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
)
add_test(NAME nesturbator_installed_load
  COMMAND "$<TARGET_FILE:nesturbator_installed_load>")
set_tests_properties(nesturbator_installed_load PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_installed_load: refusals=7 replacement=reset continuation-frames=3 result=pass"
  TIMEOUT 60
)

get_target_property(_consumer_c_standard nesturbator_installed_consumer C_STANDARD)
get_target_property(_consumer_c_standard_required
  nesturbator_installed_consumer C_STANDARD_REQUIRED)
get_target_property(_consumer_c_extensions
  nesturbator_installed_consumer C_EXTENSIONS)
if(NOT _consumer_c_standard STREQUAL "17" OR
   NOT _consumer_c_standard_required OR _consumer_c_extensions)
  message(FATAL_ERROR
    "installed consumer must use required C17 with C extensions disabled")
endif()
file(APPEND "${CMAKE_BINARY_DIR}/package-resolution.txt"
  "c_standard=C${_consumer_c_standard}\n"
  "c_standard_required=${_consumer_c_standard_required}\n"
  "c_extensions=${_consumer_c_extensions}\n")
