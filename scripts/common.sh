#!/bin/bash
# Shared helpers for SDCard Recover plugin scripts.
# Mirrors the device-name validation FPP core uses in www/api/controllers/backups.php
# (DriveMountHelper) so this plugin never operates on an unexpected block device.

MOUNTPOINT="/mnt/DamagedSD"
STATE_DIR="/home/fpp/media/config/plugin.SDCardRecover"
MANIFEST="$STATE_DIR/manifest.tsv"
LOCKFILE="/tmp/sdcard-recover.lock"

# FPP's known removable-device naming: sdX, mmcblkXpY, nvmeXnYpZ.
# Whole-disk form (no trailing partition number) is also accepted for scan/fsck steps.
DEVICE_RE='^(sd[a-z][0-9]*|mmcblk[0-9]+p?[0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*)$'

validate_device() {
    local dev="$1"
    local base
    base=$(basename "$dev")
    if [[ ! "$base" =~ $DEVICE_RE ]]; then
        echo "ERROR: refusing to operate on unrecognized device name '$dev'" >&2
        exit 1
    fi
    if [ ! -b "/dev/$base" ]; then
        echo "ERROR: /dev/$base is not a block device" >&2
        exit 1
    fi
    echo "/dev/$base"
}

# Refuse to ever touch the device FPP itself is booted/running from.
root_device() {
    findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//'
}

guard_not_root_device() {
    local dev="$1"
    local root
    root=$(root_device)
    local base="/dev/$(basename "$dev" | sed -E 's/p?[0-9]+$//')"
    if [ "$base" = "$root" ]; then
        echo "ERROR: $dev appears to be this FPP's own running storage device. Refusing." >&2
        exit 1
    fi
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}
