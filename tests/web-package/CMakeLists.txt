cmake_minimum_required(VERSION 3.25)

if(LIBFUTURO_WEB_GRAPH_ONLY)
  project(libfuturo_web_package_graph_check NONE)

  if(NOT DEFINED LIBFUTURO_WEB_BUILD_DIR OR
     NOT DEFINED LIBFUTURO_WEB_SOURCE_DIR)
    message(FATAL_ERROR
      "The web graph check requires the configured build and source directories")
  endif()

  foreach(_required_graph_file IN ITEMS
      "${LIBFUTURO_WEB_BUILD_DIR}/CMakeCache.txt"
      "${LIBFUTURO_WEB_BUILD_DIR}/CMakeFiles/TargetDirectories.txt"
      "${LIBFUTURO_WEB_BUILD_DIR}/compile_commands.json"
      "${LIBFUTURO_WEB_ARCHIVE}")
    if(NOT EXISTS "${_required_graph_file}")
      message(FATAL_ERROR
        "The web graph check is missing generated evidence: ${_required_graph_file}")
    endif()
  endforeach()

  file(READ "${LIBFUTURO_WEB_BUILD_DIR}/CMakeCache.txt" _web_cache)
  file(READ "${LIBFUTURO_WEB_BUILD_DIR}/CMakeFiles/TargetDirectories.txt"
    _web_target_directories)
  file(READ "${LIBFUTURO_WEB_BUILD_DIR}/compile_commands.json"
    _web_compile_commands)

  foreach(_web_graph_text IN ITEMS
      _web_cache _web_target_directories _web_compile_commands)
    if("${${_web_graph_text}}" MATCHES "[Nn]esturbator")
      message(FATAL_ERROR
        "The browser configure/build graph exposes Nesturbator in ${_web_graph_text}")
    endif()
  endforeach()

  foreach(_forbidden_fetch_path IN ITEMS
      "${LIBFUTURO_WEB_BUILD_DIR}/_deps/nesturbator-src"
      "${LIBFUTURO_WEB_BUILD_DIR}/_deps/nesturbator-build")
    if(EXISTS "${_forbidden_fetch_path}")
      message(FATAL_ERROR
        "The browser build fetched a forbidden Nesturbator directory: ${_forbidden_fetch_path}")
    endif()
  endforeach()

  foreach(_required_source IN ITEMS
      "${LIBFUTURO_WEB_SOURCE_DIR}/src/synthetic.c"
      "${LIBFUTURO_WEB_SOURCE_DIR}/src/muhtari_adapter.c")
    string(FIND "${_web_compile_commands}" "${_required_source}" _source_index)
    if(_source_index EQUAL -1)
      message(FATAL_ERROR
        "The browser target did not configure required LibFuturo source ${_required_source}")
    endif()
  endforeach()

  file(GLOB _web_target_metadata
    "${LIBFUTURO_WEB_BUILD_DIR}/CMakeFiles/libfuturo_web.dir/*")
  foreach(_metadata_file IN LISTS _web_target_metadata)
    if(NOT IS_DIRECTORY "${_metadata_file}")
      file(READ "${_metadata_file}" _metadata_contents)
      if(_metadata_contents MATCHES "[Nn]esturbator")
        message(FATAL_ERROR
          "The browser target metadata contains a Nesturbator reference: ${_metadata_file}")
      endif()
    endif()
  endforeach()

  if(NOT LIBFUTURO_WEB_NM OR NOT EXISTS "${LIBFUTURO_WEB_NM}")
    message(FATAL_ERROR "The web graph check needs the configured nm tool")
  endif()
  execute_process(
    COMMAND "${LIBFUTURO_WEB_NM}" -g "${LIBFUTURO_WEB_ARCHIVE}"
    RESULT_VARIABLE _web_nm_result
    OUTPUT_VARIABLE _web_archive_symbols
    ERROR_VARIABLE _web_nm_error)
  if(NOT _web_nm_result EQUAL 0)
    message(FATAL_ERROR
      "Could not inspect the browser archive symbols: ${_web_nm_error}")
  endif()
  if(_web_archive_symbols MATCHES "[Nn]esturbator")
    message(FATAL_ERROR
      "The browser archive exposes a Nesturbator dispatcher reference")
  endif()

  message(STATUS
    "web_package_graph: Muhtari-only target and compile graph; Nesturbator absent; result=pass")
  return()
endif()

project(libfuturo_web_package_export_check NONE)

if(NOT DEFINED EXPECTED_WEB_PREFIX OR EXPECTED_WEB_PREFIX STREQUAL "")
  message(FATAL_ERROR "EXPECTED_WEB_PREFIX is required")
endif()
if(NOT DEFINED EXPECTED_WEB_BUILD_ID OR EXPECTED_WEB_BUILD_ID STREQUAL "")
  message(FATAL_ERROR "EXPECTED_WEB_BUILD_ID is required")
endif()
if(NOT DEFINED EXPECTED_WEB_SOURCE_REVISION OR
   EXPECTED_WEB_SOURCE_REVISION STREQUAL "")
  message(FATAL_ERROR "EXPECTED_WEB_SOURCE_REVISION is required")
endif()
file(REAL_PATH "${EXPECTED_WEB_PREFIX}" _expected_web_prefix)

find_package(libfuturo_web 0.1.0 EXACT CONFIG REQUIRED
  PATHS "${_expected_web_prefix}/lib/cmake/libfuturo-web"
  NO_DEFAULT_PATH)

if(NOT TARGET libfuturo::web)
  message(FATAL_ERROR "The installed package did not export libfuturo::web")
endif()
if(TARGET libfuturo::libfuturo OR TARGET nesturbator::nesturbator)
  message(FATAL_ERROR
    "The browser package exposed a native LibFuturo or Nesturbator target")
endif()
if(NOT libfuturo_web_TARGET STREQUAL "libfuturo::web" OR
   NOT libfuturo_web_CORE STREQUAL "muhtari" OR
   NOT libfuturo_web_CORE_VERSION STREQUAL "0.11.1" OR
   NOT libfuturo_web_CORE_API_REVISION STREQUAL "8" OR
   NOT libfuturo_web_CORE_ABI_REVISION STREQUAL "1" OR
   NOT libfuturo_web_CORE_BEHAVIOR_REVISION STREQUAL "6" OR
   NOT libfuturo_web_CORE_SOURCE_REVISION STREQUAL
       "d58f125297c4d63a7a8108112a5eafff6f53a76a" OR
   NOT libfuturo_web_PROFILE_ID STREQUAL "muhtari-ntsc-v2" OR
   NOT libfuturo_web_CONFIGURATION_ID STREQUAL
       "muhtari-ntsc-battery-diagnostic" OR
   NOT libfuturo_web_BUILD_ID STREQUAL EXPECTED_WEB_BUILD_ID OR
   NOT libfuturo_web_SOURCE_REVISION STREQUAL EXPECTED_WEB_SOURCE_REVISION OR
   libfuturo_web_TOOLCHAIN_ID STREQUAL "" OR
   NOT libfuturo_web_SDK_IMAGE STREQUAL
       "emscripten/emsdk:7.0.0@sha256:6bd7aef93408b10bf7b36642cb7c91119b302f720b9ec2d20439f73cf07fe894" OR
   NOT libfuturo_web_SDK_PLATFORM STREQUAL "linux/amd64")
  message(FATAL_ERROR
    "The installed browser package identity does not match the selected Muhtari/Emscripten build")
endif()

function(assert_under_web_prefix path description)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${description} does not exist: ${path}")
  endif()
  file(REAL_PATH "${path}" _real_path)
  string(FIND "${_real_path}" "${_expected_web_prefix}/" _prefix_index)
  if(NOT _prefix_index EQUAL 0)
    message(FATAL_ERROR
      "${description} escaped the relocated package prefix: ${_real_path}")
  endif()
endfunction()

assert_under_web_prefix(
  "${libfuturo_web_DIR}/libfuturo_webConfig.cmake"
  "browser package config")
assert_under_web_prefix("${muhtari_DIR}/muhtariConfig.cmake"
  "colocated Muhtari config")
assert_under_web_prefix("${_expected_web_prefix}/lib/libfuturo-web.a"
  "browser archive")
assert_under_web_prefix("${_expected_web_prefix}/lib/libmuhtari.a"
  "colocated Muhtari archive")
assert_under_web_prefix("${_expected_web_prefix}/include/libfuturo/libfuturo.h"
  "LibFuturo public header")
assert_under_web_prefix("${_expected_web_prefix}/include/muhtari.h"
  "Muhtari public header")
if(EXISTS "${_expected_web_prefix}/lib/libnesturbator.a" OR
   EXISTS "${_expected_web_prefix}/lib/cmake/nesturbator/nesturbatorConfig.cmake")
  message(FATAL_ERROR
    "The browser package installed an unwanted Nesturbator archive or config")
endif()

function(imported_archive target output_variable)
  foreach(_property IMPORTED_LOCATION IMPORTED_LOCATION_NOCONFIG
      IMPORTED_LOCATION_DEBUG IMPORTED_LOCATION_RELEASE
      IMPORTED_LOCATION_RELWITHDEBINFO IMPORTED_LOCATION_MINSIZEREL)
    get_target_property(_candidate "${target}" "${_property}")
    if(_candidate AND NOT _candidate MATCHES "-NOTFOUND$")
      set("${output_variable}" "${_candidate}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR "${target} has no imported archive location")
endfunction()

imported_archive(libfuturo::web _web_archive)
imported_archive(muhtari::muhtari _muhtari_archive)
assert_under_web_prefix("${_web_archive}" "imported browser target")
assert_under_web_prefix("${_muhtari_archive}" "imported Muhtari target")
get_target_property(_web_links libfuturo::web INTERFACE_LINK_LIBRARIES)
if(NOT _web_links MATCHES "muhtari::muhtari" OR
   _web_links MATCHES "[Nn]esturbator")
  message(FATAL_ERROR
    "The browser target does not link exclusively to its selected Muhtari dependency")
endif()

file(READ "${libfuturo_web_DIR}/libfuturo_webConfig.cmake" _web_config_text)
if(_web_config_text MATCHES "nesturbatorConfig|libnesturbator\\.a|PACKAGE_LIBFUTURO_NESTURBATOR")
  message(FATAL_ERROR
    "The browser package config carries a native Nesturbator package requirement")
endif()

message(STATUS
  "web_package_export: relocated libfuturo::web identity and colocated Muhtari archive verified; Nesturbator absent; result=pass")
