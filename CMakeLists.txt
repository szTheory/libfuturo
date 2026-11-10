cmake_minimum_required(VERSION 3.25)
project(libfuturo VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(CTest)
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

option(LIBFUTURO_ENABLE_MUHTARI
  "Build and install the optional Muhtari profile" OFF)
option(LIBFUTURO_BUILD_WEB
  "Build the opt-in Emscripten package for the exact Muhtari API 8 profile" OFF)
set(LIBFUTURO_WEB_SDK_IMAGE "" CACHE STRING
  "Pinned SDK image identity included in the browser package fingerprint")
set(LIBFUTURO_WEB_SDK_PLATFORM "" CACHE STRING
  "Pinned SDK image platform included in the browser package fingerprint")
set(LIBFUTURO_WEB_SOURCE_REVISION "" CACHE STRING
  "Source commit identity supplied by the pinned browser build driver")
option(LIBFUTURO_WEB_TEST_IDENTITY
  "Build and run the Emscripten cross-runtime snapshot identity control" OFF)

set(LIBFUTURO_MUHTARI_API_REVISION "7" CACHE STRING
  "Select the supported Muhtari API revision (7 or 8)")
set_property(CACHE LIBFUTURO_MUHTARI_API_REVISION PROPERTY STRINGS 7 8)
if(NOT LIBFUTURO_MUHTARI_API_REVISION STREQUAL "7" AND
   NOT LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
  message(FATAL_ERROR
    "LIBFUTURO_MUHTARI_API_REVISION must be exactly 7 or 8")
endif()

find_package(Git QUIET)
set(LIBFUTURO_GIT_REVISION "unversioned")
if(GIT_FOUND)
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    RESULT_VARIABLE _git_revision_result
    OUTPUT_VARIABLE LIBFUTURO_GIT_REVISION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(NOT _git_revision_result EQUAL 0 OR
     LIBFUTURO_GIT_REVISION STREQUAL "")
    set(LIBFUTURO_GIT_REVISION "unversioned")
  endif()
endif()

# Keep the browser graph separate at configure time. The selected static
# library shares LibFuturo's dispatcher and Muhtari adapter sources, while
# excluding every native-only Nesturbator probe, instrumented library and
# adapter source before any of those targets can be configured or fetched.
if(LIBFUTURO_BUILD_WEB)
  if(NOT EMSCRIPTEN)
    message(FATAL_ERROR
      "LIBFUTURO_BUILD_WEB requires the Emscripten CMake toolchain (emcmake)")
  endif()
  if(NOT LIBFUTURO_ENABLE_MUHTARI OR
     NOT LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
    message(FATAL_ERROR
      "LIBFUTURO_BUILD_WEB requires LIBFUTURO_ENABLE_MUHTARI=ON and API revision 8")
  endif()

  include(cmake/MuhtariProbe.cmake)

  if(NOT LIBFUTURO_WEB_SOURCE_REVISION STREQUAL "")
    set(LIBFUTURO_GIT_REVISION "${LIBFUTURO_WEB_SOURCE_REVISION}")
  endif()

  set(_libfuturo_web_identity
    "package=libfuturo-web\ncore=muhtari\napi=${_muhtari_verified_api_revision}\nversion=${_muhtari_verified_version}\nsource=${_muhtari_verified_revision}\nprofile=muhtari-ntsc-v2\nconfiguration=muhtari-ntsc-battery-diagnostic\nsdk-image=${LIBFUTURO_WEB_SDK_IMAGE}\nsdk-platform=${LIBFUTURO_WEB_SDK_PLATFORM}\n")
  foreach(_web_identity_variable
      CMAKE_SYSTEM_NAME CMAKE_SYSTEM_PROCESSOR CMAKE_C_COMPILER_ID
      CMAKE_C_COMPILER_VERSION CMAKE_C_COMPILER_TARGET CMAKE_C_FLAGS
      CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE CMAKE_EXE_LINKER_FLAGS
      CMAKE_EXE_LINKER_FLAGS_DEBUG CMAKE_EXE_LINKER_FLAGS_RELEASE
      CMAKE_STATIC_LINKER_FLAGS EMSCRIPTEN_VERSION)
    if(DEFINED ${_web_identity_variable})
      string(APPEND _libfuturo_web_identity
        "${_web_identity_variable}=${${_web_identity_variable}}\n")
    else()
      string(APPEND _libfuturo_web_identity
        "${_web_identity_variable}=<unset>\n")
    endif()
  endforeach()
  string(SHA256 LIBFUTURO_WEB_TOOLCHAIN_ID "${_libfuturo_web_identity}")
  string(SHA256 _libfuturo_web_build_fingerprint
    "${_libfuturo_web_identity}source-tree=${LIBFUTURO_GIT_REVISION}")
  set(LIBFUTURO_WEB_BUILD_ID "sha256:${_libfuturo_web_build_fingerprint}")

  add_library(libfuturo_web STATIC
    src/synthetic.c
    src/muhtari_adapter.c
    src/sha256.c
  )
  add_library(libfuturo::web ALIAS libfuturo_web)
  set_target_properties(libfuturo_web PROPERTIES
    OUTPUT_NAME futuro-web
    EXPORT_NAME web
  )
  target_link_libraries(libfuturo_web PRIVATE muhtari::muhtari)
  target_include_directories(libfuturo_web PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
  target_compile_definitions(libfuturo_web PRIVATE
    LF_WEB_BUILD=1
    LF_HAS_MUHTARI=1
    "LF_MUHTARI_API_REVISION=${_muhtari_verified_api_revision}"
    "LF_MUHTARI_SOURCE_REVISION=\"${_muhtari_verified_revision}\""
    "LF_BUILD_ID=\"${LIBFUTURO_WEB_BUILD_ID}\"")

  function(lf_assert_web_graph_directory directory_path)
    get_property(_graph_targets DIRECTORY "${directory_path}"
      PROPERTY BUILDSYSTEM_TARGETS)
    foreach(_graph_target IN LISTS _graph_targets)
      if(_graph_target MATCHES "[Nn]esturbator")
        message(FATAL_ERROR
          "The browser build graph contains forbidden target ${_graph_target}")
      endif()
      foreach(_graph_property LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
        get_target_property(_graph_links "${_graph_target}" "${_graph_property}")
        if(_graph_links AND _graph_links MATCHES "[Nn]esturbator")
          message(FATAL_ERROR
            "The browser build target ${_graph_target} has a forbidden Nesturbator dependency")
        endif()
      endforeach()
    endforeach()
    get_property(_graph_subdirectories DIRECTORY "${directory_path}"
      PROPERTY SUBDIRECTORIES)
    foreach(_graph_subdirectory IN LISTS _graph_subdirectories)
      lf_assert_web_graph_directory("${_graph_subdirectory}")
    endforeach()
  endfunction()

  lf_assert_web_graph_directory("${CMAKE_CURRENT_SOURCE_DIR}")
  get_target_property(_web_core_links libfuturo_web LINK_LIBRARIES)
  if(_web_core_links MATCHES "[Nn]esturbator")
    message(FATAL_ERROR
      "The browser target must link only the selected Muhtari core")
  endif()

  if(BUILD_TESTING)
    add_test(NAME web_package_graph
      COMMAND "${CMAKE_COMMAND}"
        "-DLIBFUTURO_WEB_GRAPH_ONLY=ON"
        "-DLIBFUTURO_WEB_BUILD_DIR=${CMAKE_BINARY_DIR}"
        "-DLIBFUTURO_WEB_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
        "-DLIBFUTURO_WEB_ARCHIVE=${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_STATIC_LIBRARY_PREFIX}futuro-web${CMAKE_STATIC_LIBRARY_SUFFIX}"
        "-DLIBFUTURO_WEB_NM=${CMAKE_NM}"
        -S "${CMAKE_CURRENT_SOURCE_DIR}/tests/web-package"
        -B "${CMAKE_BINARY_DIR}/web-package-graph-check")
    set_tests_properties(web_package_graph PROPERTIES TIMEOUT 30)

    if(DEFINED LIBFUTURO_WEB_TEST_PREFIX AND
       NOT LIBFUTURO_WEB_TEST_PREFIX STREQUAL "")
      add_test(NAME web_package_export
        COMMAND "${CMAKE_COMMAND}"
          "-DEXPECTED_WEB_PREFIX=${LIBFUTURO_WEB_TEST_PREFIX}"
          "-DEXPECTED_WEB_BUILD_ID=${LIBFUTURO_WEB_BUILD_ID}"
          "-DEXPECTED_WEB_SOURCE_REVISION=${LIBFUTURO_GIT_REVISION}"
          -S "${CMAKE_CURRENT_SOURCE_DIR}/tests/web-package"
          -B "${CMAKE_BINARY_DIR}/web-package-export-check")
      set_tests_properties(web_package_export PROPERTIES TIMEOUT 30)
    endif()

    if(LIBFUTURO_WEB_TEST_IDENTITY)
      find_program(LIBFUTURO_WEB_NODE_EXECUTABLE NAMES node nodejs REQUIRED)
      add_executable(web_snapshot_identity_probe
        tests/web-package/snapshot_identity_probe.c)
      target_include_directories(web_snapshot_identity_probe PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/installed-consumer")
      target_link_libraries(web_snapshot_identity_probe PRIVATE libfuturo_web)
      target_link_options(web_snapshot_identity_probe PRIVATE
        "-Wl,--no-entry"
        "-sMODULARIZE=1"
        "-sEXPORT_NAME=createSnapshotIdentityModule"
        "-sEXPORTED_RUNTIME_METHODS=HEAPU8")
      add_test(NAME web_snapshot_cross_runtime_identity
        COMMAND "${LIBFUTURO_WEB_NODE_EXECUTABLE}"
          "${CMAKE_CURRENT_SOURCE_DIR}/tests/web-package/snapshot_identity_probe.cjs"
          "$<TARGET_FILE:web_snapshot_identity_probe>")
      set_tests_properties(web_snapshot_cross_runtime_identity
        PROPERTIES TIMEOUT 30)
    endif()
  endif()

  set(_libfuturo_web_cmake_dir "${CMAKE_INSTALL_LIBDIR}/cmake/libfuturo-web")
  set(LIBFUTURO_WEB_MUHTARI_CMAKE_DIR
    "${CMAKE_INSTALL_LIBDIR}/cmake/muhtari")
  set(LIBFUTURO_WEB_PACKAGE_API_REVISION
    "${_muhtari_verified_api_revision}")
  set(LIBFUTURO_WEB_PACKAGE_VERSION "${_muhtari_verified_version}")
  set(LIBFUTURO_WEB_PACKAGE_SOURCE_REVISION "${_muhtari_verified_revision}")
set(LIBFUTURO_WEB_PACKAGE_LIBFUTURO_SOURCE_REVISION
  "${LIBFUTURO_GIT_REVISION}")
  set(LIBFUTURO_MUHTARI_PACKAGE_API_REVISION
    "${_muhtari_verified_api_revision}")
  set(LIBFUTURO_MUHTARI_PACKAGE_VERSION "${_muhtari_verified_version}")
  set(LIBFUTURO_MUHTARI_PACKAGE_SOURCE_REVISION
    "${_muhtari_verified_revision}")
  configure_package_config_file(
    cmake/libfuturoWebConfig.cmake.in
    "${CMAKE_CURRENT_BINARY_DIR}/libfuturo_webConfig.cmake"
    INSTALL_DESTINATION "${_libfuturo_web_cmake_dir}"
    PATH_VARS LIBFUTURO_WEB_MUHTARI_CMAKE_DIR)
  write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/libfuturo_webConfigVersion.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY ExactVersion)
  install(TARGETS libfuturo_web EXPORT libfuturoWebTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(FILES include/libfuturo/libfuturo.h
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/libfuturo")
  install(EXPORT libfuturoWebTargets FILE libfuturoWebTargets.cmake
    NAMESPACE libfuturo:: DESTINATION "${_libfuturo_web_cmake_dir}")
  install(FILES
      "${CMAKE_CURRENT_BINARY_DIR}/libfuturo_webConfig.cmake"
      "${CMAKE_CURRENT_BINARY_DIR}/libfuturo_webConfigVersion.cmake"
    DESTINATION "${_libfuturo_web_cmake_dir}")

  set(_muhtari_web_cmake_dir "${CMAKE_INSTALL_LIBDIR}/cmake/muhtari")
  configure_package_config_file(
    cmake/muhtariConfig.cmake.in
    "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfig.cmake"
    INSTALL_DESTINATION "${_muhtari_web_cmake_dir}")
  write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfigVersion.cmake"
    VERSION "${LIBFUTURO_WEB_PACKAGE_VERSION}"
    COMPATIBILITY ExactVersion)
  install(TARGETS muhtari EXPORT muhtariTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(FILES "${muhtari_SOURCE_DIR}/include/muhtari.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(EXPORT muhtariTargets FILE muhtariTargets.cmake
    NAMESPACE muhtari:: DESTINATION "${_muhtari_web_cmake_dir}")
  install(FILES
      "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfig.cmake"
      "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfigVersion.cmake"
    DESTINATION "${_muhtari_web_cmake_dir}")
  install(FILES
      "${muhtari_SOURCE_DIR}/LICENSE"
      "${muhtari_SOURCE_DIR}/THIRD-PARTY-NOTICES.md"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/muhtari")
  install(FILES LICENSE
    DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/libfuturo")

  message(STATUS
    "libfuturo web package: core=Muhtari ${_muhtari_verified_version} API=${_muhtari_verified_api_revision} source=${_muhtari_verified_revision}")
  message(STATUS "libfuturo web toolchain identity: ${LIBFUTURO_WEB_TOOLCHAIN_ID}")
  message(STATUS "libfuturo web build identity: ${LIBFUTURO_WEB_BUILD_ID}")
  return()
endif()

include(cmake/NesturbatorProbe.cmake)
include(cmake/NesturbatorInstrumented.cmake)
add_instrumented_nesturbator()
if(LIBFUTURO_ENABLE_MUHTARI)
  include(cmake/MuhtariProbe.cmake)
endif()

set(_required_tests "${CMAKE_BINARY_DIR}/required-tests.txt")
set(_required_targets "${CMAKE_BINARY_DIR}/required-targets.txt")
set(_required_route_results "${CMAKE_BINARY_DIR}/required-route-results.txt")
set(_muhtari_api8_required_tests
  "${CMAKE_BINARY_DIR}/muhtari-api8-required-tests.txt")
set(_muhtari_api8_required_targets
  "${CMAKE_BINARY_DIR}/muhtari-api8-required-targets.txt")
file(WRITE "${_required_tests}" "")
file(WRITE "${_required_targets}" "libfuturo\nlibfuturo_test\n")
if(LIBFUTURO_ENABLE_MUHTARI AND
   LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
  file(WRITE "${_muhtari_api8_required_tests}" "")
  file(WRITE "${_muhtari_api8_required_targets}" "")
endif()

function(add_required_consumer_test test_name target_name)
  add_test(NAME "${test_name}" COMMAND "$<TARGET_FILE:${target_name}>" ${ARGN})
  set_tests_properties("${test_name}" PROPERTIES TIMEOUT 30)
  file(APPEND "${_required_tests}" "${test_name}\n")
  file(APPEND "${_required_targets}" "${target_name}\n")
endfunction()

function(add_muhtari_api8_consumer_test test_name target_name)
  add_required_consumer_test("${test_name}" "${target_name}" ${ARGN})
  file(APPEND "${_muhtari_api8_required_tests}" "${test_name}\n")
  file(APPEND "${_muhtari_api8_required_targets}" "${target_name}\n")
endfunction()

function(lf_build_fingerprint_record records_var record_name record_value)
  string(SHA256 _record_hash "${record_value}")
  set(_records "${${records_var}}")
  list(APPEND _records "${record_name}=${_record_hash}")
  set(${records_var} "${_records}" PARENT_SCOPE)
endfunction()

function(lf_compute_build_fingerprint target_name result_var)
  set(_records "")
  get_target_property(_target_sources "${target_name}" SOURCES)
  if(NOT _target_sources OR _target_sources MATCHES "-NOTFOUND$")
    message(FATAL_ERROR "Could not enumerate ${target_name} sources for its build identity")
  endif()
  set(_source_labels "")
  foreach(_source IN LISTS _target_sources)
    if(_source MATCHES "\\$<" OR IS_ABSOLUTE "${_source}")
      message(FATAL_ERROR
        "${target_name} source is not a repository-relative build input: ${_source}")
    endif()
    list(APPEND _source_labels "${_source}")
  endforeach()
  list(SORT _source_labels)
  string(JOIN "\n" _source_manifest ${_source_labels})
  lf_build_fingerprint_record(_records "target/${target_name}/sources"
    "${_source_manifest}")

  file(GLOB_RECURSE _project_headers CONFIGURE_DEPENDS
    RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.h")
  set(_fingerprint_files
    ${_source_labels}
    ${_project_headers}
    CMakeLists.txt
    cmake/NesturbatorProbe.cmake
    cmake/NesturbatorInstrumented.cmake)
  if(LIBFUTURO_ENABLE_MUHTARI)
    list(APPEND _fingerprint_files cmake/MuhtariProbe.cmake)
  endif()
  list(REMOVE_DUPLICATES _fingerprint_files)
  list(SORT _fingerprint_files)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    ${_fingerprint_files})
  foreach(_input IN LISTS _fingerprint_files)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_input}")
      message(FATAL_ERROR "Missing ${target_name} build identity input: ${_input}")
    endif()
    file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/${_input}" _input_hash)
    lf_build_fingerprint_record(_records "file/${_input}" "${_input_hash}")
  endforeach()

  foreach(_property COMPILE_DEFINITIONS COMPILE_OPTIONS LINK_LIBRARIES
      INCLUDE_DIRECTORIES SYSTEM_INCLUDE_DIRECTORIES COMPILE_FEATURES
      LINK_OPTIONS LINK_DIRECTORIES C_STANDARD C_STANDARD_REQUIRED
      C_EXTENSIONS POSITION_INDEPENDENT_CODE C_VISIBILITY_PRESET
      INTERPROCEDURAL_OPTIMIZATION)
    get_target_property(_value "${target_name}" "${_property}")
    if(NOT _value OR _value MATCHES "-NOTFOUND$")
      set(_value "")
    endif()
    string(JOIN "\n" _joined_value ${_value})
    string(REPLACE "${CMAKE_CURRENT_SOURCE_DIR}" "<source>" _joined_value
      "${_joined_value}")
    string(REPLACE "${CMAKE_BINARY_DIR}" "<build>" _joined_value
      "${_joined_value}")
    lf_build_fingerprint_record(_records
      "target/${target_name}/${_property}" "${_joined_value}")
  endforeach()

  foreach(_variable CMAKE_BUILD_TYPE CMAKE_CONFIGURATION_TYPES CMAKE_C_STANDARD
      CMAKE_C_STANDARD_REQUIRED CMAKE_C_EXTENSIONS CMAKE_C_COMPILER_ID
      CMAKE_C_COMPILER_VERSION CMAKE_C_COMPILER_TARGET
      CMAKE_C_COMPILER_ARCHITECTURE_ID CMAKE_C_COMPILER_FRONTEND_VARIANT
      CMAKE_C_COMPILER_ARG1 CMAKE_C_COMPILER_LAUNCHER
      CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG
      CMAKE_C_FLAGS_RELEASE CMAKE_C_FLAGS_RELWITHDEBINFO
      CMAKE_C_FLAGS_MINSIZEREL CMAKE_SYSTEM_NAME CMAKE_SYSTEM_PROCESSOR
      CMAKE_SIZEOF_VOID_P CMAKE_C_BYTE_ORDER CMAKE_OSX_ARCHITECTURES
      CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_INTERPROCEDURAL_OPTIMIZATION
      CMAKE_STATIC_LINKER_FLAGS CMAKE_STATIC_LINKER_FLAGS_DEBUG
      CMAKE_STATIC_LINKER_FLAGS_RELEASE)
    if(DEFINED ${_variable})
      set(_value "${${_variable}}")
    else()
      set(_value "")
    endif()
    string(REPLACE "${CMAKE_CURRENT_SOURCE_DIR}" "<source>" _value "${_value}")
    string(REPLACE "${CMAKE_BINARY_DIR}" "<build>" _value "${_value}")
    lf_build_fingerprint_record(_records "toolchain/${_variable}" "${_value}")
  endforeach()

  if(DEFINED CMAKE_C_COMPILER_LAUNCHER AND
     NOT "${CMAKE_C_COMPILER_LAUNCHER}" STREQUAL "")
    foreach(_launcher IN LISTS CMAKE_C_COMPILER_LAUNCHER)
      get_filename_component(_launcher_name "${_launcher}" NAME)
      execute_process(COMMAND "${_launcher}" --version
        RESULT_VARIABLE _launcher_result
        OUTPUT_VARIABLE _launcher_output
        ERROR_VARIABLE _launcher_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE)
      lf_build_fingerprint_record(_records "toolchain/compiler-launcher/name"
        "${_launcher_name}")
      lf_build_fingerprint_record(_records "toolchain/compiler-launcher/version"
        "${_launcher_result}:${_launcher_output}:${_launcher_error}")
    endforeach()
  endif()

  foreach(_variable CMAKE_OSX_SYSROOT CMAKE_SYSROOT CMAKE_SYSROOT_COMPILE
      CMAKE_SYSROOT_LINK)
    if(DEFINED ${_variable} AND NOT "${${_variable}}" STREQUAL "")
      get_filename_component(_value "${${_variable}}" NAME)
    else()
      set(_value "default")
    endif()
    lf_build_fingerprint_record(_records "toolchain/${_variable}" "${_value}")
  endforeach()

  get_filename_component(_compiler_name "${CMAKE_C_COMPILER}" NAME)
  lf_build_fingerprint_record(_records "toolchain/compiler-name" "${_compiler_name}")
  execute_process(COMMAND "${CMAKE_C_COMPILER}" --version
    RESULT_VARIABLE _compiler_version_result
    OUTPUT_VARIABLE _compiler_version_output
    ERROR_VARIABLE _compiler_version_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE)
  lf_build_fingerprint_record(_records "toolchain/compiler-version-result"
    "${_compiler_version_result}")
  lf_build_fingerprint_record(_records "toolchain/compiler-version-output"
    "${_compiler_version_output}\n${_compiler_version_error}")

  foreach(_tool CMAKE_AR CMAKE_RANLIB)
    if(DEFINED ${_tool} AND NOT "${${_tool}}" STREQUAL "")
      get_filename_component(_tool_name "${${_tool}}" NAME)
      execute_process(COMMAND "${${_tool}}" --version
        RESULT_VARIABLE _tool_version_result
        OUTPUT_VARIABLE _tool_version_output
        ERROR_VARIABLE _tool_version_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE)
      lf_build_fingerprint_record(_records "toolchain/${_tool}/name"
        "${_tool_name}")
      lf_build_fingerprint_record(_records "toolchain/${_tool}/version-result"
        "${_tool_version_result}")
      lf_build_fingerprint_record(_records "toolchain/${_tool}/version-output"
        "${_tool_version_output}\n${_tool_version_error}")
    endif()
  endforeach()

  if(APPLE)
    foreach(_sdk_query --show-sdk-version --show-sdk-build-version)
      execute_process(COMMAND xcrun --sdk macosx "${_sdk_query}"
        RESULT_VARIABLE _sdk_result
        OUTPUT_VARIABLE _sdk_output
        ERROR_VARIABLE _sdk_error
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE)
      lf_build_fingerprint_record(_records "toolchain/macos-sdk/${_sdk_query}"
        "${_sdk_result}:${_sdk_output}:${_sdk_error}")
    endforeach()
  endif()

  lf_build_fingerprint_record(_records "source/git-revision"
    "${LIBFUTURO_GIT_REVISION}")
  lf_build_fingerprint_record(_records "source/nesturbator-revision"
    "${_nesturbator_verified_revision}")
  if(LIBFUTURO_ENABLE_MUHTARI AND target_name STREQUAL "libfuturo")
    lf_build_fingerprint_record(_records "source/muhtari-api-revision"
      "${_muhtari_verified_api_revision}")
    lf_build_fingerprint_record(_records "source/muhtari-revision"
      "${_muhtari_verified_revision}")
    foreach(_property IN ITEMS SOURCES COMPILE_DEFINITIONS COMPILE_OPTIONS
        INCLUDE_DIRECTORIES SYSTEM_INCLUDE_DIRECTORIES COMPILE_FEATURES
        LINK_LIBRARIES INTERFACE_COMPILE_DEFINITIONS
        INTERFACE_COMPILE_OPTIONS INTERFACE_INCLUDE_DIRECTORIES
        INTERFACE_LINK_LIBRARIES LINK_OPTIONS C_STANDARD C_STANDARD_REQUIRED
        C_EXTENSIONS POSITION_INDEPENDENT_CODE)
      get_target_property(_muhtari_value muhtari "${_property}")
      if(NOT _muhtari_value OR _muhtari_value MATCHES "-NOTFOUND$")
        set(_muhtari_value "")
      endif()
      string(JOIN "\n" _muhtari_joined_value ${_muhtari_value})
      lf_build_fingerprint_record(_records
        "muhtari-target/${_property}" "${_muhtari_joined_value}")
    endforeach()
    get_cmake_property(_muhtari_cache_variables CACHE_VARIABLES)
    foreach(_muhtari_cache_variable IN LISTS _muhtari_cache_variables)
      if(_muhtari_cache_variable MATCHES "^MUHTARI_")
        get_property(_muhtari_cache_value CACHE
          "${_muhtari_cache_variable}" PROPERTY VALUE)
        lf_build_fingerprint_record(_records
          "muhtari-option/${_muhtari_cache_variable}"
          "${_muhtari_cache_value}")
      endif()
    endforeach()
  endif()
  list(SORT _records)
  string(JOIN "\n" _manifest ${_records})
  string(SHA256 _fingerprint "${_manifest}")
  set(${result_var} "sha256:${_fingerprint}" PARENT_SCOPE)
endfunction()

add_library(libfuturo STATIC
  src/synthetic.c
  src/nesturbator_adapter.c
  src/sha256.c
)
add_library(libfuturo::libfuturo ALIAS libfuturo)
target_link_libraries(libfuturo PRIVATE nesturbator::nesturbator)
if(LIBFUTURO_ENABLE_MUHTARI)
  target_sources(libfuturo PRIVATE src/muhtari_adapter.c)
  target_link_libraries(libfuturo PRIVATE muhtari::muhtari)
  target_compile_definitions(libfuturo PRIVATE
    LF_HAS_MUHTARI=1
    "LF_MUHTARI_API_REVISION=${_muhtari_verified_api_revision}"
    "LF_MUHTARI_SOURCE_REVISION=\"${_muhtari_verified_revision}\"")
  set(LIBFUTURO_MUHTARI_ENABLED TRUE)
  set(LIBFUTURO_MUHTARI_PACKAGE_API_REVISION
    "${_muhtari_verified_api_revision}")
  set(LIBFUTURO_MUHTARI_PACKAGE_VERSION "${_muhtari_verified_version}")
  set(LIBFUTURO_MUHTARI_PACKAGE_SOURCE_REVISION
    "${_muhtari_verified_revision}")
else()
  set(LIBFUTURO_MUHTARI_ENABLED FALSE)
  set(LIBFUTURO_MUHTARI_PACKAGE_API_REVISION "0")
  set(LIBFUTURO_MUHTARI_PACKAGE_VERSION "")
  set(LIBFUTURO_MUHTARI_PACKAGE_SOURCE_REVISION "")
endif()
set(LIBFUTURO_MUHTARI_CONFIGURED_API_REVISION
  "${LIBFUTURO_MUHTARI_PACKAGE_API_REVISION}" CACHE INTERNAL
  "Verified Muhtari API revision selected for this configured build" FORCE)
set(LIBFUTURO_MUHTARI_CONFIGURED_VERSION
  "${LIBFUTURO_MUHTARI_PACKAGE_VERSION}" CACHE INTERNAL
  "Verified Muhtari version selected for this configured build" FORCE)
set(LIBFUTURO_MUHTARI_CONFIGURED_SOURCE_REVISION
  "${LIBFUTURO_MUHTARI_PACKAGE_SOURCE_REVISION}" CACHE INTERNAL
  "Verified Muhtari source revision selected for this configured build" FORCE)
target_include_directories(libfuturo PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
target_compile_definitions(libfuturo PRIVATE
  "LF_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")

# Keep the installed library free of test-only sanitizer runtime requirements.
# Local conformance and behavior tests link this private instrumented build.
add_library(libfuturo_test STATIC
  src/synthetic.c
  src/nesturbator_adapter.c
  src/sha256.c
)
target_link_libraries(libfuturo_test PRIVATE nesturbator_instrumented)
target_include_directories(libfuturo_test PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
)
target_compile_definitions(libfuturo_test PRIVATE
  LF_NESTURBATOR_TESTING=1
  "LF_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")

lf_compute_build_fingerprint(libfuturo _libfuturo_build_id)
lf_compute_build_fingerprint(libfuturo_test _libfuturo_test_build_id)
target_compile_definitions(libfuturo PRIVATE
  "LF_BUILD_ID=\"${_libfuturo_build_id}\"")
target_compile_definitions(libfuturo_test PRIVATE
  "LF_BUILD_ID=\"${_libfuturo_test_build_id}\"")

set(_libfuturo_cmake_dir "${CMAKE_INSTALL_LIBDIR}/cmake/libfuturo")
set(LIBFUTURO_NESTURBATOR_CMAKE_DIR
  "${CMAKE_INSTALL_LIBDIR}/cmake/nesturbator")
set(LIBFUTURO_MUHTARI_CMAKE_DIR
  "${CMAKE_INSTALL_LIBDIR}/cmake/muhtari")
configure_package_config_file(
  cmake/libfuturoConfig.cmake.in
  "${CMAKE_CURRENT_BINARY_DIR}/libfuturoConfig.cmake"
  INSTALL_DESTINATION "${_libfuturo_cmake_dir}"
  PATH_VARS LIBFUTURO_NESTURBATOR_CMAKE_DIR LIBFUTURO_MUHTARI_CMAKE_DIR
)
write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/libfuturoConfigVersion.cmake"
  VERSION "${PROJECT_VERSION}"
  COMPATIBILITY ExactVersion
)
install(TARGETS libfuturo EXPORT libfuturoTargets
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
install(FILES include/libfuturo/libfuturo.h
  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/libfuturo"
)
install(EXPORT libfuturoTargets FILE libfuturoTargets.cmake
  NAMESPACE libfuturo:: DESTINATION "${_libfuturo_cmake_dir}"
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/libfuturoConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/libfuturoConfigVersion.cmake"
  DESTINATION "${_libfuturo_cmake_dir}"
)
install(FILES LICENSE DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/libfuturo")

if(LIBFUTURO_ENABLE_MUHTARI)
  set(_muhtari_cmake_dir "${CMAKE_INSTALL_LIBDIR}/cmake/muhtari")
  configure_package_config_file(
    cmake/muhtariConfig.cmake.in
    "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfig.cmake"
    INSTALL_DESTINATION "${_muhtari_cmake_dir}")
  write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfigVersion.cmake"
    VERSION "${LIBFUTURO_MUHTARI_PACKAGE_VERSION}"
    COMPATIBILITY ExactVersion)
  install(TARGETS muhtari EXPORT muhtariTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    INCLUDES DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(FILES "${muhtari_SOURCE_DIR}/include/muhtari.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(EXPORT muhtariTargets FILE muhtariTargets.cmake
    NAMESPACE muhtari:: DESTINATION "${_muhtari_cmake_dir}")
  install(FILES
      "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfig.cmake"
      "${CMAKE_CURRENT_BINARY_DIR}/muhtariConfigVersion.cmake"
    DESTINATION "${_muhtari_cmake_dir}")
  install(FILES
      "${muhtari_SOURCE_DIR}/LICENSE"
      "${muhtari_SOURCE_DIR}/THIRD-PARTY-NOTICES.md"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/muhtari")
endif()

add_executable(synthetic_host examples/synthetic/main.c)
target_link_libraries(synthetic_host PRIVATE libfuturo_test)
add_required_consumer_test(synthetic_tracer synthetic_host)

add_executable(synthetic_session tests/synthetic_session.c)
target_link_libraries(synthetic_session PRIVATE libfuturo_test)
add_required_consumer_test(synthetic_session synthetic_session)

if(LIBFUTURO_ENABLE_MUHTARI AND
   LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
  add_executable(muhtari_api8_consumer
    tests/installed-consumer/muhtari_snapshot.c
    tests/installed-consumer/muhtari_fixture.h
    tests/installed-consumer/muhtari_snapshot_fixture.h
    tests/installed-consumer/muhtari_snapshot_oracle.h
    tests/installed-consumer/muhtari_snapshot_host.h
    tests/installed-consumer/muhtari_snapshot_faults.h)
  target_link_libraries(muhtari_api8_consumer PRIVATE libfuturo)
  target_compile_options(muhtari_api8_consumer PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG)
  add_muhtari_api8_consumer_test(muhtari_api8_profile
    muhtari_api8_consumer)
  set_tests_properties(muhtari_api8_profile PROPERTIES
    LABELS "muhtari-api8-profile"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_profile: source=d58f125297c4d63a7a8108112a5eafff6f53a76a version=0.11.1 api=8 abi=1 behavior=6 state-format=1 profile=muhtari-ntsc-v2 fixture=owned-a78-linear-16k input=1 frame=1 video=INDEX8 audio=S16_NATIVE result=pass"
    TIMEOUT 30)
  add_muhtari_api8_consumer_test(muhtari_api8_fixture_boundary
    muhtari_api8_consumer --fixture-boundary)
  set_tests_properties(muhtari_api8_fixture_boundary PROPERTIES
    LABELS "muhtari-api8-fixture"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_fixture_boundary: R2 frame 2 pending page and R3 frame 3 published; full-span literals verified"
    TIMEOUT 30)
  add_muhtari_api8_consumer_test(muhtari_api8_fixture_oracle_controls
    muhtari_api8_consumer --fixture-oracle-controls)
  set_tests_properties(muhtari_api8_fixture_oracle_controls PROPERTIES
    LABELS "muhtari-api8-fixture"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_fixture_oracle_controls: frame,video,audio,battery literals rejected"
    TIMEOUT 30)
  add_muhtari_api8_consumer_test(muhtari_api8_snapshot_contract
    muhtari_api8_consumer --snapshot-contract)
  set_tests_properties(muhtari_api8_snapshot_contract PROPERTIES
    LABELS "muhtari-api8-snapshot"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_snapshot_contract: capability, bounded capture, identity preflight, cross-instance replay, stale-load rejection, and receiver-local battery generation verified"
    TIMEOUT 30)
  add_test(
    NAME muhtari_api8_source_fresh_process
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_fresh_process_supervisor.sh"
      "$<TARGET_FILE:muhtari_api8_consumer>")
  file(APPEND "${_required_tests}" "muhtari_api8_source_fresh_process\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_source_fresh_process\n")
  file(APPEND "${_muhtari_api8_required_targets}"
    "muhtari_api8_consumer\n")
  set_tests_properties(muhtari_api8_source_fresh_process PROPERTIES
    LABELS "muhtari-api8-fresh-process"
    PASS_REGULAR_EXPRESSION
      "event=supervisor-success route=source result=pass"
    TIMEOUT 60)
  add_test(
    NAME muhtari_api8_source_oracle_controls
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_fresh_process_oracle_controls.sh"
      "$<TARGET_FILE:muhtari_api8_consumer>"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_fresh_process_supervisor.sh")
  file(APPEND "${_required_tests}" "muhtari_api8_source_oracle_controls\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_source_oracle_controls\n")
  set_tests_properties(muhtari_api8_source_oracle_controls PROPERTIES
    LABELS "muhtari-api8-fresh-process"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_source_oracle_controls: frame,video,audio,media,capability denied result=pass"
    TIMEOUT 60)
  add_test(
    NAME muhtari_api8_supervisor_controls
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_supervisor_controls.sh"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_fresh_process_supervisor.sh"
      "$<TARGET_FILE:muhtari_api8_consumer>")
  file(APPEND "${_required_tests}" "muhtari_api8_supervisor_controls\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_supervisor_controls\n")
  set_tests_properties(muhtari_api8_supervisor_controls PROPERTIES
    LABELS "muhtari-api8-evidence"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_supervisor_controls: lifecycle,ordering,custody,cleanup faults rejected result=pass"
    TIMEOUT 60)

  add_test(
    NAME muhtari_api8_validator_smoke
    COMMAND "${CMAKE_COMMAND}"
      -DRESULT_CASES=muhtari-api8-validator-smoke
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ValidateRequiredResults.cmake")
  file(APPEND "${_required_tests}" "muhtari_api8_validator_smoke\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_validator_smoke\n")
  set_tests_properties(muhtari_api8_validator_smoke PROPERTIES
    LABELS "muhtari-api8-evidence"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_validator_smoke: positive source-and-installed pair accepted; smoke does not qualify"
    TIMEOUT 30)

  add_test(
    NAME muhtari_api8_result_controls
    COMMAND "${CMAKE_COMMAND}"
      "-DPROJECT_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/muhtari_api8_result_controls.cmake")
  file(APPEND "${_required_tests}" "muhtari_api8_result_controls\n")
  file(APPEND "${_muhtari_api8_required_tests}" "muhtari_api8_result_controls\n")
  set_tests_properties(muhtari_api8_result_controls PROPERTIES
    LABELS "muhtari-api8-evidence"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_result_controls: positive pair accepted; evidence mutations rejected result=pass"
    TIMEOUT 60)

  add_test(
    NAME muhtari_api8_relocated_consumer
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/installed-consumer/relocate-muhtari-api8.sh"
      "${CMAKE_BINARY_DIR}")
  file(APPEND "${_required_tests}" "muhtari_api8_relocated_consumer\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_relocated_consumer\n")
  set_tests_properties(muhtari_api8_relocated_consumer PROPERTIES
    LABELS "muhtari-api8-installed"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_relocated_consumer: route=installed tests=6 result=pass"
    TIMEOUT 1200
    RUN_SERIAL TRUE)
endif()

if(LIBFUTURO_ENABLE_MUHTARI AND
   LIBFUTURO_MUHTARI_API_REVISION STREQUAL "8")
  add_test(
    NAME muhtari_api8_package_modes
    COMMAND "${CMAKE_COMMAND}"
      "-DPROJECT_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DPACKAGE_TEST_ROOT=${CMAKE_BINARY_DIR}"
      "-DPACKAGE_C_COMPILER=${CMAKE_C_COMPILER}"
      "-DPACKAGE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}"
      "-DPACKAGE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}"
      "-DPACKAGE_API8_BUILD=${CMAKE_BINARY_DIR}"
      "-DPACKAGE_API8_PREFIX=${CMAKE_INSTALL_PREFIX}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectMuhtariApi8Package.cmake")
  file(APPEND "${_required_tests}" "muhtari_api8_package_modes\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_package_modes\n")
  set_tests_properties(muhtari_api8_package_modes PROPERTIES
    LABELS "muhtari-api8-profile"
    PASS_REGULAR_EXPRESSION
      "muhtari_api8_package_modes: default-off=api8-selector,invalid=reject api7=exact-metadata api8=exact-metadata foreign-archive=config-rejected foreign-config=redirect-rejected result=pass"
    TIMEOUT 900)

  add_test(
    NAME muhtari_api8_contract
    COMMAND "${CMAKE_COMMAND}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckContract.cmake")
  file(APPEND "${_required_tests}" "muhtari_api8_contract\n")
  file(APPEND "${_muhtari_api8_required_tests}"
    "muhtari_api8_contract\n")
  set_tests_properties(muhtari_api8_contract PROPERTIES
    LABELS "muhtari-api8-contract"
    PASS_REGULAR_EXPRESSION
      "muhtari_documentation_contract: selectors, topology, media ownership, fixture provenance, pre-rename boundary, and local evidence limits verified"
    TIMEOUT 30)
endif()

if(LIBFUTURO_ENABLE_MUHTARI AND
   LIBFUTURO_MUHTARI_API_REVISION STREQUAL "7")
  add_executable(muhtari_session tests/installed-consumer/muhtari_session.c)
  target_link_libraries(muhtari_session PRIVATE libfuturo)
  target_compile_definitions(muhtari_session PRIVATE
    "LIBFUTURO_MUHTARI_SOURCE_REVISION=\"${_muhtari_verified_revision}\"")
  target_compile_options(muhtari_session PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(muhtari_session PRIVATE -fsanitize=address,undefined)
  add_required_consumer_test(muhtari_session muhtari_session)
  set_tests_properties(muhtari_session PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_session: source=${_muhtari_verified_revision} profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass"
    TIMEOUT 30)
  add_required_consumer_test(muhtari_load_refusals muhtari_session
    --load-refusals)
  set_tests_properties(muhtari_load_refusals PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_load_refusals: cases=8 histories=loaded,unloaded continuation=3 allocation-ordinals=measured default-reset=pass result=pass"
    TIMEOUT 60)
  add_required_consumer_test(muhtari_frame_boundaries muhtari_session
    --frame-boundaries)
  set_tests_properties(muhtari_frame_boundaries PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass"
    TIMEOUT 90)
  add_test(
    NAME muhtari_oracle_negative_control
    COMMAND "${CMAKE_COMMAND}"
      "-DMUHTARI_SESSION_EXE=$<TARGET_FILE:muhtari_session>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectMuhtariOracleFailure.cmake"
  )
  file(APPEND "${_required_tests}" "muhtari_oracle_negative_control\n")
  file(APPEND "${_required_targets}" "muhtari_session\n")
  set_tests_properties(muhtari_oracle_negative_control PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1"
    TIMEOUT 50)

  add_executable(muhtari_save_oracle_probe
    tests/installed-consumer/muhtari_save.c
    tests/installed-consumer/muhtari_oracle.h
    tests/installed-consumer/muhtari_save_oracle.h
  )
  target_link_libraries(muhtari_save_oracle_probe PRIVATE libfuturo)
  target_compile_definitions(muhtari_save_oracle_probe PRIVATE
    "LIBFUTURO_MUHTARI_SOURCE_REVISION=\"${_muhtari_verified_revision}\"")
  target_compile_options(muhtari_save_oracle_probe PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer
  )
  target_link_options(muhtari_save_oracle_probe PRIVATE
    -fsanitize=address,undefined
  )
  add_test(
    NAME muhtari_save_oracle_negative_control
    COMMAND "${CMAKE_COMMAND}"
      "-DMUHTARI_SAVE_EXE=$<TARGET_FILE:muhtari_save_oracle_probe>"
      "-DMUHTARI_SAVE_FIXTURE=${muhtari_SOURCE_DIR}/tests/diag/battery.a78"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectMuhtariOracleFailure.cmake"
  )
  file(APPEND "${_required_tests}" "muhtari_save_oracle_negative_control\n")
  file(APPEND "${_required_targets}" "muhtari_save_oracle_probe\n")
  set_tests_properties(muhtari_save_oracle_negative_control PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1"
    TIMEOUT 70
  )
  add_custom_target(muhtari_save_oracle_negative_control
    DEPENDS muhtari_save_oracle_probe
  )

  add_executable(muhtari_host examples/muhtari/main.c)
  target_link_libraries(muhtari_host PRIVATE libfuturo)
  target_compile_options(muhtari_host PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG)
  add_test(
    NAME muhtari_example
    COMMAND "${CMAKE_COMMAND}"
      "-DMUHTARI_SESSION_EXE=$<TARGET_FILE:muhtari_session>"
      "-DMUHTARI_HOST_EXE=$<TARGET_FILE:muhtari_host>"
      "-DMUHTARI_TEST_ROOT=${CMAKE_BINARY_DIR}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectMuhtariExample.cmake"
  )
  file(APPEND "${_required_tests}" "muhtari_example\n")
  file(APPEND "${_required_targets}" "muhtari_host\n")
  set_tests_properties(muhtari_example PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_example: fixture=owned-a78-linear-16k bytes=16512 sha256=783bcf1c6dd15433451c4d05f03bf8b7cd4d1923fb24cc50ee80548a5a904256 source=project-authored-C-generator license=Apache-2.0 example=partial-and-steady-public-session result=pass"
    TIMEOUT 60)

  add_test(
    NAME installed_macos_host
    COMMAND sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/installed-consumer/relocate-consumer.sh"
      --macos-host
  )
  file(APPEND "${_required_tests}" "installed_macos_host\n")
  set_tests_properties(installed_macos_host PROPERTIES
    RUN_SERIAL TRUE
    TIMEOUT 300)

  # The cumulative guest-limit seam is compiled into this private adapter
  # archive only; neither it nor its test symbol is installed or exported.
  add_library(muhtari_test_adapter STATIC src/muhtari_adapter.c)
  target_include_directories(muhtari_test_adapter PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  target_link_libraries(muhtari_test_adapter PRIVATE muhtari::muhtari)
  target_compile_definitions(muhtari_test_adapter PRIVATE
    LF_MUHTARI_TESTING=1
    "LF_MUHTARI_API_REVISION=${_muhtari_verified_api_revision}"
    "LF_MUHTARI_SOURCE_REVISION=\"${_muhtari_verified_revision}\"")
  target_compile_options(muhtari_test_adapter PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer)

  add_executable(muhtari_boundaries tests/muhtari_boundaries.c)
  target_include_directories(muhtari_boundaries PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests")
  target_link_libraries(muhtari_boundaries PRIVATE muhtari_test_adapter)
  target_compile_options(muhtari_boundaries PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(muhtari_boundaries PRIVATE -fsanitize=address,undefined)
  add_required_consumer_test(muhtari_guest_limit muhtari_boundaries)
  set_tests_properties(muhtari_guest_limit PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_guest_limit: cumulative=UINT32_MAX exact one-over=rejected zero-work=noop next-native-interval=oracle-match allocation-free-advances=4 create-failure-ordinals=complete setup-allocations=measured result=pass"
    TIMEOUT 45)

  add_test(
    NAME muhtari_test_seam_scope
    COMMAND "${CMAKE_COMMAND}"
      "-DNM_TOOL=${CMAKE_NM}"
      "-DPRODUCTION_ARCHIVE=$<TARGET_FILE:libfuturo>"
      "-DTEST_ADAPTER_ARCHIVE=$<TARGET_FILE:muhtari_test_adapter>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckMuhtariTestSeam.cmake"
  )
  file(APPEND "${_required_tests}" "muhtari_test_seam_scope\n")
  file(APPEND "${_required_targets}" "muhtari_test_adapter\n")
  set_tests_properties(muhtari_test_seam_scope PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_test_seam_scope: production=absent test=private result=pass"
    TIMEOUT 15)

  add_test(
    NAME muhtari_package_modes
    COMMAND "${CMAKE_COMMAND}"
      "-DPROJECT_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DPACKAGE_TEST_ROOT=${CMAKE_BINARY_DIR}"
      "-DPACKAGE_C_COMPILER=${CMAKE_C_COMPILER}"
      "-DPACKAGE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}"
      "-DPACKAGE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}"
      "-DPACKAGE_SOURCE_BUILD=${CMAKE_BINARY_DIR}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectMuhtariPackage.cmake"
  )
  file(APPEND "${_required_tests}" "muhtari_package_modes\n")
  set_tests_properties(muhtari_package_modes PROPERTIES
    PASS_REGULAR_EXPRESSION
      "muhtari_package_modes: default-off=consumer,artifacts,profile-unavailable core-target-conflicts=nesturbator,muhtari pipe-prefix=accepted override=exact-source-gate result=pass"
    TIMEOUT 600)
endif()
set(_muhtari_archive_argument "")
if(LIBFUTURO_ENABLE_MUHTARI)
  set(_muhtari_archive_argument "$<TARGET_FILE:muhtari>")
endif()
add_test(
  NAME oracle_negative_control
  COMMAND "${CMAKE_COMMAND}"
    "-DSYNTHETIC_SESSION_EXE=$<TARGET_FILE:synthetic_session>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectOracleFailure.cmake"
)
file(APPEND "${_required_tests}" "oracle_negative_control\n")
set_tests_properties(oracle_negative_control PROPERTIES TIMEOUT 15)

add_executable(synthetic_boundaries tests/synthetic_boundaries.c)
target_link_libraries(synthetic_boundaries PRIVATE libfuturo_test)
add_required_consumer_test(synthetic_boundaries synthetic_boundaries)

add_executable(nesturbator_probe tests/nesturbator_probe.c)
target_link_libraries(nesturbator_probe PRIVATE nesturbator::nesturbator)
target_compile_definitions(nesturbator_probe PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_probe nesturbator_probe)
set_tests_properties(nesturbator_probe PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_probe: source=2338608ab184f040620a30d17756f5e06a42d4e3 lifecycle=create,destroy result=pass"
  TIMEOUT 15
)

add_executable(nesturbator_session tests/nesturbator_session.c)
target_link_libraries(nesturbator_session PRIVATE libfuturo_test)
target_include_directories(nesturbator_session PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
target_compile_definitions(nesturbator_session PRIVATE
  LF_NESTURBATOR_TESTING=1
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_session nesturbator_session)
set_tests_properties(nesturbator_session PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_session: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom load,input,frame,av,close result=pass"
  TIMEOUT 30
)
add_executable(nesturbator_source_snapshot_capability_controls
  tests/nesturbator_snapshot_capability_controls.c)
target_link_libraries(nesturbator_source_snapshot_capability_controls PRIVATE
  libfuturo_test)
target_include_directories(nesturbator_source_snapshot_capability_controls
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_definitions(nesturbator_source_snapshot_capability_controls
  PRIVATE
    LF_NESTURBATOR_TESTING=1
    "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_source_snapshot_capability_controls
  nesturbator_source_snapshot_capability_controls)
set_tests_properties(nesturbator_source_snapshot_capability_controls
  PROPERTIES PASS_REGULAR_EXPRESSION
    "snapshot_capability_controls: route=source entries=A,B denied=zero-snapshot-calls result=pass"
  TIMEOUT 30)

add_executable(nesturbator_installed_snapshot_capability_controls
  tests/nesturbator_snapshot_capability_controls.c)
target_link_libraries(nesturbator_installed_snapshot_capability_controls
  PRIVATE libfuturo)
target_include_directories(nesturbator_installed_snapshot_capability_controls
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/tests")
target_compile_definitions(nesturbator_installed_snapshot_capability_controls
  PRIVATE
    SNAPSHOT_CONTROL_INSTALLED=1
    "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_installed_snapshot_capability_controls
  nesturbator_installed_snapshot_capability_controls)
set_tests_properties(nesturbator_installed_snapshot_capability_controls
  PROPERTIES PASS_REGULAR_EXPRESSION
    "snapshot_capability_controls: route=installed entries=A,B denied=zero-snapshot-calls result=pass"
  TIMEOUT 30)

add_required_consumer_test(nesturbator_snapshot_replay nesturbator_session
  --snapshot-replay
)
set_tests_properties(nesturbator_snapshot_replay PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_snapshot_replay: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom capability,capture,replay=frame3,ticks2144304,av-literal result=pass"
  TIMEOUT 60
)
add_test(
  NAME nesturbator_fresh_process_snapshot
  COMMAND "${CMAKE_COMMAND}"
    "-DNESTURBATOR_SESSION_EXE=$<TARGET_FILE:nesturbator_session>"
    "-DSOURCE_LIBFUTURO_ARCHIVE=$<TARGET_FILE:libfuturo_test>"
    "-DSOURCE_NESTURBATOR_ARCHIVE=$<TARGET_FILE:nesturbator::nesturbator>"
    "-DSOURCE_SUPERVISOR=${CMAKE_CURRENT_SOURCE_DIR}/tests/nesturbator_fresh_process_supervisor.sh"
    "-DSOURCE_PROCESS_HELPER=${CMAKE_CURRENT_SOURCE_DIR}/scripts/process-tree-cleanup.sh"
    "-DSOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
    "-DSOURCE_REPORT=${CMAKE_CURRENT_BINARY_DIR}/fresh-process-source-report.txt"
    "-DSOURCE_COMMIT=${LIBFUTURO_GIT_REVISION}"
    "-DSOURCE_LIBFUTURO_BUILD_ID=${_libfuturo_test_build_id}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectNesturbatorFreshProcessSnapshot.cmake"
)
file(APPEND "${_required_tests}" "nesturbator_fresh_process_snapshot\n")
file(APPEND "${_required_targets}" "nesturbator_session\n")
set_tests_properties(nesturbator_fresh_process_snapshot PROPERTIES
  PASS_REGULAR_EXPRESSION "event=supervisor-success"
  TIMEOUT 120
)
add_test(
  NAME nesturbator_battery_fresh_process_snapshot
  COMMAND "${CMAKE_COMMAND}"
    "-DNESTURBATOR_SESSION_EXE=$<TARGET_FILE:nesturbator_session>"
    "-DSOURCE_LIBFUTURO_ARCHIVE=$<TARGET_FILE:libfuturo_test>"
    "-DSOURCE_NESTURBATOR_ARCHIVE=$<TARGET_FILE:nesturbator::nesturbator>"
    "-DSOURCE_SUPERVISOR=${CMAKE_CURRENT_SOURCE_DIR}/tests/nesturbator_fresh_process_supervisor.sh"
    "-DSOURCE_PROCESS_HELPER=${CMAKE_CURRENT_SOURCE_DIR}/scripts/process-tree-cleanup.sh"
    "-DSOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
    "-DSOURCE_REPORT=${CMAKE_CURRENT_BINARY_DIR}/battery-fresh-process-source-report.txt"
    "-DSOURCE_MODE=battery"
    "-DSOURCE_COMMIT=${LIBFUTURO_GIT_REVISION}"
    "-DSOURCE_LIBFUTURO_BUILD_ID=${_libfuturo_test_build_id}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectNesturbatorFreshProcessSnapshot.cmake"
)
set_tests_properties(nesturbator_battery_fresh_process_snapshot PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_battery_fresh_process_snapshot: result=pass"
  TIMEOUT 180
)
file(APPEND "${_required_tests}" "nesturbator_battery_fresh_process_snapshot\n")
file(APPEND "${_required_targets}" "nesturbator_session\n")
add_test(
  NAME nesturbator_fresh_process_supervisor_controls
  COMMAND /bin/sh
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/nesturbator_supervisor_controls.sh"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/nesturbator_fresh_process_supervisor.sh"
)
file(APPEND "${_required_tests}"
  "nesturbator_fresh_process_supervisor_controls\n")
file(APPEND "${_required_targets}" "nesturbator_session\n")
set_tests_properties(nesturbator_fresh_process_supervisor_controls PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_supervisor_controls: failure-stops, battery-failure-stops, valid-order-starts-b result=pass"
  TIMEOUT 60
)
add_required_consumer_test(nesturbator_snapshot_refusals nesturbator_session
  --snapshot-refusals
)
set_tests_properties(nesturbator_snapshot_refusals PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_snapshot_refusals: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom cases=envelope,native,foreign-content,battery,session-overflow,reloaded-capacity continuation=literal result=pass"
  TIMEOUT 60
)
add_required_consumer_test(nesturbator_snapshot_oracle_control nesturbator_session
  --snapshot-wrong-expected
)
set_tests_properties(nesturbator_snapshot_oracle_control PROPERTIES
  PASS_REGULAR_EXPRESSION "snapshot replay failed at stage 5"
  TIMEOUT 45
)
add_required_consumer_test(nesturbator_battery_snapshot_recovery
  nesturbator_session --snapshot-battery)
set_tests_properties(nesturbator_battery_snapshot_recovery PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_battery_snapshot: route=source source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass"
  TIMEOUT 60
)
add_required_consumer_test(nesturbator_battery_snapshot_oracle_control
  nesturbator_session --snapshot-battery-wrong-expected)
set_tests_properties(nesturbator_battery_snapshot_oracle_control PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_battery_snapshot_oracle_control: route=source progress,video,audio,media=rejected result=pass"
  TIMEOUT 45
)
add_executable(nesturbator_load_corpus tests/nesturbator_load_corpus.c)
target_link_libraries(nesturbator_load_corpus PRIVATE libfuturo_test)
target_compile_definitions(nesturbator_load_corpus PRIVATE
  "LIBFUTURO_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\"")
add_required_consumer_test(nesturbator_load_corpus nesturbator_load_corpus
  --all
)
set_tests_properties(nesturbator_load_corpus PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=all executed=307/expected=307 immediate-media=full continuation-frames=3 assertion-complete=true result=pass"
  TIMEOUT 180
)
add_required_consumer_test(nesturbator_load_allocations nesturbator_load_corpus
  --allocations
)
set_tests_properties(nesturbator_load_allocations PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=allocations layout_count=21 observed_ordinals=complete histories=unloaded,loaded ownership-balanced=true assertion-complete=true result=pass"
  TIMEOUT 180
)
add_required_consumer_test(nesturbator_load_positives nesturbator_load_corpus
  --positives
)
set_tests_properties(nesturbator_load_positives PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=positives cases=default-explicit,replacement-reset,trainer-p05 assertion-complete=true result=pass"
  TIMEOUT 30
)
add_required_consumer_test(nesturbator_ines_legacy_chr_ram nesturbator_load_corpus
  --ines-legacy-chr-ram
)
set_tests_properties(nesturbator_ines_legacy_chr_ram PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 mode=ines-v1-implicit-chr-ram case=I04-01 status=LF_OK continuation-frames=3 result=pass"
  TIMEOUT 30
)
add_test(
  NAME nesturbator_load_oracle_controls
  COMMAND "${CMAKE_COMMAND}"
    "-DNESTURBATOR_LOAD_CORPUS_EXE=$<TARGET_FILE:nesturbator_load_corpus>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectNesturbatorLoadFailure.cmake"
)
file(APPEND "${_required_tests}" "nesturbator_load_oracle_controls\n")
file(APPEND "${_required_targets}" "nesturbator_load_corpus\n")
set_tests_properties(nesturbator_load_oracle_controls PROPERTIES
  PASS_REGULAR_EXPRESSION
    "nesturbator_load_oracle_controls: normal=pass wrong-status=ordinary-mismatch divergence=media-bytes offset=0 result=pass"
  TIMEOUT 50
)
add_test(
  NAME instrumentation_scope
  COMMAND "${CMAKE_COMMAND}"
    "-DMODE=all"
    "-DCOMPILE_COMMANDS=${CMAKE_BINARY_DIR}/compile_commands.json"
    "-DUNIT_LIST=${CMAKE_BINARY_DIR}/instrumented-core-units.txt"
    "-DPROJECT_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
    "-DNESTURBATOR_SOURCE_DIR=${nesturbator_SOURCE_DIR}"
    "-DBUILD_DIR=${CMAKE_BINARY_DIR}"
    "-DSCOPE_OUTPUT=${CMAKE_BINARY_DIR}/instrumentation-scope.txt"
    "-DLIBFUTURO_ARCHIVE=$<TARGET_FILE:libfuturo>"
    "-DNESTURBATOR_ARCHIVE=$<TARGET_FILE:nesturbator>"
    "-DINSTRUMENTED_ARCHIVE=$<TARGET_FILE:nesturbator_instrumented>"
    "-DNM_TOOL=${CMAKE_NM}"
    "-DCORPUS_LINK_COMMAND=${CMAKE_BINARY_DIR}/CMakeFiles/nesturbator_load_corpus.dir/link.txt"
    "-DCORPUS_EXECUTABLE=$<TARGET_FILE:nesturbator_load_corpus>"
    "-DNESTURBATOR_REVISION=${_nesturbator_verified_revision}"
    "-DLIBFUTURO_MUHTARI_ENABLED=${LIBFUTURO_ENABLE_MUHTARI}"
    "-DMUHTARI_SOURCE_DIR=${muhtari_SOURCE_DIR}"
    "-DMUHTARI_REVISION=${_muhtari_verified_revision}"
    "-DMUHTARI_ARCHIVE=${_muhtari_archive_argument}"
    "-DCOMPILER_ID=${CMAKE_C_COMPILER_ID}"
    "-DCOMPILER_VERSION=${CMAKE_C_COMPILER_VERSION}"
    "-DTARGET_PROFILE=${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}-${CMAKE_OSX_ARCHITECTURES}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckInstrumentationScope.cmake"
)
file(APPEND "${_required_tests}" "instrumentation_scope\n")
set_tests_properties(instrumentation_scope PROPERTIES
  PASS_REGULAR_EXPRESSION
    "instrumentation_scope: controls=10 actual_units=23 normal_archives=clean assertion-complete=true result=pass"
  TIMEOUT 15
)
add_test(
  NAME nesturbator_save_restart
  COMMAND "${CMAKE_COMMAND}"
    "-DNESTURBATOR_SESSION_EXE=$<TARGET_FILE:nesturbator_session>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectNesturbatorSaveRestart.cmake"
)
file(APPEND "${_required_tests}" "nesturbator_save_restart\n")
file(APPEND "${_required_targets}" "nesturbator_session\n")
# The fixture, digest, and four consumer-process budgets total 100 seconds;
# leave 50 seconds for CMake and CTest overhead and cleanup diagnostics.
set_tests_properties(nesturbator_save_restart PROPERTIES TIMEOUT 150)
add_required_consumer_test(nesturbator_load_failures nesturbator_session --load-failures)
set_tests_properties(nesturbator_load_failures PROPERTIES TIMEOUT 60)
add_required_consumer_test(nesturbator_frame_failures nesturbator_session
  --frame-failures
)
set_tests_properties(nesturbator_frame_failures PROPERTIES TIMEOUT 30)
add_test(
  NAME nesturbator_oracle_negative_control
  COMMAND "${CMAKE_COMMAND}"
    "-DNESTURBATOR_SESSION_EXE=$<TARGET_FILE:nesturbator_session>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectNesturbatorOracleFailure.cmake"
)
file(APPEND "${_required_tests}" "nesturbator_oracle_negative_control\n")
set_tests_properties(nesturbator_oracle_negative_control PROPERTIES TIMEOUT 30)

add_executable(conformance_positive tests/conformance.c)
target_link_libraries(conformance_positive PRIVATE libfuturo_test)

# Keep these deliberate implementation defects in private test-only libraries.
# The install/export rules above continue to publish only the normal target.
function(add_conformance_variant executable_name library_name variant_definition)
  add_library(${library_name} STATIC
    src/synthetic.c
    src/nesturbator_adapter.c
    src/sha256.c
  )
  target_link_libraries(${library_name} PRIVATE nesturbator::nesturbator)
  target_include_directories(${library_name} PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  )
  target_compile_definitions(${library_name} PRIVATE
    "LF_NESTURBATOR_SOURCE_REVISION=\"${_nesturbator_verified_revision}\""
    "${variant_definition}=1"
  )
  lf_compute_build_fingerprint(${library_name} _variant_build_id)
  target_compile_definitions(${library_name} PRIVATE
    "LF_BUILD_ID=\"${_variant_build_id}\"")
  add_executable(${executable_name} tests/conformance.c)
  target_link_libraries(${executable_name} PRIVATE ${library_name})
endfunction()

add_conformance_variant(conformance_clear_on_unsupported_load
  conformance_clear_on_unsupported_load_core
  LF_CONFORMANCE_VARIANT_CLEAR_ON_UNSUPPORTED_LOAD
)
add_conformance_variant(conformance_double_guest_units
  conformance_double_guest_units_core
  LF_CONFORMANCE_VARIANT_DOUBLE_GUEST_UNITS
)
add_custom_target(conformance DEPENDS
  conformance_positive
  conformance_clear_on_unsupported_load
  conformance_double_guest_units
)
add_test(
  NAME conformance
  COMMAND "${CMAKE_COMMAND}"
    "-DCONFORMANCE_EXE=$<TARGET_FILE:conformance_positive>"
    "-DCONFORMANCE_LOAD_VARIANT_EXE=$<TARGET_FILE:conformance_clear_on_unsupported_load>"
    "-DCONFORMANCE_TIME_VARIANT_EXE=$<TARGET_FILE:conformance_double_guest_units>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ExpectConformanceFailure.cmake"
)
file(APPEND "${_required_tests}" "conformance\n")
file(APPEND "${_required_targets}" "conformance\n")
set_tests_properties(conformance PROPERTIES TIMEOUT 45)

add_test(
  NAME required_result_controls
  COMMAND "${CMAKE_COMMAND}"
    -DRESULT_CASES=all
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ValidateRequiredResults.cmake"
)
file(APPEND "${_required_tests}" "required_result_controls\n")
set_tests_properties(required_result_controls PROPERTIES TIMEOUT 15)
add_custom_target(required_result_controls
  COMMAND "${CMAKE_COMMAND}"
    -DRESULT_CASES=all
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ValidateRequiredResults.cmake"
  VERBATIM
)

add_test(
  NAME process_tree_cleanup
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/scripts/probe-process-tree-cleanup.sh"
)
file(APPEND "${_required_tests}" "process_tree_cleanup\n")
set_tests_properties(process_tree_cleanup PROPERTIES TIMEOUT 36)

add_test(
  NAME contract_traceability
  COMMAND "${CMAKE_COMMAND}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CheckContract.cmake"
)
file(APPEND "${_required_tests}" "contract_traceability\n")
set_tests_properties(contract_traceability PROPERTIES TIMEOUT 15)

file(STRINGS "${_required_tests}" _registered_required_tests)
foreach(test_name IN LISTS _registered_required_tests)
  get_property(_test_timeout_is_set TEST "${test_name}" PROPERTY TIMEOUT SET)
  if(NOT _test_timeout_is_set)
    message(FATAL_ERROR
      "Required CTest '${test_name}' must have an explicit execution timeout")
  endif()
  get_property(_test_timeout TEST "${test_name}" PROPERTY TIMEOUT)
  if(NOT _test_timeout MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR
      "Required CTest '${test_name}' has invalid execution timeout '${_test_timeout}'")
  endif()
endforeach()

file(WRITE "${_required_route_results}" "")
foreach(test_name IN LISTS _registered_required_tests)
  file(APPEND "${_required_route_results}" "ctest|${test_name}|required\n")
endforeach()
file(APPEND "${_required_route_results}"
  "consumer|installed_consumer_save_restart|required\n"
  "consumer|installed_consumer_snapshot|required\n"
  "consumer|source_fresh_process_snapshot|required\n"
  "consumer|installed_consumer_fresh_process_snapshot|required\n"
  "consumer|source_battery_fresh_process_snapshot|required\n"
  "consumer|installed_consumer_battery_fresh_process_snapshot|required\n"
  "consumer|installed_consumer_battery_snapshot|required\n"
  "consumer|installed_consumer_load_refusal|required\n"
  "consumer|installed_muhtari_session|required\n"
  "consumer|installed_muhtari_save_restart|required\n"
  "consumer|installed_macos_host|required\n"
  "unsupported|hosted_current_profile|unsupported\n"
)

set(_owned_c_targets
  libfuturo_test synthetic_host synthetic_session synthetic_boundaries nesturbator_probe
  nesturbator_session nesturbator_source_snapshot_capability_controls
  nesturbator_installed_snapshot_capability_controls nesturbator_load_corpus conformance_positive
  conformance_clear_on_unsupported_load_core conformance_clear_on_unsupported_load
  conformance_double_guest_units_core conformance_double_guest_units
)
foreach(target_name IN LISTS _owned_c_targets)
  target_compile_options("${target_name}" PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
    -fsanitize=address,undefined -fno-omit-frame-pointer
  )
endforeach()
target_link_options(synthetic_host PRIVATE -fsanitize=address,undefined)
target_link_options(synthetic_session PRIVATE -fsanitize=address,undefined)
target_link_options(synthetic_boundaries PRIVATE -fsanitize=address,undefined)
target_link_options(nesturbator_probe PRIVATE -fsanitize=address,undefined)
target_link_options(nesturbator_session PRIVATE -fsanitize=address,undefined)
target_link_options(nesturbator_source_snapshot_capability_controls PRIVATE
  -fsanitize=address,undefined)
target_link_options(nesturbator_installed_snapshot_capability_controls PRIVATE
  -fsanitize=address,undefined)
target_link_options(nesturbator_load_corpus PRIVATE
  -fsanitize=address,undefined
)
target_link_options(conformance_positive PRIVATE -fsanitize=address,undefined)
target_link_options(conformance_clear_on_unsupported_load PRIVATE
  -fsanitize=address,undefined
)
target_link_options(conformance_double_guest_units PRIVATE
  -fsanitize=address,undefined
)
