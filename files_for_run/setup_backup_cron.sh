#!/bin/bash
set -eu

#------------------------------------------------------------------------------
# Setup Weekly Perforce Backup Cron Job
#
# This script sets up a weekly cron job to backup the Perforce server
# Run this script once after the container starts to setup automated backups
#------------------------------------------------------------------------------

SDP_INSTANCE=${SDP_INSTANCE:-1}
BACKUP_DESTINATION=${BACKUP_DESTINATION:-}

# Check if backup destination is configured
if [[ -z "$BACKUP_DESTINATION" ]]; then
    echo "WARNING: BACKUP_DESTINATION environment variable is not set."
    echo "Backups will not be scheduled until this is configured."
    exit 0
fi

# Check if backup destination is accessible
if [[ ! -d "$BACKUP_DESTINATION" ]]; then
    echo "Creating backup destination directory: $BACKUP_DESTINATION"
    mkdir -p "$BACKUP_DESTINATION" || {
        echo "ERROR: Cannot create backup destination: $BACKUP_DESTINATION"
        exit 1
    }
fi

# Test write access
TEST_FILE="${BACKUP_DESTINATION}/.backup_test_$$"
if ! touch "$TEST_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to backup destination: $BACKUP_DESTINATION"
    exit 1
fi
rm -f "$TEST_FILE"

echo "Backup destination verified: $BACKUP_DESTINATION"

# Create backup cron job
# Run every Sunday at 2:00 AM
CRON_SCHEDULE="0 2 * * 0"
BACKUP_SCRIPT="/usr/local/bin/p4_backup.sh"
CRON_JOB="$CRON_SCHEDULE $BACKUP_SCRIPT >> /hxlogs/p4/${SDP_INSTANCE}/logs/backup.log 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
    echo "Backup cron job already exists, updating..."
    # Remove existing backup job
    (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT") | crontab -
fi

# Add the new cron job
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "Scheduled weekly backup cron job:"
echo "  Schedule: Every Sunday at 2:00 AM"
echo "  Command: $BACKUP_SCRIPT"
echo "  Log: /hxlogs/p4/${SDP_INSTANCE}/logs/backup.log"

# Show current crontab
echo ""
echo "Current crontab for user $(whoami):"
crontab -l