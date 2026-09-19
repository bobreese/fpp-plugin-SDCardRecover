#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is installed.
# testdisk is handled by pluginInfo.json's own "dependencies" block instead
# - FPP installs it before this script runs, and tracks this plugin as its
# requester so it's safely reference-counted for removal on uninstall.
# Nothing else this plugin needs goes in that tracked list - see below.
#
# e2fsprogs/dosfstools/exfatprogs/rsync/zip all get installed here, by hand,
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
# hand. This step just makes sure all these packages exist; it never
# un-installs any of them.
#
# zip joined the untracked group for the same reason, found in fpp-data
# review: it was still declared in dependencies.packages, on the theory
# that it was this plugin's own dependency (it's used for the Step 5 zip
# download). It isn't exclusively - FPP core itself shells out to zip
# directly (www/fppEEPROM.php, packaging an EEPROM config as a zip), so a
# box can easily have it installed already for reasons that have nothing
# to do with this plugin, exactly like rsync above. Reference-counted
# removal doesn't know that; observed live, uninstalling this plugin ran
# `apt-get remove -y zip` even though zip predated this plugin's install.
#
# Package name note: this line used to say "exfat-fsck" instead of
# exfatprogs, which was never a real Debian package - confirmed via
# packages.debian.org ("No such package"). set -e meant the bogus name
# silently aborted this whole script before anything else in it ran, on
# every install until caught here.
#
# Only install what's actually missing - found in fpp-data review, then
# confirmed live: apt-get install on an already-installed package upgrades
# it to the latest candidate, and apt-get update is exactly what makes a
# newer candidate visible in the first place. A real install triggered
# upgrades of e2fsprogs and its dependents, whose postinst trigger then ran
# update-initramfs and regenerated /boot/firmware's initramfs images for a
# kernel version the box didn't even have modules for. A plugin install
# should never touch the boot path - dropped apt-get update entirely, and
# every package below is only ever installed if its binary isn't already
# on PATH, so an already-present package is never touched at all.
set -e
MISSING=()
command -v fsck.ext4  >/dev/null 2>&1 || MISSING+=("e2fsprogs")
command -v fsck.vfat  >/dev/null 2>&1 || MISSING+=("dosfstools")
command -v fsck.exfat >/dev/null 2>&1 || MISSING+=("exfatprogs")
command -v rsync      >/dev/null 2>&1 || MISSING+=("rsync")
command -v zip        >/dev/null 2>&1 || MISSING+=("zip")
if [ ${#MISSING[@]} -gt 0 ]; then
    apt-get install -y "${MISSING[@]}"
fi
mkdir -p /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin installed."
