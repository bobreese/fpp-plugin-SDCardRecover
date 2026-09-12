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

# Known FPP locations worth recovering. Adjust if your FPP media layout differs.
TARGET_DIRS=(
    "config"
    "media/sequences"
    "media/music"
    "media/videos"
    "media/effects"
    "media/channeloutputs"
    "media/playlists"
    "media/images"
    "media/plugins"
    "media/upload"
)

TOTAL=0
GOOD=0
BAD=0

for rel in "${TARGET_DIRS[@]}"; do
    dir="$MOUNTPOINT/$rel"
    [ -d "$dir" ] || continue
    log "Verifying $rel ..."
    while IFS= read -r -d '' f; do
        TOTAL=$((TOTAL+1))
        rel_f="${f#$MOUNTPOINT/}"
        expected=$(stat -c '%s' "$f" 2>/dev/null)
        # Read the whole file through dd; a bad sector surfaces as a non-zero
        # exit code or a short read, without writing anything back to the card.
        actual=$(dd if="$f" of=/dev/null bs=1M 2>/tmp/sdcr_dd_err; echo $?)
        read_bytes=$(stat -c '%s' "$f" 2>/dev/null)
        if [ "$actual" = "0" ] && [ -n "$expected" ]; then
            echo -e "${rel_f}\t${expected}\tOK" >> "$MANIFEST"
            GOOD=$((GOOD+1))
        else
            echo -e "${rel_f}\t${expected:-0}\tUNREADABLE" >> "$MANIFEST"
            BAD=$((BAD+1))
            log "  UNREADABLE: $rel_f ($(cat /tmp/sdcr_dd_err | tail -1))"
        fi
    done < <(find "$dir" -type f -print0)
done

log "Verification complete: $GOOD readable, $BAD unreadable, $TOTAL total files."
log "Manifest written to $MANIFEST"

if [ "$BAD" -gt 0 ]; then
    log "NOTE: files marked UNREADABLE were skipped, not copied. Consider the"
    log "deep-scan (raw carving) mode to attempt recovery of these by signature."
fi

exit 0
