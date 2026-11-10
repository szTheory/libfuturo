# Cleanup helpers for bounded process trees. The launched command gets its own
# process group, so descendants inherit a stable group ID even if their parent
# exits or forks while cleanup is in progress.

lf_process_tree_start() {
  case $- in
    *m*) lf_start_restore_monitor=1 ;;
    *) lf_start_restore_monitor=0 ;;
  esac
  set -m
  "$@" &
  LF_PROCESS_TREE_ROOT=$!
  if [ "$lf_start_restore_monitor" -eq 0 ]; then
    set +m
  fi
}

lf_process_tree_signal_group() {
  lf_signal_name=$1
  lf_signal_root=$2
  kill -"$lf_signal_name" -- "-$lf_signal_root" 2>/dev/null || true
}

lf_process_tree_begin_cleanup() {
  lf_begin_root=$1
  lf_process_tree_signal_group TERM "$lf_begin_root"
}

lf_process_tree_finish_cleanup() {
  lf_finish_root=$1

  # Keep the process group alive through the grace period. A descendant may
  # still fork after TERM, and remains in this group even if the leader exits.
  sleep 1
  sleep 1

  # A process group remains attached to its PGID while any member exists, so
  # this also reaches descendants whose original parent has already exited.
  if kill -0 -- "-$lf_finish_root" 2>/dev/null; then
    lf_process_tree_signal_group KILL "$lf_finish_root"
  fi

  # Every caller owns the launched command as its direct child.
  wait "$lf_finish_root" 2>/dev/null || true
  for lf_finish_attempt in 1 2 3 4 5; do
    if ! kill -0 -- "-$lf_finish_root" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

lf_process_tree_terminate() {
  lf_terminate_root=$1
  lf_process_tree_begin_cleanup "$lf_terminate_root"
  lf_process_tree_finish_cleanup "$lf_terminate_root"
}

lf_process_tree_cancel_handler() {
  LF_PROCESS_TREE_CANCEL_SIGNAL=$1
  lf_cancel_root=${LF_PROCESS_TREE_ACTIVE_PID:-}
  lf_cancel_active=${LF_PROCESS_TREE_CLEANUP_ACTIVE:-0}
  if [ -n "$lf_cancel_root" ] && [ "$lf_cancel_active" -eq 0 ]; then
    LF_PROCESS_TREE_CLEANUP_ACTIVE=1
    if ! lf_process_tree_terminate "$lf_cancel_root"; then
      LF_PROCESS_TREE_CLEANUP_FAILED=1
    else
      LF_PROCESS_TREE_ACTIVE_PID=
    fi
    LF_PROCESS_TREE_CLEANUP_ACTIVE=0
  fi
  return 0
}
