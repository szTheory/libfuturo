# Build a private copy of the exact verified Nesturbator sources for parser
# instrumentation. The ordinary upstream targets remain the installed ones.
function(add_instrumented_nesturbator)
  set(_expected_core_sources
    src/instance.c
    src/cartridge.c
    src/crc32.c
    src/state.c
    src/mapper_nrom.c
    src/mapper_mmc1.c
    src/mapper_uxrom.c
    src/mapper_cnrom.c
    src/mapper_axrom.c
    src/mapper_mmc3.c
    src/frame.c
    src/bus.c
    src/apu.c
    src/synth.c
    src/ppu.c
    src/palette.c
    src/palette_ntsc.c
    src/testcard.c
  )
  set(_expected_cpu_sources src/cpu.c)

  if(NOT _nesturbator_verified_revision STREQUAL
     "2338608ab184f040620a30d17756f5e06a42d4e3")
    message(FATAL_ERROR
      "instrumented Nesturbator requires the verified 2338608ab184f040620a30d17756f5e06a42d4e3 pin")
  endif()
  if(NOT TARGET nesturbator OR NOT TARGET nesturbator_cpu)
    message(FATAL_ERROR
      "instrumented Nesturbator requires the verified upstream core and CPU targets")
  endif()

  get_target_property(_upstream_sources nesturbator SOURCES)
  get_target_property(_upstream_cpu_sources nesturbator_cpu SOURCES)
  if(NOT _upstream_sources OR NOT _upstream_cpu_sources)
    message(FATAL_ERROR
      "instrumented Nesturbator could not read the verified upstream source lists")
  endif()

  set(_instrumented_core_sources "")
  set(_observed_core_sources "")
  set(_cpu_object_expression_count 0)
  foreach(_source IN LISTS _upstream_sources)
    if(_source MATCHES "^\\$<TARGET_OBJECTS:([^>]+)>$")
      if(NOT CMAKE_MATCH_1 STREQUAL "nesturbator_cpu")
        message(FATAL_ERROR
          "instrumented Nesturbator found an unknown object expression: ${_source}")
      endif()
      math(EXPR _cpu_object_expression_count
        "${_cpu_object_expression_count} + 1")
      list(APPEND _instrumented_core_sources
        "$<TARGET_OBJECTS:nesturbator_instrumented_cpu>")
    elseif(_source MATCHES "\\$<")
      message(FATAL_ERROR
        "instrumented Nesturbator found an unsupported source expression: ${_source}")
    else()
      if(IS_ABSOLUTE "${_source}")
        message(FATAL_ERROR
          "instrumented Nesturbator expected relative upstream source paths: ${_source}")
      endif()
      if(NOT _source IN_LIST _expected_core_sources)
        message(FATAL_ERROR
          "instrumented Nesturbator found an unexpected core source: ${_source}")
      endif()
      if(NOT EXISTS "${nesturbator_SOURCE_DIR}/${_source}")
        message(FATAL_ERROR
          "instrumented Nesturbator source is missing from the verified pin: ${_source}")
      endif()
      list(APPEND _observed_core_sources "${_source}")
      list(APPEND _instrumented_core_sources
        "${nesturbator_SOURCE_DIR}/${_source}")
    endif()
  endforeach()

  if(NOT _cpu_object_expression_count EQUAL 1)
    message(FATAL_ERROR
      "instrumented Nesturbator expected exactly one upstream CPU object expression")
  endif()
  list(SORT _observed_core_sources)
  set(_sorted_expected_core_sources "${_expected_core_sources}")
  list(SORT _sorted_expected_core_sources)
  if(NOT _observed_core_sources STREQUAL _sorted_expected_core_sources)
    message(FATAL_ERROR
      "instrumented Nesturbator upstream core unit list differs from the verified pin")
  endif()
  if(NOT _upstream_cpu_sources STREQUAL _expected_cpu_sources)
    message(FATAL_ERROR
      "instrumented Nesturbator expected the verified CPU unit src/cpu.c")
  endif()
  if(NOT EXISTS "${nesturbator_SOURCE_DIR}/src/cpu.c")
    message(FATAL_ERROR
      "instrumented Nesturbator CPU source is missing from the verified pin")
  endif()

  add_library(nesturbator_instrumented_cpu OBJECT
    "${nesturbator_SOURCE_DIR}/src/cpu.c")
  add_library(nesturbator_instrumented STATIC ${_instrumented_core_sources})

  foreach(_pair
      "nesturbator_cpu;nesturbator_instrumented_cpu"
      "nesturbator;nesturbator_instrumented")
    list(GET _pair 0 _normal_target)
    list(GET _pair 1 _instrumented_target)
    foreach(_property COMPILE_DEFINITIONS COMPILE_OPTIONS INCLUDE_DIRECTORIES)
      get_target_property(_value "${_normal_target}" "${_property}")
      if(_value AND NOT _value MATCHES "-NOTFOUND$")
        if(_property STREQUAL "COMPILE_DEFINITIONS")
          target_compile_definitions("${_instrumented_target}" PRIVATE
            ${_value})
        elseif(_property STREQUAL "COMPILE_OPTIONS")
          target_compile_options("${_instrumented_target}" PRIVATE
            ${_value})
        else()
          target_include_directories("${_instrumented_target}" PRIVATE
            ${_value})
        endif()
      endif()
    endforeach()
    get_target_property(_visibility "${_normal_target}" C_VISIBILITY_PRESET)
    get_target_property(_pic "${_normal_target}" POSITION_INDEPENDENT_CODE)
    if(NOT _visibility OR _visibility MATCHES "-NOTFOUND$")
      message(FATAL_ERROR
        "instrumented Nesturbator could not copy ${_normal_target} visibility")
    endif()
    if(NOT _pic OR _pic MATCHES "-NOTFOUND$")
      message(FATAL_ERROR
        "instrumented Nesturbator could not copy ${_normal_target} PIC setting")
    endif()
    set_target_properties("${_instrumented_target}" PROPERTIES
      C_STANDARD 17
      C_STANDARD_REQUIRED ON
      C_EXTENSIONS OFF
      C_VISIBILITY_PRESET "${_visibility}"
      POSITION_INDEPENDENT_CODE "${_pic}")
    target_compile_options("${_instrumented_target}" PRIVATE
      -fsanitize=address,undefined -fno-omit-frame-pointer)
  endforeach()

  target_include_directories(nesturbator_instrumented PUBLIC
    "${nesturbator_SOURCE_DIR}/include")

  set(_unit_manifest "${CMAKE_BINARY_DIR}/instrumented-core-units.txt")
  file(WRITE "${_unit_manifest}" "format=libfuturo-instrumented-units-v1\n")
  file(APPEND "${_unit_manifest}"
    "nesturbator_instrumented_cpu|src/cpu.c\n")
  foreach(_source IN LISTS _observed_core_sources)
    file(APPEND "${_unit_manifest}"
      "nesturbator_instrumented|${_source}\n")
  endforeach()
endfunction()
