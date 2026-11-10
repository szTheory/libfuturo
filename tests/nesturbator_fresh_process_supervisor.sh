#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
consumer=${1:-}
mode=${2:-battery-free}
if [ -z "$consumer" ]; then
  printf '%s\n' "usage: $0 <consumer-executable> [--battery|--battery-oracle-controls]" >&2
  exit 2
fi
case $mode in
  battery-free|--battery|--battery-oracle-controls) ;;
  *) printf 'invalid fresh-process mode: %s\n' "$mode" >&2; exit 2 ;;
esac

helper=${LF_PROCESS_TREE_HELPER:-$script_dir/../scripts/process-tree-cleanup.sh}
if [ ! -r "$helper" ]; then
  printf '%s\n' "missing process-tree helper: $helper" >&2
  exit 2
fi
. "$helper"

timeout_seconds=${LF_FRESH_PROCESS_TIMEOUT_SECONDS:-30}
case $timeout_seconds in
  ''|*[!0-9]*) printf '%s\n' 'invalid fresh-process timeout' >&2; exit 2 ;;
esac
if [ "$timeout_seconds" -lt 1 ]; then
  printf '%s\n' 'fresh-process timeout must be positive' >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-snapshot-pair.XXXXXXXX") || exit 1
checkpoint=$scratch/checkpoint.bin
save_dir=$scratch/save
mkdir "$save_dir" || exit 1
selected_save=$save_dir/selected-save.bin
oracle_save_dir=$scratch/oracle-save
oracle_save=$oracle_save_dir/selected-save.bin
events=$scratch/events.log
a_output=$scratch/a.log
b_output=$scratch/b.log
wrong_output=$scratch/wrong.log
oracle_output=$scratch/oracle-controls.log
: > "$events"
LF_PROCESS_TREE_ACTIVE_PID=
LF_PROCESS_TREE_CLEANUP_FAILED=0

finish() {
  status=$?
  trap - EXIT
  if [ -f "$events" ]; then
    cat "$events"
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap finish EXIT

handle_signal() {
  signal=$1
  printf 'event=cancelled signal=%s\n' "$signal" >> "$events"
  lf_process_tree_cancel_handler "$signal"
  exit 130
}
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

append_event() {
  printf '%s\n' "$1" >> "$events"
}

fail() {
  append_event "event=failed reason=$1"
  exit 1
}

run_child() {
  action=$1
  path=$2
  if [ -n "${LF_FRESH_PROCESS_TEST_FIXTURE:-}" ]; then
    "$LF_FRESH_PROCESS_TEST_FIXTURE" "$action" "$path" \
      "${LF_FRESH_PROCESS_TEST_MODE:-valid}"
    return $?
  fi
  case $mode in
    --battery|--battery-oracle-controls)
      case $action in
        capture) "$consumer" --snapshot-battery-process-capture "$path" "$selected_save" ;;
        restore) "$consumer" --snapshot-battery-process-restore "$path" "$selected_save" ;;
        oracle-controls)
          if [ "$mode" = --battery-oracle-controls ]; then
            "$consumer" --snapshot-battery-process-oracle-controls "$path" "$oracle_save"
          else
            return 2
          fi
          ;;
        *) return 2 ;;
      esac
      return $?
      ;;
  esac
  case $action in
    capture) "$consumer" --snapshot-process-capture "$path" ;;
    restore) "$consumer" --snapshot-process-restore "$path" ;;
    wrong) "$consumer" --snapshot-process-restore "$path" --wrong-oracle ;;
    *) return 2 ;;
  esac
}

wait_child() {
  child_pid=$1
  child_timeout=$2
  elapsed_tenths=0
  limit_tenths=$((child_timeout * 10))
  while kill -0 "$child_pid" 2>/dev/null; do
    if [ "$elapsed_tenths" -ge "$limit_tenths" ]; then
      return 124
    fi
    sleep 0.1
    elapsed_tenths=$((elapsed_tenths + 1))
  done
  wait "$child_pid"
}

start_child() {
  child_action=$1
  child_path=$2
  child_log=$3
  lf_process_tree_start run_child "$child_action" "$child_path" \
    > "$child_log" 2>&1
  LF_PROCESS_TREE_ACTIVE_PID=$LF_PROCESS_TREE_ROOT
}

stop_active_child() {
  if [ -n "$LF_PROCESS_TREE_ACTIVE_PID" ]; then
    child_pid=$LF_PROCESS_TREE_ACTIVE_PID
    if ! lf_process_tree_terminate "$child_pid"; then
      LF_PROCESS_TREE_CLEANUP_FAILED=1
    fi
    LF_PROCESS_TREE_ACTIVE_PID=
  fi
}

exact_event_count() {
  event_file=$1
  event_pattern=$2
  awk -v pattern="$event_pattern" '$0 ~ pattern { count += 1 } END { print count + 0 }' \
    "$event_file"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

snapshot_header_bytes() {
  dd if="$checkpoint" bs=1 skip="$1" count="$2" 2>/dev/null
}

snapshot_header_string() {
  snapshot_header_bytes "$1" "$2" | tr -d '\000'
}

snapshot_header_u32() {
  od -An -tu4 -j "$1" -N4 "$checkpoint" | tr -d '[:space:]'
}

snapshot_header_u64() {
  od -An -tu8 -j "$1" -N8 "$checkpoint" | tr -d '[:space:]'
}

snapshot_header_hex() {
  od -An -v -tx1 -j "$1" -N "$2" "$checkpoint" | tr -d '[:space:]'
}

append_event 'event=supervisor-start'
append_event 'event=a-start'
start_child capture "$checkpoint" "$a_output"
a_pid=$LF_PROCESS_TREE_ACTIVE_PID
wait_child "$a_pid" "$timeout_seconds"
a_status=$?
if [ "$a_status" -eq 124 ]; then
  append_event 'event=a-timeout'
  stop_active_child
  fail a-timeout
fi
LF_PROCESS_TREE_ACTIVE_PID=
append_event "event=a-exit status=$a_status"
if [ "$a_status" -ne 0 ]; then
  fail a-nonzero
fi

close_count=$(exact_event_count "$a_output" '^event=checkpoint-close ')
destroy_count=$(exact_event_count "$a_output" '^event=instance-destroyed$')
a_pass_pattern='^nesturbator_snapshot_process_a: .*result=pass$'
if [ "$mode" = --battery ] || [ "$mode" = --battery-oracle-controls ]; then
  a_pass_pattern='^nesturbator_snapshot_battery_process_a: .*result=pass$'
fi
a_pass_count=$(exact_event_count "$a_output" "$a_pass_pattern")
close_line=$(awk '/^event=checkpoint-close / { print NR }' "$a_output")
destroy_line=$(awk '/^event=instance-destroyed$/ { print NR }' "$a_output")
pass_pattern='^nesturbator_snapshot_process_a: .*result=pass$'
if [ "$mode" = --battery ] || [ "$mode" = --battery-oracle-controls ]; then
  pass_pattern='^nesturbator_snapshot_battery_process_a: .*result=pass$'
fi
pass_line=$(awk -v pattern="$pass_pattern" '$0 ~ pattern { print NR }' "$a_output")
if [ "$close_count" -ne 1 ] || [ "$destroy_count" -ne 1 ] ||
   [ "$a_pass_count" -ne 1 ] || [ -z "$close_line" ] ||
   [ -z "$destroy_line" ] || [ -z "$pass_line" ] ||
   [ "$close_line" -ge "$destroy_line" ] ||
   [ "$destroy_line" -ge "$pass_line" ]; then
  fail a-lifecycle-evidence
fi
close_bytes=$(awk '/^event=checkpoint-close / { sub(/^bytes=/, "", $2); print $2 }' "$a_output")
close_digest=$(awk '/^event=checkpoint-close / { sub(/^sha256=/, "", $3); print $3 }' "$a_output")
case $close_bytes in ''|*[!0-9]*) fail invalid-checkpoint-length ;; esac
if [ -n "$close_digest" ]; then
  case $close_digest in *[!0-9a-f]*) fail invalid-checkpoint-digest ;; esac
  if [ "${#close_digest}" -ne 64 ]; then
    fail invalid-checkpoint-digest
  fi
fi
if [ ! -f "$checkpoint" ]; then
  fail checkpoint-missing-or-invalid
fi
actual_bytes=$(wc -c < "$checkpoint" | tr -d '[:space:]')
actual_digest=$(sha256_file "$checkpoint") || fail sha256-tool-unavailable
if [ "$actual_bytes" != "$close_bytes" ] ||
   { [ -n "$close_digest" ] && [ "$actual_digest" != "$close_digest" ]; }; then
  fail checkpoint-byte-mismatch
fi
close_digest=$actual_digest
append_event "event=checkpoint-close bytes=$close_bytes sha256=$close_digest"

snapshot_magic=$(snapshot_header_string 0 8)
snapshot_version=$(snapshot_header_u32 8)
snapshot_header_size=$(snapshot_header_u32 12)
snapshot_total_size=$(snapshot_header_u64 16)
snapshot_native_size=$(snapshot_header_u64 24)
snapshot_state_format=$(snapshot_header_u32 32)
snapshot_core_abi=$(snapshot_header_u32 36)
snapshot_behavior=$(snapshot_header_u32 40)
snapshot_core_build=$(snapshot_header_string 44 64)
snapshot_libfuturo_build=$(snapshot_header_string 108 80)
snapshot_profile=$(snapshot_header_string 188 32)
snapshot_configuration=$(snapshot_header_string 220 32)
snapshot_options=$(snapshot_header_string 252 32)
snapshot_content_digest=$(snapshot_header_hex 284 32)
snapshot_content_bytes=$(snapshot_header_u64 356)
expected_content_bytes=24592
if [ "$mode" = --battery ] || [ "$mode" = --battery-oracle-controls ]; then
  expected_content_bytes=40976
fi
case "$snapshot_content_digest" in *[!0-9a-f]*) fail invalid-content-digest ;; esac
if [ "${#snapshot_content_digest}" -ne 64 ] ||
   [ "$snapshot_magic" != LFSNAP2 ] || [ "$snapshot_version" != 2 ] ||
   [ "$snapshot_header_size" != 388 ] ||
   [ "$snapshot_total_size" != "$close_bytes" ] ||
   [ "$snapshot_native_size" -ne "$((close_bytes - 388))" ] ||
   [ "$snapshot_state_format" != 3 ] || [ "$snapshot_core_abi" != 1 ] ||
   [ "$snapshot_behavior" != 9 ] ||
   [ "$snapshot_core_build" != nesturbator-2338608ab184f040620a30d17756f5e06a42d4e3 ] ||
   [ -z "$snapshot_libfuturo_build" ] ||
   [ "$snapshot_profile" != nesturbator-ntsc-v1 ] ||
   [ "$snapshot_configuration" != nesturbator-default ] ||
   [ "$snapshot_options" != nesturbator-options-none-v1 ] ||
   [ "$snapshot_content_bytes" != "$expected_content_bytes" ]; then
  fail checkpoint-runtime-identity
fi
append_event "event=snapshot-identity envelope-version=$snapshot_version header-bytes=$snapshot_header_size total-bytes=$snapshot_total_size native-bytes=$snapshot_native_size state-format=$snapshot_state_format core-abi=$snapshot_core_abi behavior-revision=$snapshot_behavior core-build=$snapshot_core_build libfuturo-build=$snapshot_libfuturo_build profile=$snapshot_profile configuration=$snapshot_configuration options=$snapshot_options content-bytes=$snapshot_content_bytes content-sha256=$snapshot_content_digest"
append_event 'event=instance-destroyed'
append_event 'event=a-success-closed-and-destroyed'

oracle_save_digest=
if [ "$mode" = --battery-oracle-controls ]; then
  if ! mkdir "$oracle_save_dir" || [ ! -f "$selected_save" ] ||
     ! cp "$selected_save" "$oracle_save"; then
    fail oracle-selected-save-copy
  fi
  oracle_save_digest=$(sha256_file "$oracle_save") || fail sha256-tool-unavailable
  append_event "event=oracle-selected-save-copied sha256=$oracle_save_digest"
fi

append_event 'event=b-start'
start_child restore "$checkpoint" "$b_output"
b_pid=$LF_PROCESS_TREE_ACTIVE_PID
wait_child "$b_pid" "$timeout_seconds"
b_status=$?
if [ "$b_status" -eq 124 ]; then
  append_event 'event=b-timeout'
  stop_active_child
  fail b-timeout
fi
LF_PROCESS_TREE_ACTIVE_PID=
append_event "event=b-exit status=$b_status"
if [ "$b_status" -ne 0 ]; then
  fail b-nonzero
fi

if [ "$mode" = battery-free ] && [ -z "${LF_FRESH_PROCESS_TEST_FIXTURE:-}" ]; then
  snapshot_cases='valid_exact_extent empty_extent truncated_header truncated_snapshot oversized_extent extent_overflow encoded_total_overflow declared_total_mismatch native_extent_mismatch bad_magic bad_header_extent unsupported_version native_state_format core_abi behavior_revision core_build libfuturo_build profile configuration options content_extent frame_overflow pending_input continuation_flags native_payload_corrupt content_digest'
  for snapshot_case in $snapshot_cases; do
    case_count=$(awk -v name="$snapshot_case" \
      '$0 ~ "^event=snapshot-case name=" name " " &&
       $0 ~ " status=(ok|invalid-argument|limit-exceeded) result=pass continuation=literal($| )" { count += 1 }
       END { print count + 0 }' "$b_output")
    if [ "$case_count" -ne 1 ]; then
      fail "b-refusal-case-$snapshot_case"
    fi
    awk -v name="$snapshot_case" \
      '$0 ~ "^event=snapshot-case name=" name " " &&
       $0 ~ " status=(ok|invalid-argument|limit-exceeded) result=pass continuation=literal($| )" { print }' \
      "$b_output" >> "$events"
  done
  content_control_count=$(exact_event_count "$b_output" \
    '^event=snapshot-content-control bytes=[0-9][0-9]* same_length=pass different_sha256=pass battery_free=pass profile=nesturbator-ntsc-v1 configuration=nesturbator-default route_eligible=pass$')
  if [ "$content_control_count" -ne 1 ]; then
    fail b-content-identity-control
  fi
  awk '/^event=snapshot-content-control / { print }' "$b_output" >> "$events"
fi
b_close_count=$(exact_event_count "$b_output" '^event=checkpoint-reopened ')
b_pass_pattern='^nesturbator_snapshot_process_b: .*result=pass$'
if [ "$mode" = --battery ] || [ "$mode" = --battery-oracle-controls ]; then
  b_pass_pattern='^nesturbator_snapshot_battery_process_b: .*result=pass$'
fi
b_pass_count=$(exact_event_count "$b_output" "$b_pass_pattern")
b_digest=$(awk '/^event=checkpoint-reopened / { sub(/^sha256=/, "", $3); print $3 }' "$b_output")
b_bytes=$(awk '/^event=checkpoint-reopened / { sub(/^bytes=/, "", $2); print $2 }' "$b_output")
post_b_bytes=$(wc -c < "$checkpoint" | tr -d '[:space:]')
post_b_digest=$(sha256_file "$checkpoint") || fail sha256-tool-unavailable
if [ "$b_close_count" -ne 1 ] || [ "$b_pass_count" -ne 1 ] ||
   [ "$b_bytes" != "$close_bytes" ] ||
   [ "$post_b_bytes" != "$close_bytes" ] ||
   [ "$post_b_digest" != "$close_digest" ] ||
   { [ -n "$b_digest" ] && [ "$b_digest" != "$close_digest" ]; }; then
  fail b-checkpoint-oracle
fi
append_event "event=checkpoint-reopened bytes=$b_bytes sha256=$post_b_digest"
append_event 'event=b-success'

if [ "$mode" = --battery ] || [ "$mode" = --battery-oracle-controls ]; then
  battery_refusal_cases='zero_extent null_zero_extent truncated_header truncated_native_payload trailing_byte malformed_magic malformed_version malformed_header malformed_total_length malformed_native_length malformed_content_extent wrong_core_build wrong_libfuturo_build wrong_native_format wrong_core_abi wrong_behavior_revision wrong_profile wrong_configuration wrong_options wrong_content_digest native_corruption repeated_invalid_candidate'
  for refusal_case in $battery_refusal_cases; do
    refusal_expected_count=1
    if [ "$refusal_case" = repeated_invalid_candidate ]; then
      refusal_expected_count=2
    fi
    refusal_count=$(exact_event_count "$b_output" \
      "^event=battery-b-refusal name=$refusal_case status=invalid-argument preservation=continuation,full-media,generation,selected-save,ack result=pass\$")
    if [ "$refusal_count" -ne "$refusal_expected_count" ]; then
      fail "b-battery-refusal-$refusal_case"
    fi
    awk -v name="$refusal_case" \
      '$0 ~ "^event=battery-b-refusal name=" name " " { print }' \
      "$b_output" >> "$events"
  done
  refusal_baseline_count=$(exact_event_count "$b_output" \
    '^event=battery-b-refusal-baseline generation=[0-9][0-9]* media=R2 selected-save=R3 result=pass$')
  if [ "$refusal_baseline_count" -ne 1 ]; then
    fail b-battery-refusal-baseline
  fi
  awk '/^event=battery-b-refusal-baseline / { print }' "$b_output" >> "$events"
  if [ "$(exact_event_count "$a_output" '^event=selected-save-r3 ')" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" '^event=selected-save-imported-r3 ')" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" '^event=battery-restore-r2 ')" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" '^event=pre-rename-failure-preserved-r3 ')" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" '^event=save-r2-readback-acknowledged ')" -ne 1 ]; then
    fail battery-save-custody-evidence
  fi
  import_line=$(awk '/^event=selected-save-imported-r3 / { print NR }' "$b_output")
  restore_line=$(awk '/^event=battery-restore-r2 / { print NR }' "$b_output")
  failure_line=$(awk '/^event=pre-rename-failure-preserved-r3 / { print NR }' "$b_output")
  acknowledgment_line=$(awk '/^event=save-r2-readback-acknowledged / { print NR }' "$b_output")
  if [ -z "$import_line" ] || [ -z "$restore_line" ] ||
     [ -z "$failure_line" ] || [ -z "$acknowledgment_line" ] ||
     [ "$import_line" -ge "$restore_line" ] ||
     [ "$restore_line" -ge "$failure_line" ] ||
     [ "$failure_line" -ge "$acknowledgment_line" ]; then
    fail battery-save-event-order
  fi
  append_event 'event=battery-save-custody-r3-imported-r2-restored-r2-committed'
fi

if [ "$mode" = --battery-oracle-controls ]; then
  append_event 'event=battery-oracle-controls-start'
  start_child oracle-controls "$checkpoint" "$oracle_output"
  oracle_pid=$LF_PROCESS_TREE_ACTIVE_PID
  wait_child "$oracle_pid" "$timeout_seconds"
  oracle_status=$?
  if [ "$oracle_status" -eq 124 ]; then
    append_event 'event=battery-oracle-controls-timeout'
    stop_active_child
    fail battery-oracle-controls-timeout
  fi
  LF_PROCESS_TREE_ACTIVE_PID=
  oracle_pass_count=$(exact_event_count "$oracle_output" \
    '^nesturbator_snapshot_battery_oracle_control: .*result=pass$')
  oracle_baseline_count=$(exact_event_count "$oracle_output" \
    '^event=battery-oracle-baseline result=pass frame=3 ticks=2144280 rgb=5a5a5a audio=799 full-media=pass$')
  if [ "$oracle_status" -ne 0 ] || [ "$oracle_pass_count" -ne 1 ] ||
     [ "$oracle_baseline_count" -ne 1 ]; then
    fail battery-oracle-controls-success
  fi
  awk '/^event=battery-oracle-baseline / { print }' "$oracle_output" >> "$events"
  for oracle_case in progress video audio media; do
    oracle_case_count=$(exact_event_count "$oracle_output" \
      "^event=battery-oracle-control name=$oracle_case expected=$oracle_case actual=$oracle_case result=pass\$")
    if [ "$oracle_case_count" -ne 1 ]; then
      fail "battery-wrong-oracle-$oracle_case"
    fi
    awk -v name="$oracle_case" \
      '$0 ~ "^event=battery-oracle-control name=" name " " { print }' \
      "$oracle_output" >> "$events"
  done
  post_oracle_save_digest=$(sha256_file "$oracle_save") || fail sha256-tool-unavailable
  if [ "$post_oracle_save_digest" != "$oracle_save_digest" ]; then
    fail battery-oracle-selected-save-changed
  fi
  append_event 'event=battery-oracle-controls-pass'
fi

if [ "$mode" = battery-free ] && [ "${LF_FRESH_PROCESS_SKIP_WRONG_ORACLE:-0}" != 1 ]; then
  append_event 'event=b-wrong-oracle-start'
  start_child wrong "$checkpoint" "$wrong_output"
  wrong_pid=$LF_PROCESS_TREE_ACTIVE_PID
  wait_child "$wrong_pid" "$timeout_seconds"
  wrong_status=$?
  if [ "$wrong_status" -eq 124 ]; then
    append_event 'event=b-wrong-oracle-timeout'
    stop_active_child
    fail wrong-oracle-timeout
  fi
  LF_PROCESS_TREE_ACTIVE_PID=
  wrong_rejected_count=$(exact_event_count "$wrong_output" '^event=wrong-oracle-rejected$')
  wrong_pass_count=$(exact_event_count "$wrong_output" '^nesturbator_snapshot_process_b: .*result=pass$')
  if [ "$wrong_status" -eq 0 ] || [ "$wrong_rejected_count" -ne 1 ] ||
     [ "$wrong_pass_count" -ne 0 ]; then
    fail wrong-oracle-control
  fi
  append_event "event=b-wrong-oracle-rejected status=$wrong_status"
fi

append_event 'event=supervisor-success'
exit 0
