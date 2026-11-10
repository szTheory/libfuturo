restore_original_paths() {
  restore_error=0
  chmod "$ROOT_MODE" "$ROOT_DIR" 2>/dev/null || restore_error=1
  chmod "$BUILD_MODE" "$BUILD_DIR" 2>/dev/null || restore_error=1
  if [ "$restore_error" -ne 0 ]; then
    echo "relocation consumer: could not restore original source/build permissions" >&2
    return 1
  fi
  PATHS_PROTECTED=0
}

probe_original_paths() {
  /bin/sh -c '
    source_dir=$1; build_dir=$2; stage_dir=$3
    source_file=$4; build_file=$5; stage_file=$6
    for path in "$source_dir" "$build_dir"; do
      if (CDPATH= cd "$path" >/dev/null 2>&1); then
        printf "original directory remained traversable: %s\n" "$path" >&2
        exit 1
      fi
    done
    for path in "$source_file" "$build_file"; do
      if [ -r "$path" ]; then
        printf "original file remained readable: %s\n" "$path" >&2
        exit 1
      fi
    done
    if [ -e "$stage_dir" ] || [ -e "$stage_file" ]; then
      printf "staging probe path was expected to be absent: %s %s\n" \
        "$stage_dir" "$stage_file" >&2
      exit 1
    fi
  ' probe "$1" "$2" "$3" "$1/CMakeLists.txt" "$2/CMakeCache.txt" "$4"
}

protect_original_paths() {
  PATHS_PROTECTED=1
  if ! chmod 000 "$BUILD_DIR" || ! chmod 000 "$ROOT_DIR"; then
    echo "relocation consumer: could not protect original source/build permissions" >&2
    return 1
  fi
  if command -v record_protected_path_diagnostics >/dev/null 2>&1; then
    if ! record_protected_path_diagnostics; then
      echo "relocation consumer: could not record protected-path diagnostics" >&2
      return 1
    fi
  fi
}

run_bounded() {
  label=$1
  timeout_seconds=$2
  shift 2

  LF_PROCESS_TREE_ACTIVE_PID=
  LF_PROCESS_TREE_CANCEL_SIGNAL=none
  LF_PROCESS_TREE_CLEANUP_ACTIVE=0
  LF_PROCESS_TREE_CLEANUP_FAILED=0
  bounded_cancel_handler() {
    cancel_signal=$1
    if [ "$label" = macos-host ] && [ -n "${CASE_ROOT:-}" ]; then
      if [ ! -f "$CASE_ROOT/cleanup-started.txt" ]; then
        printf 'reason=signal\nsignal=%s\nstarted_epoch=%s\n' \
          "$cancel_signal" "$(date +%s)" > "$CASE_ROOT/cleanup-started.txt"
      fi
    fi
    lf_process_tree_cancel_handler "$cancel_signal"
  }
  trap 'bounded_cancel_handler HUP' HUP
  trap 'bounded_cancel_handler INT' INT
  trap 'bounded_cancel_handler TERM' TERM

  lf_process_tree_start "$@" > "$SCRATCH/$label.log" 2>&1
  command_pid=$LF_PROCESS_TREE_ROOT
  LF_PROCESS_TREE_ACTIVE_PID=$command_pid
  started_at=$(date +%s)
  timed_out=0
  cleanup_failed=0
  while kill -0 "$command_pid" 2>/dev/null; do
    [ "$LF_PROCESS_TREE_CANCEL_SIGNAL" = none ] || break
    now=$(date +%s)
    if [ $((now - started_at)) -ge "$timeout_seconds" ]; then
      timed_out=1
      LF_PROCESS_TREE_CLEANUP_ACTIVE=1
      if [ "$label" = macos-host ] && [ -n "${CASE_ROOT:-}" ]; then
        printf 'reason=timeout\ntimeout_seconds=%s\nstarted_epoch=%s\n' \
          "$timeout_seconds" "$(date +%s)" > "$CASE_ROOT/cleanup-started.txt"
      fi
      if ! lf_process_tree_terminate "$command_pid"; then
        cleanup_failed=1
      else
        LF_PROCESS_TREE_ACTIVE_PID=
      fi
      LF_PROCESS_TREE_CLEANUP_ACTIVE=0
      break
    fi
    /bin/sleep 1 || true
  done

  if [ "$LF_PROCESS_TREE_CANCEL_SIGNAL" != none ] &&
      [ "$LF_PROCESS_TREE_ACTIVE_PID" = "$command_pid" ] &&
      [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -eq 0 ] &&
      [ "$LF_PROCESS_TREE_CLEANUP_ACTIVE" -eq 0 ] &&
      kill -0 "$command_pid" 2>/dev/null; then
    LF_PROCESS_TREE_CLEANUP_ACTIVE=1
    if ! lf_process_tree_terminate "$command_pid"; then
      cleanup_failed=1
    else
      LF_PROCESS_TREE_ACTIVE_PID=
    fi
    LF_PROCESS_TREE_CLEANUP_ACTIVE=0
  fi

  if wait "$command_pid"; then
    command_status=0
  else
    command_status=$?
  fi
  LF_PROCESS_TREE_ACTIVE_PID=
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  bounded_signal=$LF_PROCESS_TREE_CANCEL_SIGNAL
  if [ "$label" = macos-host ]; then
    if [ -z "$bounded_signal" ]; then
      bounded_signal=none
    fi
    elapsed_seconds=$(( $(date +%s) - started_at ))
    printf 'format=libfuturo-host-ctest-process-v1\nctest_pid=%s\nexit_status=%s\nsignal=%s\ntimed_out=%s\nelapsed_seconds=%s\n' \
      "$command_pid" "$command_status" "$bounded_signal" \
      "$([ "$timed_out" -eq 1 ] && printf yes || printf no)" \
      "$elapsed_seconds" > "$SCRATCH/macos-host.process-facts.txt"
  fi
  if [ "$LF_PROCESS_TREE_CLEANUP_FAILED" -ne 0 ]; then
    cleanup_failed=1
  fi
  if [ "$cleanup_failed" -ne 0 ]; then
    echo "relocation consumer: $label cleanup did not stop its process group" >&2
    return 125
  fi
  case "$bounded_signal" in
    HUP) return 129 ;;
    INT) return 130 ;;
    TERM) return 143 ;;
  esac
  if [ "$timed_out" -eq 1 ]; then
    echo "relocation consumer: $label exceeded ${timeout_seconds}s" >&2
    return 124
  fi
  if [ "$command_status" -ne 0 ]; then
    echo "relocation consumer: $label failed (exit $command_status)" >&2
    cat "$SCRATCH/$label.log" >&2
    return "$command_status"
  fi
}

run_isolated_stage() {
  stage_name=$1
  timeout_limit=$2
  shift 2
  if ! protect_original_paths; then
    if ! restore_original_paths; then
      echo "relocation consumer: $stage_name could not restore permissions after protection failure" >&2
      return 1
    fi
    return 1
  fi
  if ! probe_original_paths "$ROOT_DIR" "$BUILD_DIR" "$STAGE_ROOT" \
      "$STAGE_ROOT/prefix/lib/cmake/libfuturo/libfuturoConfig.cmake"; then
    if ! restore_original_paths; then
      echo "relocation consumer: $stage_name could not restore original permissions after isolation probe failure" >&2
      return 1
    fi
    echo "relocation consumer: $stage_name isolation probe did not block original paths" >&2
    return 1
  fi
  if run_bounded "$stage_name" "$timeout_limit" "$@"; then
    stage_status=0
  else
    stage_status=$?
  fi
  if ! restore_original_paths; then
    echo "relocation consumer: $stage_name could not restore original permissions after stage" >&2
    return 1
  fi
  [ "$stage_status" -eq 0 ] || return "$stage_status"
  printf 'isolation_stage=%s checked_paths=checkout,build,staging availability=unavailable,unavailable,unavailable result=passed\n' \
    "$stage_name" >> "$REPORT_TMP"
}
