#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "native host open retry: expected app bundle and valid fixture path" >&2
  exit 2
fi

APP_BUNDLE=$1
CONTENT_PATH=$2
TEMP_ROOT=${TMPDIR:-/tmp}
SCRATCH=$(/usr/bin/mktemp -d "$TEMP_ROOT/libfuturo-host-open-retry.XXXXXX")
UNREADABLE_PATH=$SCRATCH/unreadable.a78
EMPTY_PATH=$SCRATCH/empty.a78
DIRECTORY_PATH=$SCRATCH/directory.a78
FIFO_PATH=$SCRATCH/fifo.a78
OVERSIZED_PATH=$SCRATCH/oversized.a78
MALFORMED_PATH=$SCRATCH/malformed.a78
UNSUPPORTED_PATH=$SCRATCH/unsupported.a78
RESULT_FILE=$SCRATCH/result.txt
CLI_RESULT_FILE=$SCRATCH/cli-result.txt
SCHEDULER_RESULT_FILE=$SCRATCH/scheduler-result.txt
OPEN_PID=
current_test_pids() {
  if [ -z "$RESULT_FILE" ]; then
    return
  fi
  for CANDIDATE_PID in $(/usr/bin/pgrep -x installed_macos_host 2>/dev/null || true); do
    PROCESS_COMMAND=$(/bin/ps -p "$CANDIDATE_PID" -o command= 2>/dev/null || true)
    case "$PROCESS_COMMAND" in
      *"$RESULT_FILE"*) echo "$CANDIDATE_PID" ;;
    esac
  done
}
stop_test_app() {
  for CANDIDATE_PID in $(current_test_pids); do
    /bin/kill -TERM "$CANDIDATE_PID" 2>/dev/null || true
  done
}
stop_open_launcher() {
  if [ -n "$OPEN_PID" ]; then
    /bin/kill -TERM "$OPEN_PID" 2>/dev/null || true
    wait "$OPEN_PID" 2>/dev/null || true
    OPEN_PID=
  fi
}
cleanup() {
  STATUS=$?
  trap - EXIT
  if [ "$STATUS" -ne 0 ]; then
    stop_test_app
    stop_open_launcher
    for PROGRESS_FILE in "$SCRATCH/result.txt.progress" \
      "$SCRATCH/cli-result.txt.progress" \
      "$SCRATCH/scheduler-result.txt.progress"; do
      if [ -f "$PROGRESS_FILE" ]; then
        echo 'native host open retry: test progress follows' >&2
        /bin/cat "$PROGRESS_FILE" >&2
      fi
    done
  fi
  /bin/rm -rf "$SCRATCH"
  exit "$STATUS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/printf 'x' > "$UNREADABLE_PATH"
/bin/chmod 000 "$UNREADABLE_PATH"
: > "$EMPTY_PATH"
/bin/mkdir "$DIRECTORY_PATH"
/usr/bin/mkfifo "$FIFO_PATH"
/usr/bin/truncate -s 1048705 "$OVERSIZED_PATH"
/usr/bin/printf 'x' > "$MALFORMED_PATH"
/bin/dd if=/dev/zero of="$UNSUPPORTED_PATH" bs=2048 count=1 2>/dev/null

wait_for_result() {
  EXPECTED=$1
  PROGRESS_FILE=$RESULT_FILE.progress
  ATTEMPT=0
  while [ ! -f "$RESULT_FILE" ] && [ "$ATTEMPT" -lt 140 ]; do
    if [ -f "$PROGRESS_FILE" ] && /usr/bin/grep -Fq 'test-assertion-failed:' "$PROGRESS_FILE"; then
      echo 'native host open retry: app assertion failed' >&2
      /bin/cat "$PROGRESS_FILE" >&2
      return 1
    fi
    /bin/sleep 0.1
    ATTEMPT=$((ATTEMPT + 1))
  done
  if [ ! -f "$RESULT_FILE" ]; then
    echo 'native host open retry: app produced no result within 14 seconds' >&2
    return 1
  fi
  if ! /usr/bin/grep -Fqx "$EXPECTED" "$RESULT_FILE"; then
    echo 'native host open retry: app produced an unexpected result' >&2
    /bin/cat "$RESULT_FILE" >&2
    return 1
  fi
  ATTEMPT=0
  while [ -n "$(current_test_pids)" ] && [ "$ATTEMPT" -lt 20 ]; do
    /bin/sleep 0.1
    ATTEMPT=$((ATTEMPT + 1))
  done
  if [ -n "$(current_test_pids)" ]; then
    echo 'native host open retry: app wrote success but did not exit within 2 seconds' >&2
    return 1
  fi
  if ! /usr/bin/grep -Fqx \
    'audio-toggle: retained=before-load,session,replacement reset=unmuted result=pass' \
    "$PROGRESS_FILE"; then
    echo 'native host open retry: app did not complete the mute preference journey' >&2
    /bin/cat "$PROGRESS_FILE" >&2
    return 1
  fi
  stop_open_launcher
  /bin/cat "$RESULT_FILE"
}

EXPECTED='installed_macos_host: picker=present cancel=idle reader=6 load=2 allocation=1 retry=presented result=pass'
/usr/bin/open -n -a "$APP_BUNDLE" --args \
  --test-panel-flow \
  --test-panel-failure "$SCRATCH/absent.a78" \
  --test-panel-failure "$UNREADABLE_PATH" \
  --test-panel-failure "$EMPTY_PATH" \
  --test-panel-failure "$DIRECTORY_PATH" \
  --test-panel-failure "$FIFO_PATH" \
  --test-panel-failure "$OVERSIZED_PATH" \
  --test-panel-failure "$MALFORMED_PATH" \
  --test-panel-failure "$UNSUPPORTED_PATH" \
  --test-panel-failure "$CONTENT_PATH" \
  --test-retry "$CONTENT_PATH" \
  --test-close-after-presentations 2 \
  --test-result-file "$RESULT_FILE" &
OPEN_PID=$!
wait_for_result "$EXPECTED"

RESULT_FILE=$CLI_RESULT_FILE
CLI_EXPECTED='installed_macos_host: cli=invalid-load error=after-cleanup retry=presented result=pass'
/usr/bin/open -n -a "$APP_BUNDLE" --args \
  --content "$MALFORMED_PATH" \
  --test-cli-retry "$CONTENT_PATH" \
  --test-close-after-presentations 2 \
  --test-result-file "$CLI_RESULT_FILE" &
OPEN_PID=$!
wait_for_result "$CLI_EXPECTED"

RESULT_FILE=$SCHEDULER_RESULT_FILE
SCHEDULER_EXPECTED='installed_macos_host: scheduler=overflow cleanup=before-alert retry=presented result=pass'
/usr/bin/open -n -a "$APP_BUNDLE" --args \
  --content "$CONTENT_PATH" \
  --test-scheduler-retry "$CONTENT_PATH" \
  --test-close-after-presentations 2 \
  --test-result-file "$SCHEDULER_RESULT_FILE" &
OPEN_PID=$!
wait_for_result "$SCHEDULER_EXPECTED"

echo 'native_host_ui: result=pass'
