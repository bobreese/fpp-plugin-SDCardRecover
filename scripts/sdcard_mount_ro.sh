#!/bin/bash
# Step 2a: Try to mount the card's media partition read-only as DamagedSD.
# Never mounts read-write - we don't want FPP's own mount to be what finishes
# off a marginal card. If this fails, the caller should fall back to
# sdcard_fsck_check.sh before trying again.
source "$(dirname "$0")/common.sh"

PART="$1"
if [ -z "$PART" ]; then
    echo "ERROR: usage: sdcard_mount_ro.sh <partition-device>" >&2
    exit 1
fi

PART=$(validate_device "$PART") || exit 1
guard_not_root_device "$PART"

mkdir -p "$MOUNTPOINT"

if mountpoint -q "$MOUNTPOINT"; then
    log "Unmounting stale mount at $MOUNTPOINT first..."
    umount "$MOUNTPOINT" 2>/dev/null
fi

FSTYPE=$(lsblk -no FSTYPE "$PART")
log "Attempting read-only mount of $PART (fstype: ${FSTYPE:-unknown}) at $MOUNTPOINT..."

case "$FSTYPE" in
    ext2|ext3|ext4)
        mount -o ro,noload "$PART" "$MOUNTPOINT"
        ;;
    vfat|fat32|exfat)
        mount -o ro "$PART" "$MOUNTPOINT"
        ;;
    *)
        mount -o ro "$PART" "$MOUNTPOINT"
        ;;
esac

if mountpoint -q "$MOUNTPOINT"; then
    log "Mounted $PART read-only at $MOUNTPOINT."
    exit 0
else
    log "Read-only mount of $PART failed."
    exit 2
fi
