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

# Set up the SDP instance if necessary.
if ! bash /usr/local/bin/setup_sdp.sh; then
  echo "Failed to set up SDP instance" >&2
  exit 1
fi

# Start perforce service.
if ! /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start; then
  echo "Failed to start Perforce service" >&2
  exit 1
fi

echo "Perforce service started. Entering sleep mode."

#--- send sleep into the background, then wait for it.
sleep infinity &
#--- "wait" will wait until the command you sent to the background terminates, which will be never.
#--- "wait" is a bash built-in, so bash can now handle the signals sent by "docker stop"
wait