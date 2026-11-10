#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
supervisor=${1:-$script_dir/nesturbator_fresh_process_supervisor.sh}
fixture_action=0
case ${1:-} in
  capture|restore|wrong) fixture_action=1 ;;
esac
if [ "$fixture_action" -eq 0 ] && [ ! -r "$supervisor" ]; then
  printf '%s\n' "missing supervisor: $supervisor" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-supervisor-controls.XXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM

fixture_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    sha256sum "$1" | awk '{ print $1 }'
  fi
}

write_checkpoint_field() {
  offset=$1
  encoded=$2
  printf "$encoded" | dd of="$path" bs=1 seek="$offset" conv=notrunc 2>/dev/null
}

write_valid_checkpoint() {
  path=$1
  dd if=/dev/zero of="$path" bs=389 count=1 2>/dev/null || return 2
  write_checkpoint_field 0 'LFSNAP2\000' || return 2
  write_checkpoint_field 8 '\002\000\000\000' || return 2
  write_checkpoint_field 12 '\204\001\000\000' || return 2
  write_checkpoint_field 16 '\205\001\000\000\000\000\000\000' || return 2
  write_checkpoint_field 24 '\001\000\000\000\000\000\000\000' || return 2
  write_checkpoint_field 32 '\003\000\000\000' || return 2
  write_checkpoint_field 36 '\001\000\000\000' || return 2
  write_checkpoint_field 40 '\011\000\000\000' || return 2
  write_checkpoint_field 44 'nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3' || return 2
  write_checkpoint_field 108 'sha256:0000000000000000000000000000000000000000000000000000000000000000' || return 2
  write_checkpoint_field 188 'nesturbator-ntsc-v1' || return 2
  write_checkpoint_field 220 'nesturbator-default' || return 2
  write_checkpoint_field 252 'nesturbator-options-none-v1' || return 2
  write_checkpoint_field 356 '\020\140\000\000\000\000\000\000' || return 2
}

write_valid_battery_checkpoint() {
  path=$1
  write_valid_checkpoint "$path" || return 2
  write_checkpoint_field 356 '\020\240\000\000\000\000\000\000' || return 2
}

fixture_capture() {
  path=$1
  mode=$2
  if [ "$mode" = cancel ]; then
    : > "${LF_FRESH_PROCESS_TEST_MARKER:?}"
    sleep 30
    return $?
  fi
  if [ "$mode" = valid ]; then
    write_valid_checkpoint "$path" || return 2
  elif [ "${mode#battery-}" != "$mode" ]; then
    write_valid_battery_checkpoint "$path" || return 2
  else
    printf 'controlled checkpoint bytes\n' > "$path" || return 2
  fi
  bytes=$(wc -c < "$path" | tr -d '[:space:]')
  digest=$(fixture_sha256 "$path") || return 2
  case $mode in
    a-timeout)
      sleep 30
      return $?
      ;;
    a-missing-close)
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_process_a: result=pass'
      return 0
      ;;
    a-reordered)
      printf '%s\n' 'event=instance-destroyed'
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$digest"
      printf '%s\n' 'nesturbator_snapshot_process_a: result=pass'
      return 0
      ;;
    a-duplicate)
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$digest"
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$digest"
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_process_a: result=pass'
      return 0
      ;;
    a-nonzero|valid)
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$digest"
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_process_a: result=pass'
      if [ "$mode" = a-nonzero ]; then
        return 7
      fi
      return 0
      ;;
    battery-a-timeout)
      sleep 30
      return $?
      ;;
    battery-a-missing-close)
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_battery_process_a: result=pass'
      return 0
      ;;
    battery-a-bad-close)
      printf 'event=checkpoint-close bytes=%s sha256=bad\n' "$bytes"
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_battery_process_a: result=pass'
      return 0
      ;;
    battery-a-nonzero|battery-valid|battery-b-missing-import|battery-b-missing-restore|battery-b-missing-failed-update|battery-b-missing-ack)
      printf '%s\n' 'event=selected-save-r3 bytes=8192 generation=3 payload=exact readback=exact result=pass'
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$digest"
      printf '%s\n' 'event=instance-destroyed'
      printf '%s\n' 'nesturbator_snapshot_battery_process_a: result=pass'
      if [ "$mode" = battery-a-nonzero ]; then
        return 7
      fi
      return 0
      ;;
    *) return 2 ;;
  esac
}

fixture_restore() {
  path=$1
  mode=$2
  digest=$(fixture_sha256 "$path") || return 2
  bytes=$(wc -c < "$path" | tr -d '[:space:]')
  printf 'event=checkpoint-reopened bytes=%s sha256=%s\n' "$bytes" "$digest"
  if [ "${mode#battery-}" = "$mode" ]; then
    printf '%s\n' 'nesturbator_snapshot_process_b: result=pass'
    return 0
  fi
  if [ "$mode" != battery-b-missing-import ]; then
    printf '%s\n' 'event=selected-save-imported-r3 bytes=8192 generation=3 before-positive-advance=pass result=pass'
  fi
  if [ "$mode" != battery-b-missing-restore ]; then
    printf '%s\n' 'event=battery-restore-r2 bytes=8192 generation=4 selected-r3-preserved=pass result=pass'
  fi
  refusal_cases='zero_extent null_zero_extent truncated_header truncated_native_payload trailing_byte malformed_magic malformed_version malformed_header malformed_total_length malformed_native_length malformed_content_extent wrong_core_build wrong_libfuturo_build wrong_native_format wrong_core_abi wrong_behavior_revision wrong_profile wrong_configuration wrong_options wrong_content_digest native_corruption repeated_invalid_candidate'
  for refusal_case in $refusal_cases; do
    printf 'event=battery-b-refusal name=%s status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\n' \
      "$refusal_case"
    if [ "$refusal_case" = repeated_invalid_candidate ]; then
      printf '%s\n' 'event=battery-b-refusal name=repeated_invalid_candidate status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass'
    fi
  done
  printf '%s\n' 'event=battery-b-refusal-baseline generation=4 media=R2 selected-save=R3 result=pass'
  if [ "$mode" != battery-b-missing-failed-update ]; then
    printf '%s\n' 'event=pre-rename-failure-preserved-r3 bytes=8384 ack=exact stage-cleanup=pass result=pass'
  fi
  if [ "$mode" != battery-b-missing-ack ]; then
    printf '%s\n' 'event=save-r2-readback-acknowledged bytes=8192 generation=4 readback=exact result=pass'
  fi
  printf '%s\n' 'nesturbator_snapshot_battery_process_b: loads=1 frame=3 ticks=2144280 video=5a5a5a audio=799-silence media=full-8192 selected-save=R2-readback result=pass'
  return 0
}

run_case() {
  name=$1
  expected_status=$2
  timeout=$3
  supervisor_mode=${4:-battery-free}
  supervisor_mode_arg=
  if [ "$supervisor_mode" = battery ]; then
    supervisor_mode_arg=--battery
  fi
  output=$scratch/$name.log
  marker=$scratch/$name.started
  if [ "$name" = cancelled ] || [ "$name" = battery-cancelled ]; then
    LF_FRESH_PROCESS_TEST_FIXTURE="$script_dir/nesturbator_supervisor_controls.sh" \
      LF_FRESH_PROCESS_TEST_MODE=cancel \
      LF_FRESH_PROCESS_TEST_MARKER="$marker" \
      LF_FRESH_PROCESS_TIMEOUT_SECONDS="$timeout" \
      LF_FRESH_PROCESS_SKIP_WRONG_ORACLE=1 \
      /bin/sh "$supervisor" "$script_dir/nesturbator_supervisor_controls.sh" \
      "$supervisor_mode_arg" \
      > "$output" 2>&1 &
    supervisor_pid=$!
    attempts=0
    while [ ! -f "$marker" ] && [ "$attempts" -lt 50 ]; do
      if ! kill -0 "$supervisor_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if [ ! -f "$marker" ]; then
      kill -TERM "$supervisor_pid" 2>/dev/null || true
      wait "$supervisor_pid" 2>/dev/null || true
      printf 'supervisor cancellation fixture did not start\n' >&2
      cat "$output" >&2
      return 1
    fi
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid"
    actual_status=$?
  else
    LF_FRESH_PROCESS_TEST_FIXTURE="$script_dir/nesturbator_supervisor_controls.sh" \
      LF_FRESH_PROCESS_TEST_MODE="$name" \
      LF_FRESH_PROCESS_TIMEOUT_SECONDS="$timeout" \
      LF_FRESH_PROCESS_SKIP_WRONG_ORACLE=1 \
      /bin/sh "$supervisor" "$script_dir/nesturbator_supervisor_controls.sh" \
      "$supervisor_mode_arg" \
      > "$output" 2>&1
    actual_status=$?
  fi
  if [ "$actual_status" -ne "$expected_status" ]; then
    printf 'case %s returned %s, expected %s\n' \
      "$name" "$actual_status" "$expected_status" >&2
    cat "$output" >&2
    return 1
  fi
  if [ "$name" = valid ] || [ "$name" = battery-valid ]; then
    if ! grep -q '^event=b-start$' "$output" ||
       ! grep -q '^event=supervisor-success$' "$output"; then
      printf 'valid control did not reach B\n' >&2
      cat "$output" >&2
      return 1
    fi
    if [ "$name" = battery-valid ] &&
       ! grep -q '^event=battery-save-custody-r3-imported-r2-restored-r2-committed$' "$output"; then
      printf 'valid battery control did not prove save custody\n' >&2
      cat "$output" >&2
      return 1
    fi
  elif [ "${name#battery-b-}" != "$name" ]; then
    if ! grep -q '^event=b-start$' "$output" ||
       grep -q '^event=supervisor-success$' "$output"; then
      printf 'battery B failure did not stop qualification in case %s\n' "$name" >&2
      cat "$output" >&2
      return 1
    fi
  else
    if grep -q '^event=b-start$' "$output"; then
      printf 'invalid A lifecycle launched B in case %s\n' "$name" >&2
      cat "$output" >&2
      return 1
    fi
    if ! grep -q '^event=a-start$' "$output"; then
      printf 'case %s did not record A start\n' "$name" >&2
      cat "$output" >&2
      return 1
    fi
  fi
  return 0
}

case ${1:-} in
  capture) fixture_capture "$2" "$3"; exit $? ;;
  restore) fixture_restore "$2" "$3"; exit $? ;;
  wrong)
    printf '%s\n' 'event=wrong-oracle-rejected'
    exit 1
    ;;
esac

if [ "$#" -gt 1 ]; then
  printf '%s\n' 'usage: nesturbator_supervisor_controls.sh [supervisor-script]' >&2
  exit 2
fi

run_case a-nonzero 1 5 || exit 1
run_case a-missing-close 1 5 || exit 1
run_case a-timeout 1 1 || exit 1
run_case cancelled 130 30 || exit 1
run_case a-reordered 1 5 || exit 1
run_case a-duplicate 1 5 || exit 1
run_case valid 0 5 || exit 1
run_case battery-a-nonzero 1 5 battery || exit 1
run_case battery-a-missing-close 1 5 battery || exit 1
run_case battery-a-bad-close 1 5 battery || exit 1
run_case battery-a-timeout 1 1 battery || exit 1
run_case battery-cancelled 130 30 battery || exit 1
run_case battery-b-missing-import 1 5 battery || exit 1
run_case battery-b-missing-restore 1 5 battery || exit 1
run_case battery-b-missing-failed-update 1 5 battery || exit 1
run_case battery-b-missing-ack 1 5 battery || exit 1
run_case battery-valid 0 5 battery || exit 1
printf '%s\n' 'nesturbator_supervisor_controls: failure-stops, battery-failure-stops, valid-order-starts-b result=pass'
