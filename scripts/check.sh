#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/process-tree-cleanup.sh"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
if [[ "$OS_NAME" != "Darwin" || "$ARCH_NAME" != "arm64" ]]; then
  printf 'error: required profile is Darwin/arm64; found %s/%s\n' "$OS_NAME" "$ARCH_NAME" >&2
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  printf '%s\n' 'error: xcrun is required to select the macOS Clang and SDK' >&2
  exit 2
fi
CLANG_PATH="$(xcrun --find clang)"
SDK_PATH="$(xcrun --show-sdk-path)"
SDK_VERSION="$(xcrun --show-sdk-version)"
MACOS_PRODUCT="$(sw_vers -productName)"
MACOS_VERSION="$(sw_vers -productVersion)"
if [[ -z "$CLANG_PATH" || -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  printf '%s\n' 'error: selected Clang or macOS SDK is unavailable' >&2
  exit 2
fi

printf 'Profile: %s %s (%s/%s)\n' "$MACOS_PRODUCT" "$MACOS_VERSION" "$OS_NAME" "$ARCH_NAME"
printf 'Clang: %s (%s)\n' "$CLANG_PATH" "$("$CLANG_PATH" --version | head -n 1)"
printf 'CMake: %s (%s)\n' "$(command -v cmake)" "$(cmake --version | head -n 1)"
printf 'CTest: %s (%s)\n' "$(command -v ctest)" "$(ctest --version | head -n 1)"
printf 'SDK: macOS %s at %s\n' "$SDK_VERSION" "$SDK_PATH"
printf 'GitHub runner image: ImageOS=%s ImageVersion=%s\n' \
  "${ImageOS:-not-provided}" "${ImageVersion:-not-provided}"

BUILD_DIR="$ROOT_DIR/build/check"
NETWORK_CONFIGURE_TIMEOUT_SECONDS=300
BUILD_TIMEOUT_SECONDS=180
CONFIGURE_ELAPSED_SECONDS=
BUILD_ELAPSED_SECONDS=
CTEST_ELAPSED_SECONDS=
RELOCATION_ELAPSED_SECONDS=
FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS=

WORKFLOW_CONTROL_FILES=()
cleanup_workflow_controls() {
  local control_file
  if (( ${#WORKFLOW_CONTROL_FILES[@]} == 0 )); then
    return
  fi
  for control_file in "${WORKFLOW_CONTROL_FILES[@]}"; do
    rm -f "$control_file"
  done
}
trap cleanup_workflow_controls EXIT

assert_workflow_rejects_event() {
  local trigger_key="$1"
  local label="$2"
  local control_file
  local checker_output

  control_file="$(mktemp "${TMPDIR:-/tmp}/libfuturo-workflow.XXXXXX")"
  WORKFLOW_CONTROL_FILES+=("$control_file")
  if ! LF_WORKFLOW_CONTROL_TRIGGER="$trigger_key" awk '
      BEGIN { trigger_key = ENVIRON["LF_WORKFLOW_CONTROL_TRIGGER"] }
      { print }
      $0 == "  workflow_dispatch:" {
        print "  " trigger_key ":"
        inserted += 1
      }
      END { if (inserted != 1) exit 1 }
    ' "$ROOT_DIR/.github/workflows/native.yml" > "$control_file"; then
    printf 'error: could not create the %s workflow negative control\n' "$label" >&2
    return 1
  fi

  if checker_output="$(cmake "-DWORKFLOW_FILE=$control_file" \
      -P "$ROOT_DIR/cmake/CheckWorkflow.cmake" 2>&1)"; then
    printf 'error: workflow checker accepted %s extra event key\n' "$label" >&2
    return 1
  fi
  if ! grep -Fq 'workflow contract: unexpected trigger' <<< "$checker_output"; then
    printf 'error: %s negative control failed for an unexpected reason:\n%s\n' \
      "$label" "$checker_output" >&2
    return 1
  fi
  printf 'Workflow checker rejected %s extra event key\n' "$label"
}

cmake "-DWORKFLOW_FILE=$ROOT_DIR/.github/workflows/native.yml" \
  -P "$ROOT_DIR/cmake/CheckWorkflow.cmake"
assert_workflow_rejects_event "push" "unquoted"
assert_workflow_rejects_event '"push"' "double-quoted"
assert_workflow_rejects_event "'pull_request'" "single-quoted"
assert_workflow_rejects_event '"\u0070ush"' "escaped"
assert_workflow_rejects_event '<<' "merge-key"
cleanup_workflow_controls
trap - EXIT

run_bounded() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2

  LF_PROCESS_TREE_ACTIVE_PID=
  LF_PROCESS_TREE_CANCEL_SIGNAL=none
  LF_PROCESS_TREE_CLEANUP_ACTIVE=0
  LF_PROCESS_TREE_CLEANUP_FAILED=0
  trap 'lf_process_tree_cancel_handler INT' INT
  trap 'lf_process_tree_cancel_handler TERM' TERM
  trap 'lf_process_tree_cancel_handler HUP' HUP
  trap 'lf_process_tree_cancel_handler QUIT' QUIT

  printf 'Running %s (timeout %ss)\n' "$label" "$timeout_seconds"
  lf_process_tree_start "$@"
  local command_pid=$LF_PROCESS_TREE_ROOT
  LF_PROCESS_TREE_ACTIVE_PID="$command_pid"
  local started_at=$SECONDS
  local timed_out=0
  local cleanup_failed=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if [[ "$LF_PROCESS_TREE_CANCEL_SIGNAL" != none ]]; then
      break
    fi
    if (( SECONDS - started_at >= timeout_seconds )); then
      timed_out=1
      LF_PROCESS_TREE_CLEANUP_ACTIVE=1
      if ! lf_process_tree_terminate "$command_pid"; then
        cleanup_failed=1
      else
        LF_PROCESS_TREE_ACTIVE_PID=
      fi
      LF_PROCESS_TREE_CLEANUP_ACTIVE=0
      break
    fi
    sleep 1 || true
  done

  # A signal can arrive after the trap is installed but before the new PID is
  # registered. Clean up that just-started group before returning cancellation.
  if [[ "$LF_PROCESS_TREE_CANCEL_SIGNAL" != none && "$LF_PROCESS_TREE_ACTIVE_PID" == "$command_pid" &&
        "$LF_PROCESS_TREE_CLEANUP_FAILED" == 0 && "$LF_PROCESS_TREE_CLEANUP_ACTIVE" == 0 ]] &&
      kill -0 "$command_pid" 2>/dev/null; then
    LF_PROCESS_TREE_CLEANUP_ACTIVE=1
    if ! lf_process_tree_terminate "$command_pid"; then
      cleanup_failed=1
    else
      LF_PROCESS_TREE_ACTIVE_PID=
    fi
    LF_PROCESS_TREE_CLEANUP_ACTIVE=0
  fi

  local command_status=0
  wait "$command_pid" || command_status=$?
  LF_PROCESS_TREE_ACTIVE_PID=
  trap - INT TERM HUP QUIT
  local elapsed_seconds=$((SECONDS - started_at))
  case "$label" in
    "CMake configure and public dependency fetch") CONFIGURE_ELAPSED_SECONDS="$elapsed_seconds" ;;
    "required CMake build") BUILD_ELAPSED_SECONDS="$elapsed_seconds" ;;
    "relocated installed consumer save/restart") RELOCATION_ELAPSED_SECONDS="$elapsed_seconds" ;;
    "relocated installed consumer fresh-process snapshot") FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS="$elapsed_seconds" ;;
  esac
  if [[ "$LF_PROCESS_TREE_CLEANUP_FAILED" != 0 ]]; then
    cleanup_failed=1
  fi
  if (( cleanup_failed )); then
    printf 'error: bounded %s left a process alive after cleanup\n' "$label" >&2
    return 125
  fi
  case "$LF_PROCESS_TREE_CANCEL_SIGNAL" in
    INT) return 130 ;;
    TERM) return 143 ;;
    HUP) return 129 ;;
    QUIT) return 131 ;;
  esac
  if (( timed_out )); then
    printf 'error: %s exceeded its %ss timeout\n' "$label" "$timeout_seconds" >&2
    return 124
  fi
  return "$command_status"
}

if run_bounded "CMake configure and public dependency fetch" \
    "$NETWORK_CONFIGURE_TIMEOUT_SECONDS" \
    cmake -S "$ROOT_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_COMPILER="$CLANG_PATH" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
      -DFETCHCONTENT_QUIET=OFF \
      -DLIBFUTURO_ENABLE_MUHTARI=ON; then
  :
else
  exit "$?"
fi

if ! grep -Fqx 'LIBFUTURO_ENABLE_MUHTARI:BOOL=ON' "$BUILD_DIR/CMakeCache.txt"; then
  printf '%s\n' 'error: canonical configure did not retain LIBFUTURO_ENABLE_MUHTARI=ON' >&2
  exit 3
fi

TEST_MANIFEST="$BUILD_DIR/required-tests.txt"
TARGET_MANIFEST="$BUILD_DIR/required-targets.txt"
if [[ ! -s "$TEST_MANIFEST" ]]; then
  printf '%s\n' 'error: CMake registered no required tests' >&2
  exit 3
fi
if [[ ! -s "$TARGET_MANIFEST" ]]; then
  printf '%s\n' 'error: CMake registered no required build targets' >&2
  exit 3
fi

REQUIRED_TESTS=()
while IFS= read -r test_name; do
  [[ -z "$test_name" ]] || REQUIRED_TESTS+=("$test_name")
done < "$TEST_MANIFEST"
REQUIRED_TARGETS=()
while IFS= read -r target_name; do
  [[ -z "$target_name" ]] || REQUIRED_TARGETS+=("$target_name")
done < "$TARGET_MANIFEST"
if (( ${#REQUIRED_TESTS[@]} == 0 || ${#REQUIRED_TARGETS[@]} == 0 )); then
  printf '%s\n' 'error: required test/target manifest is empty' >&2
  exit 3
fi

EXPECTED_REQUIRED_TESTS=(
  synthetic_tracer
  synthetic_session
  synthetic_boundaries
  oracle_negative_control
  nesturbator_probe
  nesturbator_session
  nesturbator_source_snapshot_capability_controls
  nesturbator_installed_snapshot_capability_controls
  nesturbator_snapshot_replay
  nesturbator_snapshot_refusals
  nesturbator_snapshot_oracle_control
  nesturbator_fresh_process_snapshot
  nesturbator_battery_fresh_process_snapshot
  nesturbator_fresh_process_supervisor_controls
  nesturbator_battery_snapshot_recovery
  nesturbator_battery_snapshot_oracle_control
  muhtari_session
  muhtari_load_refusals
  muhtari_frame_boundaries
  muhtari_example
  muhtari_oracle_negative_control
  muhtari_save_oracle_negative_control
  muhtari_guest_limit
  muhtari_test_seam_scope
  muhtari_package_modes
  installed_macos_host
  nesturbator_load_corpus
  instrumentation_scope
  nesturbator_load_allocations
  nesturbator_load_positives
  nesturbator_ines_legacy_chr_ram
  nesturbator_load_oracle_controls
  nesturbator_save_restart
  nesturbator_load_failures
  nesturbator_frame_failures
  nesturbator_oracle_negative_control
  conformance
  required_result_controls
  process_tree_cleanup
  contract_traceability
)
EXPECTED_TEST_LIST="$(printf '%s\n' "${EXPECTED_REQUIRED_TESTS[@]}" | LC_ALL=C sort)"
ACTUAL_TEST_LIST="$(printf '%s\n' "${REQUIRED_TESTS[@]}" | LC_ALL=C sort)"
if [[ "$ACTUAL_TEST_LIST" != "$EXPECTED_TEST_LIST" ]]; then
  printf '%s\n' 'error: required-test manifest differs from the canonical inventory' >&2
  diff -u <(printf '%s\n' "$EXPECTED_TEST_LIST") \
    <(printf '%s\n' "$ACTUAL_TEST_LIST") >&2 || true
  exit 3
fi

EXPECTED_REQUIRED_TARGETS=(
  libfuturo
  libfuturo_test
  synthetic_host
  synthetic_session
  synthetic_boundaries
  nesturbator_probe
  nesturbator_session
  muhtari_session
  muhtari_save_oracle_probe
  muhtari_host
  muhtari_boundaries
  muhtari_test_adapter
  nesturbator_source_snapshot_capability_controls
  nesturbator_installed_snapshot_capability_controls
  nesturbator_load_corpus
  conformance
)
EXPECTED_TARGET_LIST="$(printf '%s\n' "${EXPECTED_REQUIRED_TARGETS[@]}" | LC_ALL=C sort)"
ACTUAL_TARGET_LIST="$(printf '%s\n' "${REQUIRED_TARGETS[@]}" | LC_ALL=C sort -u)"
if [[ "$ACTUAL_TARGET_LIST" != "$EXPECTED_TARGET_LIST" ]]; then
  printf '%s\n' 'error: required-target manifest differs from the canonical target set' >&2
  diff -u <(printf '%s\n' "$EXPECTED_TARGET_LIST") \
    <(printf '%s\n' "$ACTUAL_TARGET_LIST") >&2 || true
  exit 3
fi

RESULT_MANIFEST="$BUILD_DIR/required-route-results.txt"
if [[ ! -s "$RESULT_MANIFEST" ]]; then
  printf '%s\n' 'error: CMake registered no required route results' >&2
  exit 3
fi
EXPECTED_ROUTE_ROWS=()
for test_name in "${EXPECTED_REQUIRED_TESTS[@]}"; do
  EXPECTED_ROUTE_ROWS+=("ctest|$test_name|required")
done
EXPECTED_ROUTE_ROWS+=(
  'consumer|installed_consumer_save_restart|required'
  'consumer|installed_consumer_snapshot|required'
  'consumer|source_fresh_process_snapshot|required'
  'consumer|installed_consumer_fresh_process_snapshot|required'
  'consumer|source_battery_fresh_process_snapshot|required'
  'consumer|installed_consumer_battery_fresh_process_snapshot|required'
  'consumer|installed_consumer_battery_snapshot|required'
  'consumer|installed_consumer_load_refusal|required'
  'consumer|installed_muhtari_session|required'
  'consumer|installed_muhtari_save_restart|required'
  'consumer|installed_macos_host|required'
  'unsupported|hosted_current_profile|unsupported'
)
EXPECTED_ROUTE_LIST="$(printf '%s\n' "${EXPECTED_ROUTE_ROWS[@]}" | LC_ALL=C sort)"
ACTUAL_ROUTE_LIST="$(LC_ALL=C sort "$RESULT_MANIFEST")"
if [[ "$ACTUAL_ROUTE_LIST" != "$EXPECTED_ROUTE_LIST" ]]; then
  printf '%s\n' 'error: canonical required-result manifest differs from its expected route' >&2
  diff -u <(printf '%s\n' "$EXPECTED_ROUTE_LIST") \
    <(printf '%s\n' "$ACTUAL_ROUTE_LIST") >&2 || true
  exit 3
fi

if run_bounded "required CMake build" "$BUILD_TIMEOUT_SECONDS" \
    cmake --build "$BUILD_DIR" --target "${REQUIRED_TARGETS[@]}"; then
  :
else
  exit "$?"
fi

CTEST_LOG="$BUILD_DIR/ctest-output.log"
CTEST_JUNIT="$BUILD_DIR/ctest-results.junit.xml"
CTEST_INVENTORY="$BUILD_DIR/ctest-inventory.json"
CTEST_PROCESS_FACTS="$BUILD_DIR/ctest-process-facts.txt"
REQUIRED_RESULTS="$BUILD_DIR/required-results.tsv"
EXPECTED_MARKERS_FILE="$BUILD_DIR/expected-result-markers.txt"
SOURCE_FRESH_PROCESS_REPORT="$BUILD_DIR/fresh-process-source-report.txt"
SOURCE_BATTERY_FRESH_PROCESS_REPORT="$BUILD_DIR/battery-fresh-process-source-report.txt"
FRESH_PROCESS_RELOCATION_LOG="$BUILD_DIR/fresh-process-relocation-consumer.log"
FRESH_PROCESS_RELOCATION_REPORT="$BUILD_DIR/relocation-reports/absent-fresh-process-report.txt"
FRESH_PROCESS_RELOCATION_STATUS=0
BATTERY_FRESH_PROCESS_RELOCATION_LOG="$BUILD_DIR/battery-fresh-process-relocation-consumer.log"
BATTERY_FRESH_PROCESS_RELOCATION_REPORT="$BUILD_DIR/relocation-reports/absent-battery-fresh-process-report.txt"
BATTERY_FRESH_PROCESS_RELOCATION_STATUS=0
BATTERY_FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS=0
rm -f "$CTEST_LOG" "$CTEST_JUNIT" "$CTEST_INVENTORY" \
  "$CTEST_PROCESS_FACTS" "$SOURCE_FRESH_PROCESS_REPORT" \
  "$SOURCE_BATTERY_FRESH_PROCESS_REPORT" "$FRESH_PROCESS_RELOCATION_LOG" \
  "$BATTERY_FRESH_PROCESS_RELOCATION_LOG"

if ! ctest --test-dir "$BUILD_DIR" --show-only=json-v1 > "$CTEST_INVENTORY"; then
  printf '%s\n' 'error: CTest could not produce its fresh JSON-v1 test inventory' >&2
  exit 4
fi

CTEST_PID=
CTEST_SIGNAL=none
CTEST_CLEANUP_STARTED=no
CTEST_STARTED_AT=$SECONDS
on_ctest_signal() {
  CTEST_SIGNAL="$1"
  if [[ -n "$CTEST_PID" && "$CTEST_CLEANUP_STARTED" == no ]]; then
    CTEST_CLEANUP_STARTED=yes
    lf_process_tree_begin_cleanup "$CTEST_PID"
  fi
}
trap 'on_ctest_signal INT' INT
trap 'on_ctest_signal TERM' TERM
trap 'on_ctest_signal HUP' HUP
trap 'on_ctest_signal QUIT' QUIT
lf_process_tree_start env \
  "ASAN_OPTIONS=${ASAN_OPTIONS:+${ASAN_OPTIONS}:}halt_on_error=1" \
  "UBSAN_OPTIONS=${UBSAN_OPTIONS:+${UBSAN_OPTIONS}:}halt_on_error=1:print_stacktrace=1" \
  ctest --test-dir "$BUILD_DIR" --output-on-failure --verbose --no-tests=error \
  --output-junit "$CTEST_JUNIT" > "$CTEST_LOG" 2>&1
CTEST_PID=$LF_PROCESS_TREE_ROOT
if [[ "$CTEST_SIGNAL" != none && "$CTEST_CLEANUP_STARTED" == no ]]; then
  # A signal may arrive between installing the trap and registering the PID.
  CTEST_CLEANUP_STARTED=yes
  lf_process_tree_begin_cleanup "$CTEST_PID"
fi
CTEST_STATUS=0
if wait "$CTEST_PID" 2>/dev/null; then
  CTEST_STATUS=0
else
  CTEST_STATUS=$?
fi
if [[ "$CTEST_SIGNAL" != none && -n "$CTEST_PID" ]]; then
  # Bash may interrupt wait when a trapped signal arrives. Keep the process
  # group ID until its descendants and direct child have stopped and been reaped.
  if ! lf_process_tree_finish_cleanup "$CTEST_PID"; then
    printf '%s\n' 'error: CTest process group remained alive after cancellation cleanup' >&2
    exit 6
  fi
  FINAL_CTEST_STATUS=0
  if wait "$CTEST_PID" 2>/dev/null; then
    FINAL_CTEST_STATUS=0
  else
    FINAL_CTEST_STATUS=$?
  fi
  if [[ "$FINAL_CTEST_STATUS" != 127 ]]; then
    CTEST_STATUS="$FINAL_CTEST_STATUS"
  fi
fi
if [[ "$CTEST_SIGNAL" == none && "$CTEST_STATUS" == 130 ]]; then
  CTEST_SIGNAL=INT
elif [[ "$CTEST_SIGNAL" == none && "$CTEST_STATUS" == 143 ]]; then
  CTEST_SIGNAL=TERM
elif [[ "$CTEST_SIGNAL" == none && "$CTEST_STATUS" == 131 ]]; then
  CTEST_SIGNAL=QUIT
fi
CTEST_ELAPSED_SECONDS=$((SECONDS - CTEST_STARTED_AT))
printf 'format=libfuturo-ctest-process-v1\nctest_pid=%s\nexit_status=%s\nsignal=%s\ntimed_out=no\ninventory=ctest-inventory.json\njunit=ctest-results.junit.xml\nlog=ctest-output.log\n' \
  "$CTEST_PID" "$CTEST_STATUS" "$CTEST_SIGNAL" > "$CTEST_PROCESS_FACTS"
CTEST_PID=
trap - INT TERM HUP
trap - QUIT
cat "$CTEST_LOG"

ctest_case_elapsed_seconds() {
  local test_name="$1"
  local elapsed
  elapsed="$({ grep -F "<testcase name=\"$test_name\"" "$CTEST_JUNIT" || true; } \
    | sed -nE 's/.* time="([0-9]+([.][0-9]+)?)".*/\1/p' | head -n 1)"
  if [[ ! "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'error: CTest JUnit has no finite elapsed time for %s\n' "$test_name" >&2
    return 1
  fi
  printf '%s' "$elapsed"
}

CORPUS_CTEST_SECONDS="$(ctest_case_elapsed_seconds nesturbator_load_corpus)"
ALLOCATION_CTEST_SECONDS="$(ctest_case_elapsed_seconds nesturbator_load_allocations)"
CONTROL_CTEST_SECONDS="$(ctest_case_elapsed_seconds required_result_controls)"
INSTRUMENTATION_CTEST_SECONDS="$(ctest_case_elapsed_seconds instrumentation_scope)"

MACOS_HOST_REPORT="$BUILD_DIR/relocation-reports/absent-macos-host-report.txt"
MACOS_HOST_REPORT_REL="$(sed -nE \
  's/^[0-9]+: relocation consumer: macOS host passed; evidence=(.*)$/\1/p' \
  "$CTEST_LOG" | tail -n 1)"
if [[ -n "$MACOS_HOST_REPORT_REL" && "$MACOS_HOST_REPORT_REL" != /* &&
      -f "$ROOT_DIR/$MACOS_HOST_REPORT_REL" ]]; then
  MACOS_HOST_REPORT="$ROOT_DIR/$MACOS_HOST_REPORT_REL"
fi

RELOCATION_LOG="$BUILD_DIR/relocation-consumer.log"
RELOCATION_REPORT="$BUILD_DIR/relocation-reports/absent-required-report.txt"
RELOCATION_STATUS=0
if [[ "$CTEST_SIGNAL" == none ]]; then
  rm -f "$RELOCATION_LOG"
  if run_bounded "relocated installed consumer save/restart" 300 \
      sh tests/installed-consumer/relocate-consumer.sh --save-restart \
      > "$RELOCATION_LOG" 2>&1; then
    :
  else
    RELOCATION_STATUS=$?
  fi
  cat "$RELOCATION_LOG"
  RELOCATION_REPORT_REL="$(sed -nE \
    's/^relocation consumer: save\/restart (passed|failed); evidence=//p' \
    "$RELOCATION_LOG" | tail -n 1)"
  if [[ -n "$RELOCATION_REPORT_REL" && -f "$ROOT_DIR/$RELOCATION_REPORT_REL" ]]; then
    RELOCATION_REPORT="$ROOT_DIR/$RELOCATION_REPORT_REL"
  fi

  if run_bounded "relocated installed consumer fresh-process snapshot" 300 \
      sh tests/installed-consumer/relocate-consumer.sh --fresh-process-snapshot \
      > "$FRESH_PROCESS_RELOCATION_LOG" 2>&1; then
    :
  else
    FRESH_PROCESS_RELOCATION_STATUS=$?
  fi
  cat "$FRESH_PROCESS_RELOCATION_LOG"
  FRESH_PROCESS_RELOCATION_REPORT_REL="$(sed -nE \
    's/^relocation consumer: fresh-process snapshot passed; evidence=//p' \
    "$FRESH_PROCESS_RELOCATION_LOG" | tail -n 1)"
  if [[ -n "$FRESH_PROCESS_RELOCATION_REPORT_REL" && \
        "$FRESH_PROCESS_RELOCATION_REPORT_REL" != /* && \
        -f "$ROOT_DIR/$FRESH_PROCESS_RELOCATION_REPORT_REL" ]]; then
    FRESH_PROCESS_RELOCATION_REPORT="$ROOT_DIR/$FRESH_PROCESS_RELOCATION_REPORT_REL"
  fi

  BATTERY_FRESH_PROCESS_STARTED_AT=$SECONDS
  if run_bounded "relocated installed battery fresh-process snapshot" 300 \
      sh tests/installed-consumer/relocate-consumer.sh --battery-fresh-process-snapshot \
      > "$BATTERY_FRESH_PROCESS_RELOCATION_LOG" 2>&1; then
    :
  else
    BATTERY_FRESH_PROCESS_RELOCATION_STATUS=$?
  fi
  BATTERY_FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS=$((SECONDS - BATTERY_FRESH_PROCESS_STARTED_AT))
  cat "$BATTERY_FRESH_PROCESS_RELOCATION_LOG"
  BATTERY_FRESH_PROCESS_MARKER_COUNT=$(grep -Ec \
    '^relocation consumer: battery fresh-process snapshot passed; evidence=' \
    "$BATTERY_FRESH_PROCESS_RELOCATION_LOG" || true)
  BATTERY_FRESH_PROCESS_RELOCATION_REPORT_REL="$(sed -nE \
    's/^relocation consumer: battery fresh-process snapshot passed; evidence=(build\/check\/relocation-reports\/relocate-[A-Za-z0-9._-]+[.]txt)$/\1/p' \
    "$BATTERY_FRESH_PROCESS_RELOCATION_LOG" | tail -n 1)"
  if [[ "$BATTERY_FRESH_PROCESS_MARKER_COUNT" -eq 1 && \
        -n "$BATTERY_FRESH_PROCESS_RELOCATION_REPORT_REL" && \
        -f "$ROOT_DIR/$BATTERY_FRESH_PROCESS_RELOCATION_REPORT_REL" ]]; then
    BATTERY_FRESH_PROCESS_RELOCATION_REPORT="$ROOT_DIR/$BATTERY_FRESH_PROCESS_RELOCATION_REPORT_REL"
  else
    BATTERY_FRESH_PROCESS_RELOCATION_STATUS=1
  fi
fi

cat > "$EXPECTED_MARKERS_FILE" <<'MARKERS'
nesturbator_probe|nesturbator_probe: source=2338608ab184f040620a30d17756f5e06a42d4e3 lifecycle=create,destroy result=pass
nesturbator_session|nesturbator_session: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom load,input,frame,av,close result=pass
nesturbator_source_snapshot_capability_controls|snapshot_capability_controls: route=source entries=A,B denied=zero-snapshot-calls result=pass
nesturbator_installed_snapshot_capability_controls|snapshot_capability_controls: route=installed entries=A,B denied=zero-snapshot-calls result=pass
nesturbator_snapshot_replay|nesturbator_snapshot_replay: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom capability,capture,replay=frame3,ticks2144304,av-literal result=pass
nesturbator_snapshot_refusals|nesturbator_snapshot_refusals: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 fixture=generated-nrom cases=envelope,native,foreign-content,battery,session-overflow,reloaded-capacity continuation=literal result=pass
nesturbator_snapshot_oracle_control|snapshot replay failed at stage 5
nesturbator_fresh_process_snapshot|event=supervisor-success
nesturbator_battery_fresh_process_snapshot|event=battery-save-custody-r3-imported-r2-restored-r2-committed
nesturbator_battery_fresh_process_snapshot|nesturbator_battery_fresh_process_snapshot: result=pass
nesturbator_fresh_process_supervisor_controls|nesturbator_supervisor_controls: failure-stops, battery-failure-stops, valid-order-starts-b result=pass
nesturbator_battery_snapshot_recovery|nesturbator_battery_snapshot: route=source source=2338608ab184f040620a30d17756f5e06a42d4e3 release=v0.1.12 build=nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 api=1 behavior=9 state-format=3 configuration=nesturbator-default fixture=generated-battery-mmc1-v1 bytes=40976 sha256=2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 media=full-span-8192,restored-literal capture=2 newer=3 restored=2 replay=frame3,ticks2144280,rgb5a5a5a,audio799 generation=changed-once,identical-unchanged refusal-vector=continuation,media,generation,selected-save,ack foreign=altered-mmc1,mmc3-refused failed-replacement=prior-commit-and-ack-preserved recovery=prior-exact,restored-selected,reopened-exact result=pass
nesturbator_battery_snapshot_oracle_control|nesturbator_battery_snapshot_oracle_control: route=source progress,video,audio,media=rejected result=pass
muhtari_session|muhtari_session: source=d5fd241e3f4d701d73867cc2e465c56a6fe6793d profile=muhtari-ntsc-v1 fixture=owned-a78-linear-16k ports=two first_samples=54 steady_samples=801 raw_video=INDEX8 non_silent_audio=pass result=pass
muhtari_load_refusals|muhtari_load_refusals: cases=8 histories=loaded,unloaded continuation=3 allocation-ordinals=measured default-reset=pass result=pass
muhtari_frame_boundaries|muhtari_frame_boundaries: rejected=14 unsupported-input-bits=6 stride=319,320,321 video-extent=minus-one,exact,plus-one stride-overflow=multiply,add audio-capacity=800,801,802 zero-work=noop result=pass
muhtari_example|muhtari_example: fixture=owned-a78-linear-16k bytes=16512 sha256=783bcf1c6dd15433451c4d05f03bf8b7cd4d1923fb24cc50ee80548a5a904256 source=project-authored-C-generator license=Apache-2.0 example=partial-and-steady-public-session result=pass
installed_macos_host|installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass
muhtari_oracle_negative_control|muhtari_oracle_negative_control: detected expected indexed mismatch normal-exit=0 wrong-exit=1
muhtari_guest_limit|muhtari_guest_limit: cumulative=UINT32_MAX exact one-over=rejected zero-work=noop next-native-interval=oracle-match allocation-free-advances=4 create-failure-ordinals=complete setup-allocations=measured result=pass
muhtari_test_seam_scope|muhtari_test_seam_scope: production=absent test=private result=pass
muhtari_package_modes|muhtari_package_modes: default-off=consumer,artifacts,profile-unavailable core-target-conflicts=nesturbator,muhtari pipe-prefix=accepted override=exact-source-gate result=pass
nesturbator_load_corpus|nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=all executed=307/expected=307 immediate-media=full continuation-frames=3 assertion-complete=true result=pass
instrumentation_scope|instrumentation_scope: controls=10 actual_units=23 normal_archives=clean assertion-complete=true result=pass
nesturbator_load_allocations|nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=allocations layout_count=21 observed_ordinals=complete histories=unloaded,loaded ownership-balanced=true assertion-complete=true result=pass
nesturbator_load_positives|nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 recipe=lf-load-matrix-1 mode=positives cases=default-explicit,replacement-reset,trainer-p05 assertion-complete=true result=pass
nesturbator_ines_legacy_chr_ram|nesturbator_load_corpus: source=2338608ab184f040620a30d17756f5e06a42d4e3 profile=nesturbator-ntsc-v1 mode=ines-v1-implicit-chr-ram case=I04-01 status=LF_OK continuation-frames=3 result=pass
nesturbator_load_oracle_controls|nesturbator_load_oracle_controls: normal=pass wrong-status=ordinary-mismatch divergence=media-bytes offset=0 result=pass
nesturbator_load_failures|nesturbator_session: load-failures refused-loads=13 allocations=1 result=pass
nesturbator_frame_failures|nesturbator_session: frame-failures capacities=checked jam=latched,reload-recovers result=pass
nesturbator_frame_failures|nesturbator_session: jam-terminal latch-and-reload result=pass
nesturbator_oracle_negative_control|nesturbator_oracle_negative_control: detected expected RGB mismatch (normal exit 0, wrong exit 1)
nesturbator_save_restart|nesturbator_save_restart: fixture-digest=sha256:2282919ee95a168d9f37e972bce7858758eccc724bb3e40279b01735244673a9 result=pass
nesturbator_save_restart|nesturbator_save_restart: real-save-restart=writer,committed-fresh-restorer,failed-update,fresh-restorer result=pass
nesturbator_save_restart|nesturbator_save_restart: failed-write-recovery=old-commit-old-ack-fresh-restorer result=pass
conformance|conformance: positive API assertions pass; isolated load and guest-time violations fail with their exact obligation diagnostics
required_result_controls|required_result_validator: controls=required-positive,missing-registration,missing-report,disabled,failed,skipped,cancelled,evidence-free,advisory-pass,advisory-failure,unsupported,distinct-save-load,missing-load-marker,nonzero-child,timeout,cancelled-child,save-only,unknown-consumer,muhtari-complete,muhtari-missing-marker,muhtari-nonzero-child,muhtari-missing-normal-link,muhtari-legacy-only,muhtari-missing-normal,muhtari-missing-refusal,muhtari-missing-boundaries,muhtari-missing-oracle-control,muhtari-missing-archive,muhtari-nonzero-boundary,muhtari-timeout-boundary,muhtari-cancelled-boundary,muhtari-unexpected-unsupported,muhtari-save-complete,muhtari-save-missing-marker,muhtari-save-wrong-source-pin,muhtari-save-missing-archive,muhtari-save-missing-executable,muhtari-save-missing-oracle-control,muhtari-save-wrong-oracle-marker,muhtari-save-oracle-nonzero-child,muhtari-save-nonzero-child,muhtari-save-cancelled-child,snapshot-complete,snapshot-missing-marker,snapshot-wrong-pin-profile-configuration-fixture-format,snapshot-missing-stage-and-archive-executable-identities,snapshot-wrong-libfuturo-identity,snapshot-wrong-core-identity,snapshot-wrong-executable-identity,snapshot-nonzero-timeout-cancelled-child,fresh-process-source-complete,fresh-process-installed-complete,fresh-process-reordered-events,fresh-process-missing-refusal,fresh-process-missing-marker,fresh-process-wrong-identity,fresh-process-wrong-checkpoint-hash,fresh-process-wrong-checkpoint-extent,fresh-process-missing-artifact,fresh-process-bad-artifact-hash,fresh-process-failed,fresh-process-skipped,fresh-process-timeout,fresh-process-cancelled,fresh-process-nonzero-child,fresh-process-wrong-oracle,fresh-process-wrong-package-artifact,battery-complete,missing-registration-report-result,battery-wrong-pin-release-profile-configuration-fixture-digest-extent-target,wrong-state-format-api-behavior-build,wrong-source-commit-fingerprint,wrong-libfuturo-core-executable-hash,missing-source-and-installed-artifact-hashes,wrong-replay-full-media-generation-refusal-native-identity,wrong-failed-replacement-or-successful-reopen,missing-stage-recovery-oracle-marker,wrong-oracle-marker,recovery-nonzero-skipped-timeout-cancelled,oracle-nonzero-skipped-cancelled,stage-failed,duplicate-identity-child-exit,legacy-snapshot-save-only result=pass
required_result_controls|macos_host_evidence_controls: cases=complete,missing-registration,reordered-report-tests,reordered-inventory-tests,reordered-junit-tests,missing-report,native-marker,missing-cleanup-marker,missing-protocol-marker,cleanup-marker-wrong-test,protocol-marker-wrong-test,retry-markers-wrong-test,audio-missing-format-completion-player-stop-engine-stop-identity,nonzero,timeout,cancelled,skipped,disabled,evidence-free,wrong-pin,wrong-source,package-resolution,artifact-identities,isolation-stage,headless-only,unsupported,duplicate,absolute-path,pid-trailing-garbage result=pass
required_result_controls|required_result_validator_battery: routes=source,installed;controls=positive,identity-pair-mismatch,report-path-run-id-junit-traversal,duplicate-identity-event-refusal,missing-marker-refusal-close-reopen-save-custody,wrong-status-exit-pin-release-build-profile-config-options-native-format-fixture-digest-extent-target-checkpoint-digest-extent,replay-frame-ticks-video-audio-media,generation-binding,source-artifact-missing-bad-hash,installed-executable-package-hash-row result=pass
muhtari_save_oracle_negative_control|muhtari_save_oracle_negative_control: detected expected full-span mismatch normal-exit=0 wrong-exit=1
process_tree_cleanup|process_tree_cleanup: late TERM-resistant descendant stopped after leader exit; result=pass
MARKERS

if ! grep -Eiq 'AddressSanitizer|UndefinedBehaviorSanitizer|runtime error:' \
    "$CTEST_LOG" "$CTEST_JUNIT" 2>/dev/null; then
  SANITIZER_DIAGNOSTICS=no
else
  SANITIZER_DIAGNOSTICS=yes
fi
printf 'sanitizer_diagnostics=%s\n' "$SANITIZER_DIAGNOSTICS" \
  >> "$CTEST_PROCESS_FACTS"

rm -f "$REQUIRED_RESULTS"
cmake \
  "-DRESULT_CASES=actual" \
  "-DRESULT_MANIFEST=$RESULT_MANIFEST" \
  "-DEXPECTED_MARKERS_FILE=$EXPECTED_MARKERS_FILE" \
  "-DCTEST_INVENTORY=$CTEST_INVENTORY" \
  "-DCTEST_JUNIT=$CTEST_JUNIT" \
  "-DCTEST_LOG=$CTEST_LOG" \
  "-DCTEST_PROCESS_FACTS=$CTEST_PROCESS_FACTS" \
  "-DRELOCATION_REPORT=$RELOCATION_REPORT" \
  "-DSOURCE_FRESH_PROCESS_REPORT=$SOURCE_FRESH_PROCESS_REPORT" \
  "-DFRESH_PROCESS_RELOCATION_REPORT=$FRESH_PROCESS_RELOCATION_REPORT" \
  "-DSOURCE_BATTERY_FRESH_PROCESS_REPORT=$SOURCE_BATTERY_FRESH_PROCESS_REPORT" \
  "-DBATTERY_FRESH_PROCESS_RELOCATION_REPORT=$BATTERY_FRESH_PROCESS_RELOCATION_REPORT" \
  "-DMACOS_HOST_REPORT=$MACOS_HOST_REPORT" \
  "-DMACOS_HOST_ARTIFACT_ROOT=$BUILD_DIR" \
  "-DRESULT_OUTPUT=$REQUIRED_RESULTS" \
  "-DRESULT_BASE_DIR=$BUILD_DIR" \
  "-DPRIVATE_ROOT=$ROOT_DIR" \
  -P "$ROOT_DIR/cmake/ValidateRequiredResults.cmake"

if [[ ! -f "$MACOS_HOST_REPORT" ]] ||
   ! grep -Fqx \
     'macos-host-audio-evidence=system-path,completion,format,player-stop,engine-stop:validated' \
     "$MACOS_HOST_REPORT"; then
  printf '%s\n' 'error: relocated macOS host audio evidence was not validated' >&2
  exit 5
fi

INSTRUMENTATION_SCOPE="$BUILD_DIR/instrumentation-scope.txt"
if [[ ! -s "$INSTRUMENTATION_SCOPE" ]]; then
  printf '%s\n' 'error: actual instrumentation scope evidence is missing' >&2
  exit 5
fi
INSTRUMENTATION_SCOPE_DIGEST="$(
  cmake -E sha256sum "$INSTRUMENTATION_SCOPE" | awk '{print $1}'
)"
if [[ ! "$INSTRUMENTATION_SCOPE_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
  printf '%s\n' 'error: could not compute instrumentation scope evidence digest' >&2
  exit 5
fi
CTEST_LOG_DIGEST="$(cmake -E sha256sum "$CTEST_LOG" | awk '{print $1}')"
CTEST_JUNIT_DIGEST="$(cmake -E sha256sum "$CTEST_JUNIT" | awk '{print $1}')"
CTEST_INVENTORY_DIGEST="$(cmake -E sha256sum "$CTEST_INVENTORY" | awk '{print $1}')"
for digest in "$CTEST_LOG_DIGEST" "$CTEST_JUNIT_DIGEST" "$CTEST_INVENTORY_DIGEST"; do
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'error: could not compute a current CTest evidence digest' >&2
    exit 5
  fi
done
LOAD_REFUSAL_ELAPSED_SECONDS="$(sed -n \
  's/^load-refusal-elapsed-seconds=\([0-9][0-9]*\)$/\1/p' "$RELOCATION_REPORT")"
SOURCE_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS="$(sed -nE \
  's/.*<testcase name="nesturbator_battery_fresh_process_snapshot"[^>]* time="([0-9]+([.][0-9]+)?)".*/\1/p' \
  "$CTEST_JUNIT" | head -n 1)"
INSTALLED_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS="$(sed -n \
  's/^installed-battery-fresh-process-elapsed-seconds=\([0-9][0-9]*\)$/\1/p' \
  "$BATTERY_FRESH_PROCESS_RELOCATION_REPORT")"
if [[ ! "$CONFIGURE_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$BUILD_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$CTEST_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$RELOCATION_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$BATTERY_FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$SOURCE_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ||
      ! "$INSTALLED_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS" =~ ^[0-9]+$ ||
      ! "$LOAD_REFUSAL_ELAPSED_SECONDS" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'error: one or more required route elapsed measurements are missing' >&2
  exit 5
fi

IDENTITY_RECORD="$BUILD_DIR/verification-identity.txt"
IDENTITY_TMP="$IDENTITY_RECORD.tmp"
{
  printf 'format=libfuturo-verification-identity-v1\n'
  sed '/^format=/d' "$RELOCATION_REPORT"
  printf 'ctest_inventory_ref=ctest-inventory.json\n'
  printf 'ctest_junit_ref=ctest-results.junit.xml\n'
  printf 'ctest_log_ref=ctest-output.log\n'
  printf 'ctest_process_facts_ref=ctest-process-facts.txt\n'
  printf 'required_result_rows_ref=required-results.tsv\n'
  printf 'load_corpus_evidence_ref=ctest-output.log#nesturbator_load_corpus\n'
  printf 'load_corpus_evidence_sha256=%s\n' "$CTEST_LOG_DIGEST"
  printf 'instrumentation_scope_ref=instrumentation-scope.txt\n'
  printf 'instrumentation_scope_sha256=%s\n' "$INSTRUMENTATION_SCOPE_DIGEST"
  printf 'ctest_log_sha256=%s\n' "$CTEST_LOG_DIGEST"
  printf 'ctest_junit_sha256=%s\n' "$CTEST_JUNIT_DIGEST"
  printf 'ctest_inventory_sha256=%s\n' "$CTEST_INVENTORY_DIGEST"
  printf 'configure_elapsed_seconds=%s\n' "$CONFIGURE_ELAPSED_SECONDS"
  printf 'required_build_elapsed_seconds=%s\n' "$BUILD_ELAPSED_SECONDS"
  printf 'ctest_elapsed_seconds=%s\n' "$CTEST_ELAPSED_SECONDS"
  printf 'corpus_ctest_elapsed_seconds=%s\n' "$CORPUS_CTEST_SECONDS"
  printf 'allocation_ctest_elapsed_seconds=%s\n' "$ALLOCATION_CTEST_SECONDS"
  printf 'control_ctest_elapsed_seconds=%s\n' "$CONTROL_CTEST_SECONDS"
  printf 'instrumentation_ctest_elapsed_seconds=%s\n' "$INSTRUMENTATION_CTEST_SECONDS"
  printf 'relocation_elapsed_seconds=%s\n' "$RELOCATION_ELAPSED_SECONDS"
  printf 'fresh_process_relocation_elapsed_seconds=%s\n' \
    "$FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS"
  printf 'source_battery_fresh_process_elapsed_seconds=%s\n' \
    "$SOURCE_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS"
  printf 'installed_battery_fresh_process_child_elapsed_seconds=%s\n' \
    "$INSTALLED_BATTERY_FRESH_PROCESS_ELAPSED_SECONDS"
  printf 'battery_fresh_process_relocation_elapsed_seconds=%s\n' \
    "$BATTERY_FRESH_PROCESS_RELOCATION_ELAPSED_SECONDS"
  printf 'load_refusal_child_elapsed_seconds=%s\n' "$LOAD_REFUSAL_ELAPSED_SECONDS"
  printf 'relocation_report_ref=%s\n' "${RELOCATION_REPORT#"$BUILD_DIR"/}"
  printf 'source_fresh_process_report_ref=%s\n' \
    "${SOURCE_FRESH_PROCESS_REPORT#"$BUILD_DIR"/}"
  printf 'source_fresh_process_report_sha256=sha256:%s\n' \
    "$(cmake -E sha256sum "$SOURCE_FRESH_PROCESS_REPORT" | awk '{print $1}')"
  printf 'fresh_process_relocation_report_ref=%s\n' \
    "${FRESH_PROCESS_RELOCATION_REPORT#"$BUILD_DIR"/}"
  printf 'fresh_process_relocation_report_sha256=sha256:%s\n' \
    "$(cmake -E sha256sum "$FRESH_PROCESS_RELOCATION_REPORT" | awk '{print $1}')"
  printf 'source_battery_fresh_process_report_ref=%s\n' \
    "${SOURCE_BATTERY_FRESH_PROCESS_REPORT#"$BUILD_DIR"/}"
  printf 'source_battery_fresh_process_report_sha256=sha256:%s\n' \
    "$(cmake -E sha256sum "$SOURCE_BATTERY_FRESH_PROCESS_REPORT" | awk '{print $1}')"
  printf 'installed_battery_fresh_process_report_ref=%s\n' \
    "${BATTERY_FRESH_PROCESS_RELOCATION_REPORT#"$BUILD_DIR"/}"
  printf 'installed_battery_fresh_process_report_sha256=sha256:%s\n' \
    "$(cmake -E sha256sum "$BATTERY_FRESH_PROCESS_RELOCATION_REPORT" | awk '{print $1}')"
  printf 'installed_battery_fresh_process_log_ref=%s\n' \
    "${BATTERY_FRESH_PROCESS_RELOCATION_LOG#"$BUILD_DIR"/}"
  printf 'installed_battery_fresh_process_log_sha256=sha256:%s\n' \
    "$(cmake -E sha256sum "$BATTERY_FRESH_PROCESS_RELOCATION_LOG" | awk '{print $1}')"
  if [[ -f "$MACOS_HOST_REPORT" ]]; then
    printf 'macos_host_report_ref=%s\n' "${MACOS_HOST_REPORT#"$BUILD_DIR"/}"
    printf 'macos_host_report_sha256=sha256:%s\n' \
      "$(cmake -E sha256sum "$MACOS_HOST_REPORT" | awk '{print $1}')"
  else
    printf 'macos_host_report_ref=missing\n'
    printf 'macos_host_report_sha256=missing\n'
  fi
  cat "$REQUIRED_RESULTS"
} > "$IDENTITY_TMP"
mv "$IDENTITY_TMP" "$IDENTITY_RECORD"
if grep -Fq "$ROOT_DIR" "$IDENTITY_RECORD" || grep -Eq '(^|[=|])(/Users/|/private/tmp/)' "$IDENTITY_RECORD"; then
  printf '%s\n' 'error: verification identity record contains an absolute local path' >&2
  exit 5
fi
if [[ "$RELOCATION_STATUS" -ne 0 ]]; then
  printf 'error: relocated consumer route failed with exit %s\n' "$RELOCATION_STATUS" >&2
  exit 5
fi
if [[ "$FRESH_PROCESS_RELOCATION_STATUS" -ne 0 ]]; then
  printf 'error: relocated fresh-process consumer route failed with exit %s\n' \
    "$FRESH_PROCESS_RELOCATION_STATUS" >&2
  exit 5
fi
if [[ "$BATTERY_FRESH_PROCESS_RELOCATION_STATUS" -ne 0 ]]; then
  printf 'error: relocated battery fresh-process consumer route failed with exit %s\n' \
    "$BATTERY_FRESH_PROCESS_RELOCATION_STATUS" >&2
  exit 5
fi
printf 'Verification identity: build/check/verification-identity.txt\n'
