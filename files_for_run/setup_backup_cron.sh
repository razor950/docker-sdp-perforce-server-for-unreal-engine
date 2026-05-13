#!/bin/bash
set -eu

#------------------------------------------------------------------------------
# Setup Weekly Perforce Backup Cron Job
#
# This script adds a weekly backup cron job for the perforce user.
# It preserves the existing SDP crontab entries.
#------------------------------------------------------------------------------

SDP_INSTANCE=${SDP_INSTANCE:-1}
BACKUP_DESTINATION=${BACKUP_DESTINATION:-}

if [[ -z "$BACKUP_DESTINATION" ]]; then
    echo "WARNING: BACKUP_DESTINATION environment variable is not set."
    echo "Backups will not be scheduled until this is configured."
    exit 0
fi

if [[ ! -d "$BACKUP_DESTINATION" ]]; then
    echo "Creating backup destination directory: $BACKUP_DESTINATION"
    mkdir -p "$BACKUP_DESTINATION" || {
        echo "ERROR: Cannot create backup destination: $BACKUP_DESTINATION"
        exit 1
    }
    chown perforce:perforce "$BACKUP_DESTINATION"
fi

# Test write access as perforce, since the cron job will run as perforce.
TEST_FILE="${BACKUP_DESTINATION}/.backup_test_$$"
if ! sudo -u perforce touch "$TEST_FILE" 2>/dev/null; then
    echo "ERROR: perforce cannot write to backup destination: $BACKUP_DESTINATION"
    exit 1
fi
rm -f "$TEST_FILE"

echo "Backup destination verified for perforce: $BACKUP_DESTINATION"

# Run every Sunday at 8:00 AM, after SDP daily checkpoint has run.
CRON_SCHEDULE="0 8 * * 0"
BACKUP_SCRIPT="/usr/local/bin/p4_backup.sh"
BACKUP_LOG="/hxlogs/p4/${SDP_INSTANCE}/logs/backup.log"

CRON_JOB="$CRON_SCHEDULE BACKUP_DESTINATION=${BACKUP_DESTINATION} SDP_INSTANCE=${SDP_INSTANCE} ${BACKUP_SCRIPT} >> ${BACKUP_LOG} 2>&1"

TMP_CRON=$(mktemp)
trap 'rm -f "$TMP_CRON"' EXIT

# Preserve existing perforce crontab, including SDP maintenance jobs.
sudo -u perforce crontab -l 2>/dev/null > "$TMP_CRON" || true

if grep -Fq "$BACKUP_SCRIPT" "$TMP_CRON"; then
    echo "Backup cron job already exists for perforce. Leaving existing entry unchanged."
else
    echo "$CRON_JOB" >> "$TMP_CRON"
    sudo -u perforce crontab "$TMP_CRON"
    echo "Scheduled weekly backup cron job for perforce:"
fi

echo "  Schedule: Every Sunday at 8:00 AM"
echo "  Command: $BACKUP_SCRIPT"
echo "  Log: $BACKUP_LOG"

echo ""
echo "Current crontab for user perforce:"
sudo -u perforce crontab -l
