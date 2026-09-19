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

# Block-layer read-only, on top of (not instead of) the mount-level `ro`
# below - found in fpp-data review: `mount -o ro` alone only asks the
# filesystem driver not to write; the unrecognized-fstype branch below
# doesn't even get `noload`, so on an actual ext4 partition the kernel would
# still replay its journal (a real write) despite `ro`. `blockdev --setro`
# makes the underlying block device itself reject any write with EROFS,
# regardless of what filesystem driver claims it or what mount options it's
# given - a kernel guarantee instead of a filesystem driver's cooperation.
# Reset before fsck -y in sdcard_fsck_repair.sh, which needs to write here
# on purpose.
blockdev --setro "$PART"

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
