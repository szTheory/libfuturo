include(FetchContent)

set(_nesturbator_commit "2338608ab184f040620a30d17756f5e06a42d4e3")
set(_nesturbator_repository "https://github.com/szTheory/nesturbator.git")

if(DEFINED FETCHCONTENT_SOURCE_DIR_NESTURBATOR
   AND NOT FETCHCONTENT_SOURCE_DIR_NESTURBATOR STREQUAL "")
  message(FATAL_ERROR
    "FETCHCONTENT_SOURCE_DIR_NESTURBATOR is not allowed; use the pinned public source")
endif()

FetchContent_Declare(nesturbator
  GIT_REPOSITORY "${_nesturbator_repository}"
  GIT_TAG "${_nesturbator_commit}"
  GIT_SHALLOW FALSE
  GIT_PROGRESS TRUE
  GIT_CONFIG
    http.connectTimeout=15
    http.lowSpeedLimit=1024
    http.lowSpeedTime=30
)
FetchContent_GetProperties(nesturbator)
if(NOT nesturbator_POPULATED)
  # Populate without adding the upstream project. The single-name form is
  # needed here so FetchContent reuses its cached source directory; CMP0169 is
  # kept OLD because exact source validation must happen before add_subdirectory.
  cmake_policy(PUSH)
  if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(nesturbator)
  cmake_policy(POP)
endif()

cmake_path(IS_PREFIX CMAKE_BINARY_DIR "${nesturbator_SOURCE_DIR}" NORMALIZE
  _nesturbator_source_in_build_tree)
if(NOT _nesturbator_source_in_build_tree)
  message(FATAL_ERROR
    "nesturbator must be acquired inside the local build tree: ${nesturbator_SOURCE_DIR}")
endif()

find_package(Git REQUIRED)
execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${nesturbator_SOURCE_DIR}" remote get-url origin
  RESULT_VARIABLE _nesturbator_origin_result
  OUTPUT_VARIABLE _nesturbator_origin
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _nesturbator_origin_error
)
if(NOT _nesturbator_origin_result EQUAL 0
   OR NOT _nesturbator_origin STREQUAL _nesturbator_repository)
  message(FATAL_ERROR
    "Expected nesturbator public origin ${_nesturbator_repository}; got '${_nesturbator_origin}': ${_nesturbator_origin_error}")
endif()

execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${nesturbator_SOURCE_DIR}" rev-parse HEAD
  RESULT_VARIABLE _nesturbator_revision_result
  OUTPUT_VARIABLE _nesturbator_revision
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _nesturbator_revision_error
)
if(NOT _nesturbator_revision_result EQUAL 0
   OR NOT _nesturbator_revision STREQUAL _nesturbator_commit)
  message(FATAL_ERROR
    "Expected nesturbator ${_nesturbator_commit}; got '${_nesturbator_revision}': ${_nesturbator_revision_error}")
endif()

execute_process(
  COMMAND "${GIT_EXECUTABLE}" -C "${nesturbator_SOURCE_DIR}"
    status --porcelain=v1 --untracked-files=all --ignore-submodules=none
  RESULT_VARIABLE _nesturbator_status_result
  OUTPUT_VARIABLE _nesturbator_status
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_VARIABLE _nesturbator_status_error
)
if(NOT _nesturbator_status_result EQUAL 0)
  message(FATAL_ERROR
    "Could not inspect nesturbator worktree status: ${_nesturbator_status_error}")
endif()
if(NOT _nesturbator_status STREQUAL "")
  message(FATAL_ERROR
    "Pinned nesturbator source must be clean, including untracked files:\n${_nesturbator_status}")
endif()

set(_nesturbator_verified_revision "${_nesturbator_revision}")

# Only expose the source after origin, full revision, and worktree contents
# have all been verified. This executes the dependency's CMakeLists.txt.
add_subdirectory("${nesturbator_SOURCE_DIR}" "${nesturbator_BINARY_DIR}")

if(NOT TARGET nesturbator::nesturbator)
  message(FATAL_ERROR "Pinned nesturbator did not provide nesturbator::nesturbator")
endif()
