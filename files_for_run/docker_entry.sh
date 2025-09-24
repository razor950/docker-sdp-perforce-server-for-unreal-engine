#!/bin/bash
set -eu

# Stop perforce service.
function exit_script(){
  echo "Caught SIGTERM"
  /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop
  echo "Perforce service stopped. Exiting."
  exit 0
}

# Trap the SIGTERM signal so we can gracefully stop perforce service when docker stop is called.
trap exit_script SIGTERM


SETUP_COMPLETE_MARKER="/p4/.sdp_setup_complete"

# --- Setup SDP instance
if [[ -f "$SETUP_COMPLETE_MARKER" ]]; then
  echo "SDP instance already configured. Skipping setup."
else
  echo "Setting up SDP instance..."
  if bash /usr/local/bin/setup_sdp.sh; then
    echo "SDP setup completed successfully"
    # Create marker file to indicate setup is complete
    touch "$SETUP_COMPLETE_MARKER"
  else
    echo "Failed to set up SDP instance" >&2
    exit 1
  fi
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

# --- Start p4d for normal operation
echo "Starting Perforce service for normal operation..."
if ! /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start; then
  echo "Failed to start Perforce service" >&2
  exit 1
fi

# --- Verify p4d is running
sleep 3
if /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status; then
  echo "✅ Perforce service is running successfully"
  echo ""
  echo "🔗 Connection Details:"
  echo "   Server URL: ssl:$(hostname -i):1666 (internal)"
  echo "   External URL: ssl:your-nas-ip:1666"
  echo "   Default User: perforce"
  echo "   Default Password: F@stSCM! (change on first login)"
  echo ""
  echo "📋 Clients need to trust the SSL certificate:"
  echo "   p4 trust -y"
  echo ""
  echo "🔐 SSL Fingerprint for verification:"
  if [[ -f /p4/ssl/certificate.txt ]]; then
    sudo -u perforce openssl x509 -in /p4/ssl/certificate.txt -fingerprint -sha256 -noout 2>/dev/null | cut -d'=' -f2 || echo "   Could not extract fingerprint"
  fi
else
  echo "❌ Perforce service failed to start properly"
  exit 1
fi

echo ""
echo "Perforce service started successfully. Container ready."
echo "Entering sleep mode to keep container running..."

#--- send sleep into the background, then wait for it.
sleep infinity &
#--- "wait" will wait until the command you sent to the background terminates, which will be never.
#--- "wait" is a bash built-in, so bash can now handle the signals sent by "docker stop"
wait