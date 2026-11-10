cmake_minimum_required(VERSION 3.25)

foreach(_required_var IN ITEMS PROJECT_ROOT PACKAGE_TEST_ROOT
    PACKAGE_C_COMPILER PACKAGE_OSX_ARCHITECTURES PACKAGE_OSX_SYSROOT
    PACKAGE_API8_BUILD PACKAGE_API8_PREFIX)
  if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
    message(FATAL_ERROR
      "muhtari_api8_package_modes: required variable ${_required_var} is missing")
  endif()
endforeach()

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _scratch_suffix)
set(_scratch_root
  "${PACKAGE_TEST_ROOT}/muhtari-api8-package-modes-${_scratch_suffix}")
file(MAKE_DIRECTORY "${_scratch_root}")

function(run_checked label timeout_seconds)
  execute_process(
    COMMAND ${ARGN}
    RESULT_VARIABLE _result
    OUTPUT_VARIABLE _stdout
    ERROR_VARIABLE _stderr
    TIMEOUT "${timeout_seconds}"
  )
  if(NOT "${_result}" STREQUAL "0")
    message(FATAL_ERROR
      "muhtari_api8_package_modes: ${label} failed (${_result})\n${_stdout}\n${_stderr}")
  endif()
  set(_stdout "${_stdout}" PARENT_SCOPE)
  set(_stderr "${_stderr}" PARENT_SCOPE)
endfunction()

function(configure_package_consumer label install_prefix expected_api
    expected_version expected_source consumer_build)
  run_checked("${label} package consumer configure" 90
    "${CMAKE_COMMAND}"
    -S "${PROJECT_ROOT}/tests/installed-consumer"
    -B "${consumer_build}"
    "-DEXPECTED_INSTALL_PREFIX=${install_prefix}"
    -DEXPECTED_MUHTARI_ENABLED=ON
    "-DEXPECTED_MUHTARI_API_REVISION=${expected_api}"
    "-DEXPECTED_MUHTARI_VERSION=${expected_version}"
    "-DEXPECTED_MUHTARI_SOURCE_REVISION=${expected_source}"
    "-DCMAKE_BUILD_TYPE=Debug"
    "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
    "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
    "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
  )
  file(READ "${consumer_build}/package-resolution.txt" _resolution)
  foreach(_expected_line IN ITEMS
      "muhtari-api=${expected_api}"
      "muhtari-version=${expected_version}"
      "muhtari-source=${expected_source}")
    string(FIND "${_resolution}" "${_expected_line}" _line_index)
    if(_line_index EQUAL -1)
      message(FATAL_ERROR
        "muhtari_api8_package_modes: ${label} package-resolution.txt lacks ${_expected_line}")
    endif()
  endforeach()
endfunction()

set(_disabled_build "${_scratch_root}/disabled-build")
set(_disabled_prefix "${_scratch_root}/disabled-prefix")
set(_disabled_consumer "${_scratch_root}/disabled-consumer")
run_checked("default-off API 8-selector configure" 300
  "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}" -B "${_disabled_build}"
  -DCMAKE_BUILD_TYPE=Debug
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
  -DLIBFUTURO_ENABLE_MUHTARI=OFF
  -DLIBFUTURO_MUHTARI_API_REVISION=8
)
file(STRINGS "${_disabled_build}/CMakeCache.txt" _disabled_selector
  REGEX "^LIBFUTURO_MUHTARI_API_REVISION:STRING=")
file(STRINGS "${_disabled_build}/CMakeCache.txt" _disabled_muhtari_source
  REGEX "^muhtari_SOURCE_DIR:")
if(NOT _disabled_selector STREQUAL
   "LIBFUTURO_MUHTARI_API_REVISION:STRING=8" OR
   _disabled_muhtari_source)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: API 8 selector did not remain dependency-free while disabled")
endif()
run_checked("default-off API 8-selector library build" 180
  "${CMAKE_COMMAND}" --build "${_disabled_build}" --target libfuturo
  --parallel 2)
run_checked("default-off API 8-selector install" 60
  "${CMAKE_COMMAND}" --install "${_disabled_build}"
  --prefix "${_disabled_prefix}")
run_checked("default-off API 8-selector consumer configure" 60
  "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}/tests/installed-consumer"
  -B "${_disabled_consumer}"
  "-DEXPECTED_INSTALL_PREFIX=${_disabled_prefix}"
  -DEXPECTED_MUHTARI_ENABLED=OFF
  -DEXPECTED_MUHTARI_API_REVISION=0
  -DEXPECTED_MUHTARI_VERSION=
  -DEXPECTED_MUHTARI_SOURCE_REVISION=
  -DLIBFUTURO_CONSUMER_PACKAGE_ONLY=ON
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}")
run_checked("default-off API 8-selector consumer build" 60
  "${CMAKE_COMMAND}" --build "${_disabled_consumer}"
  --target muhtari_disabled_consumer --parallel 2)
run_checked("default-off API 8-selector consumer test" 45
  "${CMAKE_CTEST_COMMAND}" --test-dir "${_disabled_consumer}"
  -R "^muhtari_disabled_consumer$" --output-on-failure --verbose
  --no-tests=error)
set(_disabled_output "${_stdout}\n${_stderr}")
string(FIND "${_disabled_output}"
  "muhtari_disabled: unknown-profile=explicit base-profile=usable result=pass"
  _disabled_marker)
if(_disabled_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: default-off consumer marker is missing\n${_disabled_output}")
endif()

set(_invalid_build "${_scratch_root}/invalid-build")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}" -B "${_invalid_build}"
    -DCMAKE_BUILD_TYPE=Debug
    "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
    "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
    "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
    -DLIBFUTURO_ENABLE_MUHTARI=OFF
    -DLIBFUTURO_MUHTARI_API_REVISION=9
  RESULT_VARIABLE _invalid_result
  OUTPUT_VARIABLE _invalid_stdout
  ERROR_VARIABLE _invalid_stderr
  TIMEOUT 90)
if("${_invalid_result}" STREQUAL "0")
  message(FATAL_ERROR
    "muhtari_api8_package_modes: unsupported selector 9 configured successfully")
endif()
set(_invalid_output "${_invalid_stdout}\n${_invalid_stderr}")
string(FIND "${_invalid_output}"
  "LIBFUTURO_MUHTARI_API_REVISION must be exactly 7 or 8"
  _invalid_marker)
if(_invalid_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: selector 9 failed before the intended validation\n${_invalid_output}")
endif()

set(_api7_build "${_scratch_root}/api7-build")
set(_api7_prefix "${_scratch_root}/api7-prefix")
set(_api7_consumer "${_scratch_root}/api7-consumer")
run_checked("API 7 configure" 300
  "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}" -B "${_api7_build}"
  -DCMAKE_BUILD_TYPE=Debug
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
  -DLIBFUTURO_ENABLE_MUHTARI=ON
  -DLIBFUTURO_MUHTARI_API_REVISION=7)
run_checked("API 7 library build" 180
  "${CMAKE_COMMAND}" --build "${_api7_build}" --target libfuturo
  --parallel 2)
run_checked("API 7 install" 60
  "${CMAKE_COMMAND}" --install "${_api7_build}" --prefix "${_api7_prefix}")
configure_package_consumer(API7 "${_api7_prefix}" 7 0.10.0
  d5fd241e3f4d701d73867cc2e465c56a6fe6793d "${_api7_consumer}")

set(_api8_consumer "${_scratch_root}/api8-consumer")
configure_package_consumer(API8 "${PACKAGE_API8_PREFIX}" 8 0.11.1
  d58f125297c4d63a7a8108112a5eafff6f53a76a "${_api8_consumer}")
run_checked("API 8 downstream consumer build" 90
  "${CMAKE_COMMAND}" --build "${_api8_consumer}"
  --target muhtari_api8_consumer --parallel 2)
run_checked("API 8 downstream consumer profile" 45
  "${CMAKE_CTEST_COMMAND}" --test-dir "${_api8_consumer}"
  -R "^muhtari_api8_profile$" --output-on-failure --verbose --no-tests=error)
set(_api8_output "${_stdout}\n${_stderr}")
string(FIND "${_api8_output}"
  "muhtari_api8_profile: source=d58f125297c4d63a7a8108112a5eafff6f53a76a version=0.11.1 api=8 abi=1 behavior=6 state-format=1 profile=muhtari-ntsc-v2 fixture=owned-a78-linear-16k input=1 frame=1 video=INDEX8 audio=S16_NATIVE result=pass"
  _api8_marker)
if(_api8_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: downstream profile marker is missing\n${_api8_output}")
endif()

set(_foreign_config "${_scratch_root}/foreign-muhtari-config")
file(MAKE_DIRECTORY "${_foreign_config}")
file(WRITE "${_foreign_config}/muhtariConfig.cmake"
  "message(FATAL_ERROR \"foreign Muhtari config was selected\")\n")
set(_foreign_config_consumer "${_scratch_root}/foreign-config-consumer")
run_checked("foreign Muhtari config rejection" 90
  "${CMAKE_COMMAND}"
  -S "${PROJECT_ROOT}/tests/installed-consumer"
  -B "${_foreign_config_consumer}"
  "-DEXPECTED_INSTALL_PREFIX=${PACKAGE_API8_PREFIX}"
  -DEXPECTED_MUHTARI_ENABLED=ON
  -DEXPECTED_MUHTARI_API_REVISION=8
  -DEXPECTED_MUHTARI_VERSION=0.11.1
  -DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a
  "-Dmuhtari_DIR=${_foreign_config}"
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}")
file(READ "${_foreign_config_consumer}/package-resolution.txt"
  _foreign_config_resolution)
string(FIND "${_foreign_config_resolution}"
  "muhtari-api=8" _foreign_api_marker)
if(_foreign_api_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: package config resolution did not retain API 8")
endif()

set(_foreign_archive_consumer "${_scratch_root}/foreign-archive-consumer")
run_checked("foreign Muhtari archive rejection" 90
  "${CMAKE_COMMAND}"
  -S "${PROJECT_ROOT}/tests/installed-consumer"
  -B "${_foreign_archive_consumer}"
  "-DEXPECTED_INSTALL_PREFIX=${PACKAGE_API8_PREFIX}"
  -DEXPECTED_MUHTARI_ENABLED=ON
  -DEXPECTED_MUHTARI_API_REVISION=8
  -DEXPECTED_MUHTARI_VERSION=0.11.1
  -DEXPECTED_MUHTARI_SOURCE_REVISION=d58f125297c4d63a7a8108112a5eafff6f53a76a
  -DLIBFUTURO_PRELOADED_CORE_CONFLICT=muhtari
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}")
set(_foreign_archive_output "${_stdout}\n${_stderr}")
string(FIND "${_foreign_archive_output}"
  "core_identity_conflict: core=muhtari rejected=pass"
  _foreign_archive_marker)
if(_foreign_archive_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_api8_package_modes: foreign archive was not rejected by the identity check")
endif()

file(REMOVE_RECURSE "${_scratch_root}")
message(STATUS
  "muhtari_api8_package_modes: default-off=api8-selector,invalid=reject api7=exact-metadata api8=exact-metadata foreign-archive=config-rejected foreign-config=redirect-rejected result=pass")
