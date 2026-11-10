include(FetchContent)

set(_muhtari_repository "https://github.com/szTheory/muhtari.git")
if(LIBFUTURO_MUHTARI_API_REVISION STREQUAL "7")
  set(_muhtari_commit "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
  set(_muhtari_expected_version "0.10.0")
elseif(LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
  set(_muhtari_commit "d58f125297c4d63a7a8108112a5eafff6f53a76a")
  set(_muhtari_expected_version "0.11.1")
else()
  message(FATAL_ERROR
    "LIBFUTURO_MUHTARI_API_REVISION must be exactly 7 or 8")
endif()

if(DEFINED FETCHCONTENT_SOURCE_DIR_MUHTARI
   AND NOT FETCHCONTENT_SOURCE_DIR_MUHTARI STREQUAL "")
  message(FATAL_ERROR
    "FETCHCONTENT_SOURCE_DIR_MUHTARI is not allowed; use the pinned public source")
endif()

FetchContent_Declare(muhtari
  GIT_REPOSITORY "${_muhtari_repository}"
  GIT_TAG "${_muhtari_commit}"
  GIT_SHALLOW FALSE
  GIT_PROGRESS TRUE
  GIT_CONFIG
    http.connectTimeout=15
    http.lowSpeedLimit=1024
    http.lowSpeedTime=30
)
FetchContent_GetProperties(muhtari)
if(NOT muhtari_POPULATED)
  cmake_policy(PUSH)
  if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(muhtari)
  cmake_policy(POP)
endif()

cmake_path(IS_PREFIX CMAKE_BINARY_DIR "${muhtari_SOURCE_DIR}" NORMALIZE
  _muhtari_source_in_build_tree)
if(NOT _muhtari_source_in_build_tree)
  message(FATAL_ERROR
    "muhtari must be acquired inside the local build tree: ${muhtari_SOURCE_DIR}")
endif()

file(STRINGS "${muhtari_SOURCE_DIR}/version.txt" _muhtari_source_version
  LIMIT_COUNT 1)
file(STRINGS "${muhtari_SOURCE_DIR}/include/muhtari.h"
  _muhtari_api_declaration
  REGEX "^[ \t]*#define[ \t]+MUHTARI_API_VERSION[ \t]+[0-9]+[ \t]*$")
if(NOT _muhtari_source_version STREQUAL _muhtari_expected_version OR
   NOT _muhtari_api_declaration MATCHES
     "MUHTARI_API_VERSION[ \t]+([0-9]+)$")
  message(FATAL_ERROR
    "Pinned Muhtari version/API metadata is missing or malformed")
endif()
set(_muhtari_header_api_revision "${CMAKE_MATCH_1}")
if(NOT _muhtari_header_api_revision STREQUAL
   LIBFUTURO_MUHTARI_API_REVISION)
  message(FATAL_ERROR
    "Pinned Muhtari source declares API ${_muhtari_header_api_revision}; expected ${LIBFUTURO_MUHTARI_API_REVISION}")
endif()

find_package(Git REQUIRED)
execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${muhtari_SOURCE_DIR}" remote get-url origin
  RESULT_VARIABLE _muhtari_origin_result
  OUTPUT_VARIABLE _muhtari_origin
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _muhtari_origin_error
)
if(NOT _muhtari_origin_result EQUAL 0
   OR NOT _muhtari_origin STREQUAL _muhtari_repository)
  message(FATAL_ERROR
    "Expected muhtari public origin ${_muhtari_repository}; got '${_muhtari_origin}': ${_muhtari_origin_error}")
endif()

execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${muhtari_SOURCE_DIR}" rev-parse HEAD
  RESULT_VARIABLE _muhtari_revision_result
  OUTPUT_VARIABLE _muhtari_revision
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _muhtari_revision_error
)
if(NOT _muhtari_revision_result EQUAL 0
   OR NOT _muhtari_revision STREQUAL _muhtari_commit)
  message(FATAL_ERROR
    "Expected muhtari ${_muhtari_commit}; got '${_muhtari_revision}': ${_muhtari_revision_error}")
endif()

execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${muhtari_SOURCE_DIR}"
    status --porcelain=v1 --untracked-files=all --ignore-submodules=none
  RESULT_VARIABLE _muhtari_status_result
  OUTPUT_VARIABLE _muhtari_status
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _muhtari_status_error
)
if(NOT _muhtari_status_result EQUAL 0)
  message(FATAL_ERROR
    "Could not inspect muhtari worktree status: ${_muhtari_status_error}")
endif()
if(NOT _muhtari_status STREQUAL "")
  message(FATAL_ERROR
    "Pinned muhtari source must be clean, including untracked files:\n${_muhtari_status}")
endif()

set(_muhtari_verified_revision "${_muhtari_revision}")
set(_muhtari_verified_api_revision "${_muhtari_header_api_revision}")
set(_muhtari_verified_version "${_muhtari_source_version}")
add_subdirectory("${muhtari_SOURCE_DIR}" "${muhtari_BINARY_DIR}")
if(NOT TARGET muhtari::muhtari)
  message(FATAL_ERROR "Pinned muhtari did not provide muhtari::muhtari")
endif()
