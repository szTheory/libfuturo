#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
consumer=${1:-}
if [ -z "$consumer" ]; then
  printf '%s\n' "usage: $0 <consumer-executable>" >&2
  exit 2
fi

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
route=${LF_FRESH_PROCESS_ROUTE:-source}
case $route in
  source|installed) ;;
  *) printf 'invalid fresh-process route: %s\n' "$route" >&2; exit 2 ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-muhtari-pair.XXXXXXXX") || exit 1
checkpoint=$scratch/checkpoint.bin
selected_save=$scratch/selected-save.bin
acknowledgment=$scratch/selected-save.ack
a_output=$scratch/process-a.log
b_output=$scratch/process-b.log
events=$scratch/events.log
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

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    return 1
  fi
}

exact_event_count() {
  event_file=$1
  event_pattern=$2
  awk -v pattern="$event_pattern" '$0 ~ pattern { count += 1 } END { print count + 0 }' \
    "$event_file"
}

wait_child() {
  child_pid=$1
  elapsed_tenths=0
  limit_tenths=$((timeout_seconds * 10))
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
  stage=$1
  output=$2
  if [ -n "${LF_FRESH_PROCESS_TEST_FIXTURE:-}" ]; then
    "$LF_FRESH_PROCESS_TEST_FIXTURE" "$stage" "$checkpoint" \
      "$selected_save" "$acknowledgment" "${LF_FRESH_PROCESS_TEST_MODE:-valid}"
  elif [ "$stage" = a ]; then
    "$consumer" --process-a "$checkpoint" "$selected_save" "$acknowledgment"
  elif [ -n "${LF_FRESH_PROCESS_B_MODE:-}" ]; then
    "$consumer" --process-b "$checkpoint" "$selected_save" \
      "$acknowledgment" "$LF_FRESH_PROCESS_B_MODE"
  else
    "$consumer" --process-b "$checkpoint" "$selected_save" "$acknowledgment"
  fi > "$output" 2>&1
  return $?
}

launch_child() {
  stage=$1
  output=$2
  lf_process_tree_start start_child "$stage" "$output"
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

finish_child_group() {
  child_pid=$1
  if kill -0 -- "-$child_pid" 2>/dev/null; then
    if ! lf_process_tree_terminate "$child_pid"; then
      LF_PROCESS_TREE_CLEANUP_FAILED=1
    fi
  fi
  LF_PROCESS_TREE_ACTIVE_PID=
}

append_event "event=supervisor-start route=$route"
append_event 'event=a-start'
launch_child a "$a_output"
a_pid=$LF_PROCESS_TREE_ACTIVE_PID
wait_child "$a_pid"
a_status=$?
if [ "$a_status" -eq 124 ]; then
  append_event 'event=a-timeout'
  stop_active_child
  fail a-timeout
fi
finish_child_group "$a_pid"
if [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -ne 0 ]; then
  fail a-process-tree-cleanup
fi
append_event "event=a-exit status=$a_status"
if [ "$a_status" -ne 0 ]; then
  fail a-nonzero
fi

# The A result is accepted only after the actual child closes its checkpoint,
# destroys its instance, and reports success in that order.
a_close_count=$(exact_event_count "$a_output" '^event=checkpoint-close ')
a_r3_count=$(exact_event_count "$a_output" '^event=selected-save-commit-r3 .*readback=exact result=pass$')
a_destroy_count=$(exact_event_count "$a_output" '^event=instance-destroyed$')
a_pass_count=$(exact_event_count "$a_output" '^muhtari_api8_process_a: .*result=pass$')
a_close_line=$(awk '/^event=checkpoint-close / { print NR }' "$a_output")
a_r3_line=$(awk '/^event=selected-save-commit-r3 .*readback=exact result=pass$/ { print NR }' "$a_output")
a_destroy_line=$(awk '/^event=instance-destroyed$/ { print NR }' "$a_output")
a_pass_line=$(awk '/^muhtari_api8_process_a: .*result=pass$/ { print NR }' "$a_output")
if [ "$a_close_count" -ne 1 ] || [ "$a_r3_count" -ne 1 ] ||
   [ "$a_destroy_count" -ne 1 ] ||
   [ "$a_pass_count" -ne 1 ] || [ -z "$a_close_line" ] ||
   [ -z "$a_r3_line" ] ||
   [ -z "$a_destroy_line" ] || [ -z "$a_pass_line" ] ||
   [ "$a_r3_line" -ge "$a_close_line" ] ||
   [ "$a_close_line" -ge "$a_destroy_line" ] ||
   [ "$a_destroy_line" -ge "$a_pass_line" ]; then
  fail a-lifecycle-evidence
fi
a_close_bytes=$(awk '/^event=checkpoint-close / { sub(/^bytes=/, "", $2); print $2 }' "$a_output")
a_close_digest=$(awk '/^event=checkpoint-close / { sub(/^sha256=/, "", $3); print $3 }' "$a_output")
case $a_close_bytes in ''|*[!0-9]*) fail invalid-checkpoint-length ;; esac
case $a_close_digest in *[!0-9a-f]*) fail invalid-checkpoint-digest ;; esac
if [ "${#a_close_digest}" -ne 64 ] || [ ! -f "$checkpoint" ] ||
   [ "$(wc -c < "$checkpoint" | tr -d '[:space:]')" != "$a_close_bytes" ] ||
   [ "$(sha256_file "$checkpoint")" != "$a_close_digest" ]; then
  fail checkpoint-byte-mismatch
fi
append_event "event=checkpoint-close bytes=$a_close_bytes sha256=$a_close_digest"

a_r3_digest=$(awk '/^event=selected-save-commit-r3 / { for (i = 1; i <= NF; ++i) if ($i ~ /^sha256=/) { sub(/^sha256=/, "", $i); print $i } }' "$a_output")
a_r3_ack_digest=$(awk '/^event=selected-save-commit-r3 / { for (i = 1; i <= NF; ++i) if ($i ~ /^ack-save-sha256=/) { sub(/^ack-save-sha256=/, "", $i); print $i } }' "$a_output")
if [ -z "$a_r3_digest" ] || [ -z "$a_r3_ack_digest" ]; then
  fail a-r3-event-identity
fi

if [ ! -f "$selected_save" ] || [ ! -f "$acknowledgment" ]; then
  fail r3-save-or-ack-missing
fi
r3_bytes=$(wc -c < "$selected_save" | tr -d '[:space:]')
r3_digest=$(sha256_file "$selected_save") || fail sha256-tool-unavailable
r3_ack_digest=$(sha256_file "$acknowledgment") || fail sha256-tool-unavailable
if [ "$r3_digest" != "$a_r3_digest" ] ||
   [ "$a_r3_ack_digest" != "$r3_digest" ]; then
  fail a-r3-readback-mismatch
fi
append_event "event=selected-save-r3 bytes=$r3_bytes sha256=$r3_digest ack-sha256=$r3_ack_digest"
awk '/^event=selected-save-commit-r3 / || /^event=checkpoint-close / ||
     /^event=instance-destroyed$/ { print "verified_lifecycle=" $0 }' \
  "$a_output" >> "$events"
append_event "verified_lifecycle=process_a_pass=$(awk '/^muhtari_api8_process_a: .*result=pass$/ { print; exit }' "$a_output")"
append_event "verified_lifecycle=event=a-exit status=$a_status"

# B is not even launched until A's close, destruction and orderly zero exit
# have been checked and its closed checkpoint independently hashed above.
append_event 'event=b-start'
launch_child b "$b_output"
b_pid=$LF_PROCESS_TREE_ACTIVE_PID
wait_child "$b_pid"
b_status=$?
if [ "$b_status" -eq 124 ]; then
  append_event 'event=b-timeout'
  stop_active_child
  fail b-timeout
fi
finish_child_group "$b_pid"
if [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -ne 0 ]; then
  fail b-process-tree-cleanup
fi
append_event "event=b-exit status=$b_status"
if [ -n "${LF_FRESH_PROCESS_B_MODE:-}" ]; then
  expected_mismatch=$LF_FRESH_PROCESS_B_MODE
  case $expected_mismatch in
    frame|video|audio) ;;
    media) expected_mismatch=battery ;;
    *) fail invalid-oracle-control-mode ;;
  esac
  if [ "$b_status" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" "^event=oracle-control name=.* mismatch=$expected_mismatch result=expected-failure$")" -ne 1 ] ||
     [ "$(exact_event_count "$b_output" '^muhtari_api8_process_b: .*result=pass$')" -ne 0 ] ||
     [ "$(exact_event_count "$b_output" '^event=guest-r3-host-save-r2 .*guest-media=r3 host-ack=r2 result=pass$')" -ne 1 ]; then
    fail "oracle-control-$LF_FRESH_PROCESS_B_MODE"
  fi
  append_event "event=oracle-control name=$LF_FRESH_PROCESS_B_MODE mismatch=$expected_mismatch result=pass"
  append_event "event=supervisor-oracle-control route=$route result=pass"
  exit 0
fi
if [ "$b_status" -ne 0 ]; then
  fail b-nonzero
fi

if [ "$(exact_event_count "$b_output" '^event=checkpoint-reopened ')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=selected-save-imported-r3 .*before-positive-advance=pass result=pass$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=battery-restore-r2 .*selected-r3-preserved=pass result=pass$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=pre-rename-failure-preserved-r3 .*stage-cleanup=pass result=pass$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=save-r2-readback-acknowledged .*readback=exact result=pass$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=guest-r3-host-save-r2 .*guest-media=r3 host-ack=r2 result=pass$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^event=instance-destroyed$')" -ne 1 ] ||
   [ "$(exact_event_count "$b_output" '^muhtari_api8_process_b: .*result=pass$')" -ne 1 ]; then
  fail b-required-evidence
fi
refusal_cases='zero_extent null_zero_extent truncated_header truncated_native_payload trailing_byte malformed_magic malformed_version malformed_header header_integrity zero_total_extent overflow_total_extent inconsistent_total_extent zero_native_extent overflow_native_extent inconsistent_native_extent malformed_content_extent wrong_libfuturo_build wrong_core_build wrong_native_format wrong_core_abi wrong_behavior_revision wrong_api_revision wrong_profile wrong_configuration wrong_options wrong_content_digest native_corruption native_semantic_invalid same_length_content'
for refusal_case in $refusal_cases; do
  refusal_count=$(exact_event_count "$b_output" \
    "^event=battery-b-refusal name=$refusal_case status=[0-9][0-9]* .*preservation=continuation,full-media,generation,selected-save,ack result=pass$")
  if [ "$refusal_count" -ne 1 ]; then
    fail "b-refusal-$refusal_case"
  fi
  awk -v name="$refusal_case" \
    '$0 ~ "^event=battery-b-refusal name=" name " " &&
     $0 ~ " preservation=continuation,full-media,generation,selected-save,ack result=pass$" { print }' \
    "$b_output" >> "$events"
done
if [ "$(exact_event_count "$b_output" '^event=battery-b-refusal name=native_semantic_invalid .*outer=valid native-checksum=valid validator=invalid-state preservation=continuation,full-media,generation,selected-save,ack result=pass$')" -ne 1 ]; then
  fail b-semantic-refusal-evidence
fi
if [ "$(exact_event_count "$b_output" '^event=battery-b-refusal name=same_length_content .*same-length=pass different-sha256=pass snapshot-operations=unsupported preservation=continuation,full-media,generation,selected-save,ack result=pass$')" -ne 1 ]; then
  fail b-content-identity-control
fi
b_import_digest=$(awk '/^event=selected-save-imported-r3 / { sub(/^sha256=/, "", $2); print $2 }' "$b_output")
b_failure_digest=$(awk '/^event=pre-rename-failure-preserved-r3 / { sub(/^sha256=/, "", $2); print $2 }' "$b_output")
b_reopen_bytes=$(awk '/^event=checkpoint-reopened / { sub(/^bytes=/, "", $2); print $2 }' "$b_output")
b_reopen_digest=$(awk '/^event=checkpoint-reopened / { sub(/^sha256=/, "", $3); print $3 }' "$b_output")
b_reopen_line=$(awk '/^event=checkpoint-reopened / { print NR }' "$b_output")
b_import_line=$(awk '/^event=selected-save-imported-r3 / { print NR }' "$b_output")
b_restore_line=$(awk '/^event=battery-restore-r2 / { print NR }' "$b_output")
b_failure_line=$(awk '/^event=pre-rename-failure-preserved-r3 / { print NR }' "$b_output")
b_commit_line=$(awk '/^event=save-r2-readback-acknowledged / { print NR }' "$b_output")
b_guest_line=$(awk '/^event=guest-r3-host-save-r2 / { print NR }' "$b_output")
b_destroy_line=$(awk '/^event=instance-destroyed$/ { print NR }' "$b_output")
b_pass_line=$(awk '/^muhtari_api8_process_b: .*result=pass$/ { print NR }' "$b_output")
if [ -z "$b_import_digest" ] || [ "$b_import_digest" != "$r3_digest" ] ||
   [ -z "$b_failure_digest" ] || [ "$b_failure_digest" != "$r3_digest" ] ||
   [ "$b_reopen_bytes" != "$a_close_bytes" ] ||
   [ "$b_reopen_digest" != "$a_close_digest" ] ||
   [ -z "$b_reopen_line" ] || [ -z "$b_import_line" ] ||
   [ "$b_reopen_line" -ge "$b_import_line" ] ||
   [ "$b_import_line" -ge "$b_restore_line" ] ||
   [ "$b_restore_line" -ge "$b_failure_line" ] ||
   [ "$b_failure_line" -ge "$b_commit_line" ] ||
   [ "$b_commit_line" -ge "$b_guest_line" ] ||
   [ "$b_guest_line" -ge "$b_destroy_line" ] ||
   [ "$b_destroy_line" -ge "$b_pass_line" ]; then
  fail r3-custody-mismatch
fi
if [ ! -f "$selected_save" ] || [ ! -f "$acknowledgment" ]; then
  fail final-save-or-ack-missing
fi
final_save_digest=$(sha256_file "$selected_save") || fail sha256-tool-unavailable
final_ack_digest=$(sha256_file "$acknowledgment") || fail sha256-tool-unavailable
b_commit_digest=$(awk '/^event=save-r2-readback-acknowledged / { sub(/^sha256=/, "", $2); print $2 }' "$b_output")
final_ack_save_digest=$(awk -F= '$1 == "save-sha256" { print $2 }' "$acknowledgment")
b_commit_ack_digest=$(awk '/^event=save-r2-readback-acknowledged / { for (i = 1; i <= NF; ++i) if ($i ~ /^ack-save-sha256=/) { sub(/^ack-save-sha256=/, "", $i); print $i } }' "$b_output")
if [ -z "$b_commit_digest" ] || [ "$final_save_digest" != "$b_commit_digest" ] ||
   [ -z "$final_ack_save_digest" ] || [ "$final_ack_save_digest" != "$final_save_digest" ] ||
   [ -z "$b_commit_ack_digest" ] || [ "$b_commit_ack_digest" != "$final_save_digest" ]; then
  fail final-r2-readback-mismatch
fi
awk '/^event=checkpoint-reopened / ||
     /^event=selected-save-imported-r3 / ||
     /^event=battery-restore-r2 / ||
     /^event=pre-rename-failure-preserved-r3 / ||
     /^event=battery-b-refusal / ||
     /^event=save-r2-readback-acknowledged / ||
     /^event=guest-r3-host-save-r2 / ||
     /^event=instance-destroyed$/ { print "verified_lifecycle=" $0 }' \
  "$b_output" >> "$events"
append_event "verified_lifecycle=process_b_pass=$(awk '/^muhtari_api8_process_b: .*result=pass$/ { print; exit }' "$b_output")"
append_event "verified_lifecycle=event=b-exit status=$b_status"
append_event "event=selected-save-r2 bytes=$(wc -c < "$selected_save" | tr -d '[:space:]') sha256=$final_save_digest ack-sha256=$final_ack_digest"
append_event "event=supervisor-success route=$route result=pass"
