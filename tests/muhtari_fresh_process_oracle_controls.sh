#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
consumer=${1:-}
supervisor=${2:-$script_dir/muhtari_fresh_process_supervisor.sh}
if [ -z "$consumer" ] || [ ! -x "$consumer" ] || [ ! -r "$supervisor" ]; then
  printf '%s\n' "usage: $0 <consumer-executable> <supervisor-script>" >&2
  exit 2
fi
route=${LF_FRESH_PROCESS_ROUTE:-source}
case $route in
  source|installed) ;;
  *) printf 'invalid fresh-process route: %s\n' "$route" >&2; exit 2 ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-muhtari-oracle-controls.XXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM

fail() {
  printf 'muhtari oracle control failed: %s\n' "$1" >&2
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    cat "$2" >&2
  fi
  exit 1
}

for oracle in frame video audio media; do
  output=$scratch/oracle-$oracle.log
  LF_FRESH_PROCESS_B_MODE=$oracle /bin/sh "$supervisor" "$consumer" \
    > "$output" 2>&1
  status=$?
  if [ "$status" -ne 0 ] ||
     ! grep -q "^event=oracle-control name=$oracle .* result=pass$" "$output" ||
     ! grep -q "^event=supervisor-oracle-control route=$route result=pass$" "$output"; then
    fail "wrong-$oracle did not fail at the intended B assertion" "$output"
  fi
done

for stage in a b; do
  for mode in deny-status deny-supported; do
    output=$scratch/capability-$stage-$mode.log
    if [ "$stage" = a ]; then
      "$consumer" --process-a "$scratch/checkpoint" "$scratch/save" \
        "$scratch/ack" "$mode" > "$output" 2>&1
    else
      "$consumer" --process-b "$scratch/checkpoint" "$scratch/save" \
        "$scratch/ack" "$mode" > "$output" 2>&1
    fi
    status=$?
    if [ "$status" -ne 77 ] ||
       ! grep -q "^event=capability-control stage=$stage mode=$mode .*snapshot-calls=0 result=pass$" "$output" ||
       grep -q 'event=selected-save\|event=checkpoint-reopened\|event=battery-restore' "$output"; then
      fail "capability denial $stage/$mode did not stop before snapshot work" "$output"
    fi
  done
done

printf 'muhtari_api8_%s_oracle_controls: frame,video,audio,media,capability denied result=pass\n' \
  "$route"
