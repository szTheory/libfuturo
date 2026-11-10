#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIR/native-smoke-cleanup.sh"
CONTROL_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/native-smoke-controls.XXXXXX")
CONTROL_STATUS=$CONTROL_DIR/status.txt
CONTROL_RESULT=$CONTROL_DIR/result.txt
trap '/bin/rm -rf "$CONTROL_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

EXPECTED='installed_macos_host: profile=muhtari-ntsc-v1 native-window=pass presentation=pass close=pass result=pass'
PRODUCTION='installed_macos_host: production-view=LFHostView input=port0-fire startup-rgb=pass geometry=320:242,fit,letterbox capture=backing-rgba controls=rgb,geometry result=pass'
AUDIO='installed_macos_host: audio=system source=s16-native,mono,48000 output-rate=48000 output-channels=2 dataPlayedBack=1 pool-drops=0 prime-delay-ms=41 player-stopped=true engine-stopped=true result=pass'

printf 'starting 0\n' > "$CONTROL_STATUS"
native_smoke_read_supervisor_state "$CONTROL_STATUS"
[ "$smoke_supervisor_state" = starting ]
printf 'running 12\n' > "$CONTROL_STATUS"
native_smoke_read_supervisor_state "$CONTROL_STATUS"
[ "$smoke_supervisor_state" = running ]
[ "$smoke_supervisor_ack" -eq 12 ]
native_smoke_supervisor_app_is_running "$CONTROL_STATUS"
printf 'terminated 12\n' > "$CONTROL_STATUS"
if native_smoke_supervisor_app_is_running "$CONTROL_STATUS" 2>/dev/null; then
  echo 'terminated app instance was incorrectly reported as running' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
printf 'unknown 12 5\n' > "$CONTROL_STATUS"
if native_smoke_supervisor_app_is_running "$CONTROL_STATUS" 2>/dev/null; then
  echo 'unknown app instance state was incorrectly reported as running' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
printf 'unknown 12 invalid\n' > "$CONTROL_STATUS"
if native_smoke_read_supervisor_state "$CONTROL_STATUS"; then
  echo 'malformed supervisor state was accepted' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi

if native_smoke_validate_app_result "$CONTROL_RESULT" "$EXPECTED" "$PRODUCTION" 2>/dev/null; then
  echo 'missing app result was accepted' >&2
  exit 1
fi
printf '%s\n' 'wrong-result' "$PRODUCTION" > "$CONTROL_RESULT"
if native_smoke_validate_app_result "$CONTROL_RESULT" "$EXPECTED" "$PRODUCTION" 2>/dev/null; then
  echo 'unexpected app result was accepted' >&2
  exit 1
fi
printf '%s\n' "$EXPECTED" > "$CONTROL_RESULT"
if native_smoke_validate_app_result "$CONTROL_RESULT" "$EXPECTED" "$PRODUCTION" 2>/dev/null; then
  echo 'result without the production-view marker was accepted' >&2
  exit 1
fi
printf '%s\n' "$EXPECTED" "$PRODUCTION" "$AUDIO" > "$CONTROL_RESULT"
native_smoke_validate_app_result "$CONTROL_RESULT" "$EXPECTED" "$PRODUCTION"

sed 's/ player-stopped=true//' "$CONTROL_RESULT" > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'missing player-stopped field was accepted' >&2
  exit 1
fi
sed 's/ player-stopped=true/player-stopped=false/' "$CONTROL_RESULT" \
  > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'false player-stopped state was accepted' >&2
  exit 1
fi
sed 's/ engine-stopped=true//' "$CONTROL_RESULT" > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'missing engine-stopped field was accepted' >&2
  exit 1
fi
sed 's/ engine-stopped=true/engine-stopped=false/' "$CONTROL_RESULT" \
  > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'false engine-stopped state was accepted' >&2
  exit 1
fi
sed 's/dataPlayedBack=1/dataPlayedBack=0/' "$CONTROL_RESULT" \
  > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'zero dataPlayedBack count was accepted' >&2
  exit 1
fi
sed 's/output-rate=48000/output-rate=0/' "$CONTROL_RESULT" \
  > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'zero output rate was accepted' >&2
  exit 1
fi
sed 's/output-channels=2/output-channels=0/' "$CONTROL_RESULT" \
  > "$CONTROL_RESULT.tmp"
if native_smoke_validate_app_result "$CONTROL_RESULT.tmp" "$EXPECTED" \
    "$PRODUCTION" 2>/dev/null; then
  echo 'zero output channel count was accepted' >&2
  exit 1
fi

CONTROL_MODE=
CONTROL_STATE=running
CONTROL_ACK=0
CONTROL_STAGE=
CONTROL_REQUESTS=
CONTROL_TERM_POLLS=0
CONTROL_FORCE_POLLS=0
CONTROL_TERM_ATTEMPTS=3
CONTROL_FORCE_ATTEMPTS=3
CONTROL_REAPED=0
CONTROL_REMOVED=
CONTROL_PRESERVED=
CONTROL_MARKER=

write_control_state() {
  case "$CONTROL_STATE" in
    unknown) printf 'unknown %s 5\n' "$CONTROL_ACK" > "$CONTROL_STATUS" ;;
    *) printf '%s %s\n' "$CONTROL_STATE" "$CONTROL_ACK" > "$CONTROL_STATUS" ;;
  esac
}

fake_request_termination() {
  if native_smoke_supervisor_app_is_running "$CONTROL_STATUS" 2>/dev/null; then
    :
  else
    REQUEST_STATE=$?
    [ "$REQUEST_STATE" -eq 1 ] && return 0
    return 2
  fi
  CONTROL_ACK=$((CONTROL_ACK + 1))
  case "$1" in
    TERMINATE)
      CONTROL_STAGE=TERMINATE
      CONTROL_REQUESTS="${CONTROL_REQUESTS}${CONTROL_REQUESTS:+ }TERMINATE"
      ;;
    FORCE_TERMINATE)
      CONTROL_STAGE=FORCE_TERMINATE
      CONTROL_REQUESTS="${CONTROL_REQUESTS}${CONTROL_REQUESTS:+ }FORCE_TERMINATE"
      ;;
    *) return 2 ;;
  esac
  write_control_state
}

fake_app_is_running() {
  if [ "$CONTROL_STATE" = running ]; then
    case "$CONTROL_STAGE:$CONTROL_MODE" in
      TERMINATE:graceful)
        CONTROL_TERM_POLLS=$((CONTROL_TERM_POLLS + 1))
        [ "$CONTROL_TERM_POLLS" -lt 2 ] || CONTROL_STATE=terminated
        ;;
      TERMINATE:force|TERMINATE:stuck)
        CONTROL_TERM_POLLS=$((CONTROL_TERM_POLLS + 1))
        ;;
      FORCE_TERMINATE:force)
        CONTROL_FORCE_POLLS=$((CONTROL_FORCE_POLLS + 1))
        CONTROL_STATE=terminated
        ;;
      FORCE_TERMINATE:stuck)
        CONTROL_FORCE_POLLS=$((CONTROL_FORCE_POLLS + 1))
        ;;
      *) echo "unexpected fake supervisor state: $CONTROL_STAGE/$CONTROL_MODE" >&2; return 2 ;;
    esac
    write_control_state
  fi
  native_smoke_supervisor_app_is_running "$CONTROL_STATUS" 2>/dev/null
}

fake_sleep() {
  :
}

fake_reap_supervisor() {
  CONTROL_REAPED=$((CONTROL_REAPED + 1))
  [ "$CONTROL_STATE" = terminated ]
}

fake_stop_supervised_app() {
  native_smoke_stop_supervised_app \
    71 fake_request_termination fake_app_is_running fake_sleep \
    "$CONTROL_TERM_ATTEMPTS" "$CONTROL_FORCE_ATTEMPTS" \
    fake_reap_supervisor
}

fake_preserve_scratch() {
  CONTROL_PRESERVED=$1
}

fake_remove_scratch() {
  CONTROL_REMOVED=$1
}

fake_report_success() {
  if [ "$CONTROL_STATE" != terminated ] || [ "$CONTROL_REAPED" -ne 1 ] ||
      [ -z "$CONTROL_REMOVED" ]; then
    echo 'success marker was requested before app termination and cleanup' >&2
    return 1
  fi
  CONTROL_MARKER=printed
}

reset_control_case() {
  CONTROL_MODE=$1
  CONTROL_STATE=running
  CONTROL_ACK=0
  CONTROL_STAGE=
  CONTROL_REQUESTS=
  CONTROL_TERM_POLLS=0
  CONTROL_FORCE_POLLS=0
  CONTROL_TERM_ATTEMPTS=3
  CONTROL_FORCE_ATTEMPTS=3
  CONTROL_REAPED=0
  CONTROL_REMOVED=
  CONTROL_PRESERVED=
  CONTROL_MARKER=
  write_control_state
}

reset_control_case graceful
native_smoke_cleanup_successful_run \
  fake_stop_supervised_app fake_preserve_scratch fake_remove_scratch \
  /tmp/native-smoke-success fake_report_success
[ "$CONTROL_REQUESTS" = TERMINATE ]
[ "$CONTROL_TERM_POLLS" -eq 2 ]
[ "$CONTROL_FORCE_POLLS" -eq 0 ]
[ "$CONTROL_REAPED" -eq 1 ]
[ "$CONTROL_REMOVED" = /tmp/native-smoke-success ]
[ "$CONTROL_MARKER" = printed ]

reset_control_case force
CONTROL_TERM_ATTEMPTS=2
native_smoke_cleanup_successful_run \
  fake_stop_supervised_app fake_preserve_scratch fake_remove_scratch \
  /tmp/native-smoke-force fake_report_success
[ "$CONTROL_REQUESTS" = 'TERMINATE FORCE_TERMINATE' ]
[ "$CONTROL_TERM_POLLS" -eq 3 ]
[ "$CONTROL_FORCE_POLLS" -eq 1 ]
[ "$CONTROL_REAPED" -eq 1 ]
[ "$CONTROL_REMOVED" = /tmp/native-smoke-force ]
[ "$CONTROL_MARKER" = printed ]

reset_control_case stuck
if native_smoke_cleanup_failed_run \
    fake_stop_supervised_app fake_preserve_scratch /tmp/native-smoke-scratch; then
  echo 'cleanup accepted an app instance that survived force termination' >&2
  exit 1
else
  [ "$?" -eq 1 ]
fi
[ "$CONTROL_REQUESTS" = 'TERMINATE FORCE_TERMINATE' ]
[ "$CONTROL_REAPED" -eq 0 ]
[ "$CONTROL_PRESERVED" = /tmp/native-smoke-scratch ]
[ -z "$CONTROL_REMOVED" ]

reset_control_case graceful
if native_smoke_cleanup_failed_run \
    fake_stop_supervised_app fake_preserve_scratch \
    /tmp/native-smoke-failed-confirmed; then
  :
else
  echo 'failed run cleanup rejected confirmed app termination' >&2
  exit 1
fi
[ "$CONTROL_STATE" = terminated ]
[ "$CONTROL_REAPED" -eq 1 ]
[ "$CONTROL_PRESERVED" = /tmp/native-smoke-failed-confirmed ]
[ -z "$CONTROL_REMOVED" ]

reset_control_case graceful
CONTROL_STATE=unknown
write_control_state
if native_smoke_cleanup_successful_run \
    fake_stop_supervised_app fake_preserve_scratch fake_remove_scratch \
    /tmp/native-smoke-unknown fake_report_success; then
  echo 'successful cleanup accepted unknown app state' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
[ -z "$CONTROL_REQUESTS" ]
[ "$CONTROL_PRESERVED" = /tmp/native-smoke-unknown ]
[ -z "$CONTROL_REMOVED" ]
[ -z "$CONTROL_MARKER" ]

printf 'native_smoke_cleanup_controls: state=exact-instance result=required termination=normal,force grace=bounded scratch=preserved-on-failure,unknown result=pass\n'
