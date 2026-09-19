#!/bin/bash
# Shared helpers for SDCard Recover plugin scripts.
# Mirrors the device-name validation FPP core uses in www/api/controllers/backups.php
# (DriveMountHelper) so this plugin never operates on an unexpected block device.

MOUNTPOINT="/mnt/DamagedSD"
DEST_MOUNTPOINT="/mnt/SDCardRecoverDest"
STATE_DIR="/home/fpp/media/config/plugin.SDCardRecover"
MANIFEST="$STATE_DIR/manifest.tsv"
LOCKFILE="/tmp/sdcard-recover.lock"

# Log file name and location - PLUGIN_GUIDELINES.md section 1.1: exactly one runtime
# log, named <logdir>/plugin-<repoName>.log, with <logdir> resolved the
# FPP-provided way rather than hard-coded, since a relocated media directory
# would otherwise break it silently. The "plugin-" prefix isn't cosmetic -
# it's the glob FPP's own log management matches to rotate plugin logs (by
# size, keeping the last 2 copies, compressed) separately from its own logs;
# a differently-named file is invisible to that and grows unbounded. Source
# FPP's own scripts/common for $LOGDIR (and friends) rather than guessing at
# $mediaDirectory ourselves - the FPPDIR default matches what that script
# itself expects when sourced from outside $FPPDIR/scripts/.
: "${FPPDIR:=/opt/fpp}"
. "${FPPDIR}/scripts/common"
LOG_DIR="$LOGDIR"
LOG_FILE="$LOG_DIR/plugin-fpp-plugin-SDCardRecover.log"

# FPP's known removable-device naming: sdX, mmcblkXpY, nvmeXnYpZ.
# Whole-disk form (no trailing partition number) is also accepted for scan/fsck steps.
DEVICE_RE='^(sd[a-z][0-9]*|mmcblk[0-9]+p?[0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*)$'

# Kept in sync with sdcard_verify.sh's TARGET_DIRS (minus the home/fpp/media/
# prefix) - the set of categories a local restore is allowed to target.
#
# "channeloutputs" was here before and has been removed: confirmed against
# FPP's own www/backup.php ($system_config_areas) that no such directory has
# ever existed - channel output settings are files (channeloutputs.json,
# universes.json, etc.) directly inside config/, already covered by that
# category. Added "scripts" (mediaDirectory/scripts, Command/Event scripts)
# and "channelmemorymaps" (mediaDirectory/channelmemorymaps, legacy Pixel
# Overlay Models) and "events" (mediaDirectory/events) - all real,
# previously-missed directories from that same source. Added "backups"
# (mediaDirectory/backups) after cross-checking against FPP's OTHER backup
# tool, scripts/copy_settings_to_storage.sh ("File Copy Backup") - its own
# named "Backups" action, distinct from config/backups (JSON config backup
# archive, already covered inside the config category).
CATEGORY_RE='^(config|sequences|music|videos|effects|scripts|events|channelmemorymaps|playlists|images|plugins|upload|backups)$'

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

# FPP's media directory isn't always on the root device - www/settings-storage.php's
# storageDevice setting lets it live on a separate USB drive entirely. --target
# walks up to the containing mountpoint when the exact path isn't one itself, so
# this returns the SAME value as root_device() when /home/fpp/media is just a
# directory on the root filesystem (the common case) - redundant with the
# root_device() check in that case, not empty, and harmlessly so.
media_device() {
    findmnt -n -o SOURCE --target /home/fpp/media 2>/dev/null | sed -E 's/p?[0-9]+$//'
}

# Refuse to ever touch a device FPP itself is booted from, that's backing FPP's
# own media directory (which can be a separate storage device - see
# media_device() above), or that has a partition mounted somewhere this plugin
# doesn't already control. Found in fpp-data review: this used to check
# root_device() only, so FPP's own USB storage device (transport type "usb",
# same as any other candidate) passed straight through - scan listed it,
# fsck_repair accepted it. e2fsck's own non-interactive mode refuses a mounted
# ext4 filesystem on its own, so that case was safe by luck, not by anything
# this plugin did; fsck.vfat -y has no such built-in protection and would run
# against a live, in-use FAT filesystem if asked to.
#
# A partition already mounted at MOUNTPOINT/DEST_MOUNTPOINT is excluded
# deliberately: that's this plugin's OWN prior mount of the exact device being
# checked (a stale mount from an earlier run that the caller is about to
# unmount and redo, e.g. sdcard_mount_ro.sh's own re-mount, or the source card
# still mounted read-only when sdcard_carve.sh runs) - not something else
# depending on it. Anywhere else, a mounted partition means something outside
# this plugin's knowledge or control needs it, and there is no way to know
# that is safe to interrupt.
guard_not_root_device() {
    local dev="$1"
    local root media
    root=$(root_device)
    media=$(media_device)
    local base="/dev/$(basename "$dev" | sed -E 's/p?[0-9]+$//')"
    if [ "$base" = "$root" ]; then
        echo "ERROR: $dev appears to be this FPP's own running storage device. Refusing." >&2
        exit 1
    fi
    if [ -n "$media" ] && [ "$base" = "$media" ]; then
        echo "ERROR: $dev is backing this FPP's own media directory (/home/fpp/media). Refusing." >&2
        exit 1
    fi
    local part mp
    for part in "$base"?*; do
        [ -b "$part" ] || continue
        mp=$(findmnt -n -o TARGET -S "$part" 2>/dev/null)
        if [ -n "$mp" ] && [ "$mp" != "$MOUNTPOINT" ] && [ "$mp" != "$DEST_MOUNTPOINT" ]; then
            echo "ERROR: $dev has a partition ($part) mounted at $mp. Refusing." >&2
            exit 1
        fi
    done
    mp=$(findmnt -n -o TARGET -S "$base" 2>/dev/null)
    if [ -n "$mp" ] && [ "$mp" != "$MOUNTPOINT" ] && [ "$mp" != "$DEST_MOUNTPOINT" ]; then
        echo "ERROR: $dev is mounted at $mp. Refusing." >&2
        exit 1
    fi
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

ensure_log_file() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    # Scripts run as root via sudo; the FPP web UI (fpp user) still needs to
    # be able to view/delete this from the File Manager Logs tab.
    chown fpp:fpp "$LOG_FILE" 2>/dev/null || true
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

ensure_log_file
SDCR_SCRIPT_NAME=$(basename "$0")
log "=== $SDCR_SCRIPT_NAME started: $* ==="
trap 'log "=== $SDCR_SCRIPT_NAME finished (exit $?) ==="' EXIT
