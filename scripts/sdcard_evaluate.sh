#!/bin/bash
# Step 4: compare free space on this FPP's own storage against how much
# recoverable data was actually found, so the UI can warn before the user
# picks "Local FPP storage" as a destination that can't fit it.
source "$(dirname "$0")/common.sh"

LOCAL_MEDIA="/home/fpp/media"

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: no manifest found. Run verification or deep scan first." >&2
    exit 1
fi

RECOVERABLE_BYTES=$(awk -F'\t' '$3=="OK"{sum+=$2} END{print sum+0}' "$MANIFEST")
RECOVERABLE_FILES=$(awk -F'\t' '$3=="OK"{c++} END{print c+0}' "$MANIFEST")
UNREADABLE_FILES=$(awk -F'\t' '$3=="UNREADABLE"{c++} END{print c+0}' "$MANIFEST")

LOCAL_FREE_BYTES=$(df --output=avail -B1 "$LOCAL_MEDIA" | tail -1 | tr -d ' ')

log "Recoverable data found: $RECOVERABLE_FILES file(s), $RECOVERABLE_BYTES bytes"
log "Unreadable (skipped): $UNREADABLE_FILES file(s)"
log "Free space on this FPP's local storage ($LOCAL_MEDIA): $LOCAL_FREE_BYTES bytes"

# Prefixed marker line, not just "the last line of output": common.sh's own
# EXIT trap logs "=== ... finished ===" *after* this, which would otherwise
# be mistaken for the payload by anything doing end($out)-style parsing.
php -r '
$recoverableBytes = (int)$argv[1];
$recoverableFiles = (int)$argv[2];
$unreadableFiles  = (int)$argv[3];
$localFree        = (int)$argv[4];
echo "EVALJSON:" . json_encode([
    "recoverableBytes" => $recoverableBytes,
    "recoverableFiles" => $recoverableFiles,
    "unreadableFiles"  => $unreadableFiles,
    "localFreeBytes"   => $localFree,
    "fitsLocally"       => $localFree > ($recoverableBytes * 1.05), // 5% headroom
]) . "\n";
' "$RECOVERABLE_BYTES" "$RECOVERABLE_FILES" "$UNREADABLE_FILES" "$LOCAL_FREE_BYTES"
