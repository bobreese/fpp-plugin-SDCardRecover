#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is removed. FPP's own
# scripts/uninstall_plugin discards this script's exit code and removes the
# plugin directory unconditionally afterward, so there's no signal back to
# the UI if any of this fails - it has to be correct on its own.
#
# Only unmounts the source/destination cards this plugin mounted and clears
# its own scratch state. Never touches files already restored into real
# /home/fpp/media/<category>/ directories, a USB drive, or a downloaded
# zip - those are the operator's files at that point, not this plugin's.
#
# FPP's own Uninstall confirmation (www/plugins.php) is a generic dialog
# with no per-plugin hook - a plugin can't inject a "download it first?"
# choice into it, and this script itself runs non-interactively via sudo
# with nothing to prompt on. So instead of asking, any recovery zip that
# was generated but never downloaded gets moved to media/upload/ - FPP's
# File Manager already lists and can download anything there (Uploads tab)
# - rather than being silently deleted along with the rest of the scratch
# state.
source "$(dirname "$0")/common.sh" 2>/dev/null || true

for mp in /mnt/DamagedSD /mnt/SDCardRecoverDest; do
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp"
    fi
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

rm -rf "$STATE_DIR"
echo "SDCard Recover plugin uninstalled."
