#!/bin/bash
# Core recovery-scoping step, used instead of trusting fsck/filesystem metadata:
# walk every file FPP cares about on the mounted DamagedSD partition and
# actually read it end-to-end. A file that reads cleanly and in full is
# recoverable regardless of what fsck would have said about the filesystem;
# a file that throws an I/O error (bad sectors) is flagged, not copied blind.
#
# Writes a manifest (path<TAB>bytes<TAB>status) that sdcard_evaluate.sh and
# sdcard_recover.sh both consume downstream.
source "$(dirname "$0")/common.sh"

if ! mountpoint -q "$MOUNTPOINT"; then
    echo "ERROR: $MOUNTPOINT is not mounted. Run the mount step first." >&2
    exit 1
fi

ensure_state_dir
: > "$MANIFEST"

# Known FPP locations worth recovering, relative to the mounted partition's
# OWN root - which, now that guessPartition() (js/sdcard-recover.js) picks
# the ext4 root partition rather than the small vfat boot partition, is the
# card's actual filesystem root ("/"), not /home/fpp. So these need the full
# home/fpp/media/... path, matching $mediaDirectory in FPP's own config.php -
# a bare "config" (as an earlier version of this had, alongside "media/...")
# would have meant /home/fpp/config, which has never been a real FPP path;
# config lives under media, at /home/fpp/media/config.
# "channeloutputs" was here before and has been removed: confirmed against
# FPP's own www/backup.php ($system_config_areas, www/config.php) that no
# such directory has ever existed - channel output settings are files
# (channeloutputs.json, universes.json, etc.) directly inside config/,
# already covered by that category below. That same source is what
# surfaced "scripts", "events", and "channelmemorymaps" as real,
# previously-missed directories:
#   $scriptDirectory          = mediaDirectory . "/scripts"           (Command/Event scripts)
#   $eventDirectory           = mediaDirectory . "/events"
#   $system_config_areas['channelmemorymaps']['file'] = mediaDirectory . "/channelmemorymaps"  (legacy Pixel Overlay Models)
# "backups" ($SOURCE/backups in scripts/copy_settings_to_storage.sh, FPP's
# "File Copy Backup" tool) is its own real, separate directory - distinct
# from config/backups (FPP's JSON config backup archive, already covered
# recursively as part of the config/ category below).
TARGET_DIRS=(
    "home/fpp/media/config"
    "home/fpp/media/sequences"
    "home/fpp/media/music"
    "home/fpp/media/videos"
    "home/fpp/media/effects"
    "home/fpp/media/scripts"
    "home/fpp/media/events"
    "home/fpp/media/channelmemorymaps"
    "home/fpp/media/playlists"
    "home/fpp/media/images"
    "home/fpp/media/plugins"
    "home/fpp/media/upload"
    "home/fpp/media/backups"
)

# copy_settings_to_storage.sh's "Configuration" action explicitly EXCLUDES
# this one file from a generic config copy - it's a BeagleBone-specific
# virtual EEPROM cape file, hardware identity that doesn't make sense to
# carry onto different physical hardware, unlike everything else under
# config/. Skipped here for the same reason, even though it lives inside
# the config/ directory we otherwise walk recursively.
SKIP_FILES_RELATIVE=(
    "home/fpp/media/config/cape-eeprom.bin"
)
is_skipped_file() {
    local rel="$1"
    for skip in "${SKIP_FILES_RELATIVE[@]}"; do
        [ "$rel" = "$skip" ] && return 0
    done
    return 1
}

# FPP's actual device identity (HostName, network config, output settings -
# everything $settings[] holds) lives in this ONE flat key=value file
# (www/config.php: $settingsFile = $mediaDirectory . "/settings"), a sibling
# of media/config/, not inside it or any other TARGET_DIRS entry. Missing
# this specifically is why restoring "config" changed nothing about a
# device's identity on reboot - the actual settings never got captured.
# "timezone" ($timezoneFile = mediaDirectory . "/timezone") is the same kind
# of top-level flat file, holding the device's configured timezone.
TARGET_FILES=(
    "home/fpp/media/settings"
    "home/fpp/media/timezone"
)

TOTAL=0
GOOD=0
BAD=0

verify_one_file() {
    local f="$1"
    local rel_f="${f#$MOUNTPOINT/}"
    is_skipped_file "$rel_f" && return 0
    TOTAL=$((TOTAL+1))
    local expected
    expected=$(stat -c '%s' "$f" 2>/dev/null)
    # Read the whole file through dd; a bad sector surfaces as a non-zero
    # exit code or a short read, without writing anything back to the card.
    local actual
    actual=$(dd if="$f" of=/dev/null bs=1M 2>/tmp/sdcr_dd_err; echo $?)
    if [ "$actual" = "0" ] && [ -n "$expected" ]; then
        echo -e "${rel_f}\t${expected}\tOK" >> "$MANIFEST"
        GOOD=$((GOOD+1))
    else
        echo -e "${rel_f}\t${expected:-0}\tUNREADABLE" >> "$MANIFEST"
        BAD=$((BAD+1))
        log "  UNREADABLE: $rel_f ($(cat /tmp/sdcr_dd_err | tail -1))"
    fi
}

for rel in "${TARGET_DIRS[@]}"; do
    dir="$MOUNTPOINT/$rel"
    [ -d "$dir" ] || continue
    log "Verifying $rel ..."
    while IFS= read -r -d '' f; do
        verify_one_file "$f"
    done < <(find "$dir" -type f -print0)
done

for rel in "${TARGET_FILES[@]}"; do
    f="$MOUNTPOINT/$rel"
    [ -f "$f" ] || continue
    log "Verifying $rel ..."
    verify_one_file "$f"
done

log "Verification complete: $GOOD readable, $BAD unreadable, $TOTAL total files."
log "Manifest written to $MANIFEST"

if [ "$BAD" -gt 0 ]; then
    log "NOTE: files marked UNREADABLE were skipped, not copied. Consider the"
    log "deep-scan (raw carving) mode to attempt recovery of these by signature."
fi

exit 0
