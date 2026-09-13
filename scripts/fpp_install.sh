#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is installed.
# testdisk/zip/rsync are handled by pluginInfo.json's own "dependencies"
# block instead - FPP installs those before this script runs, and tracks
# this plugin as their requester so they're safely reference-counted for
# removal on uninstall. e2fsprogs/dosfstools/exfatprogs stay installed here,
# by hand, deliberately OUTSIDE that tracked mechanism: e2fsprogs/dosfstools
# are base-system filesystem tools present on virtually every FPP image
# already (e2fsprogs is even Debian-essential), and a real uninstall test
# showed FPP's reference-counted removal trying to apt-get remove them - it
# took raspi-firmware down as a side effect of removing dosfstools, and
# would have removed e2fsprogs too had apt's essential-package guard not
# refused. exfatprogs joins them here rather than in dependencies.packages
# on the same caution, even though it isn't a base-system package itself.
# This line just makes sure they exist; it never un-installs them.
#
# Package name note: this used to say "exfat-fsck", which was never a real
# Debian package - confirmed via packages.debian.org ("No such package").
# The actual package providing fsck.exfat/mkfs.exfat on Debian 11+ is
# exfatprogs (replaces the old exfat-utils/exfat-fuse combo). set -e meant
# the bogus name silently aborted this whole script before e2fsprogs/
# dosfstools were ever attempted either, on every install until caught here.
set -e
apt-get update
apt-get install -y e2fsprogs dosfstools exfatprogs
mkdir -p /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin installed."
