#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "native host lifecycle: expected app bundle and fixture path" >&2
  exit 2
fi

APP_BUNDLE=$1
CONTENT_PATH=$2
TEMP_ROOT=${TMPDIR:-/tmp}
SCRATCH=$(/usr/bin/mktemp -d "$TEMP_ROOT/libfuturo-host-lifecycle.XXXXXX")
OPEN_PID=
WATCHDOG_PID=
WATCHDOG_SLEEP_PID=
RESULT_FILE=
stop_case_app() {
  if [ -z "$RESULT_FILE" ]; then
    return
  fi
  for CANDIDATE_PID in $(/usr/bin/pgrep -x installed_macos_host 2>/dev/null || true); do
    PROCESS_COMMAND=$(/bin/ps -p "$CANDIDATE_PID" -o command= 2>/dev/null || true)
    case "$PROCESS_COMMAND" in
      *"$RESULT_FILE"*)
        kill -TERM "$CANDIDATE_PID" 2>/dev/null || true
        ;;
    esac
  done
}
cleanup() {
  STATUS=$?
  trap - EXIT
  if [ -n "$WATCHDOG_PID" ]; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "$OPEN_PID" ]; then
    kill -TERM "$OPEN_PID" 2>/dev/null || true
    stop_case_app
    wait "$OPEN_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$SCRATCH"
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/printf 'x' > "$SCRATCH/malformed.a78"

run_case() {
  CASE_NAME=$1
  EXPECTED=$2
  shift 2
  RESULT_FILE=$SCRATCH/$CASE_NAME.result

  /usr/bin/open -W -n -a "$APP_BUNDLE" --args \
    "$@" \
    --test-result-file "$RESULT_FILE" &
  OPEN_PID=$!
  (
    trap 'if [ -n "$WATCHDOG_SLEEP_PID" ]; then kill -TERM "$WATCHDOG_SLEEP_PID" 2>/dev/null || true; fi; exit 0' TERM INT
    /bin/sleep 20 &
    WATCHDOG_SLEEP_PID=$!
    wait "$WATCHDOG_SLEEP_PID"
    stop_case_app
    kill -TERM "$OPEN_PID" 2>/dev/null || true
  ) &
  WATCHDOG_PID=$!

  if wait "$OPEN_PID"; then
    OPEN_STATUS=0
  else
    OPEN_STATUS=$?
  fi
  OPEN_PID=
  kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=
  if [ "$OPEN_STATUS" -ne 0 ]; then
    echo "native host lifecycle: $CASE_NAME LaunchServices status=$OPEN_STATUS" >&2
    return 1
  fi
  if [ ! -f "$RESULT_FILE" ] || ! /usr/bin/grep -Fqx "$EXPECTED" "$RESULT_FILE"; then
    echo "native host lifecycle: $CASE_NAME did not produce its exact result" >&2
    [ ! -f "$RESULT_FILE" ] || /bin/cat "$RESULT_FILE" >&2
    [ ! -f "$RESULT_FILE.progress" ] || /bin/cat "$RESULT_FILE.progress" >&2
    return 1
  fi
  /bin/cat "$RESULT_FILE"
}

run_case advance-close \
  'installed_macos_host: lifecycle=close phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass' \
  --content "$CONTENT_PATH" --test-drain-close
run_case advance-quit \
  'installed_macos_host: lifecycle=quit phase=advance owner-drained=pass main-sentinel=pass destroy=once result=pass' \
  --content "$CONTENT_PATH" --test-drain-quit
run_case load-error-close \
  'installed_macos_host: lifecycle=close phase=load-error owner-drained=pass main-sentinel=pass error-suppressed=pass destroy=once result=pass' \
  --content "$SCRATCH/malformed.a78" --test-drain-close-error

echo 'native_lifecycle: cases=advance-close,advance-quit,load-error-close result=pass'
