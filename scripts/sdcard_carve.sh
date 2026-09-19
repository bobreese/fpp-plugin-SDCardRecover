#!/bin/bash
# Deep-scan fallback: raw signature-based carving, offered by the UI after a
# successful mount when sdcard_verify.sh found files the filesystem can no
# longer locate. Works directly against the block device, independent of the
# filesystem's health - so it could in principle also cover the "won't mount
# at all" case, but the UI (status.php/js/sdcard-recover.js) doesn't currently
# offer that path there; see docs/testing.md for the gap. Scoped to file types
# FPP actually uses so the user isn't handed thousands of irrelevant carved
# fragments. Output has no manifest and isn't wired into sdcard_recover.sh -
# retrieve it manually from $OUTDIR.
#
# Requires testdisk/photorec (photorec is testdisk's CLI recovery binary).
source "$(dirname "$0")/common.sh"

DEV="$1"
OUTDIR="$2"
if [ -z "$DEV" ] || [ -z "$OUTDIR" ]; then
    echo "ERROR: usage: sdcard_carve.sh <device> <output-dir>" >&2
    exit 1
fi

DEV=$(validate_device "$DEV") || exit 1
guard_not_root_device "$DEV"

if ! command -v photorec >/dev/null 2>&1; then
    echo "ERROR: photorec not found. Install the 'testdisk' package." >&2
    exit 1
fi

mkdir -p "$OUTDIR"
log "Starting deep scan (raw carving) of $DEV -> $OUTDIR"
log "This does not require a working filesystem and can take a long time"
log "depending on card size; progress below is photorec's own log output."

# photorec's scripted/non-interactive mode: targets specific extensions
# (FPP sequences/media/config) rather than "everything", to keep the output
# relevant and the scan faster than a full recover-every-file-type pass.
photorec /log /d "$OUTDIR" /cmd "$DEV" \
    fileopt,everything,disable,fseq,enable,mp3,enable,wav,enable,mp4,enable,avi,enable,mov,enable,jpg,enable,png,enable,json,enable,search

RC=$?
FOUND=$(find "$OUTDIR" -type f | wc -l)
log "Deep scan complete (exit $RC). $FOUND candidate file(s) carved to $OUTDIR."
log "Carved files have generic names (photorec cannot recover original paths);"
log "review them before moving into your show's media folders."
exit $RC
