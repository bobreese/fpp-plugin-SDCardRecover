#!/bin/bash
# Step 5: copy recovered data to one or more destinations the user picked.
# Only copies files the manifest marked OK (see sdcard_verify.sh), or files
# produced by sdcard_carve.sh when running off a deep-scan manifest instead.
# Uses rsync (same tool FPP's own Copy Settings / MultiSync pages use) so
# progress streams the same way the rest of FPP's backup UI already does.
source "$(dirname "$0")/common.sh"

DEST_TYPE="$1"   # local | usb | zip
DEST_ARG="$2"    # usb: target device partition mountpoint | zip: output path | local: (unused)

if [ -z "$DEST_TYPE" ]; then
    echo "ERROR: usage: sdcard_recover.sh <local|usb|zip> [dest-arg]" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: no manifest found. Run verification or deep scan first." >&2
    exit 1
fi

SRC_ROOT="$MOUNTPOINT"
FILELIST=$(mktemp)
awk -F'\t' '$3=="OK"{print $1}' "$MANIFEST" > "$FILELIST"
COUNT=$(wc -l < "$FILELIST")

if [ "$COUNT" -eq 0 ]; then
    log "Nothing marked OK in the manifest - nothing to recover."
    rm -f "$FILELIST"
    exit 1
fi

case "$DEST_TYPE" in
    local)
        DEST="/home/fpp/media/Recovered/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$DEST"
        log "Recovering $COUNT file(s) to local storage: $DEST"
        rsync -avh --progress --files-from="$FILELIST" "$SRC_ROOT/" "$DEST/"
        RC=$?
        log "Done. Files available under $DEST"
        ;;
    usb)
        if [ -z "$DEST_ARG" ] || [ ! -d "$DEST_ARG" ]; then
            echo "ERROR: usb destination mountpoint '$DEST_ARG' is not a directory." >&2
            rm -f "$FILELIST"
            exit 1
        fi
        DEST="$DEST_ARG/SDCardRecover-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$DEST"
        log "Recovering $COUNT file(s) to USB drive: $DEST"
        rsync -avh --progress --files-from="$FILELIST" "$SRC_ROOT/" "$DEST/"
        RC=$?
        log "Done. Files available under $DEST"
        ;;
    zip)
        ensure_state_dir
        ZIPNAME="SDCardRecover-$(date +%Y%m%d-%H%M%S).zip"
        ZIPPATH="$STATE_DIR/$ZIPNAME"
        log "Packaging $COUNT file(s) into $ZIPNAME for download..."
        (cd "$SRC_ROOT" && zip -q "$ZIPPATH" -@ < "$FILELIST")
        RC=$?
        log "Done. Zip ready: $ZIPPATH"
        echo "ZIPPATH:$ZIPPATH"
        ;;
    *)
        echo "ERROR: unknown destination type '$DEST_TYPE'" >&2
        rm -f "$FILELIST"
        exit 1
        ;;
esac

rm -f "$FILELIST"
exit ${RC:-0}
