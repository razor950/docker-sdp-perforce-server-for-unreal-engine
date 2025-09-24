#!/bin/bash
set -euo pipefail

# Default instance if not provided
SDP_INSTANCE=${SDP_INSTANCE:-1}

# Graceful stop with timeout + hard kill fallback
graceful_stop() {
  local timeout="${1:-20}"   # seconds
  echo "Stopping Perforce (graceful, timeout ${timeout}s)..."

  # Try init stop; don't fail the handler if it returns non-zero
  /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop || true

  # Try to discover a p4d PID
  local pidfile=""
  for cand in "/p4/${SDP_INSTANCE}/tmp/p4d.pid" \
              "/p4/${SDP_INSTANCE}/logs/p4d.pid" \
              "/p4/${SDP_INSTANCE}/p4d.pid"; do
    [[ -s "$cand" ]] && { pidfile="$cand"; break; }
  done

  local pid=""
  [[ -n "$pidfile" ]] && pid="$(cat "$pidfile" 2>/dev/null || true)"

  # Fallback to pgrep if no pid from file
  if [[ -z "${pid:-}" ]]; then
    pid="$(pgrep -o -f "/p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}.*--daemonsafe" || true)"
  fi

  # Wait up to timeout, then SIGKILL if still present
  if [[ -n "${pid:-}" ]]; then
    for _ in $(seq 1 "$timeout"); do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "Perforce exited cleanly."
        return 0
      fi
      sleep 1
    done
    echo "Perforce still running; sending SIGKILL to PID $pid"
    kill -9 "$pid" 2>/dev/null || true
  fi
}

# Stop handler
exit_script() {
  echo "Caught termination signal"
  graceful_stop 20
  # stop background sleep so `wait` unblocks
  [[ -n "${SLEEP_PID:-}" ]] && kill "${SLEEP_PID}" 2>/dev/null || true
  echo "Perforce service stopped. Exiting."
  exit 0
}

# Trap common termination signals
trap exit_script SIGTERM SIGINT SIGHUP

# --- Setup SDP instance
if ! bash /usr/local/bin/setup_sdp.sh; then
  echo "Failed to set up SDP instance" >&2
  exit 1
fi

# --- Optional backup cron job
if [[ -n "${BACKUP_DESTINATION:-}" ]]; then
  echo "Setting up backup cron job..."
  if ! bash /usr/local/bin/setup_backup_cron.sh; then
    echo "Warning: Failed to set up backup cron job, but continuing startup..." >&2
  fi
else
  echo "BACKUP_DESTINATION not set, skipping backup setup"
fi

# --- Start p4d
if ! /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start; then
  echo "Failed to start Perforce service" >&2
  exit 1
fi

echo "Perforce service started. Entering sleep mode."

# keep PID 1 alive but responsive to traps
sleep infinity & SLEEP_PID=$!
wait "$SLEEP_PID"
