# Testing & Real-Hardware Findings

Most entries below came from testing against a real second FPP SD card
(`Pi3Test`), read over USB by a second FPP device (`GPIOTest`), with a full
raw `dd` image taken first so corruption tests were safely reversible. A
few later ones came from fpp-data's own listing review instead. Either
way, none of this was guessed at - each bug was traced back to FPP's own
real source before being fixed.

## Recovering to a second USB drive (real bug found on real hardware)

The first end-to-end test on real hardware (a genuinely damaged-adjacent FPP
card, 39 real config/media files found and verified) copied files to
`/mnt/DamagedSD` instead of the second USB stick, and rsync failed with exit
11 (I/O error) - because `/mnt/DamagedSD` **is** the source card, mounted
read-only. The destination dropdown had only ever listed partitions the scan
found *already mounted*, which sounds reasonable until you notice FPP has no
automount daemon: a freshly-inserted destination USB stick is never mounted
by anything, so it never appeared as an option - the only thing that *was*
already mounted was the source card itself (left over from mounting it a
few minutes earlier), so it got offered back as if it were a valid
destination.

Fixed by actually owning the destination drive's mount lifecycle instead of
assuming someone else already did it: `sdcard_recover.sh`'s `usb` case now
takes a raw partition device (e.g. `/dev/sdb1`), mounts it read-write at its
own dedicated `$DEST_MOUNTPOINT` (`/mnt/SDCardRecoverDest`, separate from the
read-only `$MOUNTPOINT` the source stays mounted at), refuses outright if
the chosen destination is the same partition currently mounted as the
source, copies, and unmounts afterward so the drive is safe to remove. The
destination `<select>` (`js/sdcard-recover.js`) now lists partitions
belonging to *other* disks from the scan, not whichever partition scan
happened to see mounted. All three destination branches also now check the
actual exit code of rsync/zip before logging success - the original blindly
logged "Done" regardless, which would have hidden a real failure the next
time one happened for an unrelated reason.

Two more from the same test run, once the mount fix above got a real second
drive actually reachable:

- **Destination dropdown couldn't distinguish two same-shaped drives** - it
  only showed a bare device path (`/dev/sde1`). Now carries the parent disk's
  model through (`sdcr.disks`, populated at scan time) into the label, e.g.
  `/dev/sde1 - Cruzer U (vfat) - 14.7 GB`, matching how FPP's own File Copy
  Backup page labels its own USB device dropdown.
- **rsync exit 23 ("partial transfer due to error") on a real FAT-formatted
  USB stick**, even though the files themselves landed intact and complete.
  `-a` bundles owner/group/permission/symlink preservation, none of which
  FAT32/exFAT/NTFS - what a plain USB flash drive is almost always formatted
  as - can actually hold, so rsync exits non-zero over metadata it was never
  going to be able to set, not over the file data. `sdcard_recover.sh` now
  checks the destination's fstype and drops those flags (`-rth` instead of
  `-avh`) for vfat/exfat/ntfs targets.
- **Recovered files landed nested as `SDCardRecover-<ts>/home/fpp/media/config/...`**
  instead of `SDCardRecover-<ts>/config/...` - technically correct (the
  files were genuinely there) but clunky, since `sdcard_verify.sh`'s
  manifest paths are `home/fpp/media/...` (needed to locate files on the
  mounted root filesystem) and that full path was being preserved verbatim
  into the recovered folder. `sdcard_recover.sh` now re-roots the copy at
  `.../home/fpp/media` and strips that prefix from every listed path, so the
  output mirrors a normal FPP `media/` directory directly.

## Config restore did nothing to the device's actual identity (real bug, real hardware)

First full test: restored every category, including Config, from a card
named `Pi3Test` onto a device named `GPIOTest`, rebooted, and the name never
changed. Root cause: FPP's actual device identity - `HostName`, network
config, output settings, everything `$settings[]` holds - lives in **one
flat key=value file**, `/home/fpp/media/settings` (`www/config.php`:
`$settingsFile = $mediaDirectory . "/settings"`), which is a **sibling** of
`media/config/`, not inside it and not inside any other `TARGET_DIRS` entry.
`sdcard_verify.sh` only ever walked directories, so this file was never
captured, verified, or restored, no matter what categories were selected -
"config" was restoring plugin/model JSON files under `config/`, but never
touching the one file that actually holds the device's name.

Fixed by adding a `TARGET_FILES` list to `sdcard_verify.sh`, read-tested the
same way as everything else, and folding it into the `config` category in
`sdcard_recover.sh` (it doesn't match the `^config/` path-prefix filter
everything else uses, since it isn't under a `config/` subfolder at all, so
it's bundled in explicitly). Also now backed up separately
(`settings.before-recover-<timestamp>`), alongside the existing `config/`
directory backup, before either is touched.

## Categories cross-checked against FPP's own JSON config backup

Since FPP's own JSON configuration backup (`www/backup.php`,
`$system_config_areas`) already has the maintainer-verified, canonical
answer to "what counts as FPP's config," it made sense to check our
category list against it directly rather than keep discovering gaps one
real-hardware test at a time. That turned up one real mistake and two real
gaps:

- **`channeloutputs` was never a real directory** - confirmed against
  `$system_config_areas['channelOutputs']` and `www/config.php`: channel
  output settings are files (`config/channeloutputs.json`,
  `config/universes.json`, etc.) directly inside `config/`, already covered
  by that category. This TARGET_DIRS entry never pointed at anything real,
  which is consistent with it silently never showing up in any verify log
  across every real-hardware test so far - not because the card lacked it,
  but because the path itself was never valid on any FPP install. Removed.
- **`media/scripts` and `media/events`** (`$scriptDirectory`,
  `$eventDirectory` in `www/config.php`) - Command/Event scripts, real
  directories that were simply never on the list at all.
- **`media/channelmemorymaps`** (`$system_config_areas['channelmemorymaps']`)
  - legacy Pixel Overlay Models, a real directory distinct from (and never
  the same as) the fabricated `channeloutputs`.
- **`media/timezone`** (`$timezoneFile` in `www/config.php`) - another flat
  top-level file like `settings`, holding the device's configured timezone;
  folded into the `config` category the same way `settings` is, and backed
  up the same way before being overwritten.

`CATEGORY_RE` (`scripts/common.sh`), `TARGET_DIRS`/`TARGET_FILES`
(`sdcard_verify.sh`), the config-category bundling and backups
(`sdcard_recover.sh`), and the Step 5 checkbox list (`status.php`) were all
updated together so they can't drift out of sync with each other again.

## Cross-checked against FPP's OTHER backup tool too (File Copy Backup)

FPP actually has two separate, maintainer-verified canonical lists of
"what matters": the JSON config backup above, and
`scripts/copy_settings_to_storage.sh` (the "File Copy Backup" page this
plugin's UI/progress model is patterned on in the first place). Its named
actions (All, Music, Sequences, Scripts, Plugins, Images, Events, Effects,
Videos, EEPROM, Playlists, Backups, JsonBackups, Configuration) turned up
two more real things:

- **`media/backups`** is its own real, separate directory (the "Backups"
  action's `$SOURCE/backups`) - distinct from `config/backups` (JSON config
  backup archive, already covered inside the `config` category). Added as
  its own category.
- **`config/cape-eeprom.bin` is explicitly excluded** from FPP's own
  "Configuration" copy action - it's BeagleBone-specific virtual EEPROM cape
  data, hardware identity that doesn't make sense to carry onto different
  physical hardware, unlike everything else under `config/`. Our `config`
  category walks every file under `config/` recursively, so without an
  explicit skip it would have blindly included this. Added
  `SKIP_FILES_RELATIVE`/`is_skipped_file()` in `sdcard_verify.sh` to exclude
  it specifically, matching FPP's own convention, while still walking
  everything else under `config/` as before.

## The fsck fallback UI could never actually appear (real bug, real corruption test)

Deliberately trashing a real card's ext4 superblock (`dd if=/dev/urandom`
onto the first 4KB of the partition, on a real second FPP SD card set aside
for this) surfaced the first genuine mount failure this plugin had ever
seen - and the "Run fsck -n" fallback box never appeared. Two compounding
bugs, both in `scripts_dispatch.php`'s `sdcr_passthru()`:

1. **No `2>&1`.** Every script's own `echo "ERROR: ..." >&2` (used for
   every hard failure - "not mounted," "no manifest found," etc.) went to
   Apache's error log, never to the browser or `SDCardRecover.log`. Verify's
   actual reason for exiting immediately ("not mounted") existed, just
   wasn't visible anywhere a user could see it.
2. **No real exit-code reporting.** `streamCommand()` (`js/sdcard-recover.js`)
   was inferring success from `xhr.status`, which a `passthru()`-streamed
   response always returns as 200 regardless of what the wrapped script
   actually exited with. `runMount()`'s fsck-fallback branch and
   `runFsckCheck()`'s repair-offer branch could **never** run, no matter
   what happened server-side - the "success" path always fired.

Fixed by adding `2>&1` and appending a parseable `SDCR_EXITCODE:<n>` marker
after `passthru()` returns; `streamCommand()` now parses that (not
`xhr.status`) to determine real success/failure, stripping the marker from
what's displayed/logged. Also added `scrollToMountLog()` (called from both
fsck fallback paths) since the retried mount/verify write into Step 2's main
log panel, not the nested fsck sub-box the user is actually looking at when
a check/repair finishes - confirmed confusing on real hardware when a
repair that had actually succeeded read as "nothing happened."

With this fixed, the full chain was validated end-to-end on the real
trashed card: failed mount -> `fsck -n` correctly found real errors (using
an automatically-recovered backup superblock - ext4's own resilience, not
this plugin's) -> confirmed `fsck -y` repair (which itself reported a
partial failure, exit 12, "unable to set superblock flags") -> automatic
mount retry succeeded anyway -> Verify found all tracked files readable
again, zero data loss. Worth calling out: the code retries the mount after
repair *unconditionally*, regardless of the repair's own exit code - had it
treated a nonzero repair exit as "give up," this successful recovery would
have been missed.

## Uninstalling didn't clean up everything, and once nearly took the Pi's bootloader with it (real bug, real hardware)

Uninstall had never actually been exercised before this pass - and testing
it properly meant going around FPP's own UI, not through it:

- **FPP discards `fpp_uninstall.sh`'s exit code entirely.** Confirmed by
  pulling FPP core's real `scripts/uninstall_plugin`: it runs the plugin's
  uninstall hook, then unconditionally deletes the plugin's whole directory
  regardless of what that hook returned. The Plugin Manager reports
  "uninstalled" successfully no matter what our script actually did - the
  only way to know uninstall really worked is checking device state
  directly (mountpoints, leftover directories), never the UI's own message.
- **It only unmounted `/mnt/DamagedSD`, never `/mnt/SDCardRecoverDest`** -
  a destination USB mount left over from an interrupted recovery wasn't
  being cleaned up at all. Fixed to unmount both.
- **The "leaves recovered data in `media/Recovered` in place" message was
  simply false** - that staging folder hasn't been used since recovery
  started writing straight into real `media/<category>/` directories, a USB
  drive, or a zip (see the USB-recovery bug section above). Removed the
  message, and the now-pointless `mkdir` for that folder from
  `fpp_install.sh`.
- **The real find: FPP reference-counts `dependencies.packages` and removes
  them on uninstall if nothing else claims them - and that took
  `raspi-firmware` down with it.** A real uninstall on `GPIOTest` triggered
  `apt-get remove` for every package `pluginInfo.json` declared as a
  dependency at the time (`e2fsprogs`, `dosfstools`, `testdisk`, `zip`,
  `rsync`). Removing `dosfstools` pulled `raspi-firmware` - the Pi's own
  boot/kernel-update package - down as a side effect; it had to be manually
  reinstalled. It also tried to remove `e2fsprogs`, and only failed because
  apt refused without `--allow-remove-essential` (`e2fsprogs` is
  Debian-essential). Fixed by moving `e2fsprogs`/`dosfstools` out of
  `dependencies.packages` entirely, grouping them with `exfatprogs` (see
  below) in a plain, untracked `apt-get install` inside `fpp_install.sh`
  that only ever ensures they exist - they're base-system filesystem tools
  present on virtually every FPP image already, not something this plugin
  should claim ownership of for removal purposes. `testdisk`/`zip` stayed
  in `dependencies.packages` at the time - `rsync` did too, on the theory
  that it was genuinely this plugin's own dependency. It wasn't; see below.
- **`exfat-fsck` was never a real Debian package** - `fpp_install.sh` had
  installed it by that name since the original scaffold, unverified, and it
  went uncaught until the first real install exercised after the fix above
  (previously `e2fsprogs`/`dosfstools`/`testdisk`/`zip`/`rsync` were *also*
  covered by the tracked `dependencies.packages` path, so `fpp_install.sh`'s
  own install line silently failing on the bogus name - `set -e` aborts the
  whole script the moment `apt-get install` can't resolve any one name in
  the list - went unnoticed). Confirmed via `packages.debian.org`
  ("No such package"); the real package providing `fsck.exfat`/`mkfs.exfat`
  on Debian 11+ is `exfatprogs`. Fixed in `fpp_install.sh`.
- **Fixed: uninstall used to delete any recovery zip that was generated but
  never downloaded, with no warning** (confirmed happening on real
  hardware). There's no fix through FPP's own Uninstall confirmation
  dialog - it's a generic modal built entirely in `www/plugins.php` with no
  per-plugin hook, and `fpp_uninstall.sh` itself runs non-interactively via
  `sudo` with nothing to prompt on, so a plugin genuinely cannot ask
  "download it first?" at that point. Instead, `fpp_uninstall.sh` now moves
  any undownloaded zip to `/home/fpp/media/upload/` rather than deleting
  it - FPP's File Manager already lists and can download anything in its
  Uploads tab (confirmed in `www/filemanager.php`), so the file survives
  uninstall and stays reachable from the UI without SSH.
- **`rsync` staying in `dependencies.packages` broke a different plugin on
  a different device.** After a routine uninstall of this plugin on
  `GPIOTest`, the separate `fpp-plugin-RemoteBackup` plugin - running on
  another FPP device entirely (`Pi5Backup`) - started failing to back up
  `GPIOTest` specifically, with `rsync: command not found` /
  `rsync error: error in rsync protocol data stream (code 12)`. `rsync`
  runs on both ends of an SSH pull; that's the signature of the *remote*
  side missing the binary, not the initiating one. `GPIOTest` was the only
  remote in Remote Backup's status table showing that error - everything
  else backed up and verified fine. Checking `fpp-plugin-RemoteBackup`'s
  own `pluginInfo.json` confirmed it installs `rsync` itself, untracked,
  outside `dependencies.packages` - exactly the pattern this plugin had
  just adopted for `e2fsprogs`/`dosfstools`/`exfatprogs` - so it was never
  a registered claimant of `rsync` in FPP's reference count. This plugin
  was the *only* tracked claimant on that box, and its own uninstall
  correctly-per-FPP's-logic, but wrongly in reality, took `rsync` down with
  it - the same `raspi-firmware` lesson, this time causing an actual break
  in a second, unrelated plugin instead of a near-miss. `rsync` moved out
  of `dependencies.packages` and into the untracked `apt-get install` line
  alongside the other three. Also added the `systemChanges` entry
  (`kind: download`) this plugin was missing for that untracked install
  line, matching the equivalent entry already present in
  `fpp-plugin-RemoteBackup`'s own privacy block.

## Initial Setup reappears after a cross-device Config restore (expected, not a bug)

Restoring Config from `Pi3Test` onto `GPIOTest`, then rebooting, correctly
changed `GPIOTest`'s own identity - its FPP header showed `Pi3Test`
afterward, confirming the `settings`/`timezone` fix actually works end to
end. But FPP's Initial Setup wizard (Location/Device/Privacy/Security) came
back too, which looked wrong at first: this device had already been through
setup once.

Traced through FPP's real `www/privacyConsent.inc` and `www/common.php`
rather than guessed at: FPP stamps its privacy-consent record (the
statistics/crash-data/vendor-logo choices from the wizard's Privacy step)
with `getSystemUUID()` - a value derived live from *hardware* each boot
(CPU serial / device-tree / board EEPROM, see `scripts/get_uuid`), never
stored in a file a backup could carry over. The source is explicit about
why:

> Binds the record to the device it was given on. Without this a settings
> backup restored onto a second player carries the first player's consent,
> and its owner is never asked anything.

So on reboot, `PrivacyConsentShortfall()` compared the restored record's
UUID (`Pi3Test`'s) against `GPIOTest`'s own real hardware UUID, found a
mismatch, and correctly classified it `'other-device'` - by design, not a
malfunction. FPP is refusing to let a restored backup silently inherit
another physical device's privacy consent. **Expect Initial Setup to
reappear once after restoring Config from a different physical device** -
everything else (name, network, other settings) will already be in place;
only the privacy consent step is being genuinely re-asked. A note to this
effect is in the in-app Config warning (`status.php`) so it isn't a
surprise.

## `api.php` was executed on every FPP API request and failed to load, every time (real bug, found in fpp-data review)

Not a hardware test this time - a manual review comment on the fpp-data
listing submission, verified against FPP's own real source before fixing,
same as everything else here.

FPP's `www/api/index.php` calls `addPluginEndpoints()` ->
`collectPluginEndpoints()` (`www/api/controllers/plugin.php`)
unconditionally on **every** `/api/*` request - not just requests aimed at
this plugin, and not gated by which page is open. That function scans
every installed plugin's directory and, for any that contains a file
literally named `api.php`, `require_once`s it looking for a
`getEndpoints<repoName>()` registrar - a real, PHP-only convention,
distinct from fppd's separate C++ `/plugin-apis/<name>` API this plugin
had already (correctly) ruled out as inapplicable back in
[Architecture](architecture.md). The mistake was concluding that ruling
out the C++ mechanism meant *no* auto-registration mechanism applied - it
meant only that one didn't. The PHP one applies to any file named
`api.php`, whether or not it was ever written to be a registrar, and ours
wasn't: it was page-style code with top-level side effects (reads
`$_GET['endpoint']`, sets a response code, echoes JSON), meant to be
`include_once`'d via `plugin.php?page=api.php&nopage=1` the same way
`stream.php` is. Its `require_once "config.php"` - a bare relative path
that only resolves against the plugin's own directory when reached that
specific way - failed to open when FPP core's own scan pulled the file in
directly instead.

Confirmed live: 10 calls to `/api/system/status` on a device with this
plugin installed produced 12 new lines in
`/home/fpp/media/logs/apache2-error.log` - FPP's own log directory,
included in support zips:

```
PHP Warning:  require_once(config.php): Failed to open stream ... api.php on line 19
FPP: skipping plugin API for 'fpp-plugin-SDCardRecover' -- api.php failed to load
```

`collectPluginEndpoints()` wraps the `require_once` in
`catch (\Throwable $e)` specifically so one broken plugin's `api.php`
can't take down the whole API for every other route - confirmed by the
second log line above matching that catch block's own message verbatim -
so the plugin's real functionality wasn't affected. The cost was pure log
noise: FPP's own status page polls `/api/system/status` roughly once a
second, which works out to on the order of 40 MB/day of warnings logged
for something this plugin never intended to be reachable that way at all.

Fixed by renaming the file to `ajax.php` (and updating
`js/sdcard-recover.js`'s two references to it) rather than converting it
into a real `getEndpoints<repoName>()` registrar - that would mean
re-routing it under `/api/plugin/fpp-plugin-SDCardRecover/...` instead of
through `plugin.php`'s page dispatch, a bigger change to an
already-working, already-tested piece of the plugin for no real benefit
here. The lesson generalizes: **don't name a plugin file `api.php` unless
it's actually meant to be a `getEndpoints` registrar** - FPP will find and
execute it either way.

## `fpp_install.sh` upgraded base-system packages and rewrote the boot initramfs (real bug, found in fpp-data review)

Another review comment, confirmed live before fixing. The reasoning
behind keeping `e2fsprogs`/`dosfstools`/`exfatprogs`/`rsync` off the
tracked `dependencies.packages` list (see the uninstall/`raspi-firmware`
section above) was sound - but the *install* side still ran
`apt-get update && apt-get install -y e2fsprogs dosfstools exfatprogs rsync`
unconditionally, every single install, regardless of whether those
packages were already present. That's not a no-op: `apt-get install` on
an already-installed package upgrades it to the newest available
candidate, and `apt-get update` immediately beforehand is exactly what
makes a newer candidate visible in the first place.

Confirmed live via `/var/log/apt/history.log` on a real install:

```
Upgrade: libext2fs2t64, libcom-err2, comerr-dev, rsync, logsave, libss2, e2fsprogs
```

`e2fsprogs`'s own postinst trigger then ran `update-initramfs`,
regenerating `/boot/firmware/initramfs8` and `initramfs_2712` - the actual
files `auto_initramfs=1` loads at boot - with `W: missing
/lib/modules/6.18.34+rpt-rpi-v8` (module-less images for a kernel version
the box didn't even have). A plugin whose entire purpose is recovering
data from a *second* SD card has no business rewriting the *boot* path of
the device it's installed on.

Fixed by dropping `apt-get update` entirely and checking
`command -v fsck.ext4 fsck.vfat fsck.exfat rsync` first, only running
`apt-get install` for whichever of the four are actually missing - so an
already-present package is never named in an install command at all, and
never touched. Small side benefit: `pluginInfo.json`'s own privacy
declaration for this line already said "if not already present" - before
this fix that wasn't actually true (it ran unconditionally regardless of
what the declaration claimed); now the code matches what was already
being told to the installer.

## Log file was named wrong, so it was never rotated (real bug, found in fpp-data review)

Another confirmed review finding. `PLUGIN_GUIDELINES.md` section 1.1 mandates
exactly one runtime log, named `<logdir>/plugin-<repoName>.log` - for this
plugin, `plugin-fpp-plugin-SDCardRecover.log`. This plugin's log had
instead always been named `SDCardRecover.log` (see the mentions of that
name earlier in this document, from when that really was its name). The
`plugin-` prefix isn't a style preference - it's the glob FPP's own log
management uses to rotate plugin logs (by size, keeping the last 2
copies, compressed) separately from its own. A log that doesn't match
that glob is invisible to that mechanism and grows without bound for as
long as the plugin stays installed.

`scripts/common.sh` also hard-coded `/home/fpp/media/logs` as a fallback
for `$LOGDIR` rather than resolving it the way `PLUGIN_GUIDELINES.md`
itself recommends: sourcing `${FPPDIR}/scripts/common`, which is what
actually defines `$LOGDIR` (from `$MEDIADIR`, itself read from
`${FPPDIR}/www/media_root.txt` when present) rather than guessing at it.
A hard-coded path silently breaks on a relocated media directory; sourcing
FPP's own script doesn't.

Fixed by renaming the log to `plugin-fpp-plugin-SDCardRecover.log` and
replacing the hand-rolled `$LOGDIR` fallback in `scripts/common.sh` with
`: "${FPPDIR:=/opt/fpp}"; . "${FPPDIR}/scripts/common"`, exactly the
snippet `PLUGIN_GUIDELINES.md` itself provides for shell scripts. Checked
FPP's own `scripts/common` for function-name collisions with this
plugin's own `common.sh` first (none - FPP's are camelCase like
`ensureLogFile`/`startPluginLog`, this plugin's are snake_case) before
sourcing the whole file.

## Config restore wrote straight to disk with fppd possibly still running, no restart flag (found in fpp-data review, partially fixed)

Another review finding, researched against fppd's own C++ source rather
than taken at face value. `sdcard_recover.sh`'s local-restore path
`rsync`s straight into `/home/fpp/media/config/` and overwrites
`/home/fpp/media/settings`/`timezone` directly on disk, then only *logs*
"restart FPPD" - it never actually told FPP that anything changed.

Confirmed the real risk this creates by reading `src/settings.cpp`: fppd
loads `settings` into memory once and keeps serving that in-memory copy,
but its own `setSetting(key, value, persist=true)` doesn't do a full
rewrite of the settings file - it re-reads the file fresh, finds that one
key's line, and patches only that line back in. So the danger isn't
"fppd overwrites everything we just restored" wholesale; it's narrower:
if anything triggers fppd to persist some *other* setting while it's
still running on its old, pre-restore in-memory values, that one key
could get patched with fppd's stale value, landing on top of an
otherwise-successful restore - and nothing was telling the operator (or
FPP itself) that a restart was actually needed to avoid that window.

Fixed the part the reviewer called the minimum fix: `sdcard_recover.sh`
now calls `setSetting restartFlag 1` right after a successful Config
restore - FPP's own shell `setSetting()` (from `scripts/common`, already
sourced via this plugin's `common.sh` since the log-naming fix above),
the same locked, canonical write every other FPP script uses for this,
not a hand-rolled sed. `restartFlag` is what FPP's own web UI reads
(`www/api/controllers/system.php`) to show a "Restart Needed" banner
across every page - not just a line in this plugin's own log a user could
miss - which shrinks the risk window by making the restart hard to
overlook.

**Not done**: the reviewer's "better" fix - routing the restore through
FPP's own `/api/backups` JSON restore or `copy_settings_to_storage.sh`'s
restore path instead of a raw `rsync`, so fppd's own restore tooling
handles the coordination rather than a flag set after the fact. That's a
real architectural change, not a patch: this plugin's local restore is
category-selective and driven by `sdcard_verify.sh`'s own
readability-checked manifest, which doesn't map directly onto what either
of FPP's restore tools expects as input (a full JSON config backup
archive, or a File-Copy-Backup-shaped directory tree). Left as an open
item rather than rushed.

## Validated on real hardware

Confirmed working end-to-end:

- Scan -> Mount (read-only, ext4 partition correctly chosen over the vfat
  boot partition) -> Verify -> Evaluate -> Recover, on a healthy card
- Recover to **local** storage, category-selective, restoring directly into
  `/home/fpp/media/<category>/`
- Recover to a **second USB drive** (including onto a real FAT-formatted
  stick, exercising the `-rth` vs `-avh` rsync-flags fix)
- Recover to a **zip** download
- The full **fsck fallback chain** on a genuinely trashed superblock: failed
  mount -> `fsck -n` diagnosis -> confirmed `fsck -y` repair -> automatic
  mount retry -> clean Verify, zero data loss (see the section above)
- **Uninstall**, after the fixes above: both mountpoints cleaned up, the
  plugin's own state dir removed, the plugin directory itself removed, and
  `raspi-firmware`/`dosfstools`/`rsync` confirmed reinstalled cleanly
  afterward
- **Config restore actually changing this device's identity on reboot.**
  Restored Config onto `GPIOTest` from `Pi3Test` and rebooted: `GPIOTest`'s
  own FPP header correctly showed `Pi3Test` afterward, confirming the
  `settings`/`timezone` fix works end to end (see the section above for the
  one real surprise this surfaced - FPP's Initial Setup wizard reappearing,
  which turned out to be expected FPP behavior, not a bug in this plugin)

**Not yet validated:**

1. **The "some files unreadable" path, with a genuine I/O error** (as
   opposed to silent data corruption). Confirmed during testing: writing
   `/dev/urandom` over live SD card sectors changes their *content* but
   doesn't produce a real read failure - flash storage just returns
   whatever's there, corrupted or not, without raising an I/O error unless
   there's an actual unrecoverable hardware fault. `sdcard_verify.sh`'s
   dd-based check can only ever catch genuine read failures, by design -
   silent content corruption is outside what a checksumless read test can
   detect. Testing this path properly needs a `dm-flakey`/loopback virtual
   device configured to actually return I/O errors for chosen byte ranges,
   which real SD hardware can't be made to do on demand.
2. **photorec's `/cmd` micro-syntax is finicky and version-dependent** - the
   exact extension-whitelist syntax in `sdcard_carve.sh` needs to be tested
   against the `testdisk` package version FPP actually ships, and may need
   `partition_order` / `search` flags adjusted. The deep-scan/carving path
   has not been exercised at all yet.
3. **Sudo/permissions**: every script assumes it's invoked via `sudo` from the
   web server user, matching FPP core's own pattern in `backups.php` - the
   plugin's sudoers entry (if FPP requires one per-plugin) isn't set up here.
   (Real testing so far hasn't hit a permissions problem, but that's not the
   same as this being formally set up.)
4. **Routing local Config restore through FPP's own restore tooling**
   (`/api/backups` JSON restore, or `copy_settings_to_storage.sh`'s restore
   path) instead of a raw `rsync` straight to disk - see the section above.
   `restartFlag` is set now, which shrinks the risk window, but doesn't
   change that fppd could in principle still be running when the write
   happens. A real architectural change, not yet attempted.
