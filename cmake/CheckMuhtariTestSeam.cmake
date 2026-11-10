foreach(required_var NM_TOOL PRODUCTION_ARCHIVE TEST_ADAPTER_ARCHIVE)
  if(NOT DEFINED ${required_var} OR "${${required_var}}" STREQUAL "")
    message(FATAL_ERROR "muhtari_test_seam_scope: ${required_var} is required")
  endif()
endforeach()
foreach(archive IN ITEMS "${PRODUCTION_ARCHIVE}" "${TEST_ADAPTER_ARCHIVE}")
  if(NOT EXISTS "${archive}")
    message(FATAL_ERROR
      "muhtari_test_seam_scope: archive is missing: ${archive}")
  endif()
endforeach()

execute_process(
  COMMAND "${NM_TOOL}" -g "${PRODUCTION_ARCHIVE}"
  RESULT_VARIABLE production_result
  OUTPUT_VARIABLE production_symbols
  ERROR_VARIABLE production_error
  TIMEOUT 10
)
if(NOT "${production_result}" STREQUAL "0")
  message(FATAL_ERROR
    "muhtari_test_seam_scope: could not inspect production archive: ${production_error}")
endif()
string(FIND "${production_symbols}" "lf_muhtari_test_seed_progress"
  production_seam)
if(NOT production_seam EQUAL -1)
  message(FATAL_ERROR
    "muhtari_test_seam_scope: test seam leaked into the production archive")
endif()

execute_process(
  COMMAND "${NM_TOOL}" -g "${TEST_ADAPTER_ARCHIVE}"
  RESULT_VARIABLE test_result
  OUTPUT_VARIABLE test_symbols
  ERROR_VARIABLE test_error
  TIMEOUT 10
)
if(NOT "${test_result}" STREQUAL "0")
  message(FATAL_ERROR
    "muhtari_test_seam_scope: could not inspect test adapter archive: ${test_error}")
endif()
string(FIND "${test_symbols}" "lf_muhtari_test_seed_progress" test_seam)
if(test_seam EQUAL -1)
  message(FATAL_ERROR
    "muhtari_test_seam_scope: private test adapter omitted its seed seam")
endif()

message(STATUS
  "muhtari_test_seam_scope: production=absent test=private result=pass")
