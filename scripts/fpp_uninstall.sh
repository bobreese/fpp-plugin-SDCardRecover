#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is removed. FPP's own
# scripts/uninstall_plugin discards this script's exit code and removes the
# plugin directory unconditionally afterward, so there's no signal back to
# the UI if any of this fails - it has to be correct on its own.
#
# Only unmounts the source/destination cards this plugin mounted, removes
# the now-empty /mnt/DamagedSD and /mnt/SDCardRecoverDest mountpoint
# directories, and clears its own scratch state. Never touches files
# already restored into real /home/fpp/media/<category>/ directories
# (including the pre-recover config/settings/timezone backups this plugin
# writes to /home/fpp/media/backups/ - FPP's own Backups category, not this
# plugin's scratch state), a USB drive, or a downloaded zip - those are the
# operator's files at that point, not this plugin's.
#
# FPP's own Uninstall confirmation (www/plugins.php) is a generic dialog
# with no per-plugin hook - a plugin can't inject a "download it first?"
# choice into it, and this script itself already runs non-interactively as
# root with nothing to prompt on. So instead of asking, any recovery zip that
# was generated but never downloaded, or deep-scan (carved) output that was
# never retrieved, gets moved to media/upload/ - FPP's File Manager already
# lists and can download anything there (Uploads tab) - rather than being
# silently deleted along with the rest of the scratch state.
source "$(dirname "$0")/common.sh" 2>/dev/null || true

for mp in /mnt/DamagedSD /mnt/SDCardRecoverDest; do
    if mountpoint -q "$mp" 2>/dev/null; then
        src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
        umount "$mp"
        # Found in fpp-data review: only /mnt/DamagedSD ever gets a
        # blockdev --setro (sdcard_mount_ro.sh) - /mnt/SDCardRecoverDest is
        # always mounted read-write - and it was only ever reversed on the
        # explicit fsck-repair path, not on a normal finish. If the card is
        # still plugged in when the plugin is uninstalled, it would
        # otherwise stay block-layer read-only indefinitely, with nothing
        # left installed to ever release it. See scripts/sdcard_unmount.sh
        # for the same fix on the normal (non-uninstall) path.
        if [ "$mp" = "/mnt/DamagedSD" ] && [ -n "$src" ]; then
            blockdev --setrw "$src" 2>/dev/null || true
        fi
    fi
    rmdir "$mp" 2>/dev/null || true
done

STATE_DIR="/home/fpp/media/config/plugin.SDCardRecover"
UPLOAD_DIR="/home/fpp/media/upload"
shopt -s nullglob
zips=("$STATE_DIR"/*.zip)
if [ ${#zips[@]} -gt 0 ]; then
    mkdir -p "$UPLOAD_DIR"
    for z in "${zips[@]}"; do
        mv "$z" "$UPLOAD_DIR/$(basename "$z")"
        log "NOTE: undownloaded recovery zip moved to media/upload/$(basename "$z") - grab it from FPP's File Manager -> Uploads tab, then delete it when done."
    done
fi

CARVED_DIR="$STATE_DIR/carved"
if [ -d "$CARVED_DIR" ] && [ -n "$(find "$CARVED_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    mkdir -p "$UPLOAD_DIR"
    CARVED_DEST="$UPLOAD_DIR/SDCardRecover-carved-$(date +%Y%m%d-%H%M%S)"
    mv "$CARVED_DIR" "$CARVED_DEST"
    log "NOTE: undownloaded deep-scan output moved to media/upload/$(basename "$CARVED_DEST") - grab it from FPP's File Manager -> Uploads tab, then delete it when done."
fi

rm -rf "$STATE_DIR"
echo "SDCard Recover plugin uninstalled."
