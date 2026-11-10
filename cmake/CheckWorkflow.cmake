cmake_minimum_required(VERSION 3.25)

if(NOT DEFINED WORKFLOW_FILE OR WORKFLOW_FILE STREQUAL "")
  set(WORKFLOW_FILE "${CMAKE_CURRENT_LIST_DIR}/../.github/workflows/native.yml")
endif()
if(NOT EXISTS "${WORKFLOW_FILE}")
  message(FATAL_ERROR "workflow contract: file does not exist: ${WORKFLOW_FILE}")
endif()

get_filename_component(_workflow_name "${WORKFLOW_FILE}" NAME)
if(DEFINED WORKFLOW_KIND AND NOT WORKFLOW_KIND STREQUAL "")
  set(_workflow_kind "${WORKFLOW_KIND}")
elseif(_workflow_name STREQUAL "browser.yml")
  set(_workflow_kind "browser")
else()
  set(_workflow_kind "native")
endif()

set(_expected_events [=[on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
  merge_group:
    types: [checks_requested]]=])
set(_expected_checkout [=[      - name: Check out source
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false]=])

if(_workflow_kind STREQUAL "native")
  set(_expected_name "Native validation")
  set(_after_events_marker "\n\nconcurrency:")
  set(_expected_workflow [=[name: Native validation

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
  merge_group:
    types: [checks_requested]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  native:
    name: macOS arm64 native checks
    runs-on: macos-15
    timeout-minutes: 20
    permissions:
      contents: read
    steps:
      - name: Check out source
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Run canonical checks
        run: ./scripts/check.sh
]=])
elseif(_workflow_kind STREQUAL "browser")
  set(_expected_name "Browser qualification")
  set(_after_events_marker "\n\njobs:")
  set(_expected_workflow [=[name: Browser qualification

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
  merge_group:
    types: [checks_requested]

jobs:
  browser:
    name: Linux browser qualification
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    permissions:
      contents: read
    steps:
      - name: Check out source
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Run canonical browser qualification
        run: ./scripts/check-browser-package.sh
]=])
else()
  message(FATAL_ERROR "workflow contract: unsupported workflow kind '${_workflow_kind}'")
endif()

file(READ "${WORKFLOW_FILE}" _workflow_content)
string(FIND "${_workflow_content}" "\non:\n" _on_marker)
if(_on_marker EQUAL -1)
  if(_workflow_content MATCHES "(^|\n)on:[ \t]*(push|pull_request|workflow_dispatch|merge_group)(\n|$)")
    message(FATAL_ERROR "workflow contract: unexpected trigger syntax; only the authored recurring event block is allowed")
  endif()
  message(FATAL_ERROR "workflow contract: missing literal recurring trigger block")
endif()
math(EXPR _on_start "${_on_marker} + 1")
string(SUBSTRING "${_workflow_content}" ${_on_start} -1 _after_on)
string(FIND "${_after_on}" "${_after_events_marker}" _events_end)
if(_events_end EQUAL -1)
  message(FATAL_ERROR "workflow contract: unexpected trigger syntax or unsupported top-level key")
endif()
string(SUBSTRING "${_after_on}" 0 ${_events_end} _actual_events)
if(NOT "${_actual_events}" STREQUAL "${_expected_events}")
  message(FATAL_ERROR
    "workflow contract: unexpected trigger or trigger filter; expected exactly pull_request, main push, workflow_dispatch, and merge_group checks_requested")
endif()

if(NOT "${_workflow_content}" STREQUAL "${_expected_workflow}")
  message(FATAL_ERROR
    "workflow contract: authored ${_workflow_kind} workflow differs from the reviewed least-privilege, unconditional canonical contract")
endif()

if(_workflow_kind STREQUAL "native")
  message(STATUS "workflow contract: recurring macos-15 arm64 job, read-only checkout, and canonical ./scripts/check.sh verified")
else()
  message(STATUS "workflow contract: recurring ubuntu-24.04 browser job, read-only checkout, and canonical browser package command verified")
endif()
