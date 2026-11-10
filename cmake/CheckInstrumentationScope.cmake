cmake_minimum_required(VERSION 3.25)

set(_scope_checker_file "${CMAKE_CURRENT_LIST_FILE}")

function(scope_fail diagnostic)
  message(FATAL_ERROR "instrumentation scope: ${diagnostic}")
endfunction()

function(normalize_path path base output_variable)
  if(IS_ABSOLUTE "${path}")
    set(_normalized "${path}")
  else()
    set(_normalized "${base}/${path}")
  endif()
  cmake_path(NORMAL_PATH _normalized OUTPUT_VARIABLE _normalized_result)
  set(${output_variable} "${_normalized_result}" PARENT_SCOPE)
endfunction()

function(load_compile_database output_json output_count)
  if(NOT EXISTS "${COMPILE_COMMANDS}")
    scope_fail("compile database is missing")
  endif()
  file(READ "${COMPILE_COMMANDS}" _json)
  string(JSON _count ERROR_VARIABLE _json_error LENGTH "${_json}")
  if(NOT _json_error STREQUAL "NOTFOUND")
    scope_fail("compile database is malformed: ${_json_error}")
  endif()
  if(_count EQUAL 0)
    scope_fail("compile database is empty")
  endif()
  set(${output_json} "${_json}" PARENT_SCOPE)
  set(${output_count} "${_count}" PARENT_SCOPE)
endfunction()

function(read_compile_record json index output_file output_command output_object output_directory)
  string(JSON _file ERROR_VARIABLE _file_error GET "${json}" ${index} file)
  if(NOT _file_error STREQUAL "NOTFOUND")
    scope_fail("compile record ${index} has no source file")
  endif()
  string(JSON _command ERROR_VARIABLE _command_error GET "${json}" ${index} command)
  if(NOT _command_error STREQUAL "NOTFOUND")
    scope_fail("compile record ${index} has no command")
  endif()
  string(JSON _directory ERROR_VARIABLE _directory_error GET "${json}" ${index} directory)
  if(NOT _directory_error STREQUAL "NOTFOUND")
    scope_fail("compile record ${index} has no working directory")
  endif()
  string(JSON _object ERROR_VARIABLE _object_error GET "${json}" ${index} output)
  if(NOT _object_error STREQUAL "NOTFOUND")
    string(REGEX MATCH "(^|[ \t])-o[ \t]+([^ \t]+)" _output_match "${_command}")
    if(NOT _output_match)
      scope_fail("compile record ${index} has no object output")
    endif()
    set(_object "${CMAKE_MATCH_2}")
  endif()
  set(${output_file} "${_file}" PARENT_SCOPE)
  set(${output_command} "${_command}" PARENT_SCOPE)
  set(${output_object} "${_object}" PARENT_SCOPE)
  set(${output_directory} "${_directory}" PARENT_SCOPE)
endfunction()

function(assert_unit_record json record_count expected_target relative_source source_root instrumented)
  normalize_path("${relative_source}" "${source_root}" _expected_source)
  set(_target_marker "CMakeFiles/${expected_target}.dir/")
  set(_source_matches 0)
  set(_target_matches 0)
  set(_matched_command "")
  if(record_count GREATER 0)
    math(EXPR _last_index "${record_count} - 1")
    foreach(_index RANGE 0 ${_last_index})
      read_compile_record("${json}" "${_index}"
        _record_file _record_command _record_object _record_directory)
      normalize_path("${_record_file}" "${_record_directory}" _record_source)
      if(_record_source STREQUAL _expected_source)
        math(EXPR _source_matches "${_source_matches} + 1")
        string(FIND "${_record_object}" "${_target_marker}" _target_position)
        if(NOT _target_position EQUAL -1)
          math(EXPR _target_matches "${_target_matches} + 1")
          set(_matched_command "${_record_command}")
        endif()
      endif()
    endforeach()
  endif()
  if(_target_matches EQUAL 0)
    if(_source_matches GREATER 0)
      scope_fail("wrong target output for ${expected_target}/${relative_source}")
    endif()
    scope_fail("missing compile record: ${expected_target} ${relative_source}")
  endif()
  if(NOT _target_matches EQUAL 1)
    scope_fail("duplicate compile records for ${expected_target}/${relative_source}")
  endif()

  if(instrumented)
    separate_arguments(_compile_arguments NATIVE_COMMAND "${_matched_command}")
    set(_has_required_sanitizers FALSE)
    set(_has_frame_pointer_flag FALSE)
    foreach(_argument IN LISTS _compile_arguments)
      if(_argument STREQUAL "-fsanitize=address,undefined")
        set(_has_required_sanitizers TRUE)
      elseif(_argument STREQUAL "-fno-omit-frame-pointer")
        set(_has_frame_pointer_flag TRUE)
      elseif(_argument STREQUAL "-fomit-frame-pointer")
        scope_fail("instrumented target ${expected_target}/${relative_source} disables required instrumentation with ${_argument}")
      elseif(_argument MATCHES "^-fno-sanitize=(.*)$")
        set(_disabled_sanitizers "${CMAKE_MATCH_1}")
        if(_disabled_sanitizers STREQUAL "all"
           OR _disabled_sanitizers MATCHES "(^|,)(address|undefined)(,|$)")
          scope_fail("instrumented target ${expected_target}/${relative_source} disables required instrumentation with ${_argument}")
        endif()
      endif()
    endforeach()
    if(NOT _has_required_sanitizers OR NOT _has_frame_pointer_flag)
      scope_fail("missing ASan/UBSan or frame-pointer compile flags for ${expected_target}/${relative_source}")
    endif()
  elseif(_matched_command MATCHES "-fsanitize="
         OR _matched_command MATCHES "-fno-omit-frame-pointer")
    scope_fail("normal target ${expected_target} compile record contains sanitizer flags")
  endif()
endfunction()

function(assert_target_record_count json record_count target expected_count)
  set(_target_marker "CMakeFiles/${target}.dir/")
  set(_observed_count 0)
  if(record_count GREATER 0)
    math(EXPR _last_index "${record_count} - 1")
    foreach(_index RANGE 0 ${_last_index})
      read_compile_record("${json}" "${_index}"
        _record_file _record_command _record_object _record_directory)
      string(FIND "${_record_object}" "${_target_marker}" _target_position)
      if(NOT _target_position EQUAL -1)
        math(EXPR _observed_count "${_observed_count} + 1")
      endif()
    endforeach()
  endif()
  if(NOT _observed_count EQUAL expected_count)
    scope_fail("target ${target} compile-record count expected ${expected_count}, observed ${_observed_count}")
  endif()
endfunction()

function(assert_no_normal_compile_sanitizers json record_count)
  set(_normal_targets libfuturo nesturbator nesturbator_cpu
    muhtari muhtari_objs muhtari_cpu muhtari_cartdb)
  if(record_count GREATER 0)
    math(EXPR _last_index "${record_count} - 1")
    foreach(_index RANGE 0 ${_last_index})
      read_compile_record("${json}" "${_index}"
        _record_file _record_command _record_object _record_directory)
      foreach(_target IN LISTS _normal_targets)
        string(FIND "${_record_object}" "CMakeFiles/${_target}.dir/" _target_position)
        if(NOT _target_position EQUAL -1
           AND (_record_command MATCHES "-fsanitize="
                OR _record_command MATCHES "-fno-omit-frame-pointer"))
          scope_fail("normal target ${_target} compile record contains sanitizer flags")
        endif()
      endforeach()
    endforeach()
  endif()
endfunction()

function(read_unit_manifest output_pairs)
  if(NOT EXISTS "${UNIT_LIST}")
    scope_fail("instrumented core unit list is missing")
  endif()
  file(STRINGS "${UNIT_LIST}" _lines)
  list(LENGTH _lines _line_count)
  if(_line_count LESS 2)
    scope_fail("instrumented core unit list is empty or has an unknown format")
  endif()
  list(GET _lines 0 _format)
  if(NOT _format STREQUAL "format=libfuturo-instrumented-units-v1")
    scope_fail("instrumented core unit list is empty or has an unknown format")
  endif()
  set(_pairs "")
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^format=")
      continue()
    endif()
    if(NOT _line MATCHES "^([^|]+)\\|([^|]+)$")
      scope_fail("malformed instrumented core unit entry")
    endif()
    set(_target "${CMAKE_MATCH_1}")
    set(_source "${CMAKE_MATCH_2}")
    if(NOT _target STREQUAL "nesturbator_instrumented"
       AND NOT _target STREQUAL "nesturbator_instrumented_cpu")
      scope_fail("unknown instrumented core target in unit list")
    endif()
    if(IS_ABSOLUTE "${_source}" OR _source MATCHES "\\$<")
      scope_fail("unit list contains a non-source path")
    endif()
    set(_pair "${_target}|${_source}")
    if(_pair IN_LIST _pairs)
      scope_fail("duplicate instrumented core unit entry")
    endif()
    list(APPEND _pairs "${_pair}")
  endforeach()
  set(${output_pairs} "${_pairs}" PARENT_SCOPE)
endfunction()

function(check_fixture_scope)
  load_compile_database(_fixture_json _fixture_count)
  read_unit_manifest(_fixture_pairs)
  foreach(_pair IN LISTS _fixture_pairs)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    if(_target STREQUAL "nesturbator_instrumented_cpu")
      set(_source_root "${NESTURBATOR_SOURCE_DIR}")
    else()
      set(_source_root "${NESTURBATOR_SOURCE_DIR}")
    endif()
    assert_unit_record("${_fixture_json}" "${_fixture_count}"
      "${_target}" "${_source}" "${_source_root}" TRUE)
  endforeach()
  set(_test_units
    "libfuturo_test|src/synthetic.c"
    "libfuturo_test|src/nesturbator_adapter.c"
    "libfuturo_test|src/sha256.c"
    "nesturbator_load_corpus|tests/nesturbator_load_corpus.c"
  )
  foreach(_pair IN LISTS _test_units)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    assert_unit_record("${_fixture_json}" "${_fixture_count}"
      "${_target}" "${_source}" "${PROJECT_SOURCE_DIR}" TRUE)
  endforeach()
  assert_no_normal_compile_sanitizers("${_fixture_json}" "${_fixture_count}")
endfunction()

function(make_fixture_record fixture_dir target source_root relative_source output_target flags output_record)
  set(_source "${source_root}/${relative_source}")
  set(_object "${fixture_dir}/CMakeFiles/${output_target}.dir/${relative_source}.o")
  set(_command "clang ${flags} -c ${_source} -o ${_object}")
  set(${output_record}
    "{\"directory\":\"${fixture_dir}\",\"command\":\"${_command}\",\"file\":\"${_source}\",\"output\":\"${_object}\"}"
    PARENT_SCOPE)
endfunction()

function(write_fixture case_name output_directory)
  set(_directory "${BUILD_DIR}/instrumentation-control-fixtures/${case_name}")
  set(_core_root "${_directory}/nesturbator")
  set(_project_root "${_directory}/project")
  file(MAKE_DIRECTORY "${_core_root}/src" "${_project_root}/src"
    "${_project_root}/tests")
  foreach(_relative
      src/cartridge.c src/cpu.c src/synthetic.c src/nesturbator_adapter.c
      tests/nesturbator_load_corpus.c)
    if(_relative MATCHES "^src/(cartridge|cpu)\\.c$")
      file(WRITE "${_core_root}/${_relative}" "/* generated checker fixture */\n")
    else()
      file(WRITE "${_project_root}/${_relative}" "/* generated checker fixture */\n")
    endif()
  endforeach()

  set(_unit_list "format=libfuturo-instrumented-units-v1\n")
  string(APPEND _unit_list
    "nesturbator_instrumented_cpu|src/cpu.c\n"
    "nesturbator_instrumented|src/cartridge.c\n")
  file(WRITE "${_directory}/instrumented-core-units.txt" "${_unit_list}")

  set(_records "")
  set(_instrumented_flags "-fsanitize=address,undefined -fno-omit-frame-pointer")
  if(case_name STREQUAL "missing_parser_flag")
    set(_cartridge_flags "-fno-omit-frame-pointer")
  elseif(case_name STREQUAL "disable_address")
    set(_cartridge_flags "${_instrumented_flags} -fno-sanitize=address")
  elseif(case_name STREQUAL "disable_undefined")
    set(_cartridge_flags "${_instrumented_flags} -fno-sanitize=undefined")
  elseif(case_name STREQUAL "disable_all")
    set(_cartridge_flags "${_instrumented_flags} -fno-sanitize=all")
  elseif(case_name STREQUAL "omit_frame_pointer")
    set(_cartridge_flags "${_instrumented_flags} -fomit-frame-pointer")
  else()
    set(_cartridge_flags "${_instrumented_flags}")
  endif()
  if(case_name STREQUAL "wrong_target")
    set(_cartridge_target "nesturbator")
  else()
    set(_cartridge_target nesturbator_instrumented)
  endif()
  make_fixture_record("${_directory}" nesturbator_instrumented
    "${_core_root}" src/cartridge.c "${_cartridge_target}"
    "${_cartridge_flags}" _record)
  list(APPEND _records "${_record}")

  if(NOT case_name STREQUAL "missing_cpu_record")
    make_fixture_record("${_directory}" nesturbator_instrumented_cpu
      "${_core_root}" src/cpu.c nesturbator_instrumented_cpu
      "${_instrumented_flags}" _record)
    list(APPEND _records "${_record}")
  endif()
  make_fixture_record("${_directory}" libfuturo_test
    "${_project_root}" src/synthetic.c libfuturo_test
    "${_instrumented_flags}" _record)
  list(APPEND _records "${_record}")
  make_fixture_record("${_directory}" libfuturo_test
    "${_project_root}" src/nesturbator_adapter.c libfuturo_test
    "${_instrumented_flags}" _record)
  list(APPEND _records "${_record}")
  make_fixture_record("${_directory}" libfuturo_test
    "${_project_root}" src/sha256.c libfuturo_test
    "${_instrumented_flags}" _record)
  list(APPEND _records "${_record}")
  make_fixture_record("${_directory}" nesturbator_load_corpus
    "${_project_root}" tests/nesturbator_load_corpus.c nesturbator_load_corpus
    "${_instrumented_flags}" _record)
  list(APPEND _records "${_record}")
  if(case_name STREQUAL "normal_contamination")
    set(_normal_flags "${_instrumented_flags}")
  else()
    set(_normal_flags "")
  endif()
  make_fixture_record("${_directory}" libfuturo
    "${_project_root}" src/synthetic.c libfuturo "${_normal_flags}" _record)
  list(APPEND _records "${_record}")
  make_fixture_record("${_directory}" libfuturo
    "${_project_root}" src/sha256.c libfuturo "${_normal_flags}" _record)
  list(APPEND _records "${_record}")

  set(_compile_database "[\n")
  if(NOT case_name STREQUAL "empty_evidence")
    list(LENGTH _records _record_count)
    set(_record_index 0)
    foreach(_record IN LISTS _records)
      math(EXPR _record_index "${_record_index} + 1")
      string(APPEND _compile_database "  ${_record}")
      if(NOT _record_index EQUAL _record_count)
        string(APPEND _compile_database ",")
      endif()
      string(APPEND _compile_database "\n")
    endforeach()
  endif()
  string(APPEND _compile_database "]\n")
  file(WRITE "${_directory}/compile_commands.json" "${_compile_database}")
  set(${output_directory} "${_directory}" PARENT_SCOPE)
endfunction()

function(run_control case_name expected_diagnostic)
  write_fixture("${case_name}" _fixture_dir)
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DMODE=fixture"
      "-DCOMPILE_COMMANDS=${_fixture_dir}/compile_commands.json"
      "-DUNIT_LIST=${_fixture_dir}/instrumented-core-units.txt"
      "-DNESTURBATOR_SOURCE_DIR=${_fixture_dir}/nesturbator"
      "-DPROJECT_SOURCE_DIR=${_fixture_dir}/project"
      "-P" "${_scope_checker_file}"
    RESULT_VARIABLE _result
    OUTPUT_VARIABLE _stdout
    ERROR_VARIABLE _stderr
  )
  set(_combined "${_stdout} ${_stderr}")
  string(REPLACE "\n" " " _combined "${_combined}")
  string(REGEX REPLACE "[ \t]+" " " _combined "${_combined}")
  if(case_name STREQUAL "clean")
    if(NOT _result EQUAL 0)
      scope_fail("clean synthetic control fixture failed: ${_combined}")
    endif()
  else()
    if(_result EQUAL 0)
      scope_fail("control ${case_name} unexpectedly passed")
    endif()
    string(FIND "${_combined}" "${expected_diagnostic}" _diagnostic_position)
    if(_diagnostic_position EQUAL -1)
      scope_fail("control ${case_name} failed for the wrong reason: ${_combined}")
    endif()
  endif()
endfunction()

function(run_controls)
  if(NOT DEFINED BUILD_DIR OR BUILD_DIR STREQUAL "")
    set(BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}")
  endif()
  run_control(clean "")
  run_control(missing_parser_flag
    "missing ASan/UBSan or frame-pointer compile flags for nesturbator_instrumented/src/cartridge.c")
  run_control(disable_address "disables required instrumentation")
  run_control(disable_undefined "disables required instrumentation")
  run_control(disable_all "disables required instrumentation")
  run_control(omit_frame_pointer "disables required instrumentation")
  run_control(missing_cpu_record
    "missing compile record: nesturbator_instrumented_cpu src/cpu.c")
  run_control(empty_evidence "compile database is empty")
  run_control(wrong_target
    "wrong target output for nesturbator_instrumented/src/cartridge.c")
  run_control(normal_contamination
    "normal target libfuturo compile record contains sanitizer flags")
endfunction()

function(run_actual)
  foreach(_required
      COMPILE_COMMANDS UNIT_LIST PROJECT_SOURCE_DIR NESTURBATOR_SOURCE_DIR
      BUILD_DIR SCOPE_OUTPUT LIBFUTURO_ARCHIVE NESTURBATOR_ARCHIVE
      INSTRUMENTED_ARCHIVE NM_TOOL CORPUS_LINK_COMMAND CORPUS_EXECUTABLE
      NESTURBATOR_REVISION COMPILER_ID COMPILER_VERSION TARGET_PROFILE
      LIBFUTURO_MUHTARI_ENABLED)
    if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
      scope_fail("actual mode is missing required input ${_required}")
    endif()
  endforeach()
  if(NOT NESTURBATOR_REVISION STREQUAL
     "2338608ab184f040620a30d17756f5e06a42d4e3")
    scope_fail("verified source pin does not match the approved revision")
  endif()
  if(LIBFUTURO_MUHTARI_ENABLED)
    foreach(_required MUHTARI_SOURCE_DIR MUHTARI_REVISION MUHTARI_ARCHIVE)
      if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
        scope_fail("Muhtari-enabled mode is missing required input ${_required}")
      endif()
    endforeach()
    if(NOT MUHTARI_REVISION STREQUAL
       "d5fd241e3f4d701d73867cc2e465c56a6fe6793d")
      scope_fail("verified Muhtari source pin does not match the approved revision")
    endif()
  endif()

  load_compile_database(_json _record_count)
  read_unit_manifest(_core_pairs)
  set(_core_sources "")
  set(_cpu_count 0)
  set(_core_count 0)
  set(_cartridge_count 0)
  foreach(_pair IN LISTS _core_pairs)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    if(_target STREQUAL "nesturbator_instrumented_cpu")
      math(EXPR _cpu_count "${_cpu_count} + 1")
      if(NOT _source STREQUAL "src/cpu.c")
        scope_fail("instrumented CPU target does not name src/cpu.c")
      endif()
      assert_unit_record("${_json}" "${_record_count}" "${_target}"
        "${_source}" "${NESTURBATOR_SOURCE_DIR}" TRUE)
    else()
      math(EXPR _core_count "${_core_count} + 1")
      if(_source STREQUAL "src/cartridge.c")
        math(EXPR _cartridge_count "${_cartridge_count} + 1")
      endif()
      list(APPEND _core_sources "${_source}")
      assert_unit_record("${_json}" "${_record_count}" "${_target}"
        "${_source}" "${NESTURBATOR_SOURCE_DIR}" TRUE)
    endif()
  endforeach()
  if(NOT _cpu_count EQUAL 1 OR NOT _cartridge_count EQUAL 1
     OR NOT _core_count EQUAL 18)
    scope_fail("unit list must contain cartridge.c, one CPU object, and all 18 core units")
  endif()
  set(_test_units
    "libfuturo_test|src/synthetic.c"
    "libfuturo_test|src/nesturbator_adapter.c"
    "libfuturo_test|src/sha256.c"
    "nesturbator_load_corpus|tests/nesturbator_load_corpus.c"
  )
  foreach(_pair IN LISTS _test_units)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    assert_unit_record("${_json}" "${_record_count}" "${_target}"
      "${_source}" "${PROJECT_SOURCE_DIR}" TRUE)
  endforeach()
  list(LENGTH _core_sources _core_record_count)
  assert_target_record_count("${_json}" "${_record_count}"
    nesturbator_instrumented "${_core_record_count}")
  assert_target_record_count("${_json}" "${_record_count}"
    nesturbator_instrumented_cpu 1)
  assert_target_record_count("${_json}" "${_record_count}" libfuturo_test 3)
  assert_target_record_count("${_json}" "${_record_count}"
    nesturbator_load_corpus 1)

  set(_normal_core_count 0)
  foreach(_pair IN LISTS _core_pairs)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    if(_target STREQUAL "nesturbator_instrumented_cpu")
      assert_unit_record("${_json}" "${_record_count}"
        nesturbator_cpu "${_source}" "${NESTURBATOR_SOURCE_DIR}" FALSE)
    else()
      math(EXPR _normal_core_count "${_normal_core_count} + 1")
      assert_unit_record("${_json}" "${_record_count}"
        nesturbator "${_source}" "${NESTURBATOR_SOURCE_DIR}" FALSE)
    endif()
  endforeach()
  assert_target_record_count("${_json}" "${_record_count}"
    nesturbator "${_normal_core_count}")
  assert_target_record_count("${_json}" "${_record_count}" nesturbator_cpu 1)
  assert_unit_record("${_json}" "${_record_count}"
    libfuturo src/synthetic.c "${PROJECT_SOURCE_DIR}" FALSE)
  assert_unit_record("${_json}" "${_record_count}"
    libfuturo src/nesturbator_adapter.c "${PROJECT_SOURCE_DIR}" FALSE)
  assert_unit_record("${_json}" "${_record_count}"
    libfuturo src/sha256.c "${PROJECT_SOURCE_DIR}" FALSE)
  set(_libfuturo_units 3)
  if(LIBFUTURO_MUHTARI_ENABLED)
    assert_unit_record("${_json}" "${_record_count}"
      libfuturo src/muhtari_adapter.c "${PROJECT_SOURCE_DIR}" FALSE)
    math(EXPR _libfuturo_units "${_libfuturo_units} + 1")
    foreach(_source src/instance.c src/frame.c src/synth.c src/testcard.c
        src/bus.c src/tia.c src/pokey.c src/riot.c src/maria.c src/boot.c
        src/sha1.c src/cart.c src/ports.c)
      assert_unit_record("${_json}" "${_record_count}"
        muhtari_objs "${_source}" "${MUHTARI_SOURCE_DIR}" FALSE)
    endforeach()
    assert_unit_record("${_json}" "${_record_count}"
      muhtari_cpu src/cpu.c "${MUHTARI_SOURCE_DIR}" FALSE)
    assert_unit_record("${_json}" "${_record_count}"
      muhtari_cartdb src/cartdb.c "${MUHTARI_SOURCE_DIR}" FALSE)
    assert_target_record_count("${_json}" "${_record_count}" muhtari_objs 13)
    assert_target_record_count("${_json}" "${_record_count}" muhtari_cpu 1)
    assert_target_record_count("${_json}" "${_record_count}" muhtari_cartdb 1)
  endif()
  assert_target_record_count("${_json}" "${_record_count}" libfuturo
    "${_libfuturo_units}")
  assert_no_normal_compile_sanitizers("${_json}" "${_record_count}")

  if(NOT EXISTS "${CORPUS_LINK_COMMAND}" OR NOT EXISTS "${CORPUS_EXECUTABLE}")
    scope_fail("consumer link command or corpus executable is missing")
  endif()
  file(READ "${CORPUS_LINK_COMMAND}" _link_command)
  if(NOT _link_command MATCHES "-fsanitize=address,undefined")
    scope_fail("corpus link command does not include the ASan/UBSan runtime")
  endif()
  if(NOT _link_command MATCHES "liblibfuturo_test\\.a"
     OR NOT _link_command MATCHES "libnesturbator_instrumented\\.a")
    scope_fail("corpus link command does not use both private instrumented archives")
  endif()
  if(_link_command MATCHES "libnesturbator\\.a")
    scope_fail("corpus link command also includes the ordinary Nesturbator archive")
  endif()

  foreach(_archive_pair
      "libfuturo|${LIBFUTURO_ARCHIVE}"
      "nesturbator|${NESTURBATOR_ARCHIVE}")
    string(REPLACE "|" ";" _fields "${_archive_pair}")
    list(GET _fields 0 _archive_name)
    list(GET _fields 1 _archive_path)
    if(NOT EXISTS "${_archive_path}")
      scope_fail("normal ${_archive_name} archive is missing")
    endif()
    execute_process(COMMAND "${NM_TOOL}" -u "${_archive_path}"
      RESULT_VARIABLE _nm_result OUTPUT_VARIABLE _nm_output
      ERROR_VARIABLE _nm_error)
    if(NOT _nm_result EQUAL 0)
      scope_fail("selected nm could not inspect normal ${_archive_name} archive: ${_nm_error}")
    endif()
    if(_nm_output MATCHES "U[ \t]+_*asan" OR _nm_output MATCHES "U[ \t]+_*ubsan")
      scope_fail("normal ${_archive_name} archive references a sanitizer runtime")
    endif()
    file(SHA256 "${_archive_path}" _archive_sha)
    if(_archive_name STREQUAL "libfuturo")
      set(_libfuturo_sha "${_archive_sha}")
    else()
      set(_nesturbator_sha "${_archive_sha}")
    endif()
  endforeach()
  if(LIBFUTURO_MUHTARI_ENABLED)
    if(NOT EXISTS "${MUHTARI_ARCHIVE}")
      scope_fail("normal Muhtari archive is missing")
    endif()
    execute_process(COMMAND "${NM_TOOL}" -u "${MUHTARI_ARCHIVE}"
      RESULT_VARIABLE _muhtari_nm_result OUTPUT_VARIABLE _muhtari_nm_output
      ERROR_VARIABLE _muhtari_nm_error)
    if(NOT _muhtari_nm_result EQUAL 0)
      scope_fail("selected nm could not inspect normal Muhtari archive: ${_muhtari_nm_error}")
    endif()
    if(_muhtari_nm_output MATCHES "U[ \t]+_*asan"
       OR _muhtari_nm_output MATCHES "U[ \t]+_*ubsan")
      scope_fail("normal Muhtari archive references a sanitizer runtime")
    endif()
    file(SHA256 "${MUHTARI_ARCHIVE}" _muhtari_sha)
  endif()
  if(NOT EXISTS "${INSTRUMENTED_ARCHIVE}")
    scope_fail("instrumented Nesturbator archive is missing")
  endif()
  file(SHA256 "${INSTRUMENTED_ARCHIVE}" _instrumented_sha)
  if(_libfuturo_sha STREQUAL _instrumented_sha
     OR _nesturbator_sha STREQUAL _instrumented_sha)
    scope_fail("instrumented and normal archive identities unexpectedly match")
  endif()

  set(_unit_evidence "")
  foreach(_pair IN LISTS _core_pairs)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    list(APPEND _unit_evidence "${_target}|${_source}|asan_ubsan=yes|frame_pointer=yes")
  endforeach()
  foreach(_pair IN LISTS _test_units)
    string(REPLACE "|" ";" _fields "${_pair}")
    list(GET _fields 0 _target)
    list(GET _fields 1 _source)
    list(APPEND _unit_evidence "${_target}|${_source}|asan_ubsan=yes|frame_pointer=yes")
  endforeach()
  list(SORT _unit_evidence)
  list(LENGTH _unit_evidence _actual_unit_count)
  string(CONCAT _evidence
    "format=libfuturo-instrumentation-scope-v1\n"
    "source_origin=https://github.com/szTheory/nesturbator.git\n"
    "source_revision=${NESTURBATOR_REVISION}\n"
    "source_gate=origin,full_revision,clean_source_passed\n"
    "compiler=${COMPILER_ID} ${COMPILER_VERSION}\n"
    "target_profile=${TARGET_PROFILE}\n"
    "compile_database_ref=compile_commands.json\n"
    "unit_manifest_ref=instrumented-core-units.txt\n"
    "consumer_link_ref=CMakeFiles/nesturbator_load_corpus.dir/link.txt\n"
    "normal_archive_libfuturo=liblibfuturo.a sha256:${_libfuturo_sha} sanitizer_symbols=none\n"
    "normal_libfuturo_compile_units=${_libfuturo_units} sanitizer_flags=none\n"
    "normal_archive_nesturbator=libnesturbator.a sha256:${_nesturbator_sha} sanitizer_symbols=none\n"
    "instrumented_archive=libnesturbator_instrumented.a sha256:${_instrumented_sha}\n"
    "corpus_link=libfuturo_test+nesturbator_instrumented sanitizer_runtime=address,undefined\n"
    "instrumented_core_units=19 cartridge=present cpu_object=present\n"
    "instrumented_consumer_units=libfuturo_test:3 nesturbator_load_corpus:1\n"
    "actual_flag_records=${_actual_unit_count} of ${_actual_unit_count}\n"
    "other_test_consumers=synthetic_host,synthetic_session,synthetic_boundaries,nesturbator_session,nesturbator_load_corpus,conformance_positive use the private instrumented core through libfuturo_test\n"
    "runtime_only_core_consumers=nesturbator_probe,conformance_clear_on_unsupported_load,conformance_double_guest_units use the ordinary Nesturbator archive; their owned wrapper/defect code is separately ASan/UBSan compiled\n"
    "installed_targets=libfuturo and nesturbator use ordinary sanitizer-free archives\n"
    "normal_downstream_link=retained relocated-consumer save/restart gate\n"
    "limitations=selected exact pin and local target profile only; no fuzzing or other-platform qualification\n"
  )
  if(LIBFUTURO_MUHTARI_ENABLED)
    string(REPLACE
      "source_origin=https://github.com/szTheory/nesturbator.git\n"
      "source_origin=https://github.com/szTheory/nesturbator.git\nmuhtari_source_origin=https://github.com/szTheory/muhtari.git\nmuhtari_source_revision=${MUHTARI_REVISION}\nmuhtari_source_gate=origin,full_revision,clean_source_passed\n"
      _evidence "${_evidence}")
    string(REPLACE
      "installed_targets=libfuturo and nesturbator use ordinary sanitizer-free archives\n"
      "installed_targets=libfuturo, nesturbator, and Muhtari use ordinary sanitizer-free archives\n"
      _evidence "${_evidence}")
    string(REPLACE
      "normal_archive_nesturbator=libnesturbator.a sha256:${_nesturbator_sha} sanitizer_symbols=none\n"
      "normal_archive_nesturbator=libnesturbator.a sha256:${_nesturbator_sha} sanitizer_symbols=none\nnormal_archive_muhtari=libmuhtari.a sha256:${_muhtari_sha} sanitizer_symbols=none\n"
      _evidence "${_evidence}")
    string(REPLACE
      "other_test_consumers=synthetic_host,synthetic_session,synthetic_boundaries,nesturbator_session,nesturbator_load_corpus,conformance_positive use the private instrumented core through libfuturo_test\n"
      "other_test_consumers=synthetic_host,synthetic_session,synthetic_boundaries,nesturbator_session,nesturbator_load_corpus,muhtari_session,conformance_positive use the private instrumented core through libfuturo_test except the Muhtari adapter uses its ordinary archive\n"
      _evidence "${_evidence}")
  endif()
  foreach(_unit IN LISTS _unit_evidence)
    string(APPEND _evidence "unit=${_unit}\n")
  endforeach()
  if(_evidence MATCHES "/Users/" OR _evidence MATCHES "/private/tmp/"
     OR _evidence MATCHES "${PROJECT_SOURCE_DIR}")
    scope_fail("instrumentation evidence contains a private absolute path")
  endif()
  file(WRITE "${SCOPE_OUTPUT}" "${_evidence}")
  message(STATUS
    "instrumentation_scope: controls=10 actual_units=${_actual_unit_count} normal_archives=clean assertion-complete=true result=pass")
endfunction()

if(NOT DEFINED MODE OR MODE STREQUAL "")
  set(MODE actual)
endif()
if(MODE STREQUAL "controls")
  run_controls()
  message(STATUS "instrumentation_scope_controls: cases=10 result=pass")
elseif(MODE STREQUAL "fixture")
  check_fixture_scope()
elseif(MODE STREQUAL "actual")
  run_actual()
elseif(MODE STREQUAL "all")
  run_controls()
  run_actual()
else()
  scope_fail("unknown checker mode ${MODE}")
endif()
