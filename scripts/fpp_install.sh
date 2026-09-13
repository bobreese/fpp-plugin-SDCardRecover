#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is installed.
# testdisk/zip are handled by pluginInfo.json's own "dependencies" block
# instead - FPP installs those before this script runs, and tracks this
# plugin as their requester so they're safely reference-counted for removal
# on uninstall. Nothing else this plugin needs goes in that tracked list -
# see below.
#
# e2fsprogs/dosfstools/exfatprogs/rsync all get installed here, by hand,
# deliberately OUTSIDE the tracked dependencies mechanism. e2fsprogs and
# dosfstools are base-system filesystem tools present on virtually every FPP
# image already (e2fsprogs is even Debian-essential); a real uninstall test
# showed FPP's reference-counted removal trying to apt-get remove them
# anyway - it took raspi-firmware down as a side effect of removing
# dosfstools, and would have removed e2fsprogs too had apt's
# essential-package guard not refused. exfatprogs joined them on the same
# caution, even though it isn't itself a base-system package.
#
# rsync moved here for a sharper reason, found on real hardware: it was
# still tracked, on the theory that it was "genuinely this plugin's own
# dependency" - it isn't. FPP's own Copy Settings/MultiSync backup feature
# uses rsync internally, and so does the separate fpp-plugin-RemoteBackup
# plugin, both independent of whether this plugin is installed at all.
# Every uninstall of this plugin correctly-per-FPP's-own-logic, but wrongly
# in reality, removed rsync from the box entirely, because this plugin was
# the only *tracked* claimant FPP knew about - which broke RemoteBackup's
# ability to pull a backup from that box until rsync was reinstalled by
# hand. This line just makes sure all four packages exist; it never
# un-installs any of them.
#
# Package name note: this line used to say "exfat-fsck" instead of
# exfatprogs, which was never a real Debian package - confirmed via
# packages.debian.org ("No such package"). set -e meant the bogus name
# silently aborted this whole script before anything else in it ran, on
# every install until caught here.
set -e
apt-get update
apt-get install -y e2fsprogs dosfstools exfatprogs rsync
mkdir -p /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin installed."
