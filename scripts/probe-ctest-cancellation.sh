#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  printf 'usage: %s BUILD_DIR\n' "$0" >&2
  exit 2
fi

BUILD_DIR="$1"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
PROBE_DIR="$(mktemp -d "$BUILD_DIR/ctest-cancellation-probe.XXXXXX")"
SOURCE_DIR="$PROBE_DIR/source"
mkdir -p "$SOURCE_DIR"

cat > "$SOURCE_DIR/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.25)
project(ctest_cancellation_probe NONE)
enable_testing()

add_test(NAME ordinary_failure COMMAND /bin/sh -c "exit 1")
add_test(NAME ordinary_skip COMMAND /bin/sh -c "exit 77")
set_tests_properties(ordinary_skip PROPERTIES SKIP_RETURN_CODE 77)
add_test(NAME timeout_case COMMAND "${CMAKE_COMMAND}" -E sleep 5)
set_tests_properties(timeout_case PROPERTIES TIMEOUT 1)
add_test(NAME disabled_case COMMAND "${CMAKE_COMMAND}" -E echo disabled)
set_tests_properties(disabled_case PROPERTIES DISABLED TRUE)
add_test(NAME interrupted_case
  COMMAND "${CMAKE_COMMAND}"
    "-DSTART_MARKER=${CMAKE_BINARY_DIR}/interrupted.started"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/interrupt.cmake")
set_tests_properties(interrupted_case PROPERTIES TIMEOUT 15)
add_test(NAME proofless_success COMMAND "${CMAKE_COMMAND}" -E echo ordinary-pass)
CMAKE

cat > "$SOURCE_DIR/interrupt.cmake" <<'CMAKE'
file(WRITE "${START_MARKER}" "started\n")
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
CMAKE

if ! cmake -S "$SOURCE_DIR" -B "$PROBE_DIR/build" > "$PROBE_DIR/configure.log" 2>&1; then
  cat "$PROBE_DIR/configure.log" >&2
  printf '%s\n' 'error: could not configure the standalone CTest probe' >&2
  exit 1
fi

ctest --test-dir "$PROBE_DIR/build" --show-only=json-v1 \
  > "$PROBE_DIR/inventory.json"
if [[ ! -s "$PROBE_DIR/inventory.json" ]]; then
  printf '%s\n' 'error: CTest JSON-v1 inventory is missing' >&2
  exit 1
fi

run_case() {
  local test_name="$1"
  local junit_path="$PROBE_DIR/$test_name.junit.xml"
  local log_path="$PROBE_DIR/$test_name.log"
  local status=0
  if ctest --test-dir "$PROBE_DIR/build" --no-tests=error \
      --output-junit "$junit_path" --output-on-failure \
      -R "^${test_name}$" > "$log_path" 2>&1; then
    status=0
  else
    status=$?
  fi
  printf '%s\t%d\t%s\t%s\n' "$test_name" "$status" \
    "${junit_path##*/}" "${log_path##*/}" >> "$PROBE_DIR/cases.tsv"
}

: > "$PROBE_DIR/cases.tsv"
run_case ordinary_failure
run_case ordinary_skip
run_case timeout_case
run_case disabled_case
run_case proofless_success

missing_junit="$PROBE_DIR/missing_registration.junit.xml"
missing_log="$PROBE_DIR/missing_registration.log"
missing_status=0
if ctest --test-dir "$PROBE_DIR/build" --no-tests=error \
    --output-junit "$missing_junit" --output-on-failure \
    -R '^missing_registration$' > "$missing_log" 2>&1; then
  missing_status=0
else
  missing_status=$?
fi
printf 'missing_registration\t%d\t%s\t%s\n' "$missing_status" \
  "${missing_junit##*/}" "${missing_log##*/}" >> "$PROBE_DIR/cases.tsv"

interrupt_junit="$PROBE_DIR/interrupted_case.junit.xml"
interrupt_log="$PROBE_DIR/interrupted_case.log"
interrupt_status_file="$PROBE_DIR/interrupted_case.process.txt"
ctest --test-dir "$PROBE_DIR/build" --no-tests=error \
  --output-junit "$interrupt_junit" --output-on-failure \
  -R '^interrupted_case$' > "$interrupt_log" 2>&1 &
ctest_pid=$!
marker_waits=0
while [[ ! -f "$PROBE_DIR/build/interrupted.started" ]] && (( marker_waits < 100 )); do
  if ! kill -0 "$ctest_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
  ((marker_waits += 1))
done

if [[ ! -f "$PROBE_DIR/build/interrupted.started" ]] || ! kill -0 "$ctest_pid" 2>/dev/null; then
  printf '%s\n' 'error: interrupted CTest control did not reach its running marker' >&2
  kill -TERM "$ctest_pid" 2>/dev/null || true
  wait "$ctest_pid" 2>/dev/null || true
  cat "$interrupt_log" >&2
  exit 1
fi

interrupt_requested='TERM'
pid_alive_before_signal='yes'
kill -TERM "$ctest_pid"
interrupt_status=0
if wait "$ctest_pid" 2>/dev/null; then
  interrupt_status=0
else
  interrupt_status=$?
fi
signal_exit='no'
if (( interrupt_status == 143 )); then
  signal_exit='yes'
fi
junit_present='no'
if [[ -s "$interrupt_junit" ]]; then
  junit_present='yes'
fi
{
  printf 'format=libfuturo-ctest-interruption-v1\n'
  printf 'inventory=%s\n' "${PROBE_DIR##*/}/inventory.json"
  printf 'junit=%s\n' "${interrupt_junit##*/}"
  printf 'log=%s\n' "${interrupt_log##*/}"
  printf 'ctest_pid=%s\n' "$ctest_pid"
  printf 'signal_requested=%s\n' "$interrupt_requested"
  printf 'pid_alive_before_signal=%s\n' "$pid_alive_before_signal"
  printf 'wait_exit_status=%s\n' "$interrupt_status"
  printf 'wait_status_matches_SIGTERM=%s\n' "$signal_exit"
  printf 'junit_present=%s\n' "$junit_present"
} > "$interrupt_status_file"
printf 'interrupted_case\t%d\t%s\t%s\n' "$interrupt_status" \
  "${interrupt_junit##*/}" "${interrupt_log##*/}" >> "$PROBE_DIR/cases.tsv"

absent_report="$PROBE_DIR/absent-report.junit.xml"
rm -f "$absent_report"
proofless_log="$PROBE_DIR/proofless_success.log"
expected_marker='expected-proof: present'
if grep -Fq "$expected_marker" "$proofless_log"; then
  proof_state='present'
else
  proof_state='absent'
fi
{
  printf 'format=libfuturo-ctest-probe-v1\n'
  printf 'inventory=inventory.json\n'
  printf 'cases=cases.tsv\n'
  printf 'absent_registration=missing_registration\n'
  printf 'absent_report=%s\n' "${absent_report##*/}"
  printf 'absent_report_exists=%s\n' "$(test -e "$absent_report" && printf yes || printf no)"
  printf 'expected_proof=%s\n' "$expected_marker"
  printf 'proofless_success_marker=%s\n' "$proof_state"
} > "$PROBE_DIR/probe-facts.txt"

assert_case_status() {
  local test_name="$1"
  local expected_status="$2"
  if ! awk -F '\t' -v name="$test_name" -v status="$expected_status" \
      '$1 == name && $2 == status { found = 1 } END { exit !found }' \
      "$PROBE_DIR/cases.tsv"; then
    printf 'error: CTest probe %s did not exit with expected status %s\n' \
      "$test_name" "$expected_status" >&2
    exit 1
  fi
}

assert_case_status ordinary_failure 8
assert_case_status ordinary_skip 0
assert_case_status timeout_case 8
assert_case_status disabled_case 8
assert_case_status proofless_success 0
assert_case_status missing_registration 8
assert_case_status interrupted_case 143
grep -Fq '"name" : "disabled_case"' "$PROBE_DIR/inventory.json"
grep -Fq '"name" : "DISABLED"' "$PROBE_DIR/inventory.json"
grep -Fq '<failure message="Failed"/>' "$PROBE_DIR/ordinary_failure.junit.xml"
grep -Fq '<skipped message="SKIP_RETURN_CODE=77"/>' "$PROBE_DIR/ordinary_skip.junit.xml"
grep -Fq '<failure message="Timeout"/>' "$PROBE_DIR/timeout_case.junit.xml"
grep -Fq 'status="disabled"' "$PROBE_DIR/disabled_case.junit.xml"
grep -Fq 'tests="0"' "$PROBE_DIR/missing_registration.junit.xml"
grep -Fq 'wait_status_matches_SIGTERM=yes' "$interrupt_status_file"
grep -Fq 'junit_present=no' "$interrupt_status_file"
[[ ! -e "$absent_report" ]]
[[ "$proof_state" == 'absent' ]]

printf 'CTest cancellation probe artifacts: %s\n' "${PROBE_DIR#"$BUILD_DIR"/}"
printf 'CTest process facts: %s\n' "${interrupt_status_file##*/}"
printf 'Observed: failure, timeout, disabled, and missing registration exited 8; skip and pass-without-proof exited 0.\n'
printf 'Observed: cancellation returned wait status 143 after requested SIGTERM; interrupted JUnit was absent.\n'
printf 'PROBE_RESULT: PASS (controller signal facts distinguish interruption; JUnit alone does not)\n'
