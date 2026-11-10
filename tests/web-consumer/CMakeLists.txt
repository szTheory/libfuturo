cmake_minimum_required(VERSION 3.25)
project(libfuturo_web_consumer LANGUAGES C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

foreach(required EXPECTED_INSTALL_PREFIX EXPECTED_MUHTARI_VERSION
    EXPECTED_MUHTARI_API_REVISION EXPECTED_MUHTARI_SOURCE_REVISION
    EXPECTED_LIBFUTURO_SOURCE_REVISION EXPECTED_PROFILE_ID
    EXPECTED_CONFIGURATION_ID EXPECTED_SDK_IMAGE EXPECTED_SDK_PLATFORM
    EXPECTED_FIXTURE_SHA256)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required for the relocated browser consumer")
  endif()
endforeach()

file(REAL_PATH "${EXPECTED_INSTALL_PREFIX}" _expected_prefix)
if(NOT EXISTS "${_expected_prefix}/lib/cmake/libfuturo-web/libfuturo_webConfig.cmake")
  message(FATAL_ERROR "The relocated libfuturo web package is missing")
endif()

# Resolve exactly one installed package config. No checkout, build, or staging
# prefix is supplied as a fallback search path.
set(libfuturo_web_DIR "${_expected_prefix}/lib/cmake/libfuturo-web")
find_package(libfuturo_web CONFIG REQUIRED NO_DEFAULT_PATH)

if(NOT "${libfuturo_web_CORE_VERSION}" STREQUAL "${EXPECTED_MUHTARI_VERSION}" OR
   NOT "${libfuturo_web_CORE_API_REVISION}" STREQUAL "${EXPECTED_MUHTARI_API_REVISION}" OR
   NOT "${libfuturo_web_CORE_SOURCE_REVISION}" STREQUAL "${EXPECTED_MUHTARI_SOURCE_REVISION}" OR
   NOT "${libfuturo_web_PROFILE_ID}" STREQUAL "${EXPECTED_PROFILE_ID}" OR
   NOT "${libfuturo_web_CONFIGURATION_ID}" STREQUAL "${EXPECTED_CONFIGURATION_ID}" OR
   NOT "${libfuturo_web_SDK_IMAGE}" STREQUAL "${EXPECTED_SDK_IMAGE}" OR
   NOT "${libfuturo_web_SDK_PLATFORM}" STREQUAL "${EXPECTED_SDK_PLATFORM}" OR
   NOT "${libfuturo_web_SOURCE_REVISION}" STREQUAL "${EXPECTED_LIBFUTURO_SOURCE_REVISION}")
  message(FATAL_ERROR "Installed browser package identity differs from the selected route")
endif()
string(LENGTH "${EXPECTED_FIXTURE_SHA256}" _fixture_digest_length)
if(NOT _fixture_digest_length EQUAL 64 OR
   NOT EXPECTED_FIXTURE_SHA256 MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "The generated fixture digest metadata is malformed")
endif()
string(LENGTH "${libfuturo_web_BUILD_ID}" _web_build_id_length)
if(NOT _web_build_id_length EQUAL 71 OR
   NOT libfuturo_web_BUILD_ID MATCHES "^sha256:")
  message(FATAL_ERROR "Installed LibFuturo build identity is malformed")
endif()
string(SUBSTRING "${libfuturo_web_BUILD_ID}" 7 -1 _web_build_digest)
string(LENGTH "${libfuturo_web_TOOLCHAIN_ID}" _toolchain_id_length)
if(NOT libfuturo_web_CORE STREQUAL "muhtari" OR
   NOT libfuturo_web_CORE_ABI_REVISION STREQUAL "1" OR
   NOT libfuturo_web_CORE_BEHAVIOR_REVISION STREQUAL "6" OR
   NOT _web_build_digest MATCHES "^[0-9a-f]+$" OR
   NOT _toolchain_id_length EQUAL 64 OR
   NOT libfuturo_web_TOOLCHAIN_ID MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "Installed browser package identity is incomplete or unsupported")
endif()
if(NOT TARGET libfuturo::web)
  message(FATAL_ERROR "The relocated package did not provide libfuturo::web")
endif()

set(_web_archive "")
foreach(_property IMPORTED_LOCATION IMPORTED_LOCATION_NOCONFIG
    IMPORTED_LOCATION_RELEASE IMPORTED_LOCATION_RELWITHDEBINFO
    IMPORTED_LOCATION_MINSIZEREL IMPORTED_LOCATION_DEBUG)
  get_target_property(_candidate libfuturo::web "${_property}")
  if(_candidate AND NOT _candidate MATCHES "-NOTFOUND$")
    set(_web_archive "${_candidate}")
    break()
  endif()
endforeach()
get_target_property(_web_includes libfuturo::web INTERFACE_INCLUDE_DIRECTORIES)
if(NOT _web_archive OR NOT EXISTS "${_web_archive}")
  message(FATAL_ERROR "The installed public web archive is missing")
endif()
file(REAL_PATH "${_web_archive}" _web_archive_real)
string(FIND "${_web_archive_real}" "${_expected_prefix}/" _archive_prefix_index)
if(NOT _archive_prefix_index EQUAL 0)
  message(FATAL_ERROR "The imported web archive escaped the relocated prefix")
endif()
if(NOT _web_includes)
  message(FATAL_ERROR "The installed web target has no public include directory")
endif()
foreach(_include IN LISTS _web_includes)
  file(REAL_PATH "${_include}" _include_real)
  string(FIND "${_include_real}" "${_expected_prefix}/" _include_prefix_index)
  if(NOT _include_prefix_index EQUAL 0)
    message(FATAL_ERROR "The public include path escaped the relocated prefix: ${_include_real}")
  endif()
endforeach()
get_target_property(_web_links libfuturo::web INTERFACE_LINK_LIBRARIES)
if(_web_links AND _web_links MATCHES "[Nn]esturbator")
  message(FATAL_ERROR "The relocated browser target links forbidden Nesturbator")
endif()

message(STATUS "consumer_package: config=${libfuturo_web_DIR}")
message(STATUS "consumer_package: archive=${_web_archive_real}")
message(STATUS "consumer_package: source=${libfuturo_web_SOURCE_REVISION} core=${libfuturo_web_CORE_SOURCE_REVISION} api=${libfuturo_web_CORE_API_REVISION} abi=${libfuturo_web_CORE_ABI_REVISION} behavior=${libfuturo_web_CORE_BEHAVIOR_REVISION}")

add_executable(libfuturo_web_consumer consumer.c)
target_link_libraries(libfuturo_web_consumer PRIVATE libfuturo::web)
target_compile_definitions(libfuturo_web_consumer PRIVATE
  "EXPECTED_PROFILE_ID=\"${EXPECTED_PROFILE_ID}\""
  "EXPECTED_CONFIGURATION_ID=\"${EXPECTED_CONFIGURATION_ID}\""
  "EXPECTED_CORE_BUILD_ID=\"muhtari-${EXPECTED_MUHTARI_SOURCE_REVISION}\""
  "EXPECTED_LIBFUTURO_BUILD_ID=\"${libfuturo_web_BUILD_ID}\""
  "EXPECTED_FIXTURE_SHA256=\"${EXPECTED_FIXTURE_SHA256}\"")
target_link_options(libfuturo_web_consumer PRIVATE
  "-sENVIRONMENT=web"
  "-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16"
  "-sEXIT_RUNTIME=1")
set_target_properties(libfuturo_web_consumer PROPERTIES
  OUTPUT_NAME consumer
  SUFFIX ".js"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts")
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts")
configure_file(consumer.html "${CMAKE_BINARY_DIR}/artifacts/consumer.html" COPYONLY)
configure_file(consumer-host.js "${CMAKE_BINARY_DIR}/artifacts/consumer-host.js" COPYONLY)
configure_file(
  ../installed-macos-host/MUHTARI-PALETTE-NOTICES.md
  "${CMAKE_BINARY_DIR}/artifacts/MUHTARI-PALETTE-NOTICES.md"
  COPYONLY)
