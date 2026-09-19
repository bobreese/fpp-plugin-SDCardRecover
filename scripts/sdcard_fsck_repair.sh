#!/bin/bash
# Explicit, opt-in repair path. Only reachable from the UI after the user has
# seen the sdcard_fsck_check.sh (-n) report and clicked a separately-labeled
# "Attempt repair" action - never run automatically. fsck -y can itself
# destroy data on a badly damaged filesystem, so this is a deliberate choice,
# not a default step.
source "$(dirname "$0")/common.sh"

PART="$1"
if [ -z "$PART" ]; then
    echo "ERROR: usage: sdcard_fsck_repair.sh <partition-device>" >&2
    exit 1
fi

PART=$(validate_device "$PART") || exit 1
guard_not_root_device "$PART"

if mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT" 2>/dev/null
fi

FSTYPE=$(lsblk -no FSTYPE "$PART")
log "WARNING: running repair (fsck -y) on $PART (fstype: ${FSTYPE:-unknown})."
log "This writes changes to the card and is not reversible."

case "$FSTYPE" in
    ext2|ext3|ext4)
        fsck.ext4 -y -f -v "$PART"
        ;;
    vfat|fat32)
        fsck.vfat -y -v "$PART"
        ;;
    exfat)
        fsck.exfat -y "$PART"
        ;;
    *)
        fsck -y "$PART"
        ;;
esac
RC=$?

log "fsck -y exit code: $RC"
exit $RC
