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

# Found in fpp-data review: this plugin's OWN scratch state
# (config/plugin.SDCardRecover/ - $STATE_DIR in common.sh) lives inside
# config/ like any other plugin's settings, so it was being walked and
# verified right along with everything else. If the SOURCE card also had
# this plugin installed (or was itself "this device" for a completely
# unrelated SDCardRecover session at some point), that directory holds a
# STALE manifest.tsv and possibly old zips from that unrelated session -
# not real recoverable data, and never something a user restoring "Config"
# actually wants. Worse: restoring the config category would rsync that
# stale manifest.tsv straight over THIS session's own live $MANIFEST, and
# since runRecover() (js/sdcard-recover.js) runs every selected destination
# sequentially in one Recover click, a zip/usb destination checked
# alongside local Config would then read the just-clobbered, unrelated
# manifest instead of this session's own - copying the wrong files, or
# none at all. Excluded here, at the source, so it can never enter the
# manifest under any category (config, zip, or usb all pull from the same
# manifest) rather than special-casing every destination that consumes it.
SKIP_DIR_PREFIXES_RELATIVE=(
    "home/fpp/media/config/plugin.SDCardRecover/"
)

is_skipped_file() {
    local rel="$1"
    local skip
    for skip in "${SKIP_FILES_RELATIVE[@]}"; do
        [ "$rel" = "$skip" ] && return 0
    done
    for skip in "${SKIP_DIR_PREFIXES_RELATIVE[@]}"; do
        case "$rel" in
            "$skip"*) return 0 ;;
        esac
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
DIRS_WITH_ERRORS=0

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
    # printf, not `echo -e` - found in fpp-data review: `-e` makes echo
    # interpret backslash escapes in ITS ARGUMENT, and $rel_f is a filename
    # from the damaged card, not a literal this script controls. A filename
    # containing a literal backslash (e.g. "foo\tbar.mp3" - an unusual but
    # legal ext4 filename) would have its own "\t"/"\n"/etc. reinterpreted as
    # real tabs/newlines, corrupting this TAB-delimited manifest - a bogus
    # extra column, or a line split in two - and confusing every downstream
    # `awk -F'\t'` consumer (sdcard_evaluate.sh, sdcard_recover.sh). printf's
    # `%s` substitutes each argument verbatim; only the format string itself
    # is scanned for escapes/specifiers, so arbitrary filename content -
    # backslashes, percent signs, anything - passes through unmodified.
    if [ "$actual" = "0" ] && [ -n "$expected" ]; then
        printf '%s\t%s\t%s\n' "$rel_f" "$expected" "OK" >> "$MANIFEST"
        GOOD=$((GOOD+1))
    else
        printf '%s\t%s\t%s\n' "$rel_f" "${expected:-0}" "UNREADABLE" >> "$MANIFEST"
        BAD=$((BAD+1))
        log "  UNREADABLE: $rel_f ($(cat /tmp/sdcr_dd_err | tail -1))"
    fi
}

for rel in "${TARGET_DIRS[@]}"; do
    dir="$MOUNTPOINT/$rel"
    [ -d "$dir" ] || continue
    log "Verifying $rel ..."
    # Found on real hardware, deliberately corrupting a directory's own
    # entries (not a file's content) to test the deep-scan fallback:
    # `find` hit the damage and printed "find: '<dir>': Bad message" to its
    # own stderr - but nothing here was checking that. The files that were
    # in that directory didn't come back UNREADABLE, they just silently
    # never appeared to `find` at all, so they were never counted as
    # anything - not readable, not unreadable, just absent from every
    # total. A card in that state reported a clean "0 unreadable," which
    # is actively misleading: real data was inaccessible through the
    # filesystem, and the deep-scan offer (gated on unreadable-file count)
    # would not have appeared on its own to suggest the one path
    # (raw signature carving) that doesn't depend on directory structure
    # at all. Captured separately so a directory-level failure is reported
    # as its own, explicit thing instead of silently vanishing.
    FIND_ERR=$(mktemp)
    while IFS= read -r -d '' f; do
        verify_one_file "$f"
    done < <(find "$dir" -type f -print0 2>"$FIND_ERR")
    if [ -s "$FIND_ERR" ]; then
        DIRS_WITH_ERRORS=$((DIRS_WITH_ERRORS+1))
        log "WARNING: could not fully list $rel - $(tr '\n' ' ' < "$FIND_ERR") - files in this category may exist on the card but be undiscoverable by a normal directory walk. Counts below do not include them."
    fi
    rm -f "$FIND_ERR"
done

for rel in "${TARGET_FILES[@]}"; do
    f="$MOUNTPOINT/$rel"
    [ -f "$f" ] || continue
    log "Verifying $rel ..."
    verify_one_file "$f"
done

# Kept as its own trailing clause, appended after the existing sentence
# rather than inserted into it, so js/sdcard-recover.js's established
# regex against "$GOOD readable, $BAD unreadable, $TOTAL total" keeps
# matching unchanged - this is parsed separately, as an addition, not a
# replacement.
if [ "$DIRS_WITH_ERRORS" -gt 0 ]; then
    if [ "$DIRS_WITH_ERRORS" -eq 1 ]; then
        DIR_WORD="directory"
    else
        DIR_WORD="directories"
    fi
    log "Verification complete: $GOOD readable, $BAD unreadable, $TOTAL total files. $DIRS_WITH_ERRORS $DIR_WORD could not be fully listed - see warnings above."
else
    log "Verification complete: $GOOD readable, $BAD unreadable, $TOTAL total files."
fi
log "Manifest written to $MANIFEST"

if [ "$BAD" -gt 0 ] || [ "$DIRS_WITH_ERRORS" -gt 0 ]; then
    log "NOTE: files marked UNREADABLE were skipped, not copied, and any"
    log "directory that could not be fully listed may hide more that were"
    log "never counted at all. Consider the deep-scan (raw carving) mode -"
    log "it works directly against the card's raw data and does not depend"
    log "on directory structure being intact."
fi

exit 0
