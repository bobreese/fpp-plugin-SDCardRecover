#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is removed. FPP's own
# scripts/uninstall_plugin discards this script's exit code and removes the
# plugin directory unconditionally afterward, so there's no signal back to
# the UI if any of this fails - it has to be correct on its own.
#
# Only unmounts the source/destination cards this plugin mounted and clears
# its own scratch state (manifest + any zip not yet downloaded). Never
# touches files already restored into real /home/fpp/media/<category>/
# directories, a USB drive, or a downloaded zip - those are the operator's
# files at that point, not this plugin's.
source "$(dirname "$0")/common.sh" 2>/dev/null || true

for mp in /mnt/DamagedSD /mnt/SDCardRecoverDest; do
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp"
    fi
done

rm -rf /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin uninstalled."
