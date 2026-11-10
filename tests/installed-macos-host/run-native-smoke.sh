#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "native host smoke: expected app bundle, fixture path, and supervisor path" >&2
  exit 2
fi

APP_BUNDLE=$1
CONTENT_PATH=$2
SUPERVISOR=$3
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIR/native-smoke-cleanup.sh"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "native host smoke: app bundle is missing: $APP_BUNDLE" >&2
  exit 2
fi
if [ ! -x "$SUPERVISOR" ]; then
  echo "native host smoke: supervisor is missing or not executable: $SUPERVISOR" >&2
  exit 2
fi
TEMP_ROOT=${TMPDIR:-/tmp}
SCRATCH=$(/usr/bin/mktemp -d "$TEMP_ROOT/libfuturo-host-smoke.XXXXXX")
RESULT_FILE=$SCRATCH/result.txt
PROGRESS_FILE=$RESULT_FILE.progress
SUPERVISOR_CONTROL=$SCRATCH/supervisor-control
SUPERVISOR_STATUS=$SCRATCH/supervisor-status
# Keep a harness marker so early app exits are distinguishable from a
# supervisor-only launch failure in hosted runner logs.
printf 'native-smoke: app-launch-requested\n' > "$PROGRESS_FILE"
SUPERVISOR_PID=
SUPERVISOR_SEQUENCE=0
test_app_is_running() {
  native_smoke_supervisor_app_is_running "$SUPERVISOR_STATUS"
}
request_test_app_termination() {
  case "$1" in
    TERMINATE) SUPERVISOR_ACTION=TERMINATE ;;
    FORCE_TERMINATE) SUPERVISOR_ACTION=FORCE_TERMINATE ;;
    *) echo 'native host smoke: invalid supervisor termination request' >&2; return 2 ;;
  esac
  if test_app_is_running; then
    :
  else
    TEST_APP_STATUS=$?
    [ "$TEST_APP_STATUS" -eq 1 ] && return 0
    return 2
  fi

  SUPERVISOR_SEQUENCE=$((SUPERVISOR_SEQUENCE + 1))
  if ! printf '%s %s\n' "$SUPERVISOR_ACTION" "$SUPERVISOR_SEQUENCE" >&3; then
    echo 'native host smoke: could not send a termination request to the supervisor' >&2
    return 2
  fi

  SIGNAL_ATTEMPT=0
  while [ "$SIGNAL_ATTEMPT" -lt 20 ]; do
    if native_smoke_read_supervisor_state "$SUPERVISOR_STATUS" && \
        [ "$smoke_supervisor_ack" -ge "$SUPERVISOR_SEQUENCE" ]; then
      case "$smoke_supervisor_state" in
        starting|running|terminated) ;;
        *) return 2 ;;
      esac
      return 0
    fi
    /bin/sleep 0.1
    SIGNAL_ATTEMPT=$((SIGNAL_ATTEMPT + 1))
  done
  echo 'native host smoke: supervisor did not acknowledge its termination request' >&2
  return 2
}
cleanup_sleep() {
  /bin/sleep "$1"
}
preserve_smoke_scratch() {
  if native_smoke_read_supervisor_state "$SUPERVISOR_STATUS"; then
    case "$smoke_supervisor_state" in
      starting|running)
        echo "native host smoke: preserving diagnostic scratch $1; app state=$smoke_supervisor_state" >&2
        ;;
      terminated)
        echo "native host smoke: preserving diagnostic scratch $1; exact app termination was reported" >&2
        ;;
      unknown)
        echo "native host smoke: preserving diagnostic scratch $1; app state is unknown" >&2
        ;;
    esac
  else
    echo "native host smoke: preserving diagnostic scratch $1; supervisor state could not be read" >&2
  fi
}
remove_smoke_scratch() {
  exec 3>&-
  /bin/rm -rf "$1"
}
reap_supervisor() {
  if wait "$1" 2>/dev/null; then
    return 0
  else
    REAP_STATUS=$?
    echo "native host smoke: supervisor exited with status $REAP_STATUS after app termination" >&2
    return 2
  fi
}
stop_supervised_app() {
  if [ -z "$SUPERVISOR_PID" ]; then
    return 0
  fi

  if native_smoke_stop_supervised_app \
      "$SUPERVISOR_PID" request_test_app_termination test_app_is_running \
      cleanup_sleep 50 50 reap_supervisor; then
    SUPERVISOR_PID=
    return 0
  else
    return $?
  fi
}
cleanup() {
  STATUS=$?
  trap - EXIT
  if [ "$STATUS" -ne 0 ]; then
    if native_smoke_cleanup_failed_run \
        stop_supervised_app preserve_smoke_scratch "$SCRATCH"; then
      :
    else
      CLEANUP_STATUS=$?
      if [ "$CLEANUP_STATUS" -eq 2 ]; then
        echo 'native host smoke: cleanup ended with unknown process state' >&2
      fi
    fi
  else
    if native_smoke_cleanup_successful_run \
        stop_supervised_app preserve_smoke_scratch remove_smoke_scratch "$SCRATCH"; then
      :
    else
      CLEANUP_STATUS=$?
      exit "$CLEANUP_STATUS"
    fi
  fi
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! /bin/sh "$SCRIPT_DIR/native-app-bundle-preflight.sh" \
    "$APP_BUNDLE" "$SCRATCH/bundle-preflight.txt"; then
  echo 'native host smoke: app bundle failed its no-launch preflight' >&2
  /bin/cat "$SCRATCH/bundle-preflight.txt" >&2
  exit 1
fi

/bin/sh "$SCRIPT_DIR/test-native-smoke-cleanup.sh"

/usr/bin/mkfifo "$SUPERVISOR_CONTROL"
exec 3<> "$SUPERVISOR_CONTROL"
"$SUPERVISOR" "$SUPERVISOR_STATUS" "$APP_BUNDLE" -- \
  --content "$CONTENT_PATH" \
  --test-production-view \
  --test-close-after-presentations 2 \
  --test-result-file "$RESULT_FILE" <&3 &
SUPERVISOR_PID=$!

EXPECTED='installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass'
PRODUCTION_VIEW_EXPECTED='installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass'
ATTEMPT=0
while [ ! -f "$RESULT_FILE" ] && [ "$ATTEMPT" -lt 200 ]; do
  if [ -f "$SUPERVISOR_STATUS" ]; then
    if native_smoke_read_supervisor_state "$SUPERVISOR_STATUS"; then
      case "$smoke_supervisor_state" in
        terminated)
          echo 'native host smoke: app terminated without producing a success result' >&2
          [ ! -f "$PROGRESS_FILE" ] || /bin/cat "$PROGRESS_FILE" >&2
          exit 1
          ;;
        unknown)
          echo 'native host smoke: LaunchServices app state became unknown' >&2
          /bin/cat "$SUPERVISOR_STATUS" >&2
          [ ! -f "$PROGRESS_FILE" ] || /bin/cat "$PROGRESS_FILE" >&2
          exit 1
          ;;
      esac
    else
      echo 'native host smoke: supervisor status is missing or malformed' >&2
      exit 1
    fi
  fi
  /bin/sleep 0.1
  ATTEMPT=$((ATTEMPT + 1))
done
if [ ! -f "$RESULT_FILE" ]; then
  echo 'native host smoke: app produced no result within 20 seconds' >&2
  if [ -f "$PROGRESS_FILE" ]; then
    /bin/cat "$PROGRESS_FILE" >&2
  fi
  exit 1
fi
if ! native_smoke_validate_app_result "$RESULT_FILE" "$EXPECTED" \
    "$PRODUCTION_VIEW_EXPECTED"; then
  exit 1
fi
# The exact instance can still be stopping after its result is written. Keep
# this wait bounded, with enough grace for the ordered audio teardown to finish.
if native_smoke_wait_for_app_termination test_app_is_running cleanup_sleep 200; then
  APP_TERMINATION_CONFIRMED=1
else
  APP_TERMINATION_STATUS=$?
  case "$APP_TERMINATION_STATUS" in
    1) echo 'native host smoke: app wrote success but did not terminate' >&2 ;;
    *) echo 'native host smoke: exact app termination could not be confirmed' >&2 ;;
  esac
  exit 1
fi
[ "$APP_TERMINATION_CONFIRMED" -eq 1 ] || {
  echo 'native host smoke: success requires confirmed exact-instance termination' >&2
  exit 1
}

SMOKE_RESULT_OUTPUT=$(/bin/cat "$RESULT_FILE")
PRODUCTION_VIEW_OUTPUT=$(/usr/bin/grep '^production-view-observation ' "$PROGRESS_FILE")
# LaunchServices exposes no child exit code. Passing requires both exact app
# result markers above and isTerminated confirmation for its returned instance.
report_smoke_success() {
  printf '%s\n' "$SMOKE_RESULT_OUTPUT" "$PRODUCTION_VIEW_OUTPUT"
  echo 'native_window_smoke: cleanup=confirmed scratch=removed result=pass'
}
if native_smoke_cleanup_successful_run \
    stop_supervised_app preserve_smoke_scratch remove_smoke_scratch \
    "$SCRATCH" report_smoke_success; then
  trap - EXIT
else
  SUCCESS_CLEANUP_STATUS=$?
  trap - EXIT
  exit "$SUCCESS_CLEANUP_STATUS"
fi
