#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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
  if ! awk -v trigger_key="$trigger_key" '
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
cleanup_workflow_controls
trap - EXIT

terminate_process_tree() {
  local target_pid="$1"
  local signal_name="$2"
  local child_pids child_pid
  child_pids="$(pgrep -P "$target_pid" 2>/dev/null || true)"
  for child_pid in $child_pids; do
    terminate_process_tree "$child_pid" "$signal_name"
  done
  kill "-$signal_name" "$target_pid" 2>/dev/null || true
}

run_bounded() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2

  printf 'Running %s (timeout %ss)\n' "$label" "$timeout_seconds"
  "$@" &
  local command_pid=$!
  local started_at=$SECONDS
  local timed_out=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if (( SECONDS - started_at >= timeout_seconds )); then
      timed_out=1
      terminate_process_tree "$command_pid" TERM
      sleep 2
      terminate_process_tree "$command_pid" KILL
      break
    fi
    sleep 1
  done

  local command_status=0
  wait "$command_pid" || command_status=$?
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
      -DFETCHCONTENT_QUIET=OFF; then
  :
else
  exit "$?"
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

EXPECTED_REQUIRED_TESTS=(synthetic_tracer synthetic_session synthetic_boundaries oracle_negative_control nesturbator_probe)
for test_name in "${EXPECTED_REQUIRED_TESTS[@]}"; do
  if ! printf '%s\n' "${REQUIRED_TESTS[@]}" | grep -Fqx "$test_name"; then
    printf 'error: canonical required test is not registered: %s\n' "$test_name" >&2
    exit 3
  fi
done

if run_bounded "required CMake build" "$BUILD_TIMEOUT_SECONDS" \
    cmake --build "$BUILD_DIR" --target "${REQUIRED_TARGETS[@]}"; then
  :
else
  exit "$?"
fi

DISCOVERED_TESTS="$(ctest --test-dir "$BUILD_DIR" --show-only)"
for test_name in "${REQUIRED_TESTS[@]}"; do
  if ! grep -Eq "^[[:space:]]*Test #[0-9]+: ${test_name}$" <<< "$DISCOVERED_TESTS"; then
    printf 'error: required test is missing or disabled: %s\n' "$test_name" >&2
    exit 3
  fi
done

CTEST_LOG="$BUILD_DIR/ctest-output.log"
CTEST_JUNIT="$BUILD_DIR/ctest-results.junit.xml"
if ASAN_OPTIONS="${ASAN_OPTIONS:+${ASAN_OPTIONS}:}halt_on_error=1" \
    UBSAN_OPTIONS="${UBSAN_OPTIONS:+${UBSAN_OPTIONS}:}halt_on_error=1:print_stacktrace=1" \
    ctest --test-dir "$BUILD_DIR" --output-on-failure --verbose --no-tests=error \
    --output-junit "$CTEST_JUNIT" 2>&1 | tee "$CTEST_LOG"; then
  :
else
  exit "$?"
fi

if [[ ! -s "$CTEST_JUNIT" ]]; then
  printf '%s\n' 'error: CTest did not produce its named-test report' >&2
  exit 4
fi
if grep -Eiq 'AddressSanitizer|UndefinedBehaviorSanitizer|runtime error:' \
    "$CTEST_LOG" "$CTEST_JUNIT"; then
  printf '%s\n' 'error: sanitizer diagnostics were reported' >&2
  exit 4
fi
for test_name in "${REQUIRED_TESTS[@]}"; do
  if ! grep -Eq "^[[:space:]]*[0-9]+/[0-9]+ Test #[0-9]+: ${test_name} .*Passed([[:space:]]|$)" "$CTEST_LOG"; then
    printf 'error: required test did not pass: %s\n' "$test_name" >&2
    exit 4
  fi
done
if ! grep -Fq \
    'nesturbator_probe: source=2338608ab184f040620a30d17756f5e06a42d4e3 lifecycle=create,destroy result=pass' \
    "$CTEST_LOG"; then
  printf '%s\n' 'error: pinned nesturbator lifecycle marker is missing' >&2
  exit 4
fi
