# SDCard Recover (FPP plugin scaffold)

Recovers config and media (sequences, music, video, effects, playlists) from a
second, possibly-damaged FPP SD card attached over a USB SD-card reader,
without running any destructive repair unless the user explicitly asks for it.

## Design decisions (from evaluation with the repo owner)

- **No blind fsck.** Recovery scope is decided by actually reading every file
  on the card end-to-end (`scripts/sdcard_verify.sh`), not by trusting fsck or
  filesystem metadata. A file that reads in full is recoverable; a file that
  throws an I/O error is flagged and skipped, not copied half-broken.
- **fsck is a fallback diagnostic, not step 2.** It only runs if the read-only
  mount itself fails: `fsck -n` (non-destructive check) first, and the
  destructive `fsck -y` repair only behind an explicit, separately-confirmed
  UI action (`sdcard_fsck_repair.sh`) - never automatic.
- **Both recovery modes are offered**, per the owner's call: filesystem-level
  read-verification (fast, works when the partition mounts) and raw
  signature-based carving via `photorec` (`sdcard_carve.sh`, slower, works
  even when the filesystem won't mount at all). The UI tells the user what
  was found by each and what's still missing.
- **Destinations:** local FPP storage (`media/Recovered/<timestamp>/`), a
  second attached USB drive, or a zip built for browser download - all three,
  user's choice, matching FPP's existing Copy Settings (USB) and JSON config
  backup (download) patterns.
- **Progress UI** reuses FPP's actual streaming mechanism (`StreamURL()` in
  `www/js/fpp.js` - a long-poll `xhr.onprogress` diff, not WebSocket/SSE) the
  same way Copy Settings and the Remote Backups page do. Note: FPP's real
  backup pages don't show a numeric percentage - what looks like "progress"
  there is the live log text. This scaffold's progress bars are indeterminate
  ("working..." animation) while a step streams, turning solid on completion,
  since there's no byte-accurate source to compute a true percentage from
  fsck/rsync/photorec output.

## Layout

```
pluginInfo.json         Plugin manifest (name, deps: e2fsprogs, dosfstools, testdisk, zip, rsync)
menu.inc                Registers the "SD Card Recover" status-page menu entry
status.php              Main 5-step wizard page
stream.php              Streaming worker (pattern copied from FPP's copystorage.php)
scripts_dispatch.php    Whitelist: stream.php ?cmd= -> one validated shell script + args
api.php                 Small sync JSON endpoints: evaluate, zip download
js/sdcard-recover.js    Wizard controller + streaming log panels
css/sdcard-recover.css  Step cards, log panes, indeterminate progress bars
scripts/
  common.sh             Device-name validation (same regex family as FPP core's
                         DriveMountHelper), root-device guard, shared paths
  sdcard_scan.sh         Step 1: list removable USB block devices/partitions
  sdcard_mount_ro.sh     Step 2: read-only mount attempt -> /mnt/DamagedSD
  sdcard_fsck_check.sh   Fallback: fsck -n (non-destructive) if mount fails
  sdcard_fsck_repair.sh  Explicit opt-in only: fsck -y (destructive)
  sdcard_verify.sh       Core step: read-test every config/media file, write manifest
  sdcard_carve.sh        Deep-scan fallback: photorec raw signature carving
  sdcard_evaluate.sh     Step 4: recoverable size vs. local free space
  sdcard_recover.sh      Step 5: copy OK'd files to local/usb/zip
  sdcard_unmount.sh      Cleanup
  fpp_install.sh         Plugin Manager install hook (apt deps, dirs)
  fpp_uninstall.sh       Plugin Manager uninstall hook (leaves recovered data in place)
```

## Known gaps before this runs on real hardware

This was written without access to a live FPP checkout or a Raspberry Pi to
test against, so before trusting it on an actual damaged card:

1. **Verify FPP's real include/router conventions.** `stream.php` and
   `api.php` reproduce the *pattern* researched from FPP core
   (`DisableOutputBuffering()`, `StreamURL()`, the `getEndpoints<Plugin>()`
   API-registration convention) but the exact `require_once` paths, function
   signatures, and `pluginBaseURL()` helper name should be copied verbatim
   from a current `FalconChristmas/fpp` and `FalconChristmas/fpp-plugin-Template`
   checkout.
2. **photorec's `/cmd` micro-syntax is finicky and version-dependent** - the
   exact extension-whitelist syntax in `sdcard_carve.sh` needs to be tested
   against the `testdisk` package version FPP actually ships, and may need
   `partition_order` / `search` flags adjusted.
3. **`sdcard_evaluate.sh`'s target directory list** (`TARGET_DIRS` in
   `sdcard_verify.sh`) assumes a standard FPP media layout; confirm against
   whatever FPP version/config the target systems run.
4. **Sudo/permissions**: every script assumes it's invoked via `sudo` from the
   web server user, matching FPP core's own pattern in `backups.php` - the
   plugin's sudoers entry (if FPP requires one per-plugin) isn't set up here.
5. No automated tests - this needs to be exercised against a real second SD
   card (ideally one deliberately corrupted in a VM/loopback device first)
   before pointing it at an irreplaceable show's card.

## Suggested repo name

FPP's plugin-manager convention names repos `fpp-plugin-<Name>` (see
`fpp-plugin-Template`) so FPP can recognize and install it - this scaffold
uses `fpp-plugin-SDCardRecover` for that reason, with "SDCard Recover" kept
as the human-facing name in `pluginInfo.json`.
