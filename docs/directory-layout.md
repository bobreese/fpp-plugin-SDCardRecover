# Directory Layout

```
pluginInfo.json         Plugin manifest (name, tracked deps: testdisk/zip, privacy block)
menu.inc                Registers the "SD Card Recover" status-page menu entry
status.php              Main 5-step wizard page
stream.php              Streaming worker (pattern copied from FPP's copystorage.php)
scripts_dispatch.php    Whitelist: stream.php ?cmd= -> one validated shell script + args,
                        merges stderr and appends a real SDCR_EXITCODE:<n> marker
api.php                 Small sync JSON endpoints: evaluate, zip download
js/sdcard-recover.js    Wizard controller + streaming log panels
css/sdcard-recover.css  Step cards, log panes, indeterminate progress bars
scripts/
  common.sh             Device-name validation (same regex family as FPP core's
                         DriveMountHelper), root-device guard, CATEGORY_RE
                         (the authoritative local-restore category list),
                         shared paths, and the log()/SDCardRecover.log
                         plumbing (start/finish trap per script)
  sdcard_scan.sh         Step 1: list removable USB block devices/partitions
                         (skips 0-byte empty card-reader slots)
  sdcard_mount_ro.sh     Step 2: read-only mount attempt -> /mnt/DamagedSD
  sdcard_fsck_check.sh   Fallback: fsck -n (non-destructive) if mount fails
  sdcard_fsck_repair.sh  Explicit opt-in only: fsck -y (destructive)
  sdcard_verify.sh       Core step: read-test every config/media file (dirs
                         AND the standalone settings/timezone files), skip
                         cape-eeprom.bin, write manifest
  sdcard_carve.sh        Deep-scan fallback: photorec raw signature carving
  sdcard_evaluate.sh     Step 4: recoverable size vs. local free space
  sdcard_recover.sh      Step 5: local = category-selective, restores
                         in-place into /home/fpp/media/<category>/ (with
                         config/settings/timezone backups first if Config is
                         included); usb/zip always copy everything verified
  sdcard_unmount.sh      Cleanup
  fpp_install.sh         Plugin Manager install hook: apt-get installs
                         e2fsprogs/dosfstools/exfatprogs/rsync by hand,
                         untracked (see docs/testing.md for why), creates
                         the plugin's own config/plugin.SDCardRecover state dir
  fpp_uninstall.sh       Plugin Manager uninstall hook: unmounts both
                         /mnt/DamagedSD and /mnt/SDCardRecoverDest if still
                         mounted, clears the plugin's own state dir (manifest
                         + any zip not yet downloaded) - never touches files
                         already restored into real media/<category>/
                         directories, a USB drive, or a downloaded zip
```
