#!/bin/bash
# Run once by FPP's Plugin Manager when this plugin is installed.
set -e
apt-get update
apt-get install -y e2fsprogs dosfstools exfat-fsck testdisk zip rsync
mkdir -p /home/fpp/media/Recovered
mkdir -p /home/fpp/media/config/plugin.SDCardRecover
echo "SDCard Recover plugin installed."
