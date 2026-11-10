#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
supervisor=${1:-$script_dir/muhtari_fresh_process_supervisor.sh}
consumer=${2:-}

fixture_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    sha256sum "$1" | awk '{ print $1 }'
  fi
}

fixture_a() {
  checkpoint=$2
  save=$3
  ack=$4
  mode=$5
  printf 'private checkpoint fixture\n' > "$checkpoint" || return 2
  printf 'private selected R3 fixture\n' > "$save" || return 2
  digest=$(fixture_digest "$save") || return 2
  printf 'save-sha256=%s\ngeneration=3\n' "$digest" > "$ack" || return 2
  bytes=$(wc -c < "$checkpoint" | tr -d '[:space:]')
  checkpoint_digest=$(fixture_digest "$checkpoint") || return 2
  case $mode in
    a-timeout|a-cancelled)
      if [ -n "${LF_FRESH_PROCESS_TEST_MARKER:-}" ]; then
        pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
        printf '%s\n' "$pgid" > "${LF_FRESH_PROCESS_TEST_MARKER:?}"
      fi
      sleep 30
      return $?
      ;;
  esac
  printf 'event=selected-save-commit-r3 bytes=%s sha256=%s ack-save-sha256=%s generation=3 readback=exact result=pass\n' \
    "$(wc -c < "$save" | tr -d '[:space:]')" "$digest" "$digest"
  case $mode in
    a-reordered)
      printf '%s\n' 'event=instance-destroyed'
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$checkpoint_digest"
      ;;
    a-duplicate-close)
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$checkpoint_digest"
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$checkpoint_digest"
      printf '%s\n' 'event=instance-destroyed'
      ;;
    a-missing-close) printf '%s\n' 'event=instance-destroyed' ;;
    a-missing-destroy)
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$checkpoint_digest"
      ;;
    a-bad-close)
      printf 'event=checkpoint-close bytes=%s sha256=%064d\n' "$bytes" 1
      printf '%s\n' 'event=instance-destroyed'
      ;;
    *)
      printf 'event=checkpoint-close bytes=%s sha256=%s\n' "$bytes" "$checkpoint_digest"
      printf '%s\n' 'event=instance-destroyed'
      ;;
  esac
  printf '%s\n' 'muhtari_api8_process_a: frames=2 capture=R2 save=R3 result=pass'
  [ "$mode" != a-nonzero ] || return 7
  return 0
}

fixture_b() {
  checkpoint=$2
  save=$3
  ack=$4
  mode=$5
  if [ "$mode" = b-timeout ] || [ "$mode" = b-cancelled ]; then
    if [ -n "${LF_FRESH_PROCESS_TEST_MARKER:-}" ]; then
      pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
      printf '%s\n' "$pgid" > "${LF_FRESH_PROCESS_TEST_MARKER:?}"
    fi
    sleep 30
    return $?
  fi
  checkpoint_bytes=$(wc -c < "$checkpoint" | tr -d '[:space:]')
  checkpoint_digest=$(fixture_digest "$checkpoint") || return 2
  r3_digest=$(fixture_digest "$save") || return 2
  printf 'event=checkpoint-reopened bytes=%s sha256=%s\n' \
    "$checkpoint_bytes" "$checkpoint_digest"
  if [ "$mode" = b-import-late ]; then
    printf 'event=battery-restore-r2 bytes=34816 generation=1 selected-r3-preserved=pass result=pass\n'
    printf 'event=selected-save-imported-r3 sha256=%s bytes=35176 generation=0 before-positive-advance=pass result=pass\n' "$r3_digest"
  elif [ "$mode" != b-missing-import ]; then
    printf 'event=selected-save-imported-r3 sha256=%s bytes=35176 generation=0 before-positive-advance=pass result=pass\n' "$r3_digest"
  fi
  if [ "$mode" != b-missing-restore ] &&
     [ "$mode" != b-import-late ]; then
    printf 'event=battery-restore-r2 bytes=34816 generation=1 selected-r3-preserved=pass result=pass\n'
  fi
  refusal_cases='zero_extent null_zero_extent truncated_header truncated_native_payload trailing_byte malformed_magic malformed_version malformed_header header_integrity zero_total_extent overflow_total_extent inconsistent_total_extent zero_native_extent overflow_native_extent inconsistent_native_extent malformed_content_extent wrong_libfuturo_build wrong_core_build wrong_native_format wrong_core_abi wrong_behavior_revision wrong_api_revision wrong_profile wrong_configuration wrong_options wrong_content_digest native_corruption native_semantic_invalid same_length_content'
  for refusal_case in $refusal_cases; do
    case $refusal_case in
      native_semantic_invalid)
        printf 'event=battery-b-refusal name=%s status=1 outer=valid native-checksum=valid validator=invalid-state preservation=continuation,full-media,generation,selected-save,ack result=pass\n' "$refusal_case"
        ;;
      same_length_content)
        printf 'event=battery-b-refusal name=%s status=2 same-length=pass different-sha256=pass snapshot-operations=unsupported preservation=continuation,full-media,generation,selected-save,ack result=pass\n' "$refusal_case"
        ;;
      *)
        printf 'event=battery-b-refusal name=%s status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n' "$refusal_case"
        ;;
    esac
    if [ "$mode" = b-duplicate-refusal ] && [ "$refusal_case" = zero_extent ]; then
      printf 'event=battery-b-refusal name=%s status=1 preservation=continuation,full-media,generation,selected-save,ack result=pass\n' "$refusal_case"
    fi
  done
  if [ "$mode" != b-missing-prefailure ] && [ "$mode" != b-missing-custody ]; then
    printf 'event=pre-rename-failure-preserved-r3 sha256=%s bytes=35176 stage-cleanup=pass result=pass\n' "$r3_digest"
  fi
  r2_text='private selected R2 fixture'
  printf '%s\n' "$r2_text" > "$save" || return 2
  r2_digest=$(fixture_digest "$save") || return 2
  printf 'save-sha256=%s\ngeneration=1\n' "$r2_digest" > "$ack" || return 2
  if [ "$mode" != b-missing-readback ]; then
    printf 'event=save-r2-readback-acknowledged sha256=%s ack-save-sha256=%s bytes=35176 generation=1 readback=exact result=pass\n' "$r2_digest" "$r2_digest"
  fi
  if [ "$mode" != b-missing-custody ]; then
    printf 'event=guest-r3-host-save-r2 sha256=%s generation=1 guest-media=r3 host-ack=r2 result=pass\n' "$r2_digest"
  fi
  if [ "$mode" != b-missing-destroy ]; then
    printf '%s\n' 'event=instance-destroyed'
  fi
  printf '%s\n' 'muhtari_api8_process_b: loads=1 frame=3 result=pass'
  if [ "$mode" = b-nonzero ]; then return 7; fi
  return 0
}

if [ "${1:-}" = a ] || [ "${1:-}" = b ]; then
  case $1 in
    a) fixture_a "$@" ;;
    b) fixture_b "$@" ;;
  esac
  exit $?
fi

if [ ! -r "$supervisor" ] || [ -z "$consumer" ] || [ ! -x "$consumer" ]; then
  printf 'usage: %s <supervisor-script> <consumer-executable>\n' "$0" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/libfuturo-muhtari-supervisor-controls.XXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM

fail() {
  printf 'muhtari supervisor control failed: %s\n' "$1" >&2
  if [ -n "${2:-}" ] && [ -f "$2" ]; then cat "$2" >&2; fi
  exit 1
}

run_case() {
  name=$1
  expected_status=$2
  timeout=$3
  marker=$scratch/$name.pgid
  output=$scratch/$name.log
  if [ "$name" = a-cancelled ] || [ "$name" = b-cancelled ]; then
    LF_FRESH_PROCESS_TEST_FIXTURE="$script_dir/muhtari_supervisor_controls.sh" \
      LF_FRESH_PROCESS_TEST_MODE="$name" \
      LF_FRESH_PROCESS_TEST_MARKER="$marker" \
      LF_FRESH_PROCESS_TIMEOUT_SECONDS="$timeout" \
      /bin/sh "$supervisor" "$script_dir/muhtari_supervisor_controls.sh" \
        > "$output" 2>&1 &
    supervisor_pid=$!
    attempts=0
    while [ ! -f "$marker" ] && [ "$attempts" -lt 100 ]; do
      kill -0 "$supervisor_pid" 2>/dev/null || break
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if [ ! -f "$marker" ]; then
      kill -TERM "$supervisor_pid" 2>/dev/null || true
      wait "$supervisor_pid" 2>/dev/null || true
      fail "$name fixture did not start" "$output"
    fi
    pgid=$(cat "$marker")
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid"
    actual_status=$?
    attempts=0
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if kill -0 -- "-$pgid" 2>/dev/null; then
      fail "$name left an attributable process group" "$output"
    fi
  else
    LF_FRESH_PROCESS_TEST_FIXTURE="$script_dir/muhtari_supervisor_controls.sh" \
      LF_FRESH_PROCESS_TEST_MODE="$name" \
      LF_FRESH_PROCESS_TEST_MARKER="$marker" \
      LF_FRESH_PROCESS_TIMEOUT_SECONDS="$timeout" \
      /bin/sh "$supervisor" "$script_dir/muhtari_supervisor_controls.sh" \
        > "$output" 2>&1
    actual_status=$?
  fi
  if [ "$actual_status" -ne "$expected_status" ]; then
    fail "$name returned $actual_status, expected $expected_status" "$output"
  fi
  case $name in
    a-timeout|b-timeout)
      if [ ! -f "$marker" ]; then fail "$name fixture did not record its process group" "$output"; fi
      pgid=$(cat "$marker")
      attempts=0
      while kill -0 -- "-$pgid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
      done
      if kill -0 -- "-$pgid" 2>/dev/null; then fail "$name left an attributable process group" "$output"; fi
      ;;
  esac
  case $name in
    a-*)
      if grep -q '^event=b-start$' "$output"; then
        fail "$name launched B before valid A close/destruction/exit" "$output"
      fi
      ;;
    b-*)
      if ! grep -q '^event=b-start$' "$output" ||
         grep -q '^event=supervisor-success route=source result=pass$' "$output"; then
        fail "$name did not fail closed after B start" "$output"
      fi
      ;;
  esac
  return 0
}

run_case a-missing-close 1 5 || exit 1
run_case a-missing-destroy 1 5 || exit 1
run_case a-bad-close 1 5 || exit 1
run_case a-reordered 1 5 || exit 1
run_case a-duplicate-close 1 5 || exit 1
run_case a-nonzero 1 5 || exit 1
run_case a-timeout 1 1 || exit 1
run_case a-cancelled 130 30 || exit 1
run_case b-missing-import 1 5 || exit 1
run_case b-import-late 1 5 || exit 1
run_case b-missing-restore 1 5 || exit 1
run_case b-missing-prefailure 1 5 || exit 1
run_case b-missing-custody 1 5 || exit 1
run_case b-missing-readback 1 5 || exit 1
run_case b-duplicate-refusal 1 5 || exit 1
run_case b-missing-destroy 1 5 || exit 1
run_case b-nonzero 1 5 || exit 1
run_case b-timeout 1 1 || exit 1
run_case b-cancelled 130 30 || exit 1

output=$scratch/valid.log
LF_FRESH_PROCESS_TEST_FIXTURE="$script_dir/muhtari_supervisor_controls.sh" \
  LF_FRESH_PROCESS_TEST_MODE=valid \
  LF_FRESH_PROCESS_TIMEOUT_SECONDS=5 \
  /bin/sh "$supervisor" "$script_dir/muhtari_supervisor_controls.sh" \
    > "$output" 2>&1
status=$?
if [ "$status" -ne 0 ] ||
   ! grep -q '^event=supervisor-success route=source result=pass$' "$output" ||
   ! awk '/^event=a-exit status=0$/ { a=NR } /^event=b-start$/ { b=NR } END { exit !(a > 0 && b > a) }' "$output"; then
  fail 'valid ordered A/B control did not start B after A exit' "$output"
fi

printf '%s\n' 'muhtari_api8_supervisor_controls: lifecycle,ordering,custody,cleanup faults rejected result=pass'
