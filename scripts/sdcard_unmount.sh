#!/bin/bash
# Cleanup: unmount DamagedSD.
#
# Found from a real user report: this comment used to claim this script
# runs "when the user re-scans, picks a different device, or finishes a
# recovery run" - none of that was actually true. Nothing in
# js/sdcard-recover.js ever called it, so a card mounted at Step 2 stayed
# mounted indefinitely, across page reloads and new sessions, until
# something else forced it off - which is exactly what physically
# unplugging the card did, as an unintended side effect (confirmed via
# dmesg: every "USB disconnect" was immediately followed by "EXT4-fs
# (sdX2): shut down requested"). A fresh Scan correctly, by design, hides
# an already-mounted disk, so the same card used last session looked like
# a detection failure instead of what it actually was: still mounted from
# before. Only the "re-scans" case is wired up now (js/sdcard-recover.js's
# runScan() calls this before every Scan/Rescan click) - "finishes a
# recovery run" deliberately is not, since sdcard_recover.sh's
# sibling-partition guard depends on $MOUNTPOINT staying mounted for a
# possible follow-up Recover pass; see docs/testing.md for that tradeoff.
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
