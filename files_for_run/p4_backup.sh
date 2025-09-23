#!/bin/bash
set -eu

#------------------------------------------------------------------------------
# Perforce SDP Backup Script - Efficient Incremental Version
# 
# This script creates an efficient incremental backup of a Perforce server:
# - Latest checkpoint and journals (truly incremental)
# - Depot files (rsync incremental - only changed files)
# - Monthly point-in-time snapshots for rollback capability
#
# Usage: This script should be run from inside the Perforce container
# Environment Variables Required:
#   BACKUP_DESTINATION - Full path to backup directory (e.g., /mnt/backup/perforce)
#   SDP_INSTANCE - Perforce instance number (default: 1)
#------------------------------------------------------------------------------

# Functions for logging
function msg () { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
function errmsg () { msg "ERROR: ${1:-Unknown Error}"; ErrorCount+=1; }
function warnmsg () { msg "WARNING: ${1:-Unknown Warning}"; WarningCount+=1; }
function bail () { errmsg "${1:-Unknown Error}"; exit "${2:-1}"; }

# Cleanup function
function cleanup() {
    if [[ -n "${LOCK_FILE:-}" && -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        msg "Removed backup lock file"
    fi
}

# Initialize counters
declare -i ErrorCount=0
declare -i WarningCount=0

# Setup cleanup trap
trap cleanup EXIT
trap cleanup SIGTERM
trap cleanup SIGINT

# Configuration
SDP_INSTANCE=${SDP_INSTANCE:-1}
BACKUP_DESTINATION=${BACKUP_DESTINATION:-}
BACKUP_RETENTION_WEEKS=${BACKUP_RETENTION_WEEKS:-4}
MONTHLY_SNAPSHOTS=${MONTHLY_SNAPSHOTS:-3}
SAFE_MODE=${BACKUP_SAFE_MODE:-1}  # 1 = safer backups, 0 = aggressive cleanup

# Backup lock file to prevent concurrent runs
LOCK_FILE="/tmp/p4_backup_${SDP_INSTANCE}.lock"

# Check for concurrent backup
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    if [[ "$LOCK_PID" != "unknown" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        bail "Another backup is already running (PID: $LOCK_PID, lock file: $LOCK_FILE)"
    else
        msg "Removing stale lock file: $LOCK_FILE"
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $ > "$LOCK_FILE" || bail "Cannot create backup lock file: $LOCK_FILE"
msg "Created backup lock file: $LOCK_FILE (PID: $)"

# Validate environment
[[ -n "$BACKUP_DESTINATION" ]] || bail "BACKUP_DESTINATION environment variable must be set"
[[ -d "/p4/${SDP_INSTANCE}" ]] || bail "Perforce instance ${SDP_INSTANCE} not found"

# Source P4 environment
source /p4/common/bin/p4_vars "${SDP_INSTANCE}" || bail "Failed to source P4 environment"

# Backup directory structure
CURRENT_DATE=$(date '+%Y-%m-%d')
BACKUP_LATEST="${BACKUP_DESTINATION}/latest"
BACKUP_SNAPSHOTS="${BACKUP_DESTINATION}/monthly"
CURRENT_BACKUP_LINK="${BACKUP_DESTINATION}/current"

msg "Starting efficient incremental Perforce backup for instance ${SDP_INSTANCE}"
msg "Backup destination: ${BACKUP_DESTINATION}"

# Create backup directory structure
mkdir -p "${BACKUP_LATEST}"
mkdir -p "${BACKUP_SNAPSHOTS}"
mkdir -p "${BACKUP_LATEST}/checkpoints"
mkdir -p "${BACKUP_LATEST}/journals" 
mkdir -p "${BACKUP_LATEST}/depot"
mkdir -p "${BACKUP_LATEST}/logs"

#------------------------------------------------------------------------------
# Step 1: Create a new checkpoint
#------------------------------------------------------------------------------
msg "Creating new checkpoint..."

# Run live checkpoint (this is safe while server is running)
if ! sudo -u perforce /p4/common/bin/live_checkpoint.sh "${SDP_INSTANCE}"; then
    errmsg "Failed to create checkpoint"
else
    msg "Checkpoint created successfully"
fi

#------------------------------------------------------------------------------
# Step 2: Update latest checkpoint
#------------------------------------------------------------------------------
msg "Updating latest checkpoint..."

CHECKPOINT_DIR="/p4/${SDP_INSTANCE}/checkpoints"
LATEST_CHECKPOINT=$(find "${CHECKPOINT_DIR}" -name "checkpoint.${SDP_INSTANCE}.*" -type f | sort | tail -1)

if [[ -n "$LATEST_CHECKPOINT" && -f "$LATEST_CHECKPOINT" ]]; then
    # Remove old checkpoints from backup (keep only latest)
    rm -f "${BACKUP_LATEST}/checkpoints/checkpoint.${SDP_INSTANCE}."*
    
    cp "$LATEST_CHECKPOINT" "${BACKUP_LATEST}/checkpoints/" || bail "Failed to copy checkpoint"
    msg "Updated checkpoint: $(basename "$LATEST_CHECKPOINT")"
    
    # Also copy the compressed version if it exists
    CHECKPOINT_GZ="${LATEST_CHECKPOINT}.gz"
    if [[ -f "$CHECKPOINT_GZ" ]]; then
        rm -f "${BACKUP_LATEST}/checkpoints/checkpoint.${SDP_INSTANCE}."*.gz
        cp "$CHECKPOINT_GZ" "${BACKUP_LATEST}/checkpoints/" || warnmsg "Failed to copy compressed checkpoint"
        msg "Updated compressed checkpoint: $(basename "$CHECKPOINT_GZ")"
    fi
else
    bail "No checkpoint files found in ${CHECKPOINT_DIR}"
fi

#------------------------------------------------------------------------------
# Step 3: Sync journal files (incremental)
#------------------------------------------------------------------------------
msg "Syncing journal files..."

JOURNAL_DIR="/p4/${SDP_INSTANCE}/journals"
if [[ -d "$JOURNAL_DIR" ]]; then
    # Use rsync to incrementally sync journal files
    rsync -av --delete "${JOURNAL_DIR}/" "${BACKUP_LATEST}/journals/" || warnmsg "Failed to sync journal files"
    msg "Synced journal files from ${JOURNAL_DIR}"
else
    warnmsg "Journal directory not found: ${JOURNAL_DIR}"
fi

# Copy the active journal
ACTIVE_JOURNAL="${P4JOURNAL}"
if [[ -f "$ACTIVE_JOURNAL" ]]; then
    cp "$ACTIVE_JOURNAL" "${BACKUP_LATEST}/journals/journal.active" || warnmsg "Failed to copy active journal"
    msg "Updated active journal: ${ACTIVE_JOURNAL}"
fi

#------------------------------------------------------------------------------
# Step 4: Incremental sync of depot files (the big efficiency gain!)
#------------------------------------------------------------------------------
msg "Incrementally syncing depot files (this will be fast after the first run)..."

DEPOT_DIR="/hxdepots/p4/${SDP_INSTANCE}/depots"
if [[ -d "$DEPOT_DIR" ]]; then
    # Check if source depot directory has content
    DEPOT_FILE_COUNT=$(find "$DEPOT_DIR" -type f | wc -l)
    msg "Source depot contains $DEPOT_FILE_COUNT files"
    
    if [[ $DEPOT_FILE_COUNT -eq 0 ]]; then
        warnmsg "Source depot directory is empty! Skipping depot sync to prevent data loss."
        warnmsg "If this is intentional, set BACKUP_SAFE_MODE=0 to allow empty depot sync."
        if [[ $SAFE_MODE -eq 0 ]]; then
            msg "SAFE_MODE=0: Proceeding with empty depot sync..."
        else
            msg "Depot sync skipped for safety. Check your depot directory: $DEPOT_DIR"
            ErrorCount+=1
        fi
    else
        # Use rsync for truly incremental copying - only changed files
        # Removed --delete flag for safety unless in aggressive mode
        START_TIME=$(date +%s)
        
        if [[ $SAFE_MODE -eq 0 ]]; then
            msg "SAFE_MODE=0: Using aggressive sync with --delete"
            rsync -av --delete --progress "${DEPOT_DIR}/" "${BACKUP_LATEST}/depot/" || bail "Failed to incrementally sync depot files"
        else
            msg "SAFE_MODE=1: Using safe sync without --delete"
            rsync -av --progress "${DEPOT_DIR}/" "${BACKUP_LATEST}/depot/" || bail "Failed to incrementally sync depot files"
            
            # Optional: Show files that would be deleted but weren't
            if [[ -d "${BACKUP_LATEST}/depot" ]]; then
                ORPHANED_FILES=$(rsync -avn --delete "${DEPOT_DIR}/" "${BACKUP_LATEST}/depot/" | grep "^deleting " | wc -l)
                if [[ $ORPHANED_FILES -gt 0 ]]; then
                    msg "Note: $ORPHANED_FILES orphaned files in backup (use BACKUP_SAFE_MODE=0 to auto-delete)"
                fi
            fi
        fi
        
        END_TIME=$(date +%s)
        SYNC_DURATION=$((END_TIME - START_TIME))
        msg "Incremental depot sync completed in ${SYNC_DURATION} seconds"
        
        # Show backup size
        DEPOT_SIZE=$(du -sh "${BACKUP_LATEST}/depot" | cut -f1)
        msg "Current depot backup size: ${DEPOT_SIZE}"
    fi
else
    bail "Depot directory not found: ${DEPOT_DIR}"
fi

#------------------------------------------------------------------------------
# Step 5: Update configuration and logs
#------------------------------------------------------------------------------
msg "Updating configuration files and logs..."

# Copy important config files
CONFIG_FILES=(
    "/p4/${SDP_INSTANCE}/p4d_${SDP_INSTANCE}"
    "/p4/common/config/p4_${SDP_INSTANCE}.vars"
    "/p4/${SDP_INSTANCE}/.p4config"
)

for config_file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "${BACKUP_LATEST}/logs/" || warnmsg "Failed to copy config file: $config_file"
    fi
done

# Sync recent log files (last 7 days) incrementally
LOG_DIR="/hxlogs/p4/${SDP_INSTANCE}/logs"
if [[ -d "$LOG_DIR" ]]; then
    # Create a temporary directory with recent logs, then sync it
    TEMP_LOG_DIR=$(mktemp -d)
    find "$LOG_DIR" -name "*.log" -mtime -7 -exec cp {} "$TEMP_LOG_DIR/" \; 2>/dev/null || true
    
    if [[ -n "$(ls -A "$TEMP_LOG_DIR" 2>/dev/null)" ]]; then
        rsync -av "${TEMP_LOG_DIR}/" "${BACKUP_LATEST}/logs/" || warnmsg "Failed to sync log files"
        msg "Synced recent log files"
    fi
    
    rm -rf "$TEMP_LOG_DIR"
fi

#------------------------------------------------------------------------------
# Step 6: Update backup manifest
#------------------------------------------------------------------------------
msg "Updating backup manifest..."

MANIFEST="${BACKUP_LATEST}/backup_manifest.txt"
cat > "$MANIFEST" << EOF
Perforce Incremental Backup Manifest
====================================
Last Updated: $(date)
Instance: ${SDP_INSTANCE}
P4ROOT: ${P4ROOT}
P4PORT: ${P4PORT}
Server Version: $(p4 -p ${P4PORT} info | grep "Server version" || echo "Unknown")

Backup Type: Incremental (rsync-based)
Backup Contents:
- Latest Checkpoint: $(ls "${BACKUP_LATEST}/checkpoints/" | grep -v ".gz" | tail -1 || echo "None")
- Compressed Checkpoint: $(ls "${BACKUP_LATEST}/checkpoints/" | grep ".gz" | tail -1 || echo "None")
- Journal Files: $(ls -la "${BACKUP_LATEST}/journals/" | wc -l) files
- Depot Size: $(du -sh "${BACKUP_LATEST}/depot" | cut -f1)
- Config/Logs: $(ls -la "${BACKUP_LATEST}/logs/" | wc -l) files

Total Backup Size: $(du -sh "${BACKUP_LATEST}" | cut -f1)

Monthly Snapshots Available:
$(ls -la "${BACKUP_SNAPSHOTS}/" 2>/dev/null | grep "^d" | awk '{print $9}' | grep -v "^\.$\|^\.\.$" || echo "None yet")

Note: This is an incremental backup. Depot files are only copied when changed.
For full restore, use the latest checkpoint + all journals + depot files.
EOF

msg "Updated backup manifest: ${MANIFEST}"

#------------------------------------------------------------------------------
# Step 7: Create monthly snapshot if it's the first backup of the month
#------------------------------------------------------------------------------
CURRENT_MONTH=$(date '+%Y-%m')
SNAPSHOT_DIR="${BACKUP_SNAPSHOTS}/${CURRENT_MONTH}"

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
    msg "Creating monthly snapshot for ${CURRENT_MONTH}..."
    
    # Use rsync instead of hard links (safer across different filesystems)
    # First try with hard links for efficiency, fall back to full copy
    if cp -al "${BACKUP_LATEST}" "$SNAPSHOT_DIR" 2>/dev/null; then
        msg "Created space-efficient hard-link snapshot: ${SNAPSHOT_DIR}"
    else
        msg "Hard links failed, creating full copy snapshot (this may take time)..."
        if rsync -av "${BACKUP_LATEST}/" "$SNAPSHOT_DIR/"; then
            msg "Created full copy snapshot: ${SNAPSHOT_DIR}"
        else
            warnmsg "Failed to create monthly snapshot"
        fi
    fi
    
    if [[ -d "$SNAPSHOT_DIR" ]]; then
        # Update snapshot manifest
        SNAPSHOT_MANIFEST="${SNAPSHOT_DIR}/snapshot_info.txt"
        cat > "$SNAPSHOT_MANIFEST" << EOF
Monthly Snapshot Created: $(date)
Source: Latest incremental backup
Snapshot Date: ${CURRENT_MONTH}
P4 Instance: ${SDP_INSTANCE}
Snapshot Type: $(if [[ -f "${SNAPSHOT_DIR}/.snapshot_hardlinked" ]]; then echo "Hard-linked (space efficient)"; else echo "Full copy"; fi)

This snapshot represents the state of the Perforce server on $(date).
EOF
        
        # Mark if this was a hard-linked snapshot
        if [[ $(stat -c %i "${BACKUP_LATEST}/backup_manifest.txt" 2>/dev/null || echo "0") == $(stat -c %i "${SNAPSHOT_DIR}/backup_manifest.txt" 2>/dev/null || echo "1") ]]; then
            touch "${SNAPSHOT_DIR}/.snapshot_hardlinked"
        fi
        
        # Show snapshot size
        SNAPSHOT_SIZE=$(du -sh "$SNAPSHOT_DIR" | cut -f1)
        msg "Monthly snapshot size: ${SNAPSHOT_SIZE}"
    fi
fi

#------------------------------------------------------------------------------
# Step 8: Update current backup symlink
#------------------------------------------------------------------------------
msg "Updating current backup symlink..."

if [[ -L "$CURRENT_BACKUP_LINK" ]]; then
    rm "$CURRENT_BACKUP_LINK"
fi
ln -sf "${BACKUP_LATEST}" "$CURRENT_BACKUP_LINK" || warnmsg "Failed to create current backup symlink"

#------------------------------------------------------------------------------
# Step 9: Cleanup old monthly snapshots
#------------------------------------------------------------------------------
msg "Cleaning up old monthly snapshots (keeping last ${MONTHLY_SNAPSHOTS} months)..."

if [[ -d "$BACKUP_SNAPSHOTS" ]]; then
    # Keep only the most recent monthly snapshots
    SNAPSHOTS_TO_DELETE=$(find "${BACKUP_SNAPSHOTS}" -maxdepth 1 -type d -name "20*-*" | sort -r | tail -n +$((MONTHLY_SNAPSHOTS + 1)))
    
    if [[ -n "$SNAPSHOTS_TO_DELETE" ]]; then
        echo "$SNAPSHOTS_TO_DELETE" | xargs rm -rf
        msg "Cleaned up old monthly snapshots"
    fi
fi

#------------------------------------------------------------------------------
# Step 10: Verify backup integrity (basic check)
#------------------------------------------------------------------------------
msg "Performing backup integrity verification..."

BACKUP_VALID=1

# Check that key backup components exist
REQUIRED_COMPONENTS=(
    "${BACKUP_LATEST}/checkpoints"
    "${BACKUP_LATEST}/journals" 
    "${BACKUP_LATEST}/depot"
    "${BACKUP_LATEST}/backup_manifest.txt"
)

for component in "${REQUIRED_COMPONENTS[@]}"; do
    if [[ ! -e "$component" ]]; then
        errmsg "Missing backup component: $component"
        BACKUP_VALID=0
    fi
done

# Check that checkpoint file exists and is readable
CHECKPOINT_FILES=$(find "${BACKUP_LATEST}/checkpoints" -name "checkpoint.${SDP_INSTANCE}.*" -type f 2>/dev/null | wc -l)
if [[ $CHECKPOINT_FILES -eq 0 ]]; then
    errmsg "No checkpoint files found in backup"
    BACKUP_VALID=0
else
    msg "✅ Found $CHECKPOINT_FILES checkpoint file(s)"
fi

# Check that depot has content (if source had content)
if [[ $DEPOT_FILE_COUNT -gt 0 ]]; then
    BACKUP_DEPOT_FILES=$(find "${BACKUP_LATEST}/depot" -type f 2>/dev/null | wc -l)
    if [[ $BACKUP_DEPOT_FILES -eq 0 ]]; then
        errmsg "Backup depot is empty but source depot has $DEPOT_FILE_COUNT files"
        BACKUP_VALID=0
    else
        msg "✅ Backup depot contains $BACKUP_DEPOT_FILES files"
    fi
fi

if [[ $BACKUP_VALID -eq 1 ]]; then
    msg "✅ Backup integrity verification passed"
else
    errmsg "❌ Backup integrity verification failed"
fi

#------------------------------------------------------------------------------
# Step 11: Backup summary
#------------------------------------------------------------------------------
BACKUP_SIZE=$(du -sh "${BACKUP_LATEST}" | cut -f1)
BACKUP_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

msg "Incremental backup completed successfully!"
msg "Latest backup location: ${BACKUP_LATEST}"
msg "Current backup size: ${BACKUP_SIZE}"
msg "Monthly snapshots: $(ls -1 "${BACKUP_SNAPSHOTS}/" 2>/dev/null | wc -l) available"
msg "Backup completed at: ${BACKUP_END_TIME}"

# Show efficiency info
if [[ -f "${BACKUP_LATEST}/.backup_stats" ]]; then
    LAST_SIZE=$(cat "${BACKUP_LATEST}/.backup_stats")
    msg "Previous backup size: ${LAST_SIZE}"
fi
echo "$BACKUP_SIZE" > "${BACKUP_LATEST}/.backup_stats"

if [[ $ErrorCount -gt 0 ]]; then
    msg "Backup completed with ${ErrorCount} errors and ${WarningCount} warnings"
    exit 1
else
    msg "Backup completed with ${WarningCount} warnings"
    
    # Display backup efficiency summary
    msg ""
    msg "=== Backup Efficiency Summary ==="
    msg "✅ Checkpoints: Latest only (space efficient)"
    msg "✅ Journals: Incremental sync (only new/changed)" 
    msg "✅ Depot files: Incremental sync (only changed files)"
    msg "✅ Monthly snapshots: Hard-linked when possible (space efficient)"
    msg "✅ Always recoverable: Latest checkpoint + journals + depot"
    msg "✅ Backup verification: $(if [[ $BACKUP_VALID -eq 1 ]]; then echo "PASSED"; else echo "FAILED"; fi)"
    msg "✅ Safe mode: $(if [[ $SAFE_MODE -eq 1 ]]; then echo "ENABLED (recommended)"; else echo "DISABLED (aggressive)"; fi)"
    
    if [[ $BACKUP_VALID -eq 0 ]]; then
        errmsg "Backup completed but failed integrity verification!"
        exit 1
    fi
    
    exit 0
fi