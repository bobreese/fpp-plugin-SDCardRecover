#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is installed.
# testdisk/zip/rsync are handled by pluginInfo.json's own "dependencies"
# block instead - FPP installs those before this script runs, and tracks
# this plugin as their requester so they're safely reference-counted for
# removal on uninstall. e2fsprogs/dosfstools/exfat-fsck stay installed here,
# by hand, deliberately OUTSIDE that tracked mechanism: they're base-system
# filesystem tools present on virtually every FPP image already (e2fsprogs
# is even Debian-essential), and a real uninstall test showed FPP's
# reference-counted removal trying to apt-get remove them - it took
# raspi-firmware down as a side effect of removing dosfstools, and would
# have removed e2fsprogs too had apt's essential-package guard not refused.
# This line just makes sure they exist; it never un-installs them.
set -e
apt-get update
apt-get install -y e2fsprogs dosfstools exfat-fsck
mkdir -p /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin installed."
