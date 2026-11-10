cmake_minimum_required(VERSION 3.25)

foreach(_required_var IN ITEMS PROJECT_ROOT PACKAGE_TEST_ROOT PACKAGE_C_COMPILER
    PACKAGE_OSX_ARCHITECTURES PACKAGE_OSX_SYSROOT PACKAGE_SOURCE_BUILD)
  if(NOT DEFINED ${_required_var} OR "${${_required_var}}" STREQUAL "")
    message(FATAL_ERROR
      "muhtari_package_modes: required variable ${_required_var} is missing")
  endif()
endforeach()

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _scratch_suffix)
set(_scratch_root
  "${PACKAGE_TEST_ROOT}/muhtari-package-modes-${_scratch_suffix}")
if(EXISTS "${_scratch_root}")
  message(FATAL_ERROR
    "muhtari_package_modes: unique scratch directory already exists")
endif()
set(_base_build "${_scratch_root}/default-build")
set(_install_prefix "${_scratch_root}/default-prefix")
set(_consumer_source "${_scratch_root}/consumer-source")
set(_consumer_build "${_scratch_root}/consumer-build")
set(_override_build "${_scratch_root}/override-build")
set(_override_source "${_scratch_root}/muhtari-source-override")
file(MAKE_DIRECTORY "${_scratch_root}" "${_consumer_source}" "${_override_source}")

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
      "muhtari_package_modes: ${label} failed (${_result})\n${_stdout}\n${_stderr}")
  endif()
  set(_stdout "${_stdout}" PARENT_SCOPE)
  set(_stderr "${_stderr}" PARENT_SCOPE)
endfunction()

function(run_core_identity_conflict core_name install_prefix expected_muhtari)
  set(_conflict_build "${_scratch_root}/${core_name}-conflict-build")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${_consumer_source}" -B "${_conflict_build}"
      "-DEXPECTED_INSTALL_PREFIX=${install_prefix}"
      "-DEXPECTED_MUHTARI_ENABLED=${expected_muhtari}"
      "-DLIBFUTURO_PRELOADED_CORE_CONFLICT=${core_name}"
      "-DCMAKE_BUILD_TYPE=Debug"
      "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
      "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
      "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
    RESULT_VARIABLE _result
    OUTPUT_VARIABLE _stdout
    ERROR_VARIABLE _stderr
    TIMEOUT 60
  )
  if(NOT "${_result}" STREQUAL "0")
    message(FATAL_ERROR
      "muhtari_package_modes: ${core_name} target conflict configure failed (${_result})\n${_stdout}\n${_stderr}")
  endif()
  set(_marker
    "core_identity_conflict: core=${core_name} rejected=pass")
  string(FIND "${_stdout}\n${_stderr}" "${_marker}" _marker_index)
  if(_marker_index EQUAL -1)
    message(FATAL_ERROR
      "muhtari_package_modes: ${core_name} target conflict control lacked its marker\n${_stdout}\n${_stderr}")
  endif()
endfunction()

execute_process(COMMAND date +%s OUTPUT_VARIABLE _default_start
  OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _date_result)
if(NOT "${_date_result}" STREQUAL "0" OR NOT _default_start MATCHES "^[0-9]+$")
  message(FATAL_ERROR "muhtari_package_modes: could not measure default-off route")
endif()

run_checked("fresh default-off configure" 300
  "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}" -B "${_base_build}"
  -DCMAKE_BUILD_TYPE=Debug
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
  -DFETCHCONTENT_QUIET=OFF)

set(_cache "${_base_build}/CMakeCache.txt")
if(NOT EXISTS "${_cache}")
  message(FATAL_ERROR "muhtari_package_modes: fresh default-off cache is missing")
endif()
file(STRINGS "${_cache}" _muhtari_option
  REGEX "^LIBFUTURO_ENABLE_MUHTARI:BOOL=")
if(NOT _muhtari_option STREQUAL "LIBFUTURO_ENABLE_MUHTARI:BOOL=OFF")
  message(FATAL_ERROR
    "muhtari_package_modes: omitted Muhtari option did not cache OFF: '${_muhtari_option}'")
endif()

run_checked("default-off library build" 180
  "${CMAKE_COMMAND}" --build "${_base_build}" --target libfuturo --parallel 2)
run_checked("default-off install" 60
  "${CMAKE_COMMAND}" --install "${_base_build}" --prefix "${_install_prefix}")

foreach(_required_artifact IN ITEMS
    "${_install_prefix}/include/libfuturo/libfuturo.h"
    "${_install_prefix}/lib/liblibfuturo.a"
    "${_install_prefix}/lib/cmake/libfuturo/libfuturoConfig.cmake"
    "${_install_prefix}/lib/cmake/nesturbator/nesturbatorConfig.cmake")
  if(NOT EXISTS "${_required_artifact}")
    message(FATAL_ERROR
      "muhtari_package_modes: default-off SDK artifact is missing: ${_required_artifact}")
  endif()
endforeach()

foreach(_forbidden_artifact IN ITEMS
    "${_install_prefix}/include/muhtari.h"
    "${_install_prefix}/lib/libmuhtari.a"
    "${_install_prefix}/lib/cmake/muhtari"
    "${_install_prefix}/share/licenses/muhtari")
  if(EXISTS "${_forbidden_artifact}")
    message(FATAL_ERROR
      "muhtari_package_modes: default-off SDK installed optional artifact ${_forbidden_artifact}")
  endif()
endforeach()

file(COPY_FILE "${PROJECT_ROOT}/tests/installed-consumer/CMakeLists.txt"
  "${_consumer_source}/CMakeLists.txt")
file(COPY_FILE "${PROJECT_ROOT}/tests/installed-consumer/muhtari_disabled.c"
  "${_consumer_source}/muhtari_disabled.c")
foreach(_consumer_source_file IN ITEMS
    nesturbator_session.c nesturbator_load.c nesturbator_save_fixture.h
    nesturbator_save_oracle.h muhtari_session.c muhtari_fixture.h
    muhtari_oracle.h muhtari_save.c muhtari_save_oracle.h)
  file(COPY_FILE
    "${PROJECT_ROOT}/tests/installed-consumer/${_consumer_source_file}"
    "${_consumer_source}/${_consumer_source_file}")
endforeach()
run_checked("default-off downstream configure" 60
  "${CMAKE_COMMAND}" -S "${_consumer_source}" -B "${_consumer_build}"
  "-DEXPECTED_INSTALL_PREFIX=${_install_prefix}"
  -DEXPECTED_MUHTARI_ENABLED=OFF
  -DLIBFUTURO_CONSUMER_PACKAGE_ONLY=ON)
run_checked("default-off downstream build" 60
  "${CMAKE_COMMAND}" --build "${_consumer_build}"
  --target muhtari_disabled_consumer --parallel 2)
run_checked("default-off downstream consumer" 45
  "${CMAKE_CTEST_COMMAND}" --test-dir "${_consumer_build}"
  -R "^muhtari_disabled_consumer$" --output-on-failure --verbose
  --no-tests=error)
set(_consumer_output "${_stdout}\n${_stderr}")
string(FIND "${_consumer_output}"
  "muhtari_disabled: unknown-profile=explicit base-profile=usable result=pass"
  _consumer_marker)
if(_consumer_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_package_modes: downstream default-off consumer marker is missing\n${_consumer_output}")
endif()

run_core_identity_conflict(nesturbator "${_install_prefix}" OFF)

# Reuse the current enabled build's selected artifacts to verify that a
# preloaded Muhtari target cannot substitute another archive either.
set(_enabled_prefix "${_scratch_root}/enabled|prefix")
run_checked("enabled package install for identity controls" 90
  "${CMAKE_COMMAND}" --install "${PACKAGE_SOURCE_BUILD}"
  --prefix "${_enabled_prefix}")
foreach(_required_artifact IN ITEMS
    "${_enabled_prefix}/lib/cmake/libfuturo/libfuturoConfig.cmake"
    "${_enabled_prefix}/lib/cmake/nesturbator/nesturbatorConfig.cmake"
    "${_enabled_prefix}/lib/cmake/muhtari/muhtariConfig.cmake"
    "${_enabled_prefix}/lib/libnesturbator.a"
    "${_enabled_prefix}/lib/libmuhtari.a")
  if(NOT EXISTS "${_required_artifact}")
    message(FATAL_ERROR
      "muhtari_package_modes: enabled identity-control artifact is missing: ${_required_artifact}")
  endif()
endforeach()
run_checked("enabled package configure from a pipe-containing prefix" 60
  "${CMAKE_COMMAND}" -S "${_consumer_source}"
  -B "${_scratch_root}/pipe-prefix-consumer-build"
  "-DEXPECTED_INSTALL_PREFIX=${_enabled_prefix}"
  -DEXPECTED_MUHTARI_ENABLED=ON
  "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
  "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
  "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}")
run_core_identity_conflict(muhtari "${_enabled_prefix}" ON)

execute_process(COMMAND date +%s OUTPUT_VARIABLE _override_start
  OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _date_result)
if(NOT "${_date_result}" STREQUAL "0" OR NOT _override_start MATCHES "^[0-9]+$")
  message(FATAL_ERROR "muhtari_package_modes: could not measure override control")
endif()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -S "${PROJECT_ROOT}" -B "${_override_build}"
    -DCMAKE_BUILD_TYPE=Debug
    "-DCMAKE_C_COMPILER=${PACKAGE_C_COMPILER}"
    "-DCMAKE_OSX_ARCHITECTURES=${PACKAGE_OSX_ARCHITECTURES}"
    "-DCMAKE_OSX_SYSROOT=${PACKAGE_OSX_SYSROOT}"
    -DFETCHCONTENT_QUIET=OFF
    -DLIBFUTURO_ENABLE_MUHTARI=ON
    "-DFETCHCONTENT_SOURCE_DIR_MUHTARI=${_override_source}"
  RESULT_VARIABLE _override_result
  OUTPUT_VARIABLE _override_stdout
  ERROR_VARIABLE _override_stderr
  TIMEOUT 300
)
if("${_override_result}" STREQUAL "0")
  message(FATAL_ERROR
    "muhtari_package_modes: enabled source override unexpectedly configured successfully")
endif()
set(_override_output "${_override_stdout}\n${_override_stderr}")
string(FIND "${_override_output}"
  "FETCHCONTENT_SOURCE_DIR_MUHTARI is not allowed" _override_marker)
if(_override_marker EQUAL -1)
  message(FATAL_ERROR
    "muhtari_package_modes: override configure failed before the intended acquisition gate (${_override_result})\n${_override_output}")
endif()

execute_process(COMMAND date +%s OUTPUT_VARIABLE _end
  OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _date_result)
if(NOT "${_date_result}" STREQUAL "0" OR NOT _end MATCHES "^[0-9]+$")
  message(FATAL_ERROR "muhtari_package_modes: could not finish route timing")
endif()
math(EXPR _default_seconds "${_override_start} - ${_default_start}")
math(EXPR _override_seconds "${_end} - ${_override_start}")
file(REMOVE_RECURSE "${_scratch_root}")
message(STATUS
  "muhtari_package_modes: default-off=consumer,artifacts,profile-unavailable core-target-conflicts=nesturbator,muhtari pipe-prefix=accepted override=exact-source-gate result=pass default-off-seconds=${_default_seconds} override-seconds=${_override_seconds}")
