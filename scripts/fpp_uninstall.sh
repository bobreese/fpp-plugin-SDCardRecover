#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is removed.
# Deliberately does NOT delete /home/fpp/media/Recovered or any recovered
# data - only cleans up the plugin's own scratch/manifest state.
source "$(dirname "$0")/common.sh" 2>/dev/null || true

if mountpoint -q /mnt/DamagedSD 2>/dev/null; then
    umount /mnt/DamagedSD
fi
rm -rf /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin uninstalled. Recovered data in media/Recovered was left in place."
