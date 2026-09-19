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

## Root-device guard didn't cover FPP's own storage device (found in fpp-data review)

Another real, confirmed finding. `guard_not_root_device()` only ever
compared against `root_device()` - the device `/` is mounted from. But
FPP's media directory doesn't have to be on that same device at all:
`www/settings-storage.php`'s `storageDevice` setting lets an operator put
`/home/fpp/media` on its own USB drive entirely. That drive reports
`tran=usb`, identical to any real damaged-card candidate, so
`sdcard_scan.sh` was listing FPP's own live storage as a "found" device,
and `guard_not_root_device()` had nothing that would refuse it - it would
accept it as a mount/fsck-check/fsck-repair/recover-destination target
just like any other candidate.

How bad this actually is depends on the filesystem: `e2fsck`'s own
non-interactive mode refuses to run against a filesystem it detects as
currently mounted, so `fsck.ext4 -y` against a live ext4 storage device
was safe *by luck*, not because this plugin did anything to prevent it.
`fsck.vfat -y` has no equivalent built-in protection and would run
against a live, mounted FAT filesystem if asked to - a real risk of
corrupting the device's entire media library, not just its config.

Fixed with two additions to `common.sh`, both used together:

- `media_device()` - resolves whatever device actually backs
  `/home/fpp/media` (same device as root in the common case, a separate
  one when `storageDevice` is set), and `guard_not_root_device()` now
  refuses that device by name, the same way it already refused root's.
- A general "is any partition of this device mounted somewhere this
  plugin doesn't already control" check, using `findmnt`. This catches
  the storage-device case too, but also anything else mounted for any
  other reason - a broader, more robust guard than naming specific
  devices one at a time. Deliberately excludes `$MOUNTPOINT`/
  `$DEST_MOUNTPOINT` specifically: a partition already mounted there is
  this plugin's *own* prior mount of the exact device being checked (a
  stale mount from an earlier run about to be unmounted and redone, or
  the source card still mounted read-only when `sdcard_carve.sh` runs
  against it) - not something else depending on it. Verified against all
  five call sites (`sdcard_mount_ro.sh`, `sdcard_fsck_check.sh`,
  `sdcard_fsck_repair.sh`, `sdcard_carve.sh`,
  `sdcard_recover.sh`'s usb-destination case) that none of their existing,
  already-tested mount/remount/unmount sequences would now false-positive.

Also updated `sdcard_scan.sh` to exclude the media device (and anything
else with an already-mounted partition) from the listing itself, using
mount data `lsblk` already reports - so a live, in-use device is no
longer even offered as a candidate, not just refused later if picked.

## `validate_device`'s exit 1 couldn't actually stop a script (found in fpp-data review)

A classic bash pitfall, confirmed live before fixing. All five callers do
`PART=$(validate_device "$PART")` - command substitution, which runs
`validate_device` in a **subshell**. `exit 1` inside that function only
exits the subshell; the calling script's own `set -e` (where present)
never sees a failure, and execution continues right past it with `$PART`
empty.

Confirmed live with `/dev/sdz1` (a device that doesn't exist):
`validate_device` correctly printed `"ERROR: /dev/sdz1 is not a block
device"` - the check itself was never the problem - but the calling
script then carried on with `PART` empty: `lsblk` ran with an empty
argument, then `mount -o ro "" /mnt/DamagedSD`. Every downstream command
failed safely on the empty string rather than silently operating on some
*other*, real device, so this was a no-op check rather than an actual
wrong-target risk - but that was luck in what each tool does with `""`,
not something this plugin ensured. `guard_not_root_device`, called
directly rather than through `$(...)`, doesn't have this problem at all -
its `exit` really does end the script, confirmed live refusing a real
`/dev/nvme0n1p1`.

Fixed at all five call sites (`sdcard_mount_ro.sh`, `sdcard_fsck_check.sh`,
`sdcard_fsck_repair.sh`, `sdcard_carve.sh`, and `sdcard_recover.sh`'s
usb-destination case) by checking the command substitution's own exit
status: `PART=$(validate_device "$PART") || exit 1`. `sdcard_recover.sh`'s
call site also needed its existing `rm -f "$FILELIST"` cleanup added to
that same failure path, matching every other early-exit in that script -
a bare `exit 1` there would have skipped it.

## Hardcoded colors broke FPP's dark theme (found in fpp-data review)

`css/sdcard-recover.css` hardcoded hex colors throughout - some boxes set
a light background with no explicit text color at all (silently
inheriting whatever the surrounding theme set), some set dark gray text
with no background. Both looked fine in FPP's light theme and broke in
FPP's dark theme: confirmed FPP uses Bootstrap 5.3's real
`[data-bs-theme="dark"]` mechanism (`www/css/fpp-bootstrap/dist/
fpp-bootstrap-5-3.css`), plus its own design-system layer on top
(`www/css/fpp-system-design.css`, dark overrides in `www/css/fpp-dark.css`)
- a light-background box with no explicit text color would inherit
dark-mode's light body text on top of a background that never changed,
and dark gray text with no background would end up low-contrast against
dark-mode's own dark body background.

Fixed by replacing every hardcoded value with a real FPP/Bootstrap token -
checked each one actually carries a `[data-bs-theme="dark"]` override
before using it, rather than assumed:

- `var(--fpp-bg-card)` / `var(--bs-body-color)` for the two boxes that had
  a hardcoded light background (`.sdcr-intro`, `.sdcr-summary`) - now with
  an explicit, paired text color instead of an inherited one.
- `var(--bs-secondary-color)` / `var(--bs-body-color)` for hint/rollback
  text that had a hardcoded gray with no background (`.sdcr-hint`,
  `.sdcr-rollback-info`).
- `var(--bs-warning-text-emphasis)` / `var(--bs-danger-text-emphasis)` -
  Bootstrap 5.3's own dark-aware "readable colored text on the page
  background" tokens - for the warning/danger text and the flash-highlight
  keyframe's `var(--bs-warning-bg-subtle)`.
- `var(--fpp-border)` / `var(--fpp-bg-disabled)` for borders and the
  progress-bar track.
- `var(--bs-primary)` / `var(--bs-success)` for the step-number badge and
  progress-bar accents, replacing this plugin's own arbitrary custom blue
  with FPP's actual primary color - Bootstrap deliberately keeps these
  brand colors identical in both themes, confirmed in the same compiled
  CSS, so no dark-mode override was needed for them specifically.
- Left `.sdcr-log` alone on purpose: a terminal-style panel that's always
  dark in both themes is a deliberate, common convention, not a light-mode
  box that breaks in dark mode - noted with a comment so it doesn't read
  as an oversight.

Also gave the four bare `class="btn"` buttons (Rescan, "Run fsck -n",
"Run deep scan", Refresh) an explicit `btn-secondary`, matching the
`btn-primary`/`btn-danger` variants every other button already had -
Bootstrap only fully themes a button that declares a variant.

## Deep scan-carving doesn't do what the docs claimed (found in fpp-data review)

README.md and docs/how-it-works.md both described the deep scan as a
second, independent recovery path - implying it could be used whenever the
filesystem-level path couldn't, including when the partition won't mount
at all. Checked that claim against the actual code and it doesn't hold up
on three separate points:

- **The UI never offers it in the "won't mount at all" case.**
  `js/sdcard-recover.js` only reveals `#sdcr-deepscan-offer` after Step 2's
  verify summary renders - which requires a successful mount. The fsck
  fallback branch (mount failed -> `fsck -n` -> optional `fsck -y` -> mount
  retry) has no code path that shows the deep-scan offer instead. So in
  practice deep scan is only ever offered *after* a mount already
  succeeded, as a way to look for files verify's own read-check couldn't
  locate - not as a fallback for an unmountable card, even though
  `photorec` itself works directly against the raw block device and
  genuinely doesn't care whether the filesystem mounts.
- **Its output was never wired into Step 5 (Recover) at all.** Read both
  `sdcard_carve.sh` and `sdcard_recover.sh` in full: `sdcard_carve.sh`
  writes carved files straight into `$OUTDIR`
  (`config/plugin.SDCardRecover/carved/`) with no manifest, index, or
  directory structure - `photorec` recovers by raw signature match, so
  there's no original path information left to record. `sdcard_recover.sh`
  only ever reads `$MANIFEST` (verify's own output) and copies from a
  hardcoded `SRC_ROOT="$MOUNTPOINT/home/fpp/media"`; there was never any
  code path that read from `carved/` at all, let alone one gated on a
  "deep-scan manifest" - that manifest format doesn't exist and never did.
  The header comments in both scripts previously implied otherwise.
- **FPP's File Manager doesn't surface it either**, so "retrieve it
  yourself" wasn't as easy as it sounded. Confirmed against FPP's actual
  `www/filemanager.php`: the Config tab lists files via
  `GetFiles('Config', 'maxdepth=1')`, which never recurses into a
  plugin-internal subdirectory like `config/plugin.SDCardRecover/carved/`.
  Retrieval requires SSH or a `plugin.php?plugin=...&file=...` direct
  download link - never spelled out anywhere in the docs.

None of this is a fabricated feature - deep scan genuinely runs, genuinely
finds files a damaged filesystem can't, and is genuinely useful. The gap
is entirely between what the docs promised (a real second recovery path
with its own destination) and what the code actually does (an
after-the-fact investigative tool whose output you retrieve by hand).
Given how much a real fix (wiring `carved/` into Step 5, teaching it to
tag files with a category the way `sdcard_verify.sh` does, and offering it
from the failed-mount branch too) would have expanded the scope of an
already-submitted plugin, chose to correct the documentation to match the
current, real behavior rather than rush that feature in:

- `README.md`'s "Two recovery modes" bullet now says deep scan is offered
  only after a successful mount+verify, and that its output currently has
  to be retrieved manually.
- `docs/how-it-works.md`'s deep-scan bullet says the same, and no longer
  implies uninstall silently threw the output away (see below).
- `scripts/sdcard_carve.sh`'s header comment now says the UI only offers it
  post-mount, and that its output isn't wired into `sdcard_recover.sh`.
- `scripts/sdcard_recover.sh`'s header comment no longer claims a
  deep-scan-manifest code path exists.
- `status.php`'s deep-scan offer text no longer says "doesn't need a
  working filesystem" in a spot where the UI never actually offers it
  without one, and now tells the user up front that Step 5 won't pick the
  output up automatically.

One real fix landed alongside the doc corrections: `scripts/fpp_uninstall.sh`
previously `rm -rf`'d the plugin's entire state directory unconditionally,
which would have silently destroyed any undownloaded carved output (the
zip-rescue logic added in the earlier uninstall fix only ever looked for
`*.zip` files, never the `carved/` directory). It now moves a non-empty
`carved/` directory to `media/upload/SDCardRecover-carved-<timestamp>/`
before removing the state directory, the same rescue-to-Uploads pattern
already used for an undownloaded recovery zip - so forgetting to grab deep
scan output before uninstalling no longer means losing it, even though
retrieving it before uninstalling is still simpler.

Actually wiring deep scan into a first-class recovery path with its own
destination is tracked as future work, not done here - see item 2 in
"Not yet validated" below.

## Uninstall left mount points and rollback backups with no visibility (found in fpp-data review)

fpp-data review flagged that uninstall leaves behind `/mnt/DamagedSD`,
`/mnt/SDCardRecoverDest`, and the `config.before-recover-*` /
`settings.before-recover-*` / `timezone.before-recover-*` rollback backups
that `sdcard_recover.sh` writes before overwriting Config - and that the
backups in particular "aren't visible in File Manager." Worth being
precise about which part of this was actually a real gap, since an
earlier fix this round (see "Uninstalling didn't clean up everything..."
above) already covered mount *unmounting* and scratch-state cleanup, and
status.php's own rollback warning already claimed the backups were
reachable from "FPP's File Manager."

Checked both halves against FPP's real source rather than assume either
way:

- **The backups genuinely weren't visible in File Manager**, and the
  existing UI text claiming otherwise was wrong. `sdcard_recover.sh` wrote
  them straight to `/home/fpp/media/config.before-recover-<timestamp>`
  etc. - the media root itself. Confirmed against FPP core's real
  `www/config.php` (`GetDirSetting()`) and `www/filemanager.php` that File
  Manager has no tab that browses the media root directly: the Config tab
  lists `configDirectory` (`media/config/`, one level down), and there's a
  real, dedicated **Backups** tab, but it maps to `mediaDirectory .
  '/backups'` (`media/backups/`) - a different, specific subdirectory, not
  the root. A file sitting loose in `/home/fpp/media/` isn't covered by
  either. Fixed by writing these backups to `/home/fpp/media/backups/`
  instead - FPP's own Backups category - so they now show up for real in
  File Manager -> Backups, matching what the UI already told users to
  expect. Updated `status.php`'s rollback text to name the actual
  `backups/` subpath, and `docs/first-recovery-walkthrough.md`'s log
  excerpt to match (that walkthrough's log lines get kept in sync with
  real plugin behavior, same as the log-filename fix earlier this round -
  it's meant to show what actually appears in the log today, not a frozen
  historical transcript).
- **Leaving the two now-unmounted `/mnt/*` directories behind was real but
  minor** - empty directories outside `/home/fpp/media` entirely, so
  distinct from the backups issue above and not covered by the earlier
  uninstall fix (which only ever unmounted them, never removed the
  directories themselves). Fixed with a plain `rmdir` (best-effort, same
  as the rest of this script - it already can't signal failure back to the
  UI) right after each unmount.

What was **not** a bug: keeping the rollback backups around indefinitely
rather than auto-deleting them is intentional, not an oversight - they're
the only way to undo a Config restore (see the "Config restore did
nothing..." and root-device-guard sections above), and this plugin's own
uninstall already goes out of its way to rescue other undownloaded output
rather than silently delete it. The actual gap was narrower: *where* they
were being written, not *whether* they should persist.

## `zip` stayed tracked in `dependencies.packages`, and FPP core uses it too (found in fpp-data review)

`zip` was one of the two packages left in `pluginInfo.json`'s tracked
`dependencies.packages` (alongside `testdisk`), on the theory that it was
genuinely this plugin's own dependency - it's used for the Step 5 zip
download. fpp-data review pointed out this was exactly the `rsync` story
above, repeated: observed live, `zip` was already installed on a box
*before* this plugin was, and FPP's reference-counted removal still ran
`apt-get remove -y zip` on uninstall anyway, because this plugin was the
only *tracked* claimant FPP knew about - the same "correct per FPP's own
logic, wrong in reality" failure mode, just not yet caught breaking
anything specific the way `rsync` broke `fpp-plugin-RemoteBackup`.

The review also cited FPP core's own `www/fppEEPROM.php` (~line 157):
`system("(cd $source && zip -9r - ./) > $tempfile")` when packaging an
EEPROM config for download. Confirmed directly - FPP core shells out to
`zip` itself, unconditionally, with nothing installing it for that purpose
that would register as a claimant in `dependencies.packages`. So `zip`
is realistically pre-installed on most real FPP images already, for
reasons that have nothing to do with this plugin - the same situation
`rsync` was in, just not caught on the same test box.

As the reviewer noted, the deeper issue (FPP's reference counting has no
way to know a package pre-existed before a plugin's install, so it always
removes it as though it didn't) is FPP core's problem, not something a
plugin manifest can fix. Applied the same workaround already in place for
`e2fsprogs`/`dosfstools`/`exfatprogs`/`rsync`: moved `zip` out of
`dependencies.packages` and into `fpp_install.sh`'s untracked,
install-if-missing block (`command -v zip || MISSING+=("zip")`), and added
it to the existing `download` `systemChanges` entry. `testdisk` stays
tracked - nothing found suggests FPP core or another plugin uses it, so
reference-counted removal is the correct behavior for it specifically.

## Read-only mount wasn't a kernel guarantee for every filesystem (found in fpp-data review)

`sdcard_mount_ro.sh` picks mount options by fstype: `ext2`/`ext3`/`ext4`
get `mount -o ro,noload`, `vfat`/`fat32`/`exfat` get plain `mount -o ro`,
and anything unrecognized falls through to that same plain `mount -o ro`.
fpp-data review pointed out that plain `ro` is only the filesystem driver
agreeing not to write on purpose - it isn't enforced by the kernel at the
block-device level. The specific, real gap: if `lsblk` fails to identify
an actual ext2/3/4 partition (empty `FSTYPE`, an exotic partition table,
or just a card weird enough that this whole plugin exists to recover it),
the `*` branch mounts it with plain `ro` and no `noload` - and a `ro`
mount of an ext filesystem with a dirty journal genuinely does replay that
journal on mount, which is a real write, unless `noload` is given. On a
card whose only value is what's still readable, an unintended write is
exactly the outcome this plugin exists to prevent.

Fixed by adding `blockdev --setro "$PART"` before every mount attempt,
regardless of fstype - a block-layer flag the kernel enforces for any
write to that specific partition's device node, independent of which
filesystem driver mounts it or what mount options are given. This
protects the previously-uncovered `*` branch the same as the named
ext/vfat/exfat branches, and adds a second, independent layer under the
existing `noload` flag rather than replacing it.

This interacts with `sdcard_fsck_repair.sh`, which is only ever reached
after a mount attempt already failed (confirmed in
`js/sdcard-recover.js`'s `runFsckCheck`/`runFsckRepair` flow) - meaning by
the time a user clicks the explicit, separately-confirmed "Attempt repair"
button, `sdcard_mount_ro.sh`'s failed attempt has already left that device
block-layer read-only. Without a corresponding fix, `fsck -y` - a
deliberate, user-confirmed write - would have started failing with a
write/EROFS error the moment the mount-level protection above landed,
breaking an already-real-hardware-tested feature. Added
`blockdev --setrw "$PART"` to `sdcard_fsck_repair.sh` right before it
runs, releasing exactly the protection this one script is supposed to
override on purpose.

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
2. **Deep scan/carving is a known UI/wiring limitation, not just an
   untested path.** As documented above, it's only ever offered after a
   successful mount (never from the failed-mount fallback, despite
   `photorec` not needing one), and its output isn't wired into Step 5 -
   it has to be retrieved by hand. On top of that gap, photorec's `/cmd`
   micro-syntax is finicky and version-dependent: the exact
   extension-whitelist syntax in `sdcard_carve.sh` still needs to be
   tested against the `testdisk` package version FPP actually ships, and
   may need `partition_order` / `search` flags adjusted. The path has not
   been exercised on real hardware at all yet.
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
