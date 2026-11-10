#!/bin/sh
set -eu

SOURCE_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
RUN_UID=$(id -u)
OS_NAME=$(uname -s)
ARCH_NAME=$(uname -m)
if [ "$RUN_UID" -eq 0 ]; then
  echo 'process_tree_cleanup: unsupported uid=0; permission refusal is not observable' >&2
  exit 77
fi
if [ "$OS_NAME" != Darwin ] || [ "$ARCH_NAME" != arm64 ]; then
  echo "process_tree_cleanup: unsupported platform=$OS_NAME/$ARCH_NAME; requires Darwin/arm64" >&2
  exit 77
fi
SHARED_HELPER="$SOURCE_ROOT/tests/installed-consumer/relocate-bounded-stage.sh"
if [ ! -f "$SHARED_HELPER" ]; then
  echo "process_tree_cleanup: missing shared relocated-stage helper: $SHARED_HELPER" >&2
  exit 1
fi
. "$SOURCE_ROOT/scripts/process-tree-cleanup.sh"

umask 077
TEST_STARTED_AT=$(date +%s)
TEST_DEADLINE=$((TEST_STARTED_AT + 24))
# Normal setup/arming and test work stay bounded at T+12 and T+24. If the test
# fails with an owned worker still active, the EXIT handler gets a separate
# cleanup deadline at T+31: enough for the production helper's two-second grace
# and five polls, plus bounded reaping/evidence. CTest leaves five more seconds
# for that handler to finish.
CLEANUP_DEADLINE=$((TEST_STARTED_AT + 31))
FORCE_REAP_DEADLINE=$((TEST_STARTED_AT + 30))
ACTIVE_DEADLINE=$TEST_DEADLINE
CLEANUP_ACTIVE=0
SETUP_DEADLINE=$((TEST_STARTED_AT + 12))
TEARDOWN_START_DEADLINE=$((TEST_STARTED_AT + 12))
COMPLETION_DEADLINE=$((TEST_STARTED_AT + 23))
ABSOLUTE_DEADLINE_EXCEEDED=0
COMPLETION_DEADLINE_EXCEEDED=0
SCRATCH=$(mktemp -d "${TMPDIR:-/private/tmp}/libfuturo-process-tree.XXXXXX")
SCRATCH_REAL=
cleanup_private_scratch() {
  early_exit_code=$?
  trap - EXIT
  candidate_scratch=${SCRATCH_REAL:-$SCRATCH}
  if [ -d "$candidate_scratch" ] && [ ! -L "$candidate_scratch" ]; then
    canonical_scratch=$(CDPATH= cd "$candidate_scratch" 2>/dev/null && pwd -P) || canonical_scratch=
    scratch_owner=$(stat -f %u "$canonical_scratch" 2>/dev/null) || scratch_owner=
    canonical_matches=1
    if [ -n "$SCRATCH_REAL" ] && [ "$canonical_scratch" != "$SCRATCH_REAL" ]; then
      canonical_matches=0
    fi
    if [ -n "$canonical_scratch" ] && [ "$canonical_matches" -eq 1 ] &&
        [ "$scratch_owner" = "$RUN_UID" ]; then
      /bin/rm -rf "$canonical_scratch"
    else
      early_exit_code=1
      echo 'process_tree_cleanup: minimal cleanup refused an unverified scratch path' >&2
    fi
  else
    early_exit_code=1
    echo 'process_tree_cleanup: minimal cleanup refused a missing or symlink scratch path' >&2
  fi
  exit "$early_exit_code"
}
trap cleanup_private_scratch EXIT
SCRATCH_REAL=$(CDPATH= cd "$SCRATCH" && pwd -P)
SCRATCH_OWNER=$(stat -f %u "$SCRATCH_REAL")
if [ "$SCRATCH_OWNER" != "$RUN_UID" ] || [ -L "$SCRATCH_REAL" ]; then
  echo 'process_tree_cleanup: private scratch ownership/path check failed' >&2
  exit 1
fi

check_setup_deadline() {
  now=$(date +%s)
  if [ "$now" -ge "$SETUP_DEADLINE" ]; then
    echo "process_tree_cleanup: setup/arming deadline reached at T+$((SETUP_DEADLINE - TEST_STARTED_AT))" >&2
    return 1
  fi
}

check_completion_deadline() {
  now=$(date +%s)
  if [ "$now" -ge "$COMPLETION_DEADLINE" ]; then
    COMPLETION_DEADLINE_EXCEEDED=1
    echo 'process_tree_cleanup: completion deadline reached; final teardown reserve begins' >&2
    return 1
  fi
}

check_absolute_deadline() {
  now=$(date +%s)
  if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
    ABSOLUTE_DEADLINE_EXCEEDED=1
    if [ "$CLEANUP_ACTIVE" -eq 1 ]; then deadline_kind=cleanup; else deadline_kind=test; fi
    echo "process_tree_cleanup: absolute $deadline_kind deadline reached at T+$((ACTIVE_DEADLINE - TEST_STARTED_AT))" >&2
    return 1
  fi
}

EVIDENCE_DIR=${LF_PROCESS_TREE_PROBE_EVIDENCE_DIR:-}
EVIDENCE_RUN=
if [ -n "$EVIDENCE_DIR" ]; then
  case "$EVIDENCE_DIR" in
    /*) ;;
    *) echo 'process_tree_cleanup: evidence directory must be absolute' >&2; exit 1 ;;
  esac
  /bin/mkdir -p "$EVIDENCE_DIR"
  if [ -L "$EVIDENCE_DIR" ]; then
    echo 'process_tree_cleanup: evidence directory must not be a symlink' >&2
    exit 1
  fi
  EVIDENCE_DIR=$(CDPATH= cd "$EVIDENCE_DIR" && pwd -P)
  EVIDENCE_RUN="$EVIDENCE_DIR/attempt-$(basename "$SCRATCH_REAL")"
  /bin/mkdir "$EVIDENCE_RUN"
fi
check_setup_deadline || exit 1

CASE_ROOT=
CASE_NAME=
ROOT_DIR=
BUILD_DIR=
STAGE_ROOT=
STAGE_FIXTURE_PATH=
ROOT_MODE=
BUILD_MODE=
STAGE_MODE=
WORKER_DIR=
WORKER_SCRATCH=
WORKER_SCRIPT=
LEADER_SCRIPT=
DESCENDANT_SCRIPT=
CASE_LOG=
CASE_WORKER_READY_FILE=
CASE_WORKER_RELEASE_FILE=
WORKER_STATUS_FILE=
WORKER_DONE_FILE=
WORKER_PID_FILE=
RESTORE_RESULT_FILE=
REPORT_TMP=
LEADER_READY=
LEADER_PID_FILE=
DESCENDANT_READY=
DESCENDANT_PID_FILE=
DESCENDANT_GROUP_FILE=
DESCENDANT_LEASE_READY=
DESCENDANT_LEASE_RELEASE=
DESCENDANT_LEASE_CHALLENGE=
DESCENDANT_LEASE_RESPONSE=
RELEASE_FILE=
CASE_STARTED_AT=
CASE_ELAPSED=0
CASE_WORKER_PID=
CASE_WORKER_REAPED=0
CASE_WORKER_REAPING=0
CASE_CHILD_PID=
CASE_CHILD_PGID=
CASE_DESCENDANT_PID=
CASE_GROUP_VERIFIED=0

GENERIC_DIR="$SCRATCH_REAL/generic"
GENERIC_WORKER_SCRIPT="$GENERIC_DIR/worker.sh"
GENERIC_LEADER_SCRIPT="$GENERIC_DIR/leader.sh"
GENERIC_DESCENDANT_SCRIPT="$GENERIC_DIR/descendant.sh"
GENERIC_WORKER_LOG="$GENERIC_DIR/worker.log"
GENERIC_WORKER_PID_FILE="$GENERIC_DIR/worker-pid"
GENERIC_WORKER_DONE="$GENERIC_DIR/worker-done"
GENERIC_WORKER_READY="$GENERIC_DIR/worker-ready"
GENERIC_WORKER_TRAP_READY="$GENERIC_DIR/worker-trap-ready"
GENERIC_WORKER_HANDLER_READY="$GENERIC_DIR/worker-handler-ready"
GENERIC_WORKER_RELEASE="$GENERIC_DIR/worker-release"
GENERIC_CANCEL_REQUEST="$GENERIC_DIR/cancel-request"
GENERIC_CLEANUP_STARTED="$GENERIC_DIR/cleanup-started"
GENERIC_ROOT_PID_FILE="$GENERIC_DIR/leader-pid"
GENERIC_LEADER_READY="$GENERIC_DIR/leader-ready"
GENERIC_DESCENDANT_PID_FILE="$GENERIC_DIR/descendant-pid"
GENERIC_DESCENDANT_GROUP_FILE="$GENERIC_DIR/descendant-group"
GENERIC_DESCENDANT_READY="$GENERIC_DIR/descendant-ready"
GENERIC_DESCENDANT_LEASE_READY="$GENERIC_DIR/descendant-lease-ready"
GENERIC_DESCENDANT_LEASE_RELEASE="$GENERIC_DIR/descendant-lease-release"
GENERIC_DESCENDANT_LEASE_CHALLENGE="$GENERIC_DIR/descendant-lease-challenge"
GENERIC_DESCENDANT_LEASE_RESPONSE="$GENERIC_DIR/descendant-lease-response"
GENERIC_RESULT="$GENERIC_DIR/result.txt"
GENERIC_WORKER_PID=
GENERIC_WORKER_REAPED=0
GENERIC_WORKER_REAPING=0
GENERIC_ROOT_PID=
GENERIC_DESCENDANT_PID=
LEASE_NONCE_COUNTER=0

is_numeric_pid() {
  case "$1" in
    ''|*[!0-9]*|0*|1) return 1 ;;
    *) return 0 ;;
  esac
}

validate_group_signal() {
  validated_signal=$1
  validated_pgid=$2
  signal_callback=$3
  is_numeric_pid "$validated_pgid" || return 1
  "$signal_callback" "$validated_signal" "$validated_pgid"
}

signal_group_if_live() {
  signal_name=$1
  signal_pgid=$2
  group_exists "$signal_pgid" || return 1
  kill -"$signal_name" -- "-$signal_pgid" 2>/dev/null
}

signal_owned_group() {
  validate_group_signal "$1" "$2" signal_group_if_live
}

record_group_signal_probe() {
  PARSER_GROUP_SIGNAL_CALLS=$((PARSER_GROUP_SIGNAL_CALLS + 1))
  PARSER_GROUP_SIGNAL_VALUE=$2
}

run_pid_parser_matrix() {
  PARSER_GROUP_SIGNAL_CALLS=0
  PARSER_GROUP_SIGNAL_VALUE=
  for malformed_pid in 0 00 000 01 001 1 '' 02 0002 abc 2x -1; do
    if validate_group_signal TERM "$malformed_pid" record_group_signal_probe; then
      echo "process_tree_cleanup: malformed PID unexpectedly reached group-signal callback: '$malformed_pid'" >&2
      return 1
    fi
  done
  [ "$PARSER_GROUP_SIGNAL_CALLS" -eq 0 ] || {
    echo 'process_tree_cleanup: malformed PID reached group-signal callback' >&2
    return 1
  }
  validate_group_signal TERM 23 record_group_signal_probe || return 1
  [ "$PARSER_GROUP_SIGNAL_CALLS" -eq 1 ] && [ "$PARSER_GROUP_SIGNAL_VALUE" = 23 ] || return 1
  printf 'result=pass malformed_pid_values=12 group_signal_calls_for_malformed=0 canonical_positive_control=23\n' \
    > "$SCRATCH_REAL/pid-parser-matrix.txt"
  echo 'process_tree_cleanup: canonical PID/PGID parser matrix passed; malformed group-signal calls=0'
}

path_is_owned_under_scratch() {
  owned_path=$1
  [ -d "$owned_path" ] || return 1
  [ ! -L "$owned_path" ] || return 1
  owned_real=$(CDPATH= cd "$owned_path" 2>/dev/null && pwd -P) || return 1
  case "$owned_real" in
    "$SCRATCH_REAL"|"$SCRATCH_REAL"/*) ;;
    *) return 1 ;;
  esac
  owned_uid=$(stat -f %u "$owned_real" 2>/dev/null) || return 1
  [ "$owned_uid" = "$RUN_UID" ]
}

marker_is_owned() {
  [ -f "$1" ] || return 1
  [ "$(stat -f %u "$1" 2>/dev/null)" = "$RUN_UID" ]
}

process_is_owned() {
  is_numeric_pid "$1" || return 1
  # Direct workers are children of this controller; stage processes inherit its uid.
  kill -0 "$1" 2>/dev/null
}

lease_is_active_owned() {
  lease_ready=$1
  lease_release=$2
  descendant_pid_marker=$3
  descendant_group_marker=$4
  expected_pgid=$5
  lease_challenge=$6
  lease_response=$7
  lease_deadline_kind=$8
  marker_is_owned "$lease_ready" && marker_is_owned "$descendant_pid_marker" &&
    marker_is_owned "$descendant_group_marker" || return 1
  lease_root=$(dirname "$lease_ready")
  path_is_owned_under_scratch "$lease_root" || return 1
  [ ! -e "$lease_release" ] || return 1
  [ "$(sed -n 's/^lease=//p' "$lease_ready")" = held ] || return 1
  lease_pid=$(sed -n 's/^pid=//p' "$lease_ready")
  lease_pgid=$(sed -n 's/^pgid=//p' "$lease_ready")
  lease_uid=$(sed -n 's/^uid=//p' "$lease_ready")
  descendant_pid=$(sed -n '1p' "$descendant_pid_marker")
  descendant_pgid=$(sed -n '1p' "$descendant_group_marker")
  is_numeric_pid "$lease_pid" && is_numeric_pid "$lease_pgid" &&
    [ "$lease_pid" = "$descendant_pid" ] &&
    [ "$lease_pgid" = "$expected_pgid" ] &&
    [ "$descendant_pgid" = "$expected_pgid" ] &&
    [ "$lease_uid" = "$RUN_UID" ] || return 1
  [ -n "$lease_challenge" ] && [ -n "$lease_response" ] || return 1
  [ "$(dirname "$lease_challenge")" = "$lease_root" ] &&
    [ "$(dirname "$lease_response")" = "$lease_root" ] &&
    [ ! -L "$lease_challenge" ] && [ ! -L "$lease_response" ] || return 1
  LEASE_NONCE_COUNTER=$((LEASE_NONCE_COUNTER + 1))
  lease_nonce="$SCRATCH_REAL-$RUN_UID-$TEST_STARTED_AT-$$-$LEASE_NONCE_COUNTER-$(date +%s)"
  lease_challenge_tmp="$lease_challenge.tmp.$$"
  printf 'format=libfuturo-lease-challenge-v1\nnonce=%s\npid=%s\npgid=%s\nuid=%s\n' \
    "$lease_nonce" "$lease_pid" "$lease_pgid" "$lease_uid" > "$lease_challenge_tmp" || return 1
  /bin/mv -f "$lease_challenge_tmp" "$lease_challenge" || return 1
  lease_attempt=0
  while [ "$lease_attempt" -lt 12 ]; do
    if [ "$lease_deadline_kind" = setup ]; then
      check_setup_deadline || return 1
    else
      check_absolute_deadline || return 1
    fi
    if marker_is_owned "$lease_response" &&
        [ "$(sed -n 's/^format=//p' "$lease_response")" = libfuturo-lease-response-v1 ] &&
        [ "$(sed -n 's/^nonce=//p' "$lease_response")" = "$lease_nonce" ] &&
        [ "$(sed -n 's/^pid=//p' "$lease_response")" = "$lease_pid" ] &&
        [ "$(sed -n 's/^pgid=//p' "$lease_response")" = "$lease_pgid" ] &&
        [ "$(sed -n 's/^uid=//p' "$lease_response")" = "$lease_uid" ] &&
        [ ! -e "$lease_release" ] &&
        [ "$(sed -n 's/^lease=//p' "$lease_ready")" = held ]; then
      return 0
    fi
    /bin/sleep 0.05
    lease_attempt=$((lease_attempt + 1))
  done
  return 1
}

group_exists() {
  is_numeric_pid "$1" || return 1
  kill -0 -- "-$1" 2>/dev/null
}

signal_direct_worker() {
  worker_pid=$1
  worker_pid_marker=$2
  worker_trap_ready=$3
  worker_done_marker=$4
  worker_reaping_marker=$5
  is_numeric_pid "$worker_pid" || return 1
  marker_is_owned "$worker_pid_marker" && marker_is_owned "$worker_trap_ready" || return 1
  [ ! -f "$worker_done_marker" ] && [ ! -f "$worker_reaping_marker" ] || return 2
  process_is_owned "$worker_pid" || return 1
  # The child's EXIT trap holds its unreaped PID until controller release, so
  # this second check plus direct-child ownership closes the done/signal race.
  [ ! -f "$worker_done_marker" ] && [ ! -f "$worker_reaping_marker" ] || return 2
  kill -TERM "$worker_pid" 2>/dev/null
}

case_paths() {
  CASE_NAME=$1
  CASE_ROOT="$SCRATCH_REAL/$CASE_NAME"
  ROOT_DIR="$CASE_ROOT/fixture/checkout"
  BUILD_DIR="$CASE_ROOT/fixture/build"
  STAGE_ROOT="$CASE_ROOT/fixture/staging"
  STAGE_FIXTURE_PATH="$CASE_ROOT/relocated-staging"
  WORKER_DIR="$CASE_ROOT/worker"
  WORKER_SCRATCH="$CASE_ROOT/worker-scratch"
  WORKER_SCRIPT="$WORKER_DIR/worker.sh"
  LEADER_SCRIPT="$WORKER_DIR/leader.sh"
  DESCENDANT_SCRIPT="$WORKER_DIR/descendant.sh"
  CASE_LOG="$CASE_ROOT/wrapper.log"
  CASE_WORKER_READY_FILE="$CASE_ROOT/worker-trap-ready"
  CASE_WORKER_RELEASE_FILE="$CASE_ROOT/worker-release"
  WORKER_DONE_FILE="$CASE_ROOT/worker-done"
  WORKER_STATUS_FILE="$CASE_ROOT/wrapper-status.txt"
  WORKER_PID_FILE="$CASE_ROOT/worker-pid"
  RESTORE_RESULT_FILE="$CASE_ROOT/wrapper-restoration.txt"
  REPORT_TMP="$CASE_ROOT/report.tmp"
  LEADER_READY="$CASE_ROOT/leader-ready"
  LEADER_PID_FILE="$CASE_ROOT/leader-pid"
  DESCENDANT_READY="$CASE_ROOT/descendant-ready"
  DESCENDANT_PID_FILE="$CASE_ROOT/descendant-pid"
  DESCENDANT_GROUP_FILE="$CASE_ROOT/descendant-group"
  DESCENDANT_LEASE_READY="$CASE_ROOT/descendant-lease-ready"
  DESCENDANT_LEASE_RELEASE="$CASE_ROOT/descendant-lease-release"
  DESCENDANT_LEASE_CHALLENGE="$CASE_ROOT/descendant-lease-challenge"
  DESCENDANT_LEASE_RESPONSE="$CASE_ROOT/descendant-lease-response"
  RELEASE_FILE="$CASE_ROOT/release-child"
  CASE_STARTED_AT=$(sed -n '1p' "$CASE_ROOT/started-at" 2>/dev/null || true)
  ROOT_MODE=$(sed -n 's/^checkout_mode=//p' "$CASE_ROOT/original-modes.txt" 2>/dev/null || true)
  BUILD_MODE=$(sed -n 's/^build_mode=//p' "$CASE_ROOT/original-modes.txt" 2>/dev/null || true)
  STAGE_MODE=$(sed -n 's/^staging_fixture_mode=//p' "$CASE_ROOT/original-modes.txt" 2>/dev/null || true)
  CASE_WORKER_PID=$(sed -n '1p' "$WORKER_PID_FILE" 2>/dev/null || true)
  if [ -f "$CASE_ROOT/worker-reaped" ]; then CASE_WORKER_REAPED=1; else CASE_WORKER_REAPED=0; fi
  if [ -f "$CASE_ROOT/worker-reaping" ]; then CASE_WORKER_REAPING=1; else CASE_WORKER_REAPING=0; fi
  CASE_CHILD_PID=$(sed -n '1p' "$LEADER_PID_FILE" 2>/dev/null || true)
  if is_numeric_pid "$CASE_CHILD_PID"; then CASE_CHILD_PGID=$CASE_CHILD_PID; else CASE_CHILD_PGID=; fi
  CASE_DESCENDANT_PID=
  CASE_GROUP_VERIFIED=0
}

write_case_scripts() {
  cat > "$WORKER_SCRIPT" <<'SH'
#!/bin/sh
set -eu
CASE_ROOT=${RUN_CASE_ROOT:?}
WORKER_DONE_FILE="$CASE_ROOT/worker-done"
WORKER_RELEASE_FILE="$CASE_ROOT/worker-release"
WORKER_TRAP_READY_FILE="$CASE_ROOT/worker-trap-ready"
PATHS_PROTECTED=0
worker_exit_cleanup() {
  worker_exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  set +u
  if [ "${PATHS_PROTECTED:-0}" -eq 1 ]; then
    if ! restore_original_paths; then worker_exit_status=1; fi
  fi
  printf 'done\n' > "$WORKER_DONE_FILE"
  while [ ! -f "$WORKER_RELEASE_FILE" ]; do /bin/sleep 0.05; done
  exit "$worker_exit_status"
}
trap worker_exit_cleanup EXIT
printf 'ready\n' > "$WORKER_TRAP_READY_FILE"
SOURCE_ROOT=${SOURCE_ROOT:?}
CASE_NAME=$1
ROOT_DIR="$CASE_ROOT/fixture/checkout"
BUILD_DIR="$CASE_ROOT/fixture/build"
STAGE_ROOT="$CASE_ROOT/fixture/staging"
STAGE_FIXTURE_PATH="$CASE_ROOT/relocated-staging"
WORKER_SCRATCH="$CASE_ROOT/worker-scratch"
SCRATCH=$WORKER_SCRATCH
REPORT_TMP="$CASE_ROOT/report.tmp"
ROOT_MODE=${ORIGINAL_ROOT_MODE:?}
BUILD_MODE=${ORIGINAL_BUILD_MODE:?}
STAGE_MODE=${ORIGINAL_STAGE_MODE:?}
WORKER_STATUS_FILE="$CASE_ROOT/wrapper-status.txt"
WORKER_DONE_FILE="$CASE_ROOT/worker-done"
RESTORE_RESULT_FILE="$CASE_ROOT/wrapper-restoration.txt"
LEADER_SCRIPT="$CASE_ROOT/worker/leader.sh"
DESCENDANT_SCRIPT="$CASE_ROOT/worker/descendant.sh"
LEADER_READY="$CASE_ROOT/leader-ready"
LEADER_PID_FILE="$CASE_ROOT/leader-pid"
DESCENDANT_READY="$CASE_ROOT/descendant-ready"
DESCENDANT_PID_FILE="$CASE_ROOT/descendant-pid"
DESCENDANT_GROUP_FILE="$CASE_ROOT/descendant-group"
DESCENDANT_LEASE_READY="$CASE_ROOT/descendant-lease-ready"
DESCENDANT_LEASE_RELEASE="$CASE_ROOT/descendant-lease-release"
DESCENDANT_LEASE_CHALLENGE="$CASE_ROOT/descendant-lease-challenge"
DESCENDANT_LEASE_RESPONSE="$CASE_ROOT/descendant-lease-response"
RELEASE_FILE="$CASE_ROOT/release-child"

capture_one_path_diagnostic() {
  diagnostic_label=$1
  diagnostic_path=$2
  diagnostic_container=$3
  diagnostic_exists=no
  diagnostic_readable=no
  diagnostic_traversable=no
  [ -e "$diagnostic_path" ] || [ -L "$diagnostic_path" ] && diagnostic_exists=yes
  [ -r "$diagnostic_path" ] && diagnostic_readable=yes
  [ -d "$diagnostic_path" ] && [ -x "$diagnostic_path" ] && diagnostic_traversable=yes
  diagnostic_mode=$(stat -f '%Sp (%Lp)' "$diagnostic_path" 2>/dev/null || printf absent)
  container_mode=$(stat -f '%Sp (%Lp)' "$diagnostic_container" 2>/dev/null || printf unavailable)
  {
    printf 'candidate=%s path=%s exists=%s readable=%s traversable=%s mode=%s\n' \
      "$diagnostic_label" "$diagnostic_path" "$diagnostic_exists" \
      "$diagnostic_readable" "$diagnostic_traversable" "$diagnostic_mode"
    printf 'container=%s mode=%s acl_listing_begin\n' "$diagnostic_container" "$container_mode"
    /bin/ls -lde "$diagnostic_container" 2>&1 || true
    printf 'candidate_acl_listing_begin\n'
    /bin/ls -lde "$diagnostic_path" 2>&1 || true
    printf 'acl_listing_end\n'
  } >> "$CASE_ROOT/isolation-protected-paths.txt"
}

record_protected_path_diagnostics() {
  printf 'format=libfuturo-protected-path-diagnostics-v1\n' \
    > "$CASE_ROOT/isolation-protected-paths.txt"
  capture_one_path_diagnostic checkout-directory "$ROOT_DIR" "$CASE_ROOT/fixture"
  capture_one_path_diagnostic checkout-file "$ROOT_DIR/CMakeLists.txt" "$ROOT_DIR"
  capture_one_path_diagnostic build-directory "$BUILD_DIR" "$CASE_ROOT/fixture"
  capture_one_path_diagnostic build-file "$BUILD_DIR/CMakeCache.txt" "$BUILD_DIR"
  capture_one_path_diagnostic staging-probe-directory "$STAGE_ROOT" "$CASE_ROOT/fixture"
  capture_one_path_diagnostic staging-probe-file \
    "$STAGE_ROOT/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake" "$CASE_ROOT/fixture"
  capture_one_path_diagnostic relocated-staging-fixture "$STAGE_FIXTURE_PATH" "$CASE_ROOT"
  capture_one_path_diagnostic relocated-staging-config \
    "$STAGE_FIXTURE_PATH/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake" "$STAGE_FIXTURE_PATH"
}
. "$SOURCE_ROOT/scripts/process-tree-cleanup.sh"
. "$SOURCE_ROOT/tests/installed-consumer/relocate-bounded-stage.sh"

record_wrapper_restoration() {
  restoration_result=pass
  observed_root_mode=$(stat -f %Lp "$ROOT_DIR" 2>/dev/null || printf unavailable)
  observed_build_mode=$(stat -f %Lp "$BUILD_DIR" 2>/dev/null || printf unavailable)
  observed_stage_mode=$(stat -f %Lp "$STAGE_FIXTURE_PATH" 2>/dev/null || printf unavailable)
  checkout_readable=no
  build_readable=no
  stage_fixture_readable=no
  [ -r "$ROOT_DIR/CMakeLists.txt" ] && checkout_readable=yes || restoration_result=fail
  [ -r "$BUILD_DIR/CMakeCache.txt" ] && build_readable=yes || restoration_result=fail
  [ -r "$STAGE_FIXTURE_PATH/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake" ] && \
    stage_fixture_readable=yes || restoration_result=fail
  [ "$PATHS_PROTECTED" -eq 0 ] || restoration_result=fail
  [ "$observed_root_mode" = "$ROOT_MODE" ] || restoration_result=fail
  [ "$observed_build_mode" = "$BUILD_MODE" ] || restoration_result=fail
  [ "$observed_stage_mode" = "$STAGE_MODE" ] || restoration_result=fail
  [ ! -e "$STAGE_ROOT" ] && \
    [ ! -r "$STAGE_ROOT/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake" ] || restoration_result=fail
  {
    printf 'format=libfuturo-wrapper-restoration-v1\n'
    printf 'result=%s\npaths_protected=%s\n' "$restoration_result" "$PATHS_PROTECTED"
    printf 'checkout_mode_before=%s\ncheckout_mode_after=%s\ncheckout_readable=%s\n' \
      "$ROOT_MODE" "$observed_root_mode" "$checkout_readable"
    printf 'build_mode_before=%s\nbuild_mode_after=%s\nbuild_readable=%s\n' \
      "$BUILD_MODE" "$observed_build_mode" "$build_readable"
    printf 'staging_probe_path=absent\n'
    printf 'staging_fixture_mode_before=%s\nstaging_fixture_mode_after=%s\nstaging_fixture_readable=%s\n' \
      "$STAGE_MODE" "$observed_stage_mode" "$stage_fixture_readable"
    printf 'recorded_before_exit_cleanup=yes\n'
  } > "$RESTORE_RESULT_FILE"
  [ "$restoration_result" = pass ]
}

case "$CASE_NAME" in
  normal)
    if run_isolated_stage macos-host 8 "$LEADER_SCRIPT" normal "$LEADER_PID_FILE" \
        "$LEADER_READY" "$RELEASE_FILE"; then stage_status=0; else stage_status=$?; fi
    ;;
  timeout)
    if run_isolated_stage macos-host 2 "$LEADER_SCRIPT" timeout "$LEADER_PID_FILE" \
        "$LEADER_READY" "$RELEASE_FILE" "$DESCENDANT_SCRIPT" "$DESCENDANT_PID_FILE" \
        "$DESCENDANT_READY" "$DESCENDANT_GROUP_FILE" "$DESCENDANT_LEASE_RELEASE" \
        "$DESCENDANT_LEASE_READY" "$DESCENDANT_LEASE_CHALLENGE" \
        "$DESCENDANT_LEASE_RESPONSE"; then stage_status=0; else stage_status=$?; fi
    ;;
  term)
    if run_isolated_stage macos-host 10 "$LEADER_SCRIPT" term "$LEADER_PID_FILE" \
        "$LEADER_READY" "$RELEASE_FILE" "$DESCENDANT_SCRIPT" "$DESCENDANT_PID_FILE" \
        "$DESCENDANT_READY" "$DESCENDANT_GROUP_FILE" "$DESCENDANT_LEASE_RELEASE" \
        "$DESCENDANT_LEASE_READY" "$DESCENDANT_LEASE_CHALLENGE" \
        "$DESCENDANT_LEASE_RESPONSE"; then stage_status=0; else stage_status=$?; fi
    ;;
  *) echo "process_tree_cleanup: unsupported worker case $CASE_NAME" >&2; exit 2 ;;
esac
if ! record_wrapper_restoration; then
  echo "process_tree_cleanup: $CASE_NAME wrapper did not restore protected fixtures before returning" >&2
  stage_status=1
fi
printf '%s\n' "$stage_status" > "$WORKER_STATUS_FILE"
exit "$stage_status"
SH

  cat > "$LEADER_SCRIPT" <<'SH'
#!/bin/sh
set -eu
behavior=$1
leader_pid_file=$2
leader_ready_file=$3
release_file=$4
descendant_script=${5:-}
descendant_pid_file=${6:-}
descendant_ready_file=${7:-}
descendant_group_file=${8:-}
descendant_lease_release_file=${9:-}
descendant_lease_ready_file=${10:-}
if [ "$behavior" = normal ]; then
  printf '%s\n' "$$" > "$leader_pid_file"
  printf 'ready\n' > "$leader_ready_file"
  while [ ! -f "$release_file" ]; do sleep 0.1; done
  exit 23
fi
shift 10
descendant_lease_challenge_file=${1:-}
descendant_lease_response_file=${2:-}
"$descendant_script" "$descendant_pid_file" "$descendant_ready_file" "$$" \
  "$descendant_group_file" "$descendant_lease_release_file" "$descendant_lease_ready_file" \
  "$descendant_lease_challenge_file" "$descendant_lease_response_file" &
descendant_pid=$!
attempt=0
while [ ! -s "$descendant_ready_file" ] && [ "$attempt" -lt 10 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
if [ ! -s "$descendant_ready_file" ] || [ ! -s "$descendant_lease_ready_file" ] ||
   [ "$(sed -n 's/^lease=//p' "$descendant_lease_ready_file")" != held ] ||
   [ ! -s "$descendant_pid_file" ] ||
   [ "$(sed -n '1p' "$descendant_pid_file")" != "$descendant_pid" ]; then
  echo 'process_tree_cleanup: descendant TERM-ignore readiness was not acknowledged' >&2
  exit 4
fi
printf '%s\n' "$$" > "$leader_pid_file"
printf 'ready\n' > "$leader_ready_file"
while :; do sleep 1; done
SH

  cat > "$DESCENDANT_SCRIPT" <<'SH'
#!/bin/sh
set -eu
pid_file=$1
ready_file=$2
leader_group=$3
group_file=$4
lease_release_file=$5
lease_ready_file=$6
lease_challenge_file=$7
lease_response_file=$8
trap '' TERM
printf '%s\n' "$$" > "$pid_file"
printf '%s\n' "$leader_group" > "$group_file"
printf 'lease=held\npid=%s\npgid=%s\nuid=%s\n' \
  "$$" "$leader_group" "$(id -u)" > "$lease_ready_file"
printf 'ready\n' > "$ready_file"
last_nonce=
while [ ! -f "$lease_release_file" ]; do
  if [ -s "$lease_challenge_file" ]; then
    challenge_nonce=$(sed -n 's/^nonce=//p' "$lease_challenge_file")
    challenge_pid=$(sed -n 's/^pid=//p' "$lease_challenge_file")
    challenge_pgid=$(sed -n 's/^pgid=//p' "$lease_challenge_file")
    challenge_uid=$(sed -n 's/^uid=//p' "$lease_challenge_file")
    if [ "$(sed -n 's/^format=//p' "$lease_challenge_file")" = libfuturo-lease-challenge-v1 ] &&
        [ -n "$challenge_nonce" ] && [ "$challenge_nonce" != "$last_nonce" ] &&
        [ "$challenge_pid" = "$$" ] && [ "$challenge_pgid" = "$leader_group" ] &&
        [ "$challenge_uid" = "$(id -u)" ]; then
      response_tmp="$lease_response_file.tmp.$$"
      printf 'format=libfuturo-lease-response-v1\nnonce=%s\npid=%s\npgid=%s\nuid=%s\n' \
        "$challenge_nonce" "$$" "$leader_group" "$(id -u)" > "$response_tmp"
      /bin/mv -f "$response_tmp" "$lease_response_file"
      last_nonce=$challenge_nonce
    fi
  fi
  /bin/sleep 0.05
done
SH
  chmod 700 "$WORKER_SCRIPT" "$LEADER_SCRIPT" "$DESCENDANT_SCRIPT"
}

prepare_case() {
  case_paths "$1"
  check_setup_deadline || return 1
  [ ! -e "$CASE_ROOT" ] || { echo "process_tree_cleanup: duplicate case path $CASE_NAME" >&2; return 1; }
  /bin/mkdir -m 700 "$CASE_ROOT"
  /bin/mkdir -m 700 "$CASE_ROOT/fixture" "$ROOT_DIR" "$BUILD_DIR" "$STAGE_ROOT" \
    "$WORKER_DIR" "$WORKER_SCRATCH"
  /bin/mkdir -m 700 "$STAGE_ROOT/prefix" "$STAGE_ROOT/prefix/lib" \
    "$STAGE_ROOT/prefix/lib/cmake" "$STAGE_ROOT/prefix/lib/cmake/libfuturo"
  : > "$ROOT_DIR/CMakeLists.txt"
  : > "$BUILD_DIR/CMakeCache.txt"
  : > "$STAGE_ROOT/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake"
  # Remove ACLs only from these private mock paths so chmod 000 proves the
  # intended checkout/build access boundary.
  /bin/chmod -N "$ROOT_DIR" "$BUILD_DIR" "$ROOT_DIR/CMakeLists.txt" "$BUILD_DIR/CMakeCache.txt"
  ROOT_MODE=$(stat -f %Lp "$ROOT_DIR")
  BUILD_MODE=$(stat -f %Lp "$BUILD_DIR")
  STAGE_MODE=$(stat -f %Lp "$STAGE_ROOT")
  /bin/mv "$STAGE_ROOT" "$STAGE_FIXTURE_PATH"
  : > "$REPORT_TMP"
  : > "$CASE_LOG"
  printf '%s\n' "$(date +%s)" > "$CASE_ROOT/started-at"
  {
    printf 'checkout_path=%s\ncheckout_mode=%s\n' "$ROOT_DIR" "$ROOT_MODE"
    printf 'build_path=%s\nbuild_mode=%s\n' "$BUILD_DIR" "$BUILD_MODE"
    printf 'staging_fixture_path=%s\nstaging_fixture_mode=%s\n' "$STAGE_FIXTURE_PATH" "$STAGE_MODE"
    printf 'staging_probe_path=%s state=absent\n' "$STAGE_ROOT"
  } > "$CASE_ROOT/original-modes.txt"
  path_is_owned_under_scratch "$CASE_ROOT" &&
    path_is_owned_under_scratch "$ROOT_DIR" &&
    path_is_owned_under_scratch "$BUILD_DIR" &&
    path_is_owned_under_scratch "$STAGE_FIXTURE_PATH" &&
    [ ! -e "$STAGE_ROOT" ] &&
    [ "$ROOT_DIR" != "$SOURCE_ROOT" ] && [ "$BUILD_DIR" != "$SOURCE_ROOT/build/check" ] || {
      echo "process_tree_cleanup: $CASE_NAME fixture ownership/containment safety check failed" >&2
      return 1
    }
  write_case_scripts
  check_setup_deadline || return 1
}

write_generic_scripts() {
  /bin/mkdir -m 700 "$GENERIC_DIR"
  cat > "$GENERIC_LEADER_SCRIPT" <<'SH'
#!/bin/sh
set -eu
ready_file=$1
child_pid_file=$2
child_group_file=$3
child_ready_file=$4
child_lease_ready_file=$5
child_lease_release_file=$6
child_lease_challenge_file=$7
child_lease_response_file=$8
child_script=$9
on_term() {
  "$child_script" "$child_pid_file" "$$" "$child_group_file" "$child_ready_file" \
    "$child_lease_ready_file" "$child_lease_release_file" \
    "$child_lease_challenge_file" "$child_lease_response_file" &
  exit 0
}
trap on_term TERM
printf 'ready\n' > "$ready_file"
while :; do sleep 1; done
SH
  cat > "$GENERIC_DESCENDANT_SCRIPT" <<'SH'
#!/bin/sh
set -eu
pid_file=$1
leader_group=$2
group_file=$3
ready_file=$4
lease_ready_file=$5
lease_release_file=$6
lease_challenge_file=$7
lease_response_file=$8
trap '' TERM
printf '%s\n' "$$" > "$pid_file"
printf '%s\n' "$leader_group" > "$group_file"
printf 'lease=held\npid=%s\npgid=%s\nuid=%s\n' \
  "$$" "$leader_group" "$(id -u)" > "$lease_ready_file"
printf 'ready\n' > "$ready_file"
last_nonce=
while [ ! -f "$lease_release_file" ]; do
  if [ -s "$lease_challenge_file" ]; then
    challenge_nonce=$(sed -n 's/^nonce=//p' "$lease_challenge_file")
    challenge_pid=$(sed -n 's/^pid=//p' "$lease_challenge_file")
    challenge_pgid=$(sed -n 's/^pgid=//p' "$lease_challenge_file")
    challenge_uid=$(sed -n 's/^uid=//p' "$lease_challenge_file")
    if [ "$(sed -n 's/^format=//p' "$lease_challenge_file")" = libfuturo-lease-challenge-v1 ] &&
        [ -n "$challenge_nonce" ] && [ "$challenge_nonce" != "$last_nonce" ] &&
        [ "$challenge_pid" = "$$" ] && [ "$challenge_pgid" = "$leader_group" ] &&
        [ "$challenge_uid" = "$(id -u)" ]; then
      response_tmp="$lease_response_file.tmp.$$"
      printf 'format=libfuturo-lease-response-v1\nnonce=%s\npid=%s\npgid=%s\nuid=%s\n' \
        "$challenge_nonce" "$$" "$leader_group" "$(id -u)" > "$response_tmp"
      /bin/mv -f "$response_tmp" "$lease_response_file"
      last_nonce=$challenge_nonce
    fi
  fi
  /bin/sleep 0.05
done
SH
  cat > "$GENERIC_WORKER_SCRIPT" <<'SH'
#!/bin/sh
set -e
GENERIC_DIR=${GENERIC_DIR:?}
worker_done="$GENERIC_DIR/worker-done"
worker_release="$GENERIC_DIR/worker-release"
worker_trap_ready="$GENERIC_DIR/worker-trap-ready"
worker_handler_ready="$GENERIC_DIR/worker-handler-ready"
cancel_request="$GENERIC_DIR/cancel-request"
worker_pid_is_canonical() {
  case "$1" in ''|*[!0-9]*|0*|1) return 1 ;; *) return 0 ;; esac
}
generic_term_handler() {
  if [ -n "${LF_PROCESS_TREE_ACTIVE_PID:-}" ]; then
    if [ ! -f "$GENERIC_DIR/cleanup-started" ]; then
      printf 'reason=signal\nsignal=TERM\nstarted_epoch=%s\n' \
        "$(date +%s)" > "$GENERIC_DIR/cleanup-started"
    fi
    LF_PROCESS_TREE_CLEANUP_ATTEMPTED=1
    lf_process_tree_cancel_handler TERM
  else
    LF_PROCESS_TREE_PENDING_SIGNAL=TERM
    LF_PROCESS_TREE_CANCEL_SIGNAL=TERM
  fi
}
generic_worker_exit_handshake() {
  generic_exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  set +u
  generic_cleanup_pid=${LF_PROCESS_TREE_ACTIVE_PID:-${LF_PROCESS_TREE_ROOT:-}}
  if [ -n "$generic_cleanup_pid" ] && [ "${LF_PROCESS_TREE_CLEANUP_ATTEMPTED:-0}" -eq 0 ] &&
      worker_pid_is_canonical "$generic_cleanup_pid" && group_exists "$generic_cleanup_pid"; then
    if [ ! -f "$GENERIC_DIR/cleanup-started" ]; then
      printf 'reason=worker-exit\nstarted_epoch=%s\n' "$(date +%s)" > "$GENERIC_DIR/cleanup-started"
    fi
    LF_PROCESS_TREE_CLEANUP_ATTEMPTED=1
    if ! lf_process_tree_terminate "$generic_cleanup_pid"; then generic_exit_status=1; fi
  fi
  if [ "${LF_PROCESS_TREE_CLEANUP_FAILED:-0}" -ne 0 ]; then generic_exit_status=1; fi
  printf 'done\n' > "$worker_done"
  while [ ! -f "$worker_release" ]; do /bin/sleep 0.05; done
  exit "$generic_exit_status"
}
trap generic_worker_exit_handshake EXIT
printf 'ready\n' > "$worker_trap_ready"
set -u
SOURCE_ROOT=${SOURCE_ROOT:?}
. "$SOURCE_ROOT/scripts/process-tree-cleanup.sh"
LF_PROCESS_TREE_ACTIVE_PID=
LF_PROCESS_TREE_CANCEL_SIGNAL=none
LF_PROCESS_TREE_PENDING_SIGNAL=none
LF_PROCESS_TREE_CLEANUP_ACTIVE=0
LF_PROCESS_TREE_CLEANUP_FAILED=0
LF_PROCESS_TREE_CLEANUP_ATTEMPTED=0
trap 'generic_term_handler' TERM
leader_script="$GENERIC_DIR/leader.sh"
leader_ready="$GENERIC_DIR/leader-ready"
root_pid_file="$GENERIC_DIR/leader-pid"
desc_pid_file="$GENERIC_DIR/descendant-pid"
desc_group_file="$GENERIC_DIR/descendant-group"
desc_ready="$GENERIC_DIR/descendant-ready"
desc_lease_ready="$GENERIC_DIR/descendant-lease-ready"
desc_lease_release="$GENERIC_DIR/descendant-lease-release"
desc_lease_challenge="$GENERIC_DIR/descendant-lease-challenge"
desc_lease_response="$GENERIC_DIR/descendant-lease-response"
desc_script="$GENERIC_DIR/descendant.sh"
worker_ready="$GENERIC_DIR/worker-ready"
worker_result="$GENERIC_DIR/result.txt"
lf_process_tree_start "$leader_script" "$leader_ready" "$desc_pid_file" \
  "$desc_group_file" "$desc_ready" "$desc_lease_ready" "$desc_lease_release" \
  "$desc_lease_challenge" "$desc_lease_response" "$desc_script" 2>/dev/null
root_pid=$LF_PROCESS_TREE_ROOT
if ! worker_pid_is_canonical "$root_pid"; then
  echo 'process_tree_cleanup: generic launched group has an invalid canonical PID' >&2
  exit 1
fi
LF_PROCESS_TREE_ACTIVE_PID=$root_pid
printf '%s\n' "$root_pid" > "$root_pid_file"
printf 'handler=active\npgid=%s\n' "$root_pid" > "$worker_handler_ready"
if [ "$LF_PROCESS_TREE_PENDING_SIGNAL" != none ] || [ -f "$cancel_request" ]; then
  generic_term_handler
  [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -eq 0 ] || exit 1
  exit 143
fi
attempt=0
while [ ! -s "$leader_ready" ] && [ "$attempt" -lt 10 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
if [ ! -s "$leader_ready" ]; then
  echo 'process_tree_cleanup: generic leader readiness timed out' >&2
  exit 1
fi
printf 'ready\n' > "$worker_ready"
kill -TERM "$$"
trap 'exit 143' TERM
desc_pid=$(sed -n '1p' "$desc_pid_file")
desc_group=$(sed -n '1p' "$desc_group_file")
if [ "$LF_PROCESS_TREE_CANCEL_SIGNAL" != TERM ] ||
    [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -ne 0 ] ||
    [ ! -s "$desc_ready" ] || [ "$desc_pid" = '' ] ||
    ! worker_pid_is_canonical "$root_pid" ||
    ! worker_pid_is_canonical "$desc_pid" ||
    ! worker_pid_is_canonical "$desc_group" ||
    [ "$desc_group" != "$root_pid" ] ||
    kill -0 -- "-$root_pid" 2>/dev/null || kill -0 "$desc_pid" 2>/dev/null; then
  echo 'process_tree_cleanup: generic late-descendant cancellation did not clean the group' >&2
  exit 1
fi
printf 'result=pass\nleader_pid=%s\ndescendant_pid=%s\ndescendant_group=%s\n' \
  "$root_pid" "$desc_pid" "$desc_group" > "$worker_result"
exit 0
SH
  chmod 700 "$GENERIC_LEADER_SCRIPT" "$GENERIC_DESCENDANT_SCRIPT" "$GENERIC_WORKER_SCRIPT"
  : > "$GENERIC_WORKER_LOG"
}

start_generic_worker() {
  check_setup_deadline || return 1
  SOURCE_ROOT="$SOURCE_ROOT" GENERIC_DIR="$GENERIC_DIR" \
    "$GENERIC_WORKER_SCRIPT" > "$GENERIC_WORKER_LOG" 2>&1 &
  GENERIC_WORKER_PID=$!
  is_numeric_pid "$GENERIC_WORKER_PID" || return 1
  process_is_owned "$GENERIC_WORKER_PID" || return 1
  printf '%s\n' "$GENERIC_WORKER_PID" > "$GENERIC_WORKER_PID_FILE"
  wait_for_marker "$GENERIC_WORKER_TRAP_READY" && marker_is_owned "$GENERIC_WORKER_TRAP_READY" &&
    process_is_owned "$GENERIC_WORKER_PID" || {
      echo 'process_tree_cleanup: generic worker did not enter its controller-release handshake' >&2
      return 1
    }
}

start_case_worker() {
  case_paths "$1"
  check_setup_deadline || return 1
  path_is_owned_under_scratch "$CASE_ROOT" &&
    path_is_owned_under_scratch "$ROOT_DIR" &&
    path_is_owned_under_scratch "$BUILD_DIR" &&
    path_is_owned_under_scratch "$STAGE_FIXTURE_PATH" && [ ! -e "$STAGE_ROOT" ] || {
      echo "process_tree_cleanup: $CASE_NAME fixture safety failed before worker launch" >&2
      return 1
    }
  SOURCE_ROOT="$SOURCE_ROOT" RUN_CASE_ROOT="$CASE_ROOT" \
    ORIGINAL_ROOT_MODE="$ROOT_MODE" ORIGINAL_BUILD_MODE="$BUILD_MODE" \
    ORIGINAL_STAGE_MODE="$STAGE_MODE" "$WORKER_SCRIPT" "$CASE_NAME" \
    > "$CASE_LOG" 2>&1 &
  CASE_WORKER_PID=$!
  is_numeric_pid "$CASE_WORKER_PID" || return 1
  process_is_owned "$CASE_WORKER_PID" || return 1
  printf '%s\n' "$CASE_WORKER_PID" > "$WORKER_PID_FILE"
  wait_for_marker "$CASE_WORKER_READY_FILE" && marker_is_owned "$CASE_WORKER_READY_FILE" &&
    process_is_owned "$CASE_WORKER_PID" || {
      echo "process_tree_cleanup: $CASE_NAME worker did not enter its controller-release handshake" >&2
      return 1
    }
}

wait_for_marker() {
  marker_path=$1
  while [ ! -s "$marker_path" ]; do
    check_setup_deadline || return 1
    /bin/sleep 0.1
  done
  [ -s "$marker_path" ]
}

verify_leader_identity() {
  CASE_CHILD_PID=$(sed -n '1p' "$LEADER_PID_FILE")
  is_numeric_pid "$CASE_CHILD_PID" || return 1
  marker_is_owned "$LEADER_PID_FILE" || return 1
  process_is_owned "$CASE_CHILD_PID" || return 1
  group_exists "$CASE_CHILD_PID" || return 1
  CASE_CHILD_PGID=$CASE_CHILD_PID
}

arm_case_worker() {
  case_paths "$1"
  if ! wait_for_marker "$LEADER_READY"; then
    echo "process_tree_cleanup: $CASE_NAME leader readiness missing/deadline reached" >&2
    return 1
  fi
  verify_leader_identity || {
    echo "process_tree_cleanup: $CASE_NAME leader PID/group identity is not live and owned" >&2
    return 1
  }
  if [ "$CASE_NAME" = timeout ] || [ "$CASE_NAME" = term ]; then
    if ! wait_for_marker "$DESCENDANT_READY" || ! wait_for_marker "$DESCENDANT_LEASE_READY" ||
        ! marker_is_owned "$DESCENDANT_LEASE_READY" || ! marker_is_owned "$DESCENDANT_PID_FILE" ||
        ! marker_is_owned "$DESCENDANT_GROUP_FILE"; then
      echo "process_tree_cleanup: $CASE_NAME descendant readiness/ownership missing" >&2
      return 1
    fi
    CASE_DESCENDANT_PID=$(sed -n '1p' "$DESCENDANT_PID_FILE")
    descendant_group=$(sed -n '1p' "$DESCENDANT_GROUP_FILE")
    is_numeric_pid "$CASE_DESCENDANT_PID" && process_is_owned "$CASE_DESCENDANT_PID" &&
      [ "$descendant_group" = "$CASE_CHILD_PGID" ] && group_exists "$CASE_CHILD_PGID" &&
      lease_is_active_owned "$DESCENDANT_LEASE_READY" "$DESCENDANT_LEASE_RELEASE" \
        "$DESCENDANT_PID_FILE" "$DESCENDANT_GROUP_FILE" "$CASE_CHILD_PGID" \
        "$DESCENDANT_LEASE_CHALLENGE" "$DESCENDANT_LEASE_RESPONSE" setup || {
        echo "process_tree_cleanup: $CASE_NAME descendant escaped or lacks an owned process group" >&2
        return 1
      }
  fi
  CASE_WORKER_PID=$(sed -n '1p' "$WORKER_PID_FILE")
  process_is_owned "$CASE_WORKER_PID" || {
    echo "process_tree_cleanup: $CASE_NAME wrapper worker is no longer live" >&2
    return 1
  }
  {
    printf 'worker_pid=%s uid=%s ownership=direct-child\n' "$CASE_WORKER_PID" "$RUN_UID"
    printf 'leader_pid=%s pgid=%s uid=%s ownership=private-pid-marker,job-control-group\n' \
      "$CASE_CHILD_PID" "$CASE_CHILD_PGID" "$(stat -f %u "$LEADER_PID_FILE")"
    if [ -n "$CASE_DESCENDANT_PID" ]; then
      printf 'descendant_pid=%s pgid=%s uid=%s ownership=private-pid-marker,term-ignore-ready\n' \
        "$CASE_DESCENDANT_PID" "$CASE_CHILD_PGID" "$(stat -f %u "$DESCENDANT_PID_FILE")"
    fi
    printf 'facts_ctest_pid_expected=%s\n' "$CASE_CHILD_PID"
  } > "$CASE_ROOT/identity.txt"
  case "$CASE_NAME" in
    normal)
      printf 'reason=normal-release\nstarted_epoch=%s\n' "$(date +%s)" \
        > "$CASE_ROOT/cleanup-started.txt"
      printf 'release\n' > "$RELEASE_FILE"
      ;;
    timeout) : ;; # The child writes readiness before its timeout sleep begins.
    term)
      if ! signal_direct_worker "$CASE_WORKER_PID" "$WORKER_PID_FILE" \
          "$CASE_WORKER_READY_FILE" "$WORKER_DONE_FILE" "$CASE_ROOT/worker-reaping"; then
        echo 'process_tree_cleanup: TERM case worker was no longer active under its release handshake' >&2
        return 1
      fi
      ;;
  esac
}

arm_generic_worker() {
  wait_for_marker "$GENERIC_WORKER_HANDLER_READY" &&
    marker_is_owned "$GENERIC_WORKER_HANDLER_READY" || {
      echo 'process_tree_cleanup: generic process-group handler/identity readiness is missing' >&2
      return 1
    }
  GENERIC_ROOT_PID=$(sed -n '1p' "$GENERIC_ROOT_PID_FILE")
  handler_pgid=$(sed -n 's/^pgid=//p' "$GENERIC_WORKER_HANDLER_READY")
  handler_active=$(sed -n 's/^handler=//p' "$GENERIC_WORKER_HANDLER_READY")
  is_numeric_pid "$GENERIC_ROOT_PID" && marker_is_owned "$GENERIC_ROOT_PID_FILE" &&
    [ "$handler_pgid" = "$GENERIC_ROOT_PID" ] && [ "$handler_active" = active ] || {
    echo 'process_tree_cleanup: generic leader identity marker is invalid' >&2
    return 1
  }
  wait_for_marker "$GENERIC_WORKER_READY" || {
    echo 'process_tree_cleanup: generic cleanup worker readiness/deadline failed' >&2
    return 1
  }
  wait_for_marker "$GENERIC_DESCENDANT_READY" &&
    wait_for_marker "$GENERIC_DESCENDANT_LEASE_READY" &&
    marker_is_owned "$GENERIC_DESCENDANT_LEASE_READY" &&
    marker_is_owned "$GENERIC_DESCENDANT_PID_FILE" &&
    marker_is_owned "$GENERIC_DESCENDANT_GROUP_FILE" || {
      echo 'process_tree_cleanup: generic descendant readiness/ownership is missing' >&2
      return 1
    }
  generic_descendant=$(sed -n '1p' "$GENERIC_DESCENDANT_PID_FILE")
  generic_group=$(sed -n '1p' "$GENERIC_DESCENDANT_GROUP_FILE")
  is_numeric_pid "$generic_descendant" && process_is_owned "$generic_descendant" &&
    [ "$generic_group" = "$GENERIC_ROOT_PID" ] && group_exists "$GENERIC_ROOT_PID" &&
    lease_is_active_owned "$GENERIC_DESCENDANT_LEASE_READY" \
      "$GENERIC_DESCENDANT_LEASE_RELEASE" "$GENERIC_DESCENDANT_PID_FILE" \
      "$GENERIC_DESCENDANT_GROUP_FILE" "$GENERIC_ROOT_PID" \
      "$GENERIC_DESCENDANT_LEASE_CHALLENGE" "$GENERIC_DESCENDANT_LEASE_RESPONSE" setup || {
      echo 'process_tree_cleanup: generic descendant/group identity is not live and owned' >&2
      return 1
    }
  GENERIC_WORKER_PID=$(sed -n '1p' "$GENERIC_WORKER_PID_FILE")
  process_is_owned "$GENERIC_WORKER_PID" || {
    echo 'process_tree_cleanup: generic worker exited before cancellation cleanup' >&2
    return 1
  }
}

wait_for_all_workers() {
  while :; do
    check_completion_deadline || return 1
    pending=0
    [ -f "$GENERIC_WORKER_DONE" ] || pending=1
    for pending_case in normal timeout term; do
      pending_root="$SCRATCH_REAL/$pending_case"
      [ -f "$pending_root/worker-done" ] || pending=1
    done
    [ "$pending" -eq 1 ] || return 0
    /bin/sleep 0.1
  done
}

verify_teardown_marker() {
  teardown_marker=$1
  teardown_label=$2
  [ -f "$teardown_marker" ] || return 1
  marker_epoch=$(sed -n 's/^started_epoch=//p' "$teardown_marker")
  case "$marker_epoch" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$marker_epoch" -gt "$TEARDOWN_START_DEADLINE" ]; then
    echo "process_tree_cleanup: $teardown_label teardown started after the T+$((TEARDOWN_START_DEADLINE - TEST_STARTED_AT)) deadline" >&2
    return 1
  fi
  return 0
}

wait_for_teardown_started() {
  while :; do
    all_teardown_started=1
    verify_teardown_marker "$SCRATCH_REAL/normal/cleanup-started.txt" normal || all_teardown_started=0
    verify_teardown_marker "$SCRATCH_REAL/timeout/cleanup-started.txt" timeout || all_teardown_started=0
    verify_teardown_marker "$SCRATCH_REAL/term/cleanup-started.txt" term || all_teardown_started=0
    verify_teardown_marker "$GENERIC_CLEANUP_STARTED" generic || all_teardown_started=0
    [ "$all_teardown_started" -eq 1 ] && return 0
    now=$(date +%s)
    if [ "$now" -ge "$TEARDOWN_START_DEADLINE" ]; then
      echo "process_tree_cleanup: owned cleanup did not start by the T+$((TEARDOWN_START_DEADLINE - TEST_STARTED_AT)) teardown deadline" >&2
      return 1
    fi
    /bin/sleep 0.05
  done
}

reap_case_worker() {
  case_paths "$1"
  check_completion_deadline || return 1
  [ -f "$WORKER_DONE_FILE" ] && marker_is_owned "$WORKER_DONE_FILE" || return 1
  [ -f "$CASE_WORKER_READY_FILE" ] && marker_is_owned "$CASE_WORKER_READY_FILE" || return 1
  # The EXIT handler remains alive after worker-done until this controller
  # marks reaping and explicitly releases the direct child.
  : > "$CASE_ROOT/worker-reaping"
  : > "$CASE_WORKER_RELEASE_FILE"
  wait_owned_worker "$CASE_WORKER_PID" "$WORKER_PID_FILE" "$WORKER_DONE_FILE" \
    "$CASE_ROOT/worker-reaping" "$CASE_WORKER_RELEASE_FILE" "$CASE_NAME" "$WORKER_SCRIPT" || return 1
  worker_wait_status=$OWNED_WORKER_WAIT_STATUS
  check_absolute_deadline || return 1
  printf '%s\n' "$worker_wait_status" > "$CASE_ROOT/worker-exit-status.txt"
  printf 'reaped\n' > "$CASE_ROOT/worker-reaped"
  CASE_WORKER_REAPED=1
}

reap_generic_worker() {
  check_completion_deadline || return 1
  [ -f "$GENERIC_WORKER_DONE" ] && marker_is_owned "$GENERIC_WORKER_DONE" || return 1
  [ -f "$GENERIC_WORKER_TRAP_READY" ] && marker_is_owned "$GENERIC_WORKER_TRAP_READY" || return 1
  : > "$GENERIC_DIR/worker-reaping"
  : > "$GENERIC_WORKER_RELEASE"
  wait_owned_worker "$GENERIC_WORKER_PID" "$GENERIC_WORKER_PID_FILE" "$GENERIC_WORKER_DONE" \
    "$GENERIC_DIR/worker-reaping" "$GENERIC_WORKER_RELEASE" generic "$GENERIC_WORKER_SCRIPT" || return 1
  generic_wait_status=$OWNED_WORKER_WAIT_STATUS
  check_absolute_deadline || return 1
  printf '%s\n' "$generic_wait_status" > "$GENERIC_DIR/worker-exit-status.txt"
  printf 'reaped\n' > "$GENERIC_DIR/worker-reaped"
  [ "$generic_wait_status" -eq 0 ] || return 1
  GENERIC_WORKER_REAPED=1
  GENERIC_WORKER_PID=
}

write_case_cleanup_result() {
  group_state=not-recorded
  descendant_state=not-recorded
  if [ -n "$CASE_CHILD_PGID" ] && is_numeric_pid "$CASE_CHILD_PGID"; then
    if group_exists "$CASE_CHILD_PGID"; then group_state=present; else group_state=absent; fi
  fi
  if [ -f "$DESCENDANT_PID_FILE" ]; then
    observed_descendant=$(sed -n '1p' "$DESCENDANT_PID_FILE")
    if is_numeric_pid "$observed_descendant" && kill -0 "$observed_descendant" 2>/dev/null; then
      descendant_state=present
    else
      descendant_state=absent
    fi
  fi
  case_elapsed=unavailable
  case "$CASE_STARTED_AT" in
    ''|*[!0-9]*) ;;
    *) case_elapsed=$(( $(date +%s) - CASE_STARTED_AT )) ;;
  esac
  {
    printf 'case=%s\ngroup=%s\ndescendant=%s\n' "$CASE_NAME" "$group_state" "$descendant_state"
    printf 'checkout_mode_original=%s\ncheckout_mode_at_worker_return=%s\n' \
      "$ROOT_MODE" "$(sed -n 's/^checkout_mode_after=//p' "$RESTORE_RESULT_FILE")"
    printf 'build_mode_original=%s\nbuild_mode_at_worker_return=%s\n' \
      "$BUILD_MODE" "$(sed -n 's/^build_mode_after=//p' "$RESTORE_RESULT_FILE")"
    printf 'staging_fixture_mode_original=%s\nstaging_fixture_mode_observed=%s\nstaging_probe_path=absent\n' \
      "$STAGE_MODE" "$(stat -f %Lp "$STAGE_FIXTURE_PATH" 2>/dev/null || printf unavailable)"
    printf 'elapsed_seconds=%s\n' "$case_elapsed"
  } > "$CASE_ROOT/cleanup-result.txt"
  CASE_ELAPSED=$case_elapsed
}

ensure_owned_evidence_root() {
  [ -n "$EVIDENCE_RUN" ] || return 1
  if [ ! -d "$EVIDENCE_RUN" ] || [ -L "$EVIDENCE_RUN" ] ||
      [ "$(stat -f %u "$EVIDENCE_RUN" 2>/dev/null)" != "$RUN_UID" ]; then
    echo "process_tree_cleanup: refusing unowned evidence attempt directory: $EVIDENCE_RUN" >&2
    return 1
  fi
  evidence_root_real=$(CDPATH= cd "$EVIDENCE_RUN" 2>/dev/null && pwd -P) || return 1
  [ "$evidence_root_real" = "$EVIDENCE_RUN" ]
}

ensure_owned_evidence_directory() {
  evidence_directory=$1
  ensure_owned_evidence_root || return 1
  case "$evidence_directory" in
    "$EVIDENCE_RUN"/*) evidence_name=${evidence_directory#"$EVIDENCE_RUN"/} ;;
    *) echo "process_tree_cleanup: evidence path is outside this attempt: $evidence_directory" >&2; return 1 ;;
  esac
  case "$evidence_name" in
    ''|.|..|*/*) echo "process_tree_cleanup: evidence path is not a direct child: $evidence_directory" >&2; return 1 ;;
  esac
  if [ -e "$evidence_directory" ] || [ -L "$evidence_directory" ]; then
    evidence_directory_uid=$(stat -f %u "$evidence_directory" 2>/dev/null) || return 1
    if [ ! -d "$evidence_directory" ] || [ -L "$evidence_directory" ] ||
        [ "$evidence_directory_uid" != "$RUN_UID" ]; then
      echo "process_tree_cleanup: refusing unowned evidence case path: $evidence_directory" >&2
      return 1
    fi
  else
    /bin/mkdir "$evidence_directory" || return 1
  fi
  evidence_real=$(CDPATH= cd "$evidence_directory" 2>/dev/null && pwd -P) || return 1
  [ "$evidence_real" = "$EVIDENCE_RUN/$evidence_name" ]
}

preserve_case_evidence() {
  [ -n "$EVIDENCE_RUN" ] || return 0
  check_absolute_deadline || return 1
  case_paths "$1"
  evidence_case="$EVIDENCE_RUN/$CASE_NAME"
  ensure_owned_evidence_directory "$evidence_case" || return 1
  for evidence_file in original-modes.txt identity.txt worker-pid worker-trap-ready \
      worker-done worker-reaping worker-reaped worker-release leader-ready leader-pid \
      descendant-ready descendant-pid descendant-group descendant-lease-ready \
      descendant-lease-release descendant-lease-challenge descendant-lease-response \
      release-child wrapper.log \
      wrapper-status.txt worker-exit-status.txt wrapper-restoration.txt \
      cleanup-started.txt isolation-protected-paths.txt \
      cleanup-result.txt; do
    if [ -f "$CASE_ROOT/$evidence_file" ]; then
      check_absolute_deadline || return 1
      /bin/cp "$CASE_ROOT/$evidence_file" "$evidence_case/$evidence_file" || return 1
      check_absolute_deadline || return 1
    fi
  done
  if [ -f "$WORKER_SCRATCH/macos-host.log" ]; then
    check_absolute_deadline || return 1
    /bin/cp "$WORKER_SCRATCH/macos-host.log" "$evidence_case/child.log" || return 1
    check_absolute_deadline || return 1
  fi
  if [ -f "$WORKER_SCRATCH/macos-host.process-facts.txt" ]; then
    check_absolute_deadline || return 1
    /bin/cp "$WORKER_SCRATCH/macos-host.process-facts.txt" "$evidence_case/process-facts.txt" || return 1
    check_absolute_deadline || return 1
  fi
  printf 'case=%s\nsource_root=%s\n' "$CASE_NAME" "$SOURCE_ROOT" > "$evidence_case/evidence-index.txt"
}

finish_case() {
  case_paths "$1"
  expected_status=$2
  expected_signal=$3
  expected_timeout=$4
  check_completion_deadline || return 1
  [ -s "$LEADER_READY" ] && marker_is_owned "$LEADER_READY" &&
    marker_is_owned "$LEADER_PID_FILE" || {
      echo "process_tree_cleanup: $CASE_NAME stage readiness was not observed before accepting its status" >&2
      return 1
    }
  if [ "$CASE_NAME" = timeout ] || [ "$CASE_NAME" = term ]; then
    [ -s "$DESCENDANT_READY" ] && marker_is_owned "$DESCENDANT_READY" &&
      marker_is_owned "$DESCENDANT_PID_FILE" && marker_is_owned "$DESCENDANT_GROUP_FILE" || {
        echo "process_tree_cleanup: $CASE_NAME descendant readiness was not observed before accepting its status" >&2
        return 1
      }
  fi
  observed_status=$(sed -n '1p' "$WORKER_STATUS_FILE")
  worker_exit_status=$(sed -n '1p' "$CASE_ROOT/worker-exit-status.txt")
  [ "$observed_status" = "$expected_status" ] && [ "$worker_exit_status" = "$expected_status" ] || {
    echo "process_tree_cleanup: $CASE_NAME wrapper/worker status mismatch" >&2
    return 1
  }
  facts="$WORKER_SCRATCH/macos-host.process-facts.txt"
  [ -f "$facts" ] || { echo "process_tree_cleanup: $CASE_NAME process facts missing" >&2; return 1; }
  [ "$(sed -n '1p' "$facts")" = 'format=libfuturo-host-ctest-process-v1' ] || return 1
  FACT_PID=$(sed -n 's/^ctest_pid=//p' "$facts")
  FACT_EXIT=$(sed -n 's/^exit_status=//p' "$facts")
  FACT_SIGNAL=$(sed -n 's/^signal=//p' "$facts")
  FACT_TIMEOUT=$(sed -n 's/^timed_out=//p' "$facts")
  FACT_ELAPSED=$(sed -n 's/^elapsed_seconds=//p' "$facts")
  is_numeric_pid "$FACT_PID" || return 1
  case "$FACT_EXIT" in ''|*[!0-9]*) return 1 ;; esac
  case "$FACT_ELAPSED" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FACT_PID" = "$CASE_CHILD_PID" ] || {
    echo "process_tree_cleanup: $CASE_NAME facts ctest_pid does not match the ready leader PID" >&2
    return 1
  }
  [ "$FACT_SIGNAL" = "$expected_signal" ] && [ "$FACT_TIMEOUT" = "$expected_timeout" ] || {
    echo "process_tree_cleanup: $CASE_NAME signal/timeout classification mismatch" >&2
    return 1
  }
  [ -f "$RESTORE_RESULT_FILE" ] &&
    [ "$(sed -n '1p' "$RESTORE_RESULT_FILE")" = 'format=libfuturo-wrapper-restoration-v1' ] &&
    [ "$(sed -n 's/^result=//p' "$RESTORE_RESULT_FILE")" = pass ] &&
    [ "$(sed -n 's/^paths_protected=//p' "$RESTORE_RESULT_FILE")" = 0 ] &&
    [ "$(sed -n 's/^checkout_mode_after=//p' "$RESTORE_RESULT_FILE")" = "$ROOT_MODE" ] &&
    [ "$(sed -n 's/^checkout_readable=//p' "$RESTORE_RESULT_FILE")" = yes ] &&
    [ "$(sed -n 's/^build_mode_after=//p' "$RESTORE_RESULT_FILE")" = "$BUILD_MODE" ] &&
    [ "$(sed -n 's/^build_readable=//p' "$RESTORE_RESULT_FILE")" = yes ] &&
    [ "$(sed -n 's/^staging_probe_path=//p' "$RESTORE_RESULT_FILE")" = absent ] &&
    [ "$(sed -n 's/^staging_fixture_mode_after=//p' "$RESTORE_RESULT_FILE")" = "$STAGE_MODE" ] &&
    [ "$(sed -n 's/^staging_fixture_readable=//p' "$RESTORE_RESULT_FILE")" = yes ] || {
      echo "process_tree_cleanup: $CASE_NAME pre-EXIT worker restoration assertion failed" >&2
      return 1
    }
  if group_exists "$CASE_CHILD_PGID"; then
    echo "process_tree_cleanup: $CASE_NAME owned process group remains alive" >&2
    return 1
  fi
  if [ "$CASE_NAME" = timeout ] || [ "$CASE_NAME" = term ]; then
    observed_descendant=$(sed -n '1p' "$DESCENDANT_PID_FILE")
    is_numeric_pid "$observed_descendant" || return 1
    if kill -0 "$observed_descendant" 2>/dev/null; then
      echo "process_tree_cleanup: $CASE_NAME TERM-resistant descendant remains alive" >&2
      return 1
    fi
  fi
  write_case_cleanup_result
  [ "$(sed -n 's/^group=//p' "$CASE_ROOT/cleanup-result.txt")" = absent ] || return 1
  if [ "$CASE_NAME" = timeout ] || [ "$CASE_NAME" = term ]; then
    [ "$(sed -n 's/^descendant=//p' "$CASE_ROOT/cleanup-result.txt")" = absent ] || return 1
  fi
  printf 'case=%s wrapper_status=%s signal=%s timed_out=%s ctest_pid=%s exit_status_observed=%s group=absent restoration=worker-before-exit elapsed_seconds=%s result=pass\n' \
    "$CASE_NAME" "$expected_status" "$expected_signal" "$expected_timeout" \
    "$FACT_PID" "$FACT_EXIT" "$CASE_ELAPSED"
  preserve_case_evidence "$CASE_NAME"
}

wait_for_handshake_done() {
  done_marker=$1
  while [ ! -f "$done_marker" ]; do
    now=$(date +%s)
    if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
      echo 'process_tree_cleanup: worker did not reach its release handshake before the absolute deadline' >&2
      return 1
    fi
    /bin/sleep 0.05
  done
  marker_is_owned "$done_marker"
}

ps_worker_snapshot() {
  ps_worker_pid=$1
  ps_worker_include_command=${2:-no}
  PS_WORKER_ROW_PID=
  PS_WORKER_ROW_PPID=
  PS_WORKER_ROW_UID=
  PS_WORKER_ROW_STATE=
  PS_WORKER_ROW_COMMAND=
  if [ "$ps_worker_include_command" = yes ]; then
    if ps_worker_raw=$(ps -ww -p "$ps_worker_pid" -o pid= -o ppid= -o uid= -o state= -o command= 2>/dev/null); then :; else
      if kill -0 "$ps_worker_pid" 2>/dev/null; then return 1; fi
      return 0
    fi
  else
    if ps_worker_raw=$(ps -p "$ps_worker_pid" -o pid= -o ppid= -o uid= -o state= 2>/dev/null); then :; else
      if kill -0 "$ps_worker_pid" 2>/dev/null; then return 1; fi
      return 0
    fi
  fi
  ps_worker_raw=$(printf '%s' "$ps_worker_raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || return 1
  if [ -z "$ps_worker_raw" ]; then
    if kill -0 "$ps_worker_pid" 2>/dev/null; then return 1; fi
    return 0
  fi
  if [ "$ps_worker_include_command" = yes ]; then
    IFS=' ' read -r PS_WORKER_ROW_PID PS_WORKER_ROW_PPID PS_WORKER_ROW_UID \
      PS_WORKER_ROW_STATE PS_WORKER_ROW_COMMAND <<EOF
$ps_worker_raw
EOF
  else
    IFS=' ' read -r PS_WORKER_ROW_PID PS_WORKER_ROW_PPID PS_WORKER_ROW_UID \
      PS_WORKER_ROW_STATE <<EOF
$ps_worker_raw
EOF
  fi
  is_numeric_pid "$PS_WORKER_ROW_PID" && is_numeric_pid "$PS_WORKER_ROW_PPID" || return 1
  case "$PS_WORKER_ROW_UID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$PS_WORKER_ROW_STATE" ] || return 1
}

wait_owned_worker() {
  owned_worker_pid=$1
  owned_worker_pid_file=$2
  owned_worker_done_file=$3
  owned_worker_reaping_file=$4
  owned_worker_release_file=$5
  owned_worker_label=$6
  owned_worker_script=$7
  owned_worker_kill_sent=0
  OWNED_WORKER_WAIT_STATUS=
  is_numeric_pid "$owned_worker_pid" && marker_is_owned "$owned_worker_pid_file" &&
    [ "$(sed -n '1p' "$owned_worker_pid_file")" = "$owned_worker_pid" ] &&
    marker_is_owned "$owned_worker_done_file" && marker_is_owned "$owned_worker_reaping_file" &&
    marker_is_owned "$owned_worker_release_file" && [ -f "$owned_worker_script" ] &&
    [ ! -L "$owned_worker_script" ] && marker_is_owned "$owned_worker_script" || return 1
  case "$owned_worker_script" in "$SCRATCH_REAL"/*) ;; *) return 1 ;; esac

  # Do not block in the shell's wait builtin while a released worker is still
  # running. Poll only its direct-child identity; wait is called after exit is
  # observable (normally as a zombie), so the reap itself cannot overrun the
  # active deadline.
  while :; do
    if ! ps_worker_snapshot "$owned_worker_pid"; then
      echo "process_tree_cleanup: could not inspect $owned_worker_label worker state" >&2
      return 1
    fi
    [ -n "$PS_WORKER_ROW_PID" ] || break
    [ "$PS_WORKER_ROW_PID" = "$owned_worker_pid" ] || return 1
    if [ "$PS_WORKER_ROW_PPID" != "$$" ] || [ "$PS_WORKER_ROW_UID" != "$RUN_UID" ]; then
      echo "process_tree_cleanup: $owned_worker_label worker is no longer the verified direct child" >&2
      return 1
    fi
    case "$PS_WORKER_ROW_STATE" in Z*) break ;; esac

    now=$(date +%s)
    if [ "$CLEANUP_ACTIVE" -eq 1 ] && [ "$now" -ge "$FORCE_REAP_DEADLINE" ] &&
        [ "$owned_worker_kill_sent" -eq 0 ]; then
      # The worker has completed its process-group cleanup, published its owned
      # done marker, and received release. If its direct shell still has not
      # exited, terminate only that verified direct child to keep teardown
      # bounded; the final group guard below still refuses any surviving group.
      ps_worker_snapshot "$owned_worker_pid" yes || return 1
      [ -n "$PS_WORKER_ROW_PID" ] || break
      [ "$PS_WORKER_ROW_PID" = "$owned_worker_pid" ] &&
        [ "$PS_WORKER_ROW_PPID" = "$$" ] && [ "$PS_WORKER_ROW_UID" = "$RUN_UID" ] || return 1
      case "$PS_WORKER_ROW_STATE" in Z*) break ;; esac
      case "$PS_WORKER_ROW_COMMAND" in *"$owned_worker_script"*) ;; *) return 1 ;; esac
      marker_is_owned "$owned_worker_pid_file" &&
        [ "$(sed -n '1p' "$owned_worker_pid_file")" = "$owned_worker_pid" ] &&
        marker_is_owned "$owned_worker_done_file" && marker_is_owned "$owned_worker_release_file" || return 1
      if ! kill -KILL "$owned_worker_pid" 2>/dev/null; then
        ps_worker_snapshot "$owned_worker_pid" || return 1
        [ -n "$PS_WORKER_ROW_PID" ] || break
        case "$PS_WORKER_ROW_STATE" in Z*) break ;; esac
        echo "process_tree_cleanup: could not stop verified $owned_worker_label worker after release" >&2
        return 1
      fi
      owned_worker_kill_sent=1
      continue
    fi
    if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
      echo "process_tree_cleanup: $owned_worker_label worker exit exceeded the active deadline" >&2
      return 1
    fi
    /bin/sleep 0.05
  done

  if wait "$owned_worker_pid"; then OWNED_WORKER_WAIT_STATUS=0; else OWNED_WORKER_WAIT_STATUS=$?; fi
  return 0
}

release_and_reap_case_worker() {
  case_paths "$1"
  [ -f "$WORKER_DONE_FILE" ] && marker_is_owned "$WORKER_DONE_FILE" || return 1
  : > "$CASE_ROOT/worker-reaping"
  : > "$CASE_WORKER_RELEASE_FILE"
  wait_owned_worker "$CASE_WORKER_PID" "$WORKER_PID_FILE" "$WORKER_DONE_FILE" \
    "$CASE_ROOT/worker-reaping" "$CASE_WORKER_RELEASE_FILE" "$CASE_NAME" "$WORKER_SCRIPT" || return 1
  worker_wait_status=$OWNED_WORKER_WAIT_STATUS
  printf '%s\n' "$worker_wait_status" > "$CASE_ROOT/worker-exit-status.txt"
  printf 'reaped\n' > "$CASE_ROOT/worker-reaped"
  CASE_WORKER_REAPED=1
}

release_and_reap_generic_worker() {
  [ -f "$GENERIC_WORKER_DONE" ] && marker_is_owned "$GENERIC_WORKER_DONE" || return 1
  : > "$GENERIC_DIR/worker-reaping"
  : > "$GENERIC_WORKER_RELEASE"
  wait_owned_worker "$GENERIC_WORKER_PID" "$GENERIC_WORKER_PID_FILE" "$GENERIC_WORKER_DONE" \
    "$GENERIC_DIR/worker-reaping" "$GENERIC_WORKER_RELEASE" generic "$GENERIC_WORKER_SCRIPT" || return 1
  generic_wait_status=$OWNED_WORKER_WAIT_STATUS
  printf '%s\n' "$generic_wait_status" > "$GENERIC_DIR/worker-exit-status.txt"
  printf 'reaped\n' > "$GENERIC_DIR/worker-reaped"
  GENERIC_WORKER_REAPED=1
  GENERIC_WORKER_PID=
}

stop_case_worker() {
  case_paths "$1"
  [ -n "$CASE_WORKER_PID" ] && is_numeric_pid "$CASE_WORKER_PID" || return 0
  if [ "$CASE_WORKER_REAPED" -ne 0 ]; then return 0; fi
  if [ -f "$CASE_ROOT/worker-reaping" ] || [ -f "$WORKER_DONE_FILE" ]; then
    # A done worker remains alive until release; this path never signals it.
    release_and_reap_case_worker "$CASE_NAME" || return 1
    return 0
  fi
  now=$(date +%s)
  if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
    echo "process_tree_cleanup: absolute deadline reached before $CASE_NAME worker cleanup" >&2
    return 1
  fi
  marker_is_owned "$WORKER_PID_FILE" && marker_is_owned "$CASE_WORKER_READY_FILE" &&
    process_is_owned "$CASE_WORKER_PID" || {
      echo "process_tree_cleanup: $CASE_NAME worker lacks a live owned release handshake" >&2
      return 1
    }
  # The active wrapper has installed the production cancellation handler
  # before starting its child. Signal only this verified direct child; its
  # handler owns process-group cleanup. The EXIT hold makes a concurrent
  # transition into worker-done safe until the controller releases and waits.
  if [ -f "$WORKER_DONE_FILE" ] || [ -f "$CASE_ROOT/worker-reaping" ]; then
    release_and_reap_case_worker "$CASE_NAME" || return 1
    return 0
  fi
  if ! signal_direct_worker "$CASE_WORKER_PID" "$WORKER_PID_FILE" \
      "$CASE_WORKER_READY_FILE" "$WORKER_DONE_FILE" "$CASE_ROOT/worker-reaping"; then
    if [ -f "$WORKER_DONE_FILE" ]; then
      release_and_reap_case_worker "$CASE_NAME" || return 1
      return 0
    fi
    echo "process_tree_cleanup: $CASE_NAME active worker signal was refused by its ownership handshake" >&2
    return 1
  fi
  if wait_for_handshake_done "$WORKER_DONE_FILE"; then
    release_and_reap_case_worker "$CASE_NAME"
    return $?
  fi
  if [ -f "$WORKER_DONE_FILE" ] && marker_is_owned "$WORKER_DONE_FILE"; then
    release_and_reap_case_worker "$CASE_NAME"
    return $?
  fi
  echo "process_tree_cleanup: $CASE_NAME worker failed to finish its EXIT handshake; leaving its private scratch intact" >&2
  return 1
}

stop_generic_worker() {
  [ -n "$GENERIC_WORKER_PID" ] && is_numeric_pid "$GENERIC_WORKER_PID" || return 0
  if [ -f "$GENERIC_DIR/worker-reaped" ]; then GENERIC_WORKER_REAPED=1; fi
  if [ "$GENERIC_WORKER_REAPED" -ne 0 ]; then return 0; fi
  if [ -f "$GENERIC_DIR/worker-reaping" ] || [ -f "$GENERIC_WORKER_DONE" ]; then
    release_and_reap_generic_worker || return 1
    return 0
  fi
  if ! marker_is_owned "$GENERIC_WORKER_HANDLER_READY"; then
    # Never TERM a generic worker before its PGID is recorded and its
    # production cancellation handler is active. The worker consumes this
    # request immediately after it assigns the launched PGID.
    : > "$GENERIC_CANCEL_REQUEST"
    while [ ! -f "$GENERIC_WORKER_HANDLER_READY" ] && [ ! -f "$GENERIC_WORKER_DONE" ]; do
      now=$(date +%s)
      if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
        echo 'process_tree_cleanup: generic worker did not reach its group-handler handshake before the absolute deadline' >&2
        return 1
      fi
      /bin/sleep 0.05
    done
    if [ -f "$GENERIC_WORKER_DONE" ]; then
      release_and_reap_generic_worker || return 1
      return 0
    fi
  fi
  now=$(date +%s)
  if [ "$now" -ge "$ACTIVE_DEADLINE" ]; then
    echo 'process_tree_cleanup: absolute deadline reached before generic worker cleanup' >&2
    return 1
  fi
  handler_pgid=$(sed -n 's/^pgid=//p' "$GENERIC_WORKER_HANDLER_READY")
  handler_active=$(sed -n 's/^handler=//p' "$GENERIC_WORKER_HANDLER_READY")
  generic_root_marker=$(sed -n '1p' "$GENERIC_ROOT_PID_FILE")
  marker_is_owned "$GENERIC_WORKER_PID_FILE" && marker_is_owned "$GENERIC_WORKER_TRAP_READY" &&
    marker_is_owned "$GENERIC_WORKER_HANDLER_READY" && marker_is_owned "$GENERIC_ROOT_PID_FILE" &&
    is_numeric_pid "$generic_root_marker" && [ "$handler_pgid" = "$generic_root_marker" ] &&
    [ "$handler_active" = active ] &&
    process_is_owned "$GENERIC_WORKER_PID" || {
      echo 'process_tree_cleanup: generic worker lacks a live owned release handshake' >&2
      return 1
    }
  # The generic worker has its production TERM handler installed before its
  # readiness marker. It owns cancellation of its launched process group.
  if [ -f "$GENERIC_WORKER_DONE" ] || [ -f "$GENERIC_DIR/worker-reaping" ]; then
    release_and_reap_generic_worker || return 1
    return 0
  fi
  if ! signal_direct_worker "$GENERIC_WORKER_PID" "$GENERIC_WORKER_PID_FILE" \
      "$GENERIC_WORKER_HANDLER_READY" "$GENERIC_WORKER_DONE" "$GENERIC_DIR/worker-reaping"; then
    if [ -f "$GENERIC_WORKER_DONE" ]; then
      release_and_reap_generic_worker || return 1
      return 0
    fi
    echo 'process_tree_cleanup: generic active worker signal was refused by its ownership handshake' >&2
    return 1
  fi
  if wait_for_handshake_done "$GENERIC_WORKER_DONE"; then
    release_and_reap_generic_worker
    return $?
  fi
  if [ -f "$GENERIC_WORKER_DONE" ] && marker_is_owned "$GENERIC_WORKER_DONE"; then
    release_and_reap_generic_worker
    return $?
  fi
  echo 'process_tree_cleanup: generic worker failed to finish its EXIT handshake; leaving its private scratch intact' >&2
  return 1
}

restore_fixture_modes() {
  restore_status=0
  if [ -n "$ROOT_MODE" ] && [ -d "$ROOT_DIR" ]; then chmod "$ROOT_MODE" "$ROOT_DIR" 2>/dev/null || restore_status=1; fi
  if [ -n "$BUILD_MODE" ] && [ -d "$BUILD_DIR" ]; then chmod "$BUILD_MODE" "$BUILD_DIR" 2>/dev/null || restore_status=1; fi
  return "$restore_status"
}

print_case_diagnostics() {
  case_paths "$1"
  echo "process_tree_cleanup: failed case=$CASE_NAME worker log:" >&2
  [ ! -f "$CASE_LOG" ] || cat "$CASE_LOG" >&2
  echo "process_tree_cleanup: failed case=$CASE_NAME child log:" >&2
  [ ! -f "$WORKER_SCRATCH/macos-host.log" ] || cat "$WORKER_SCRATCH/macos-host.log" >&2
  echo "process_tree_cleanup: failed case=$CASE_NAME process facts:" >&2
  [ ! -f "$WORKER_SCRATCH/macos-host.process-facts.txt" ] || cat "$WORKER_SCRATCH/macos-host.process-facts.txt" >&2
  [ ! -f "$CASE_ROOT/isolation-protected-paths.txt" ] || cat "$CASE_ROOT/isolation-protected-paths.txt" >&2
  [ ! -f "$RESTORE_RESULT_FILE" ] || cat "$RESTORE_RESULT_FILE" >&2
}

print_case_final_cleanup() {
  case_paths "$1"
  echo "process_tree_cleanup: final cleanup facts case=$CASE_NAME" >&2
  for cleanup_fact in cleanup-result.txt original-modes.txt identity.txt \
      wrapper-restoration.txt wrapper-status.txt worker-exit-status.txt cleanup-started.txt \
      worker-pid worker-trap-ready worker-done worker-reaping worker-release \
      leader-pid descendant-pid descendant-group descendant-lease-ready \
      descendant-lease-release descendant-lease-challenge descendant-lease-response \
      final-group-cleanup-attempted final-cleanup-result.txt \
      isolation-protected-paths.txt; do
    if [ -f "$CASE_ROOT/$cleanup_fact" ]; then
      printf '%s:\n' "$cleanup_fact" >&2
      cat "$CASE_ROOT/$cleanup_fact" >&2
      if [ "$cleanup_fact" = worker-pid ] || [ "$cleanup_fact" = leader-pid ] ||
          [ "$cleanup_fact" = descendant-pid ] || [ "$cleanup_fact" = descendant-group ]; then
        printf 'owner_uid=%s\n' "$(stat -f %u "$CASE_ROOT/$cleanup_fact" 2>/dev/null || printf unavailable)" >&2
      fi
    fi
  done
}

write_generic_cleanup_result() {
  generic_group_state=not-recorded
  generic_descendant_state=not-recorded
  generic_group_value=$(sed -n '1p' "$GENERIC_DESCENDANT_GROUP_FILE" 2>/dev/null || true)
  generic_descendant_value=$(sed -n '1p' "$GENERIC_DESCENDANT_PID_FILE" 2>/dev/null || true)
  if is_numeric_pid "$generic_group_value"; then
    if group_exists "$generic_group_value"; then generic_group_state=present; else generic_group_state=absent; fi
  fi
  if is_numeric_pid "$generic_descendant_value"; then
    if kill -0 "$generic_descendant_value" 2>/dev/null; then generic_descendant_state=present; else generic_descendant_state=absent; fi
  fi
  {
    printf 'worker_pid=%s\nworker_trap_ready=%s\nworker_done=%s\nworker_reaping=%s\nworker_reaped=%s\n' \
      "$(sed -n '1p' "$GENERIC_WORKER_PID_FILE" 2>/dev/null || true)" \
      "$( [ -f "$GENERIC_WORKER_TRAP_READY" ] && printf yes || printf no )" \
      "$( [ -f "$GENERIC_WORKER_DONE" ] && printf yes || printf no )" \
      "$( [ -f "$GENERIC_DIR/worker-reaping" ] && printf yes || printf no )" \
      "$( [ -f "$GENERIC_DIR/worker-reaped" ] && printf yes || printf no )"
    printf 'worker_handler_ready=%s\ncancel_request=%s\n' \
      "$( [ -f "$GENERIC_WORKER_HANDLER_READY" ] && printf yes || printf no )" \
      "$( [ -f "$GENERIC_CANCEL_REQUEST" ] && printf yes || printf no )"
    printf 'leader_pid=%s\nleader_ready=%s\n' \
      "$(sed -n '1p' "$GENERIC_ROOT_PID_FILE" 2>/dev/null || true)" \
      "$( [ -f "$GENERIC_LEADER_READY" ] && printf yes || printf no )"
      printf 'descendant_pid=%s\ndescendant_group=%s\ndescendant_ready=%s\n' \
      "$generic_descendant_value" "$generic_group_value" \
      "$( [ -f "$GENERIC_DESCENDANT_READY" ] && printf yes || printf no )"
      printf 'descendant_lease_ready=%s\ndescendant_lease_release=%s\n' \
        "$( [ -f "$GENERIC_DESCENDANT_LEASE_READY" ] && printf yes || printf no )" \
        "$( [ -f "$GENERIC_DESCENDANT_LEASE_RELEASE" ] && printf yes || printf no )"
      printf 'descendant_lease_challenge=%s\ndescendant_lease_response=%s\n' \
        "$( [ -f "$GENERIC_DESCENDANT_LEASE_CHALLENGE" ] && printf yes || printf no )" \
        "$( [ -f "$GENERIC_DESCENDANT_LEASE_RESPONSE" ] && printf yes || printf no )"
    printf 'group_state=%s\ndescendant_state=%s\n' "$generic_group_state" "$generic_descendant_state"
    printf 'worker_pid_owner_uid=%s\nleader_pid_owner_uid=%s\ndescendant_pid_owner_uid=%s\ngroup_owner_uid=%s\n' \
      "$(stat -f %u "$GENERIC_WORKER_PID_FILE" 2>/dev/null || printf unavailable)" \
      "$(stat -f %u "$GENERIC_ROOT_PID_FILE" 2>/dev/null || printf unavailable)" \
      "$(stat -f %u "$GENERIC_DESCENDANT_PID_FILE" 2>/dev/null || printf unavailable)" \
      "$(stat -f %u "$GENERIC_DESCENDANT_GROUP_FILE" 2>/dev/null || printf unavailable)"
  } > "$GENERIC_DIR/cleanup-result.txt"
}

final_group_guard() {
  guard_label=$1
  guard_root=$2
  guard_leader_marker=$3
  guard_descendant_marker=$4
  guard_group_marker=$5
  guard_lease_ready=$6
  guard_lease_release=$7
  guard_lease_challenge=$8
  guard_lease_response=$9
  guard_attempt_marker="$guard_root/final-group-cleanup-attempted"
  guard_result="$guard_root/final-cleanup-result.txt"
  guard_leader_pid=
  guard_pgid=
  guard_descendant_pid=
  guard_group_state=not-recorded
  guard_descendant_state=not-recorded
  guard_lease_state=not-revalidated
  guard_attempt=none
  guard_owner=unverified

  if path_is_owned_under_scratch "$guard_root" &&
      marker_is_owned "$guard_leader_marker"; then
    guard_leader_pid=$(sed -n '1p' "$guard_leader_marker")
    if is_numeric_pid "$guard_leader_pid"; then
      if [ -f "$guard_group_marker" ] && marker_is_owned "$guard_group_marker"; then
        guard_pgid=$(sed -n '1p' "$guard_group_marker")
      else
        guard_pgid=$guard_leader_pid
      fi
      if is_numeric_pid "$guard_pgid" && [ "$guard_pgid" = "$guard_leader_pid" ]; then
        guard_owner=recorded
      fi
    fi
  fi
  if [ -n "$guard_descendant_marker" ] && [ -f "$guard_descendant_marker" ] &&
      marker_is_owned "$guard_descendant_marker"; then
    guard_descendant_pid=$(sed -n '1p' "$guard_descendant_marker")
  fi
  if [ -e "$guard_attempt_marker" ]; then
    attempted_pgid=$(sed -n 's/^pgid=//p' "$guard_attempt_marker" 2>/dev/null || true)
    if marker_is_owned "$guard_attempt_marker" &&
        is_numeric_pid "$guard_pgid" && [ "$attempted_pgid" = "$guard_pgid" ]; then
      guard_attempt=previously-sent
    else
      guard_owner=invalid-final-cleanup-record
    fi
  fi

  guard_refresh_state() {
    if is_numeric_pid "$guard_pgid" && group_exists "$guard_pgid"; then
      guard_group_state=present
    elif is_numeric_pid "$guard_pgid"; then
      guard_group_state=absent
    else
      guard_group_state=not-recorded
    fi
    if [ -z "$guard_descendant_pid" ]; then
      guard_descendant_state=none
    elif ! is_numeric_pid "$guard_descendant_pid"; then
      guard_descendant_state=ambiguous
    elif kill -0 "$guard_descendant_pid" 2>/dev/null; then
      guard_descendant_state=present
    else
      guard_descendant_state=absent
    fi
  }
  guard_refresh_state

  guard_needs_cleanup=0
  if [ "$guard_group_state" = present ] || [ "$guard_descendant_state" = present ] ||
      [ "$guard_descendant_state" = ambiguous ]; then
    guard_needs_cleanup=1
    cleanup_status=1
    if is_numeric_pid "$guard_pgid" && [ "$guard_owner" = recorded ] &&
        [ -n "$guard_descendant_marker" ] && [ -n "$guard_group_marker" ] &&
        lease_is_active_owned "$guard_lease_ready" "$guard_lease_release" \
          "$guard_descendant_marker" "$guard_group_marker" "$guard_pgid" \
          "$guard_lease_challenge" "$guard_lease_response" final; then
      guard_lease_state=held-active-owned
      if [ ! -e "$guard_attempt_marker" ]; then
        printf 'pgid=%s\nreason=final-survivor-check\n' "$guard_pgid" > "$guard_attempt_marker"
        guard_attempt=sent
        if marker_is_owned "$guard_attempt_marker" &&
            path_is_owned_under_scratch "$guard_root" &&
            lease_is_active_owned "$guard_lease_ready" "$guard_lease_release" \
              "$guard_descendant_marker" "$guard_group_marker" "$guard_pgid" \
              "$guard_lease_challenge" "$guard_lease_response" final; then
          if signal_owned_group KILL "$guard_pgid"; then
            while :; do
              guard_refresh_state
              if [ "$guard_group_state" != present ] &&
                  [ "$guard_descendant_state" = absent ]; then
                break
              fi
              check_absolute_deadline || break
              /bin/sleep 0.05
            done
          else
            guard_attempt=refused-after-revalidation
          fi
        else
          guard_attempt=ownership-lost-before-signal
        fi
      else
        guard_attempt=already-attempted
      fi
    else
      guard_lease_state=ownership-not-reestablished
      guard_attempt=refused-ambiguous-or-unleased
    fi
    guard_refresh_state
  fi
  if [ "$guard_attempt" = previously-sent ] ||
      [ "$guard_attempt" = already-attempted ] ||
      [ "$guard_attempt" = sent ] ||
      [ "$guard_attempt" = refused-after-revalidation ] ||
      [ "$guard_attempt" = ownership-lost-before-signal ]; then
    guard_needs_cleanup=1
    cleanup_status=1
  fi

  {
    printf 'format=libfuturo-final-group-cleanup-v1\nlabel=%s\n' "$guard_label"
    printf 'leader_pid=%s\npgid=%s\ngroup_state=%s\n' \
      "$guard_leader_pid" "$guard_pgid" "$guard_group_state"
    printf 'descendant_pid=%s\ndescendant_state=%s\n' \
      "$guard_descendant_pid" "$guard_descendant_state"
    printf 'lease_state=%s\nfinal_attempt=%s\n' "$guard_lease_state" "$guard_attempt"
    printf 'survivor_seen_before_guard=%s\n' "$guard_needs_cleanup"
  } > "$guard_result"

  if [ "$guard_group_state" = present ] ||
      [ "$guard_descendant_state" = present ] ||
      [ "$guard_descendant_state" = ambiguous ] ||
      [ "$guard_group_state" = not-recorded ] ||
      [ "$guard_owner" = unverified ] ||
      [ "$guard_owner" = invalid-final-cleanup-record ]; then
    scratch_safe_to_remove=0
    cleanup_status=1
    return 1
  fi
  [ "$guard_needs_cleanup" -eq 0 ]
}

copy_final_case_evidence() {
  [ -n "$EVIDENCE_RUN" ] || return 0
  case_paths "$1"
  evidence_case="$EVIDENCE_RUN/$CASE_NAME"
  ensure_owned_evidence_directory "$evidence_case" || return 1
  for evidence_file in descendant-lease-challenge descendant-lease-response \
      final-group-cleanup-attempted final-cleanup-result.txt; do
    if [ -f "$CASE_ROOT/$evidence_file" ]; then
      check_absolute_deadline || return 1
      /bin/cp "$CASE_ROOT/$evidence_file" "$evidence_case/$evidence_file" || return 1
    fi
  done
  check_absolute_deadline
}

cleanup_probe() {
  cleanup_status=$?
  CLEANUP_ACTIVE=1
  ACTIVE_DEADLINE=$CLEANUP_DEADLINE
  scratch_safe_to_remove=1
  scratch_removed=0
  evidence_incomplete=0
  trap - EXIT HUP INT TERM
  for cleanup_name in normal timeout term; do
    check_absolute_deadline || cleanup_status=1
    cleanup_root="$SCRATCH_REAL/$cleanup_name"
    if [ -d "$cleanup_root" ]; then
      case_stop_status=0
      stop_case_worker "$cleanup_name" || { cleanup_status=1; case_stop_status=1; scratch_safe_to_remove=0; }
      case_paths "$cleanup_name"
      if [ "$cleanup_status" -ne 0 ]; then print_case_diagnostics "$cleanup_name"; fi
      restore_fixture_modes || cleanup_status=1
      write_case_cleanup_result || cleanup_status=1
      if [ "$cleanup_status" -ne 0 ] || [ "$COMPLETION_DEADLINE_EXCEEDED" -ne 0 ] ||
          [ "$ABSOLUTE_DEADLINE_EXCEEDED" -ne 0 ]; then
        print_case_final_cleanup "$cleanup_name"
      fi
      if [ "$case_stop_status" -eq 0 ]; then
        preserve_case_evidence "$cleanup_name" || { cleanup_status=1; evidence_incomplete=1; }
        check_absolute_deadline || cleanup_status=1
      fi
    fi
  done
  if [ -d "$GENERIC_DIR" ]; then
    check_absolute_deadline || cleanup_status=1
    generic_stop_status=0
    stop_generic_worker || { cleanup_status=1; generic_stop_status=1; scratch_safe_to_remove=0; }
    write_generic_cleanup_result || cleanup_status=1
    if [ "$cleanup_status" -ne 0 ]; then
      echo 'process_tree_cleanup: failed generic worker log:' >&2
      [ ! -f "$GENERIC_WORKER_LOG" ] || cat "$GENERIC_WORKER_LOG" >&2
      [ ! -f "$GENERIC_RESULT" ] || cat "$GENERIC_RESULT" >&2
      [ ! -f "$GENERIC_DIR/cleanup-result.txt" ] || cat "$GENERIC_DIR/cleanup-result.txt" >&2
    fi
    if [ "$generic_stop_status" -eq 0 ] && [ -n "$EVIDENCE_RUN" ]; then
      evidence_generic="$EVIDENCE_RUN/generic"
      if ensure_owned_evidence_directory "$evidence_generic"; then
        for generic_file in worker.log worker-pid worker-trap-ready worker-handler-ready \
            cleanup-started cancel-request worker-ready worker-done \
            worker-reaping worker-release worker-reaped worker-exit-status.txt \
            result.txt cleanup-result.txt leader-pid leader-ready \
            descendant-pid descendant-group descendant-ready \
            descendant-lease-ready descendant-lease-release \
            descendant-lease-challenge descendant-lease-response \
            final-group-cleanup-attempted \
            final-cleanup-result.txt; do
          if [ -f "$GENERIC_DIR/$generic_file" ]; then
            if ! check_absolute_deadline; then
              cleanup_status=1
              evidence_incomplete=1
              continue
            fi
            /bin/cp "$GENERIC_DIR/$generic_file" "$evidence_generic/$generic_file" || {
              cleanup_status=1
              evidence_incomplete=1
            }
            check_absolute_deadline || { cleanup_status=1; evidence_incomplete=1; }
          fi
        done
      else
        cleanup_status=1
        evidence_incomplete=1
      fi
    fi
  fi
  for final_case in normal timeout term; do
    final_root="$SCRATCH_REAL/$final_case"
    [ -d "$final_root" ] || continue
    case_paths "$final_case"
    if [ "$final_case" = normal ]; then
      final_group_marker="$LEADER_PID_FILE"
      final_descendant_marker=
      final_lease_ready=
      final_lease_release=
      final_lease_challenge=
      final_lease_response=
    else
      final_group_marker="$DESCENDANT_GROUP_FILE"
      final_descendant_marker="$DESCENDANT_PID_FILE"
      final_lease_ready="$DESCENDANT_LEASE_READY"
      final_lease_release="$DESCENDANT_LEASE_RELEASE"
      final_lease_challenge="$DESCENDANT_LEASE_CHALLENGE"
      final_lease_response="$DESCENDANT_LEASE_RESPONSE"
    fi
    final_group_guard "$final_case" "$CASE_ROOT" "$LEADER_PID_FILE" \
      "$final_descendant_marker" "$final_group_marker" \
      "$final_lease_ready" "$final_lease_release" "$final_lease_challenge" \
      "$final_lease_response" || cleanup_status=1
    if [ "$cleanup_status" -ne 0 ]; then
      print_case_diagnostics "$final_case"
      print_case_final_cleanup "$final_case"
    fi
    copy_final_case_evidence "$final_case" || {
      cleanup_status=1
      evidence_incomplete=1
    }
  done
  if [ -d "$GENERIC_DIR" ]; then
    final_group_guard generic "$GENERIC_DIR" "$GENERIC_ROOT_PID_FILE" \
      "$GENERIC_DESCENDANT_PID_FILE" "$GENERIC_DESCENDANT_GROUP_FILE" \
      "$GENERIC_DESCENDANT_LEASE_READY" "$GENERIC_DESCENDANT_LEASE_RELEASE" \
      "$GENERIC_DESCENDANT_LEASE_CHALLENGE" "$GENERIC_DESCENDANT_LEASE_RESPONSE" || cleanup_status=1
    if [ "$cleanup_status" -ne 0 ]; then
      echo 'process_tree_cleanup: final generic cleanup facts:' >&2
      cat "$GENERIC_DIR/cleanup-result.txt" "$GENERIC_DIR/final-cleanup-result.txt" >&2 2>/dev/null || true
      [ ! -f "$GENERIC_WORKER_LOG" ] || cat "$GENERIC_WORKER_LOG" >&2
    fi
    if [ -n "$EVIDENCE_RUN" ]; then
      evidence_generic="$EVIDENCE_RUN/generic"
      if ensure_owned_evidence_directory "$evidence_generic"; then
        for final_generic_file in descendant-lease-challenge descendant-lease-response \
            final-group-cleanup-attempted final-cleanup-result.txt; do
          if [ -f "$GENERIC_DIR/$final_generic_file" ]; then
            check_absolute_deadline || { cleanup_status=1; evidence_incomplete=1; }
            /bin/cp "$GENERIC_DIR/$final_generic_file" "$evidence_generic/$final_generic_file" || {
              cleanup_status=1
              evidence_incomplete=1
            }
          fi
        done
      else
        cleanup_status=1
        evidence_incomplete=1
      fi
    fi
  fi
  if [ -n "$EVIDENCE_RUN" ] && [ -f "$SCRATCH_REAL/pid-parser-matrix.txt" ] &&
      [ "$scratch_safe_to_remove" -eq 1 ]; then
    if check_absolute_deadline && ensure_owned_evidence_root; then
      /bin/cp "$SCRATCH_REAL/pid-parser-matrix.txt" "$EVIDENCE_RUN/pid-parser-matrix.txt" || {
        cleanup_status=1
        evidence_incomplete=1
      }
      check_absolute_deadline || { cleanup_status=1; evidence_incomplete=1; }
    else
      cleanup_status=1
      evidence_incomplete=1
    fi
  fi
  # Recheck every recorded process group and descendant immediately before the
  # outer scratch removal. A cleanup attempt is never repeated.
  for final_case in normal timeout term; do
    final_root="$SCRATCH_REAL/$final_case"
    [ -d "$final_root" ] || continue
    case_paths "$final_case"
    if [ "$final_case" = normal ]; then
      final_group_marker="$LEADER_PID_FILE"
      final_descendant_marker=
      final_lease_ready=
      final_lease_release=
      final_lease_challenge=
      final_lease_response=
    else
      final_group_marker="$DESCENDANT_GROUP_FILE"
      final_descendant_marker="$DESCENDANT_PID_FILE"
      final_lease_ready="$DESCENDANT_LEASE_READY"
      final_lease_release="$DESCENDANT_LEASE_RELEASE"
      final_lease_challenge="$DESCENDANT_LEASE_CHALLENGE"
      final_lease_response="$DESCENDANT_LEASE_RESPONSE"
    fi
    final_group_guard "$final_case" "$CASE_ROOT" "$LEADER_PID_FILE" \
      "$final_descendant_marker" "$final_group_marker" \
      "$final_lease_ready" "$final_lease_release" "$final_lease_challenge" \
      "$final_lease_response" || {
        cleanup_status=1
        print_case_diagnostics "$final_case"
        print_case_final_cleanup "$final_case"
      }
    copy_final_case_evidence "$final_case" || {
      cleanup_status=1
      evidence_incomplete=1
    }
  done
  if [ -d "$GENERIC_DIR" ]; then
    final_group_guard generic "$GENERIC_DIR" "$GENERIC_ROOT_PID_FILE" \
      "$GENERIC_DESCENDANT_PID_FILE" "$GENERIC_DESCENDANT_GROUP_FILE" \
      "$GENERIC_DESCENDANT_LEASE_READY" "$GENERIC_DESCENDANT_LEASE_RELEASE" \
      "$GENERIC_DESCENDANT_LEASE_CHALLENGE" "$GENERIC_DESCENDANT_LEASE_RESPONSE" || {
        cleanup_status=1
        echo 'process_tree_cleanup: final generic cleanup facts before scratch decision:' >&2
        cat "$GENERIC_DIR/cleanup-result.txt" "$GENERIC_DIR/final-cleanup-result.txt" >&2 2>/dev/null || true
        [ ! -f "$GENERIC_WORKER_LOG" ] || cat "$GENERIC_WORKER_LOG" >&2
      }
    if [ -n "$EVIDENCE_RUN" ] && ensure_owned_evidence_directory "$EVIDENCE_RUN/generic"; then
      for final_generic_file in descendant-lease-challenge descendant-lease-response \
          final-group-cleanup-attempted final-cleanup-result.txt; do
        if [ -f "$GENERIC_DIR/$final_generic_file" ]; then
          check_absolute_deadline || { cleanup_status=1; evidence_incomplete=1; }
          /bin/cp "$GENERIC_DIR/$final_generic_file" \
            "$EVIDENCE_RUN/generic/$final_generic_file" || {
              cleanup_status=1
              evidence_incomplete=1
            }
        fi
      done
    elif [ -n "$EVIDENCE_RUN" ]; then
      cleanup_status=1
      evidence_incomplete=1
    fi
  fi
  check_absolute_deadline || cleanup_status=1
  if [ "$scratch_safe_to_remove" -eq 0 ] || [ "$evidence_incomplete" -ne 0 ] ||
      [ "$ABSOLUTE_DEADLINE_EXCEEDED" -ne 0 ]; then
    cleanup_status=1
    echo "process_tree_cleanup: retaining task-owned scratch for unresolved worker/evidence state: $SCRATCH_REAL" >&2
  elif path_is_owned_under_scratch "$SCRATCH_REAL"; then
    if /bin/rm -rf "$SCRATCH_REAL"; then
      scratch_removed=1
    else
      cleanup_status=1
    fi
  else
    cleanup_status=1
    echo 'process_tree_cleanup: refused to remove scratch after ownership/containment check failed' >&2
  fi
  if [ "$cleanup_status" -eq 0 ] && [ "$scratch_removed" -eq 1 ]; then
    echo 'process_tree_cleanup: late TERM-resistant descendant stopped after leader exit; result=pass'
    echo 'process_tree_cleanup: live relocated wrapper exit, timeout, and TERM cases passed; scope=local-Darwin-arm64 result=pass'
  fi
  exit "$cleanup_status"
}
trap cleanup_probe EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Build every private fixture before starting the bounded worker set.
run_pid_parser_matrix
prepare_case timeout

# Arm timeout first: its child publishes readiness before the two-second
# bounded timeout. Setup and arming end by T+12; successful in-test teardown
# and evidence finish by T+23. On early failure, the EXIT handler has until
# T+31 to clean up only workers whose ownership handshakes still verify.
start_case_worker timeout
arm_case_worker timeout

prepare_case normal
prepare_case term
write_generic_scripts
check_setup_deadline || exit 1

# Start the remaining owned workers concurrently under the shared deadline.
start_generic_worker
start_case_worker normal
start_case_worker term

arm_generic_worker
arm_case_worker normal
arm_case_worker term
wait_for_teardown_started || exit 1
wait_for_all_workers || {
  echo 'process_tree_cleanup: one or more workers missed the shared completion deadline' >&2
  exit 1
}

reap_generic_worker
for joined_case in normal timeout term; do reap_case_worker "$joined_case"; done

finish_case normal 23 none no
finish_case timeout 124 none yes
finish_case term 143 TERM no

[ -f "$GENERIC_RESULT" ] && [ "$(sed -n '1p' "$GENERIC_RESULT")" = 'result=pass' ] || {
  echo 'process_tree_cleanup: generic late-descendant cleanup did not pass' >&2
  exit 1
}
generic_result_root=$(sed -n 's/^leader_pid=//p' "$GENERIC_RESULT")
generic_result_descendant=$(sed -n 's/^descendant_pid=//p' "$GENERIC_RESULT")
generic_result_group=$(sed -n 's/^descendant_group=//p' "$GENERIC_RESULT")
is_numeric_pid "$generic_result_descendant" &&
  [ "$generic_result_root" = "$GENERIC_ROOT_PID" ] &&
  [ "$generic_result_descendant" = "$(sed -n '1p' "$GENERIC_DESCENDANT_PID_FILE")" ] &&
  [ "$generic_result_group" = "$generic_result_root" ] &&
  ! kill -0 "$generic_result_descendant" 2>/dev/null &&
  ! group_exists "$generic_result_group" || {
    echo 'process_tree_cleanup: generic descendant PID/group identity or cleanup assertion failed' >&2
    exit 1
  }
check_completion_deadline || exit 1
