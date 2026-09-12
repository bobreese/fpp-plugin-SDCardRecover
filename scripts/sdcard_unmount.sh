#!/bin/bash
# Cleanup: unmount DamagedSD. Called when the user re-scans, picks a different
# device, or finishes a recovery run.
source "$(dirname "$0")/common.sh"

if mountpoint -q "$MOUNTPOINT"; then
    log "Unmounting $MOUNTPOINT..."
    umount "$MOUNTPOINT"
    log "Unmounted."
else
    log "$MOUNTPOINT is not mounted - nothing to do."
fi
