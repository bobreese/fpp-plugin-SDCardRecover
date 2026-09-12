#!/bin/bash
# Step 2b (fallback, only if read-only mount failed): non-destructive filesystem
# check. Uses fsck -n everywhere it's honored, which reports problems without
# writing anything back to the card. This is a diagnostic step, not a repair -
# see sdcard_fsck_repair.sh for the explicit, opt-in, destructive repair path.
source "$(dirname "$0")/common.sh"

PART="$1"
if [ -z "$PART" ]; then
    echo "ERROR: usage: sdcard_fsck_check.sh <partition-device>" >&2
    exit 1
fi

PART=$(validate_device "$PART")
guard_not_root_device "$PART"

if mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT" 2>/dev/null
fi

FSTYPE=$(lsblk -no FSTYPE "$PART")
log "Running non-destructive check (fsck -n) on $PART (fstype: ${FSTYPE:-unknown})..."
log "No changes will be written to the card during this step."

case "$FSTYPE" in
    ext2|ext3|ext4)
        fsck.ext4 -n -f -v "$PART"
        ;;
    vfat|fat32)
        fsck.vfat -n -v "$PART"
        ;;
    exfat)
        fsck.exfat -n "$PART" 2>&1 || log "fsck.exfat does not support -n on this system; treating output above as advisory only."
        ;;
    *)
        fsck -n "$PART"
        ;;
esac
RC=$?

log "fsck -n exit code: $RC (0/1 = clean or non-fatal, higher = filesystem problems present)"
exit $RC
