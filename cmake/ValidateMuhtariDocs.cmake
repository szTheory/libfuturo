cmake_minimum_required(VERSION 3.25)

if(NOT DEFINED ROOT OR ROOT STREQUAL "")
  set(ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
endif()
get_filename_component(_root "${ROOT}" REALPATH)

set(_contract_path "${_root}/docs/contract.md")
set(_profile_path "${_root}/docs/muhtari-profile.md")
set(_fixture_path "${_root}/docs/muhtari-save-fixture.md")
set(_snapshot_fixture_path "${_root}/docs/muhtari-snapshot-fixture.md")
foreach(_path IN ITEMS "${_contract_path}" "${_profile_path}" "${_fixture_path}"
    "${_snapshot_fixture_path}")
  if(NOT EXISTS "${_path}" OR IS_DIRECTORY "${_path}")
    message(FATAL_ERROR "Muhtari documentation input is missing: ${_path}")
  endif()
endforeach()

file(READ "${_contract_path}" _contract)
file(READ "${_profile_path}" _profile)
file(READ "${_fixture_path}" _fixture)
file(READ "${_profile_path}" _profile_raw)
file(READ "${_snapshot_fixture_path}" _snapshot_fixture)
foreach(_document_variable IN ITEMS _contract _profile _fixture _snapshot_fixture)
  string(REPLACE "\r" "" _normalized_document "${${_document_variable}}")
  string(REPLACE "\n" " " _normalized_document "${_normalized_document}")
  set("${_document_variable}" "${_normalized_document}")
endforeach()

set(_api8_profile_heading "## API 8 `muhtari-ntsc-v2` snapshot qualification")
string(FIND "${_profile_raw}" "${_api8_profile_heading}" _api8_profile_start)
if(_api8_profile_start EQUAL -1)
  message(FATAL_ERROR
    "Muhtari API 8 documentation contract is missing the scoped profile section")
endif()
string(LENGTH "${_api8_profile_heading}" _api8_profile_heading_length)
math(EXPR _api8_profile_body_start
  "${_api8_profile_start} + ${_api8_profile_heading_length}")
string(SUBSTRING "${_profile_raw}" ${_api8_profile_body_start} -1
  _api8_profile_body)
string(FIND "${_api8_profile_body}" "\n## " _api8_profile_end)
if(_api8_profile_end EQUAL -1)
  set(_api8_profile_section "${_api8_profile_body}")
else()
  string(SUBSTRING "${_api8_profile_body}" 0 ${_api8_profile_end}
    _api8_profile_section)
endif()
string(REPLACE "\r" "" _api8_profile_section "${_api8_profile_section}")
string(REPLACE "\n" " " _api8_profile_section "${_api8_profile_section}")

function(require_phrase document_name document phrase)
  string(FIND "${document}" "${phrase}" _index)
  if(_index EQUAL -1)
    message(FATAL_ERROR "${document_name} is missing required Phase 6 claim: ${phrase}")
  endif()
endfunction()

function(reject_phrase document_name document phrase)
  string(FIND "${document}" "${phrase}" _index)
  if(NOT _index EQUAL -1)
    message(FATAL_ERROR "${document_name} contains a contradictory or out-of-scope claim: ${phrase}")
  endif()
endfunction()

set(_contract_claims
  "muhtari-battery-v1"
  "caller-owned bytes"
  "does not expose or"
  "retain Muhtari's native media pointer"
  "loaded-content digest and effective configuration"
  "content and configuration"
  "exact loaded extent"
  "successful load and before the first positive guest advance"
  "A rejected"
  "active media span unchanged"
  "not a durable acknowledgment"
)
foreach(_claim IN LISTS _contract_claims)
  require_phrase("docs/contract.md" "${_contract}" "${_claim}")
endforeach()

set(_profile_claims
  "muhtari-ntsc-joystick-default"
  "muhtari-ntsc-battery-diagnostic"
  "NULL` or `muhtari-ntsc-joystick-default"
  "other well-formed IDs return `LF_UNSUPPORTED`"
  "0xF1F1"
  "0xF1"
  "| `NULL` or `muhtari-ntsc-joystick-default` | `0xF1F1` |"
  "| `muhtari-ntsc-battery-diagnostic` | `0xF1` |"
  "Input mask (default configuration)"
  "Input mask (battery diagnostic configuration)"
  "port 1 input bits are supported"
  "joystick on both ports, HSC off, expansion off"
  "joystick on Muhtari port 1 (libfuturo input port 0), HSC plus SaveKey on Muhtari port 2"
  "LF_CAP_IN_MEMORY_MEDIA_COPY"
  "media_extent_bytes=0"
  "34,816 bytes"
  "2,048 HSC bytes followed by 32,768"
  "muhtari-battery-v1"
  "content digest, effective configuration, media identity, exact"
  "exposes or retains the native Muhtari media pointer"
  "after successful load and before the first positive guest advance"
  "not a host revision or durable acknowledgment"
  "Phase 5 default selector"
  "local macOS arm64"
)
foreach(_claim IN LISTS _profile_claims)
  require_phrase("docs/muhtari-profile.md" "${_profile}" "${_claim}")
endforeach()
reject_phrase("docs/muhtari-profile.md" "${_profile}"
  "Both Muhtari configurations support media copy/import")
reject_phrase("docs/muhtari-profile.md" "${_profile}"
  "battery diagnostic exposes two joysticks")
reject_phrase("docs/muhtari-profile.md" "${_profile}"
  "power-loss safe")
reject_phrase("docs/muhtari-profile.md" "${_profile}"
  "multi-writer safe")
reject_phrase("docs/muhtari-profile.md" "${_profile}"
  "battery recovery or joystick evidence from the separate Phase 6 fixture has not been run")

set(_fixture_claims
  "d5fd241e3f4d701d73867cc2e465c56a6fe6793d"
  "4642ded6d026f456acf798a43efb081b76987018"
  "10f5bc279d8147b3348e102ca9f7e4dc496dd31b5099adb2ef64320e987fb4d4"
  "MIT"
  "16,512 bytes"
  "muhtari-ntsc-battery-diagnostic"
  "muhtari-battery-v1"
  "34,816 bytes"
  "muhtari_save_oracle.h"
  "The offset derivation is source-derived from the exact pinned diagnostic and layout documentation."
  "The installed consumer verified the full 34,816-byte aggregate at both the 1/1 and 2/2 checkpoints."
  "1/1"
  "2/2"
  "0x0100"
  "0x6800"
  "temporary file in the destination directory"
  "before rename"
  "prior committed file and its"
  "host acknowledgment remain byte-for-byte unchanged"
  "temporary file is removed"
  "distinct fresh process"
  "ordinary rename commit point"
  "does not establish power-loss or OS-crash"
  "post-rename failure recovery"
  "damaged-storage repair"
  "multi-writer"
  "generalized interruption or retry guarantees"
  "local macOS arm64"
  "four separate invocations"
  "installed libfuturo and Muhtari archives"
)
foreach(_claim IN LISTS _fixture_claims)
  require_phrase("docs/muhtari-save-fixture.md" "${_fixture}" "${_claim}")
endforeach()
reject_phrase("docs/muhtari-save-fixture.md" "${_fixture}"
  "power-loss durability is proven")
reject_phrase("docs/muhtari-save-fixture.md" "${_fixture}"
  "until the installed consumer executes")
reject_phrase("docs/muhtari-save-fixture.md" "${_fixture}"
  "multi-writer behavior is supported")

# Keep API 8 checks scoped to its own profile section and generated fixture;
# the API 7 profile and its historical fixture retain their separate rules.
set(_api8_profile_claims
  "Muhtari v0.11.1 at source commit"
  "d58f125297c4d63a7a8108112a5eafff6f53a76a"
  "API revision 8, ABI revision 1, behavior revision 6, and native state format 1"
  "muhtari-ntsc-battery-diagnostic"
  "effective options `none`"
  "16,512 A78 bytes with SHA-256"
  "136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e"
  "34,816 bytes"
  "LIBFUTURO_MUHTARI_API_REVISION=8"
  "explicit diagnostic configuration"
  "Snapshot capability, size, capture, and restore are unsupported for the API 7 profile"
  "libfuturo_MUHTARI_API_REVISION"
  "muhtari_SOURCE_REVISION"
  "moved-installed public routes"
  "R2 after frame 2"
  "aggregate offset 2051"
  "frame 3"
  "B compares media generation only with its own pre-restore value"
  "pre-rename failure"
  "local macOS arm64"
  "without sandboxing or crash isolation"
)
foreach(_claim IN LISTS _api8_profile_claims)
  require_phrase("Muhtari API 8 profile section" "${_api8_profile_section}"
    "${_claim}")
endforeach()

set(_api8_contract_claims
  "API 8 Muhtari exception"
  "profile `muhtari-ntsc-v2`"
  "exact LibFuturo and Muhtari builds"
  "explicit configuration ID"
  "loaded-content digest, and exact extents"
  "aggregate offset 2051"
  "publishes"
  "full media span, local generation"
  "host owns checkpoint/save paths"
  "controlled pre-rename failure"
  "not authenticity"
  "uncertain post-rename recovery"
)
foreach(_claim IN LISTS _api8_contract_claims)
  require_phrase("docs/contract.md" "${_contract}" "${_claim}")
endforeach()

set(_api8_fixture_claims
  "tests/installed-consumer/muhtari_snapshot_fixture.h"
  "16,512 bytes"
  "136cbead3da4bde24ea23acf36eb8daacced88074bbe021888aa4e17d987195e"
  "34,816 bytes"
  "R2 after frame 2 with the SaveKey page pending"
  "The pending page then publishes"
  "0x5A"
  "muhtari_api8_source_fresh_process"
  "muhtari_api8_installed_fresh_process"
  "checksum-valid native semantic-invalid state"
  "selected R3"
  "pre-rename save replacement failure"
  "they do not establish crash, abrupt-exit"
  "stable API/ABI/native state format"
)
foreach(_claim IN LISTS _api8_fixture_claims)
  require_phrase("docs/muhtari-snapshot-fixture.md" "${_snapshot_fixture}"
    "${_claim}")
endforeach()

message(STATUS
  "muhtari_documentation_contract: selectors, topology, media ownership, fixture provenance, pre-rename boundary, and recovery limits verified")
message(STATUS
  "muhtari_api8_documentation_contract: exact profile, fixture, pending-page route, host custody, and limits verified")
