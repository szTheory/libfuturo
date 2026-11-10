# Shell-side status and cleanup protocol for the LaunchServices smoke
# supervisor. AppKit owns the NSRunningApplication; this file never signals an
# application PID.

# Parse the supervisor's atomic status record. The app exit code is unavailable
# through NSRunningApplication, so `terminated` means only that the exact
# returned instance reports isTerminated. Result markers are validated
# separately by native_smoke_validate_app_result.
native_smoke_read_supervisor_state() {
  smoke_status_path=$1
  smoke_supervisor_state=
  smoke_supervisor_ack=
  smoke_supervisor_error=
  if smoke_status_line=$(cat "$smoke_status_path" 2>/dev/null); then
    :
  else
    return 2
  fi

  set -f
  set -- $smoke_status_line
  set +f
  smoke_supervisor_state=${1:-}
  case "$smoke_supervisor_state" in
    starting|running|terminated)
      [ "$#" -eq 2 ] || return 2
      smoke_supervisor_ack=$2
      case "$smoke_supervisor_ack" in ''|*[!0-9]*) return 2 ;; esac
      while [ "${smoke_supervisor_ack#0}" != "$smoke_supervisor_ack" ]; do
        smoke_supervisor_ack=${smoke_supervisor_ack#0}
      done
      [ -n "$smoke_supervisor_ack" ] || smoke_supervisor_ack=0
      [ "${#smoke_supervisor_ack}" -le 18 ] || return 2
      ;;
    unknown)
      [ "$#" -eq 3 ] || return 2
      smoke_supervisor_ack=$2
      smoke_supervisor_error=$3
      case "$smoke_supervisor_ack" in ''|*[!0-9]*) return 2 ;; esac
      case "$smoke_supervisor_error" in ''|*[!0-9]*) return 2 ;; esac
      while [ "${smoke_supervisor_ack#0}" != "$smoke_supervisor_ack" ]; do
        smoke_supervisor_ack=${smoke_supervisor_ack#0}
      done
      [ -n "$smoke_supervisor_ack" ] || smoke_supervisor_ack=0
      [ "${#smoke_supervisor_ack}" -le 18 ] || return 2
      [ "${#smoke_supervisor_error}" -le 10 ] || return 2
      ;;
    *) return 2 ;;
  esac
}

native_smoke_validate_app_result() {
  smoke_result_path=$1
  smoke_expected_result=$2
  smoke_expected_production_view=$3
  if [ ! -f "$smoke_result_path" ]; then
    echo 'native host smoke: app produced no result file' >&2
    return 1
  fi
  if ! grep -Fqx "$smoke_expected_result" "$smoke_result_path"; then
    echo 'native host smoke: app produced an unexpected result' >&2
    cat "$smoke_result_path" >&2
    return 1
  fi
  if ! grep -Fqx "$smoke_expected_production_view" "$smoke_result_path"; then
    echo 'native host smoke: production-view result marker is missing' >&2
    return 1
  fi
  native_smoke_validate_audio_result "$smoke_result_path"
}

native_smoke_validate_audio_result() {
  smoke_result_path=$1
  smoke_audio_line_count=0
  smoke_audio_line=
  while IFS= read -r smoke_result_line; do
    case "$smoke_result_line" in
      'installed_macos_host: audio='*)
        smoke_audio_line_count=$((smoke_audio_line_count + 1))
        smoke_audio_line=$smoke_result_line
        ;;
    esac
  done < "$smoke_result_path"
  if [ "$smoke_audio_line_count" -ne 1 ]; then
    echo 'native host smoke: live-audio result marker is missing or duplicated' >&2
    return 1
  fi
  if ! printf '%s\n' "$smoke_audio_line" | awk '
      function integer_field(field, key, allow_zero, value) {
        if (index(field, key "=") != 1) return 0
        value = substr(field, length(key) + 2)
        if (value !~ /^[0-9]+$/) return 0
        return allow_zero || value + 0 > 0
      }
      {
        if (NF != 11 || $1 != "installed_macos_host:" ||
            $2 != "audio=system" ||
            $3 != "source=s16-native,mono,48000" ||
            !integer_field($4, "output-rate", 0) ||
            !integer_field($5, "output-channels", 0) ||
            !integer_field($6, "dataPlayedBack", 0) ||
            !integer_field($7, "pool-drops", 1) ||
            !integer_field($8, "prime-delay-ms", 1) ||
            $9 != "player-stopped=true" ||
            $10 != "engine-stopped=true" || $11 != "result=pass") {
          exit 1
        }
      }
    '; then
    echo 'native host smoke: live-audio result marker is invalid' >&2
    return 1
  fi
}

# Return 0 while the retained app instance is starting or running, 1 only after
# NSRunningApplication.isTerminated was confirmed, and 2 for unknown state.
native_smoke_supervisor_app_is_running() {
  if native_smoke_read_supervisor_state "$1"; then
    :
  else
    echo 'native host smoke: supervisor state is missing or malformed' >&2
    return 2
  fi
  case "$smoke_supervisor_state" in
    starting|running) return 0 ;;
    terminated) return 1 ;;
    unknown)
      echo 'native host smoke: exact app instance state is unknown' >&2
      return 2
      ;;
    *) return 2 ;;
  esac
}

# The running callback returns 0 while the instance is active, 1 after its
# termination is confirmed, and 2 when state is unknown. A timeout returns 1.
native_smoke_wait_for_app_termination() {
  smoke_running_command=$1
  smoke_sleep_command=$2
  smoke_wait_attempts=$3
  smoke_wait_attempt=0

  while [ "$smoke_wait_attempt" -lt "$smoke_wait_attempts" ]; do
    if "$smoke_running_command"; then
      :
    else
      smoke_running_status=$?
      case "$smoke_running_status" in
        1) return 0 ;;
        *) return 2 ;;
      esac
    fi
    if ! "$smoke_sleep_command" 0.1; then
      echo 'native host smoke: sleep failed while checking app termination' >&2
      return 2
    fi
    smoke_wait_attempt=$((smoke_wait_attempt + 1))
  done

  if "$smoke_running_command"; then
    return 1
  else
    smoke_running_status=$?
    case "$smoke_running_status" in
      1) return 0 ;;
      *) return 2 ;;
    esac
  fi
}

# Ask the supervisor to call terminate first. Only after bounded grace does the
# second request permit forceTerminate on that same NSRunningApplication.
native_smoke_terminate_supervised_app() {
  smoke_request_command=$1
  smoke_running_command=$2
  smoke_sleep_command=$3
  smoke_term_attempts=$4
  smoke_force_attempts=$5

  if "$smoke_request_command" TERMINATE; then
    :
  else
    return $?
  fi
  if native_smoke_wait_for_app_termination \
      "$smoke_running_command" "$smoke_sleep_command" "$smoke_term_attempts"; then
    return 0
  else
    smoke_wait_status=$?
    [ "$smoke_wait_status" -eq 1 ] || return "$smoke_wait_status"
  fi

  if "$smoke_request_command" FORCE_TERMINATE; then
    :
  else
    return $?
  fi
  native_smoke_wait_for_app_termination \
    "$smoke_running_command" "$smoke_sleep_command" "$smoke_force_attempts"
}

# Reap the supervisor only after the exact app instance reports termination.
native_smoke_stop_supervised_app() {
  smoke_supervisor_pid=$1
  smoke_request_command=$2
  smoke_running_command=$3
  smoke_sleep_command=$4
  smoke_term_attempts=$5
  smoke_force_attempts=$6
  smoke_reap_command=$7

  if native_smoke_terminate_supervised_app \
      "$smoke_request_command" "$smoke_running_command" \
      "$smoke_sleep_command" "$smoke_term_attempts" \
      "$smoke_force_attempts"; then
    if "$smoke_reap_command" "$smoke_supervisor_pid"; then
      return 0
    fi
    echo 'native host smoke: supervisor did not exit successfully after confirming app termination' >&2
    return 2
  else
    return $?
  fi
}

native_smoke_cleanup_failed_run() {
  smoke_stop_supervisor_command=$1
  smoke_preserve_scratch_command=$2
  smoke_scratch_path=$3

  if "$smoke_stop_supervisor_command"; then
    "$smoke_preserve_scratch_command" "$smoke_scratch_path" || true
    return 0
  else
    smoke_stop_status=$?
  fi

  "$smoke_preserve_scratch_command" "$smoke_scratch_path" || true
  return "$smoke_stop_status"
}

native_smoke_cleanup_successful_run() {
  smoke_stop_supervisor_command=$1
  smoke_preserve_scratch_command=$2
  smoke_remove_scratch_command=$3
  smoke_scratch_path=$4
  smoke_success_report_command=${5:-:}

  if "$smoke_stop_supervisor_command"; then
    if "$smoke_remove_scratch_command" "$smoke_scratch_path"; then
      "$smoke_success_report_command"
      return $?
    else
      smoke_remove_status=$?
      "$smoke_preserve_scratch_command" "$smoke_scratch_path" || true
      return "$smoke_remove_status"
    fi
  else
    smoke_stop_status=$?
  fi

  "$smoke_preserve_scratch_command" "$smoke_scratch_path" || true
  return "$smoke_stop_status"
}
