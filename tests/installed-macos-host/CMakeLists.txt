cmake_minimum_required(VERSION 3.25)
project(libfuturo_installed_macos_host LANGUAGES C OBJC)
include(CTest)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(NOT DEFINED EXPECTED_INSTALL_PREFIX OR EXPECTED_INSTALL_PREFIX STREQUAL "")
  message(FATAL_ERROR "EXPECTED_INSTALL_PREFIX is required")
endif()
if(NOT DEFINED MUHTARI_FIXTURE_PATH OR MUHTARI_FIXTURE_PATH STREQUAL "")
  message(FATAL_ERROR "MUHTARI_FIXTURE_PATH is required")
endif()
if(NOT EXISTS "${MUHTARI_FIXTURE_PATH}")
  message(FATAL_ERROR "MUHTARI_FIXTURE_PATH does not exist")
endif()
if(NOT DEFINED MUHTARI_ORACLE_INCLUDE_DIR OR
   NOT EXISTS "${MUHTARI_ORACLE_INCLUDE_DIR}/muhtari_oracle.h")
  message(FATAL_ERROR "MUHTARI_ORACLE_INCLUDE_DIR must contain muhtari_oracle.h")
endif()

file(REAL_PATH "${EXPECTED_INSTALL_PREFIX}" _expected_prefix)
file(MAKE_DIRECTORY "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}")
file(WRITE "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/nesturbator-config.cmake"
  "message(FATAL_ERROR \"ambient Nesturbator redirect was selected\")\n")
file(WRITE "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/muhtari-config.cmake"
  "message(FATAL_ERROR \"ambient Muhtari redirect was selected\")\n")

find_package(libfuturo CONFIG REQUIRED
  PATHS "${_expected_prefix}/lib/cmake/libfuturo"
  NO_DEFAULT_PATH
)
if(NOT TARGET libfuturo::libfuturo OR
   NOT TARGET nesturbator::nesturbator OR
   NOT TARGET muhtari::muhtari)
  message(FATAL_ERROR "installed package did not provide all pinned targets")
endif()
if(NOT libfuturo_MUHTARI_ENABLED)
  message(FATAL_ERROR "installed package does not enable the Muhtari profile")
endif()

function(assert_under_prefix candidate description)
  if(NOT EXISTS "${candidate}")
    message(FATAL_ERROR "${description} does not exist")
  endif()
  file(REAL_PATH "${candidate}" _real_candidate)
  string(FIND "${_real_candidate}" "${_expected_prefix}/" _prefix_index)
  if(NOT _prefix_index EQUAL 0)
    message(FATAL_ERROR "${description} escaped the moved prefix")
  endif()
endfunction()

function(assert_imported_archive target description output_variable)
  foreach(property IMPORTED_LOCATION IMPORTED_LOCATION_NOCONFIG
      IMPORTED_LOCATION_DEBUG IMPORTED_LOCATION_RELEASE
      IMPORTED_LOCATION_RELWITHDEBINFO IMPORTED_LOCATION_MINSIZEREL)
    get_target_property(candidate "${target}" "${property}")
    if(candidate AND NOT candidate MATCHES "-NOTFOUND$")
      assert_under_prefix("${candidate}" "${description} archive")
      set("${output_variable}" "${candidate}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR "${target} has no imported archive location")
endfunction()

assert_under_prefix("${libfuturo_DIR}/libfuturoConfig.cmake"
  "libfuturo package config")
assert_under_prefix("${nesturbator_DIR}/nesturbatorConfig.cmake"
  "Nesturbator package config")
assert_under_prefix("${muhtari_DIR}/muhtariConfig.cmake"
  "Muhtari package config")
assert_imported_archive(libfuturo::libfuturo libfuturo _libfuturo_archive)
assert_imported_archive(nesturbator::nesturbator Nesturbator _nesturbator_archive)
assert_imported_archive(muhtari::muhtari Muhtari _muhtari_archive)
assert_under_prefix("${_expected_prefix}/include/libfuturo/libfuturo.h"
  "libfuturo public header")
assert_under_prefix("${_expected_prefix}/include/muhtari.h"
  "Muhtari public header")

get_target_property(_nesturbator_includes nesturbator::nesturbator
  INTERFACE_INCLUDE_DIRECTORIES)
set(_nesturbator_header_found FALSE)
foreach(include_directory IN LISTS _nesturbator_includes)
  if(IS_ABSOLUTE "${include_directory}" AND IS_DIRECTORY "${include_directory}")
    file(GLOB_RECURSE _nesturbator_headers "${include_directory}/*.h")
    if(_nesturbator_headers)
      list(GET _nesturbator_headers 0 _nesturbator_header)
      assert_under_prefix("${_nesturbator_header}" "Nesturbator public header")
      set(_nesturbator_header_found TRUE)
      break()
    endif()
  endif()
endforeach()
if(NOT _nesturbator_header_found)
  message(FATAL_ERROR "installed Nesturbator public header is missing")
endif()

message(STATUS
  "installed_macos_host_packages: libfuturo=relocated Nesturbator=relocated Muhtari=relocated")

file(RELATIVE_PATH _libfuturo_package_relative
  "${_expected_prefix}" "${libfuturo_DIR}")
file(RELATIVE_PATH _nesturbator_package_relative
  "${_expected_prefix}" "${nesturbator_DIR}")
file(RELATIVE_PATH _muhtari_package_relative
  "${_expected_prefix}" "${muhtari_DIR}")
file(WRITE "${CMAKE_BINARY_DIR}/package-resolution.txt"
  "format=libfuturo-host-package-resolution-v1\n"
  "libfuturo=${_libfuturo_package_relative}\n"
  "nesturbator=${_nesturbator_package_relative}\n"
  "muhtari=${_muhtari_package_relative}\n")

find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(UNIFORMTYPEIDENTIFIERS_FRAMEWORK UniformTypeIdentifiers REQUIRED)
find_library(AVFAUDIO_FRAMEWORK AVFAudio REQUIRED)
find_program(CODESIGN_EXECUTABLE codesign REQUIRED)

add_executable(installed_macos_host MACOSX_BUNDLE
  main.m LFHostSession.m LFContentReader.m LFInputState.m LFDisplayAdapter.m
  LFAudioBufferPool.c LFAudioOutput.m)
set_target_properties(installed_macos_host PROPERTIES
  MACOSX_BUNDLE_GUI_IDENTIFIER org.libfuturo.installed-host
  MACOSX_BUNDLE_BUNDLE_NAME libfuturo
  MACOSX_BUNDLE_SHORT_VERSION_STRING 0.1
  MACOSX_BUNDLE_BUNDLE_VERSION 0.1.0
)
add_custom_command(TARGET installed_macos_host POST_BUILD
  COMMAND "${CODESIGN_EXECUTABLE}" --force --sign -
    "$<TARGET_BUNDLE_DIR:installed_macos_host>"
  COMMENT "Signing the completed host app bundle"
  VERBATIM
)
target_link_libraries(installed_macos_host PRIVATE
  libfuturo::libfuturo
  "${APPKIT_FRAMEWORK}"
  "${FOUNDATION_FRAMEWORK}"
  "${QUARTZCORE_FRAMEWORK}"
  "${COREGRAPHICS_FRAMEWORK}"
  "${UNIFORMTYPEIDENTIFIERS_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(installed_macos_host PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_tracer
  LFHostTests.m LFHostSession.m LFContentReader.m LFDisplayAdapter.m
  LFAudioBufferPool.c LFAudioOutput.m)
target_compile_definitions(host_tracer PRIVATE LF_HOST_SESSION_TESTING=1)
target_include_directories(host_tracer PRIVATE "${MUHTARI_ORACLE_INCLUDE_DIR}")
target_link_libraries(host_tracer PRIVATE
  libfuturo::libfuturo
  "${FOUNDATION_FRAMEWORK}"
  "${COREGRAPHICS_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(host_tracer PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_content LFContentTests.m LFContentReader.m)
target_link_libraries(host_content PRIVATE "${FOUNDATION_FRAMEWORK}")
target_compile_options(host_content PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_input LFInputTests.m LFInputState.m)
target_link_libraries(host_input PRIVATE
  "${APPKIT_FRAMEWORK}"
  "${FOUNDATION_FRAMEWORK}"
)
target_compile_options(host_input PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_input_session
  LFHostInputTests.m LFHostSession.m LFContentReader.m LFInputState.m
  LFDisplayAdapter.m LFAudioBufferPool.c LFAudioOutput.m)
target_include_directories(host_input_session PRIVATE
  "${MUHTARI_ORACLE_INCLUDE_DIR}")
target_link_libraries(host_input_session PRIVATE
  libfuturo::libfuturo
  "${APPKIT_FRAMEWORK}"
  "${FOUNDATION_FRAMEWORK}"
  "${COREGRAPHICS_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(host_input_session PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_timing LFHostTimingTests.m LFHostSession.m LFContentReader.m)
target_sources(host_timing PRIVATE LFDisplayAdapter.m LFAudioBufferPool.c
  LFAudioOutput.m)
target_include_directories(host_timing PRIVATE
  "${MUHTARI_ORACLE_INCLUDE_DIR}")
target_link_libraries(host_timing PRIVATE
  libfuturo::libfuturo
  "${APPKIT_FRAMEWORK}"
  "${FOUNDATION_FRAMEWORK}"
  "${COREGRAPHICS_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(host_timing PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_display
  LFDisplayTests.m LFHostSession.m LFContentReader.m LFDisplayAdapter.m
  LFAudioBufferPool.c LFAudioOutput.m)
target_include_directories(host_display PRIVATE
  "${MUHTARI_ORACLE_INCLUDE_DIR}")
target_link_libraries(host_display PRIVATE
  libfuturo::libfuturo
  "${FOUNDATION_FRAMEWORK}"
  "${COREGRAPHICS_FRAMEWORK}"
  "${QUARTZCORE_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(host_display PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(host_audio LFHostAudioTests.m LFAudioBufferPool.c LFAudioOutput.m)
target_link_libraries(host_audio PRIVATE
  "${FOUNDATION_FRAMEWORK}"
  "${AVFAUDIO_FRAMEWORK}"
)
target_compile_options(host_audio PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

add_executable(native_smoke_supervisor
  native-smoke-supervisor.m native-smoke-protocol.c)
target_link_libraries(native_smoke_supervisor PRIVATE
  "${APPKIT_FRAMEWORK}"
  "${FOUNDATION_FRAMEWORK}"
)
target_compile_options(native_smoke_supervisor PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
  $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

# This control target compiles the same protocol implementation used by the
# supervisor and deliberately links no AppKit or Foundation frameworks.
add_executable(native_smoke_protocol_controls
  test-native-smoke-protocol.c native-smoke-protocol.c)
target_compile_options(native_smoke_protocol_controls PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -UNDEBUG
)

if(BUILD_TESTING)
  add_test(NAME host_tracer
    COMMAND "$<TARGET_FILE:host_tracer>" "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(host_tracer PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_tracer: profile=muhtari-ntsc-v1 startup=partial steady=pass pcm=pass immutable=pass capacity=801 serialized=pass overlap=pass ownership=pass destroy=once result=pass"
    TIMEOUT 15
  )

  add_test(NAME host_content COMMAND "$<TARGET_FILE:host_content>")
  set_tests_properties(host_content PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_content: sizes=empty,1,max-minus-one,max,max-plus-one nonregular=directory,fifo unreadable=pass truncation=pass growth=pass allocation=pass eintr=pass cleanup=pass result=pass"
    TIMEOUT 15
  )

  add_test(NAME host_input COMMAND "$<TARGET_FILE:host_input>")
  set_tests_properties(host_input PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_input: mappings=10 layout=letters-and-US-position aliases=independent unmapped=consumed repeats=pass focus=first-responder,window,app lost result=pass"
    TIMEOUT 15
  )

  add_test(NAME host_input_session
    COMMAND "$<TARGET_FILE:host_input_session>" "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(host_input_session PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_input_session: samples=16 native=10 release=pass both=pass mixed=pass held=pass later-change=pass queue-barrier=pass focus-loss=pass call-order=pass main-sentinel=2 pcm=valid result=pass"
    TIMEOUT 20
  )

  add_test(NAME host_timing
    COMMAND "$<TARGET_FILE:host_timing>" "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(host_timing PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_timing: startup=immediate samples=54 boundary=minus-one,equal,plus-one rational=long-ordinal overload=skip duplicate=single max-inflight=1 sentinel=pass prestop=pass reserved-stop=pass duplicate-stop=pass destroy=once overflow=checked catchup-control=detected wrong-order-control=detected stale-callbacks=filtered audio-close=reserved,disarm,owner-drain,player-stop,engine-stop,quiescent audio-mute=preopen,active,shutdown,post-stop-ignored owner-queue=pass guest=continued pcm=valid muted-advances=3 unmuted-advances=2 deadlines=1-4 stop-controls=detected result=pass"
    TIMEOUT 20
  )

  add_test(NAME host_display
    COMMAND "$<TARGET_FILE:host_display>" "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(host_display PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_display: indices=13 channels=RGBA8 alpha=opaque raw=unchanged startup=partial capture=layer-scale1,2 geometry=fit,letterbox,nonmultiple,downscale,nearest mailbox=latest,one-invalidation raw-control=detected rgb-control=detected result=pass"
    TIMEOUT 30
  )

  add_test(NAME host_audio COMMAND "$<TARGET_FILE:host_audio>")
  set_tests_properties(host_audio PROPERTIES
    PASS_REGULAR_EXPRESSION
      "host_audio: pool=capacity5 frames=54,800,801 bounds=checked drop=newest tokens=duplicate,stale rejected retirement=concurrent lock-free=10/10 graph=s16-core-input,float32-mono-48000 blocks=54,800,801 order=pass mute-output=silent,restored-source restore-transition=bounded,stable-after=[0-2]-of-3-blocks duplicate=stable completion=retired callback=pool-only close=lease-drained forbidden-controls=guest,player-stop-rejected result=pass"
    TIMEOUT 30
  )

  # Launch a fresh bundle instance through LaunchServices and retain its exact
  # NSRunningApplication for normal and forced termination.
  add_test(NAME native_window_smoke
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-native-smoke.sh"
      "$<TARGET_BUNDLE_DIR:installed_macos_host>"
      "${MUHTARI_FIXTURE_PATH}"
      "$<TARGET_FILE:native_smoke_supervisor>"
  )
  set_tests_properties(native_window_smoke PROPERTIES
    # Inner bounds are 30 s for LaunchServices, 20 s for the result, and 14 s
    # for cleanup (two 2 s acknowledgement waits and two 5 s termination waits).
    # Keep 56 s beyond that 64 s sum for setup, scheduling, and process teardown.
    TIMEOUT 120
  )

  add_test(NAME native_smoke_cleanup_controls
    COMMAND /bin/sh
      "${CMAKE_CURRENT_SOURCE_DIR}/test-native-smoke-cleanup.sh"
  )
  set_tests_properties(native_smoke_cleanup_controls PROPERTIES
    TIMEOUT 30
  )

  add_test(NAME native_smoke_protocol_controls
    COMMAND "$<TARGET_FILE:native_smoke_protocol_controls>"
  )
  set_tests_properties(native_smoke_protocol_controls PROPERTIES
    PASS_REGULAR_EXPRESSION
      "native_smoke_protocol_controls: malformed=signed,zero,overflow,trailing nul=ignored oversized=ignored stale=rejected recovery=handled result=pass"
    TIMEOUT 10
  )

  add_test(NAME native_open_retry
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-native-open-retry.sh"
      "$<TARGET_BUNDLE_DIR:installed_macos_host>"
      "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(native_open_retry PROPERTIES
    PASS_REGULAR_EXPRESSION
      "native_host_ui: result=pass"
    TIMEOUT 60
  )

  add_test(NAME native_lifecycle
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-native-lifecycle.sh"
      "$<TARGET_BUNDLE_DIR:installed_macos_host>"
      "${MUHTARI_FIXTURE_PATH}"
  )
  set_tests_properties(native_lifecycle PROPERTIES
    PASS_REGULAR_EXPRESSION
      "native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass"
    TIMEOUT 90
  )
endif()
