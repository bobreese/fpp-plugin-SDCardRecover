#!/bin/bash
# Cleanup: unmount DamagedSD. Called when the user re-scans, picks a different
# device, or finishes a recovery run.
source "$(dirname "$0")/common.sh"

if mountpoint -q "$MOUNTPOINT"; then
    SRC=$(findmnt -n -o SOURCE "$MOUNTPOINT")
    log "Unmounting $MOUNTPOINT..."
    umount "$MOUNTPOINT"
    log "Unmounted."
    # Found in fpp-data review: blockdev --setro (sdcard_mount_ro.sh) was
    # only ever reversed on the explicit fsck-repair path - our own gap,
    # since we added --setro in the first place. After a normal session
    # (no repair), the card stayed block-layer read-only in the running
    # kernel for as long as it remained plugged in. Not a correctness
    # problem for this plugin (it never intends to write to the source
    # anyway), but a real surprise for anything else on the box that later
    # tries to write to that same device while it is still attached, with
    # no obvious reason why it would fail.
    if [ -n "$SRC" ]; then
        blockdev --setrw "$SRC" 2>/dev/null || true
    fi
else
    log "$MOUNTPOINT is not mounted - nothing to do."
fi
