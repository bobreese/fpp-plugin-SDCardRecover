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
it to the existing `download` `systemChanges` entry (later removed
entirely - see "Privacy block over-declared..." below, once §6.2 turned
up showing that entry was never needed in the first place). `testdisk`
stays tracked - nothing found suggests FPP core or another plugin uses
it, so reference-counted removal is the correct behavior for it
specifically.

**Confirmed live, and worth understanding rather than being alarmed by**:
upgrading a real `GPIOTest` install through this exact change (from a
version with `zip` still in `dependencies.packages` to one without) shows
FPP's Plugin Manager print `No longer declared by 'fpp-plugin-SDCardRecover':
zip.`, then run `apt-get remove zip` on its own, entirely on FPP's own
initiative - the same reference-counted removal this whole fix exists to
avoid, firing exactly once, triggered by the *diff* between the plugin's
old and new declared dependencies rather than anything ongoing. `fpp_install.sh`
runs immediately afterward in that same upgrade transaction and its own
`command -v zip || MISSING+=("zip")` check catches the now-missing binary
and reinstalls it right back, so the box ends the upgrade with `zip`
present either way - confirmed in that same log (`SDCard Recover plugin
installed`, `rc=0` throughout). This remove-then-reinstall churn is a
one-time artifact of crossing *this specific* version boundary, not a
recurring problem - a plugin manifest that declares a package once and
never un-declares it doesn't trigger FPP's "no longer declared" path at
all, which is exactly the steady state this plugin is in from here on.

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

## `LOCKFILE` was declared and never used - no protection against concurrent runs (found in fpp-data review)

`common.sh` declared `LOCKFILE="/tmp/sdcard-recover.lock"` from early in
this plugin's history, but nothing ever opened or locked it - confirmed
with a repo-wide search turning up exactly one reference, the declaration
itself. Nothing stopped two browser tabs, or two different people on the
same network both pointed at this FPP's web UI, from running `mount_ro`,
`fsck_repair`, and `recover` (rsync) at the same time against the same
shared `$MOUNTPOINT`, `$MANIFEST`, and `$STATE_DIR` - e.g. one tab's
`sdcard_recover.sh` rsync mid-copy while another tab's `sdcard_unmount.sh`
pulls the source card out from under it, or two concurrent `fsck -y`
repairs racing on the same partition.

Fixed by actually using it: `common.sh` now does
`exec {SDCR_LOCK_FD}>"$LOCKFILE"` followed by a non-blocking
`flock -n "$SDCR_LOCK_FD"`, right after `log()` is defined. Every script
in this plugin sources `common.sh`, so this serializes the whole plugin
globally - at most one script runs at a time, across all tabs and
sessions - and a second concurrent attempt fails immediately with a clear
error instead of silently racing or hanging (neither fppd nor this
plugin's own UI has any way to show "waiting for another tab"). The lock
is released automatically when the holding process exits, since it's tied
to that process's file descriptor - no separate unlock/cleanup code
needed. Confirmed no script here ever invokes another one as a
subprocess (`scripts_dispatch.php` dispatches each independently, one per
request), so there's no self-nesting deadlock risk from a script trying to
re-acquire a lock it already holds.

`flock` itself is a standard, long-established coreutils primitive, but
this specific usage hasn't been exercised on real hardware yet - see item
5 in "Not yet validated" below.

## `renderDeviceList` built HTML by string concatenation with an attacker-controlled string (found in fpp-data review)

`js/sdcard-recover.js`'s `renderDeviceList()` built each Step 1 device row
with `row.innerHTML = '<input ...value="' + obj.device + '"> ' + '<strong>'
+ obj.device + '</strong> - ' + obj.model + ' (' + humanSize(obj.size) +
', ' + obj.tran + ')'`. `obj.model` traces straight back to `lsblk`'s
`MODEL` field (confirmed in `sdcard_scan.sh`: `"model" => $d["model"] ??
"Unknown"`, taken directly from `lsblk`'s JSON output) - the USB device's
own self-reported vendor/product string, not something this plugin or FPP
controls. A crafted USB device (or a card reader/gadget programmed to
report one) could set that string to `<img src=x onerror=...>` or similar
and get it parsed as live HTML the moment its "damaged card" shows up in
Step 1's list, in the browser of whoever's logged into this FPP's admin
UI.

Confirmed the fix actually neutralizes it before committing: fed the
exact payload through the corrected code in a real browser JS engine and
checked the resulting DOM - no `<img>` element was created; the string
came back as literal escaped text (`&lt;img src=x
onerror=alert(1)&gt;`), not a parsed element.

Fixed by building the row with `document.createElement`/`textContent`/
`document.createTextNode` instead of `innerHTML` - text nodes never parse
their content as markup, so this is safe regardless of what a device
claims its model is, without needing to sanitize the string itself.
Exactly the pattern `populateUsbDestinations()` (the Step 5 destination
dropdown, a few lines below) already used for the same `model` field -
this bug was really just an inconsistency between two functions handling
the same untrusted data differently, not a design gap in the plugin as a
whole. Checked the file's other four `innerHTML` sites for the same
pattern: all four (the evaluate-results table, its error message, and the
zip-download link) only ever embed numbers this plugin computed itself or
its own generated filenames, not raw external device-reported strings, so
they were left alone rather than churned for a bug they don't have.

## Every action - including `fsck_repair` and the Config overwrite - was a plain `GET` (found in fpp-data review)

`js/sdcard-recover.js`'s `streamCommand()` (the single function every wizard
step goes through - scan, mount, `fsck_check`, `fsck_repair`, `carve`,
`verify`, `recover`, `unmount`) sent `cmd`/`args` as a query string on a
plain `xhr.open('GET', url, true)`, and `stream.php` read them back out of
`$_GET`. That includes `fsck_repair` (`fsck -y`, a real, irreversible
write) and `recover` with Config selected (overwrites this device's own
name/IP/settings) - both real actions, not read-only ones, reachable with
nothing more than a GET request carrying the right query string.

The real risk fpp-data review named: a GET request doesn't need
JavaScript or same-origin permission to fire from an attacker's page - a
bare `<img src="http://<this-fpp>/plugin.php?...&cmd=fsck_repair&args[device]=...">`
on any web page the logged-in admin's browser merely loads would fire it,
browser-enforced same-origin policy or not (an `<img>` tag's GET isn't
subject to it the way a cross-origin `fetch()`/XHR read would be).

Checked the reviewer's own comparison before treating this as
plugin-specific: confirmed live in FPP core's actual
`www/api/controllers/system.php` - `/api/system/reboot` really is declared
`@route GET`. So this wasn't a novel mistake unique to this plugin; FPP
core has the same shape of issue on at least one of its own destructive
endpoints. That made it defensible as "consistent with FPP," not
something blocking submission - but moving to POST costs nothing and
narrows the exposure regardless of what FPP core eventually does with its
own endpoints.

Fixed both sides: `streamCommand()` now does `xhr.open('POST', url, true)`
with `cmd`/`args` moved into the request body
(`application/x-www-form-urlencoded`) instead of the query string, and
`stream.php` reads `$_POST['cmd']`/`$_POST['args']` instead of `$_GET`.
`ajax.php`'s two endpoints (`evaluate`, `download`) were left alone -
both are read-only (no state change), and `download` specifically has to
stay a plain link a browser can navigate to directly. Also dropped the
old GET version's `_=Date.now()` cache-busting query param - browsers
don't cache POST responses in the first place, so it was dead weight once
GET wasn't the transport anymore.

Verified the client-side change actually does what it's supposed to
before committing: stubbed `XMLHttpRequest` in a real browser JS engine
and confirmed `streamCommand('fsck_repair', {device: '/dev/sdb1'}, ...)`
opens `POST` against a URL with no `cmd`/`args` in it at all, and sends
`cmd=fsck_repair&args[device]=%2Fdev%2Fsdb1` as the request body -
exactly the encoding `stream.php`'s existing `$_POST['args']['device']`
access already expects, since PHP parses bracket-array syntax identically
whether it arrives via `$_GET` or `$_POST`.

Worth being honest about what this does and doesn't fix: POST alone isn't
a complete CSRF defense - a same-origin form or a fetch with
`credentials: 'include'` could still forge one from a malicious page that
gets the admin to visit it, since neither FPP core nor this plugin uses
CSRF tokens or checks `Origin`/`Referer`. What POST does close off is the
single-tag, JavaScript-free drive-by case the reviewer specifically
described - a real, cheap improvement, not a claim that this is now fully
CSRF-proof.

## `rsync -a` as root preserved the damaged card's file ownership (found in fpp-data review)

`sdcard_recover.sh`'s local-restore rsync (`rsync -avh --progress
--files-from="$CAT_FILELIST" "$SRC_ROOT/" "/home/fpp/media/"`) runs as
root (every script here does, via `sudo`), and `-a` (archive mode)
includes `-o`/`-g` - owner and group preservation. Only root can actually
set arbitrary ownership on a copy, which is exactly the situation this
script runs in, so nothing was stopping it: whatever uid/gid the damaged
card's files happened to carry - not necessarily this box's own `fpp:fpp`,
for instance if that card had ever been touched as root directly, or came
from an FPP image with a different `fpp` uid - would land unchanged on
this device's real `/home/fpp/media/`, files `fppd` and the web server
(both running as `fpp`) need to actually own or at least read.

Fixed by adding `--chown=fpp:fpp` to that rsync call, so recovered files
always end up owned by this device's own `fpp` user regardless of what
the source card's files were owned by. Left the USB-destination rsync
(`sdcard_recover.sh`'s `usb` case, copying to a user-chosen second drive)
alone - that's the operator's own external drive, not a location FPP
itself expects consistent ownership on, and the finding was specifically
about `/home/fpp/media`.

## `echo -e` could corrupt the manifest on a filename containing a backslash (found in fpp-data review)

`sdcard_verify.sh` wrote each manifest line with
`echo -e "${rel_f}\t${expected}\tOK" >> "$MANIFEST"`. `-e` makes `echo`
interpret backslash escapes **in its argument**, and `$rel_f` is a
filename read off the damaged card - not a literal this script controls.
Confirmed live in a shell: a filename containing a literal backslash-t
(`foo\tbar.mp3`, unusual but a legal ext4 filename) came out of
`echo -e` as `foo<TAB>bar.mp3<TAB>...` - the literal `\t` *inside the
filename* got reinterpreted as a real tab, silently turning one
three-column manifest line into a corrupted one with an extra column.
Every downstream consumer (`sdcard_evaluate.sh`, `sdcard_recover.sh`)
reads this file with `awk -F'\t'`, so a corrupted line means a
miscounted file, a truncated filename, or a parse that quietly picks up
the wrong field.

Fixed by switching both manifest-writing lines to
`printf '%s\t%s\t%s\n' "$rel_f" "$expected" "OK"` (and the `UNREADABLE`
equivalent). `printf`'s `%s` substitutes each argument verbatim - only
the *format string* is ever scanned for escapes/specifiers, never the
substituted values - so arbitrary filename content (backslashes, percent
signs, anything) passes through unchanged. Confirmed the fix with the
same test: the corrected `printf` line preserved the literal `foo\tbar.mp3`
as one unbroken field.

## Restoring "Plugins" installed code without going through FPP's own install flow (found in fpp-data review)

The Plugins category in Step 5's local restore was a bare checkbox with
no warning at all - unlike Config, which gets its own "(see warning)"
link, a dedicated warning box, and a required confirmation checkbox
before Recover unblocks. Checking what restoring Plugins actually does
found it deserved the same treatment, for a reason more serious than data
loss: it's an `rsync` of raw files from the recovered card's
`home/fpp/media/plugins/` straight into this device's own
`media/plugins/` - it does not run that plugin's own `fpp_install.sh`,
does not register it in FPP's plugin tracking, and never shows the
operator FPP's own install/privacy screen for it. FPP still auto-loads
plugin code from that directory regardless of how it got there - `api.php`
is the sharpest example (see the `api.php` finding earlier this round):
any plugin containing a file literally named that gets `require_once`'d
on every single FPP API request from that point on. Restoring "Plugins"
from a card whose contents the operator doesn't already know and trust is
effectively installing arbitrary third-party code on this device, bypassing
every safeguard FPP's own Plugin Manager provides.

Given Config already established the pattern for "this category needs
explicit, informed consent before Recover will run," Plugins got the
identical treatment rather than a one-off: a `(see warning)` link, a
warning box explaining exactly what does and doesn't happen, and a
required "I understand and want to proceed" checkbox that blocks Recover
the same way Config's does. The two links now share one small
`wireCategoryWarningLink()` helper in `js/sdcard-recover.js` instead of
duplicating the same handler twice. Verified the gating logic itself in a
real browser JS engine before committing: checking Plugins without
confirming leaves Recover disabled and shows the warning; confirming
enables it; checking both Config and Plugins with neither confirmed keeps
Recover disabled and shows both warnings; and clicking a warning link
auto-checks its category and flashes the box, matching Config's existing,
already-real-hardware-tested behavior exactly.

## Privacy block over-declared a `download` entry for default-apt-source packages (found in fpp-data review)

`pluginInfo.json` had declared a `download` systemChanges entry for
`fpp_install.sh`'s untracked `apt-get install` of `e2fsprogs`/
`dosfstools`/`exfatprogs`/`rsync`/`zip`, on the theory (recorded in
`docs/privacy.md`) that only packages left in `dependencies.packages`
were exempt from needing one. Confirmed against the real, current
`PLUGIN_GUIDELINES.md` §6.2, fetched fresh rather than relied on memory:
"Packages taken from the default apt, PyPI, npm and CPAN sources are
*not* a `download` and need no `privacy` entry." All five packages come
from a plain `apt-get install` against the box's already-configured
default apt sources - no added package source, no `curl|bash`, no vendor
binary - so the exemption applies regardless of whether they're declared
in `dependencies.packages` or installed by hand, which this doc had
backwards.

The reviewer called this over-declaration "harmless," and it is - an
extra disclosure doesn't mislead an operator the way a missing one would.
Removed it anyway: the `dependencies.packages`-vs-`fpp_install.sh`
placement question (see the `raspi-firmware`/`rsync`/`zip` incidents
above) is entirely about reference-counted *removal* safety, a completely
separate question from what needs a `privacy` entry, and conflating the
two is exactly what produced the wrong conclusion here. `docs/privacy.md`
corrected to cite §6.2 directly instead of the earlier, incorrect
reasoning.

## Destination dropdown never populated for a USB stick with a corrupted partition table (real bug, real hardware)

Real-hardware test on `GPIOTest`: `sdcard_scan.sh` found both a real second
SD card and a SanDisk Cruzer USB stick in Step 1, but after mounting the
SD card as the source and reaching Step 5, clicking **Refresh** to find
the Cruzer as a destination never populated the `#sdcr-usb-target`
dropdown - it stayed on the placeholder no matter how many times it was
clicked.

Root cause, confirmed from the plugin's own downloaded log bundle rather
than guessed: the Cruzer's own partition table is corrupted. `fdisk -l`
showed `/dev/sda1` starting at sector 1,948,285,285 on a disk that is only
15,633,408 sectors long - a partition starting roughly 125x past the end
of the drive, plus a zero-length `sda2` and a bogus `sda4` - and the
kernel's own boot log recorded a bare `sda:` with nothing after the colon
when the drive was attached, meaning it refused to create any
`/dev/sda1`-style partition device node for it at all (compare to the
real SD card in the same log, which showed ` sdc: sdc1 sdc2`).

That traced to a genuine gap in `sdcard_scan.sh`: its `lsblk`-driven scan
only ever emitted a `"partition": true` JSON line for a disk's actual
`children` (kernel-exposed partition device nodes). A disk with none -
whether because its table is corrupted (this Cruzer) or because it is
"superfloppy" media with a filesystem written directly on the whole disk
and no partition table at all (some smaller/cheaper USB sticks ship this
way) - produced only a bare "disk" line and no "partition" line at all.
`js/sdcard-recover.js`'s `populateUsbDestinations()` builds the
destination `<select>` exclusively from `sdcr.usbDevices`, which is
populated exclusively from `"partition": true` lines - so a disk with zero
partition children could never appear there, silently, no matter how many
times Refresh ran. (It could still appear as a Step 1 *source* candidate,
since that list is built from the disk lines directly - which matches
exactly what was observed: found in Step 1, absent from Step 5.)

Fixed with two real, distinct cases in `sdcard_scan.sh`:

- **Superfloppy media** (no partition children, but the disk itself
  reports an `fstype`): now emits a synthetic `"partition": true` line
  using the disk's own device path as both `device` and `parent`, so a
  genuinely usable whole-disk filesystem shows up as a selectable
  destination the same as a normal partitioned drive would.
- **Neither partitions nor a filesystem of its own** (this Cruzer's actual
  case): still correctly offers nothing as a destination - there is
  nothing usable to offer, and this plugin does not format drives - but
  now logs a clear `NOTE:` line naming the device, its model, and size,
  and pointing at a corrupted partition table as the likely cause, instead
  of silence. Verified the classification logic (which of the three cases
  a device falls into) against three synthetic `lsblk`-shaped device
  trees - a normal unmounted disk with real partitions, a superfloppy
  disk, and this exact corrupted-Cruzer shape - reproducing the real
  values from the downloaded log (7.45 GiB, model "Cruzer", no children,
  no disk-level fstype) before committing.

Restructured the scan's output handling to make the `NOTE:` line land in
the plugin's own persistent log (`media/logs/plugin-fpp-plugin-SDCardRecover.log`),
not just the live browser panel: the `lsblk`/PHP pipeline's output is now
captured into a variable (this operation is a single near-instant pass,
unlike the genuinely slow fsck/rsync/photorec scripts that need real
incremental streaming) instead of streamed directly, then `NOTE:` lines
are split out and re-emitted through `common.sh`'s own `log()` function
so they persist the same way every other message this plugin logs does -
matching the plugin's own established single-log-file convention rather
than adding a second, log-file-invisible diagnostic channel.

This specific Cruzer stick still cannot be used as a recovery destination
until its partition table is fixed or recreated on another computer - that
part is a real limitation of the drive, not something this plugin can or
should work around by formatting it. What was fixed is that the plugin
now says so, instead of leaving an empty dropdown as the only signal.

## Destination dropdown could silently exclude a healthy drive that reused the source's old device letter (real bug, real hardware)

Follow-up test on `GPIOTest`, after reformatting the USB stick that
surfaced the previous finding: this time `fdisk`/`lsblk` confirmed the
stick had a completely normal, healthy partition (`/dev/sdb1`, 14.6 GiB
FAT32) - the reformat worked, and this was a different bug. Step 5's
**Refresh** still could not find it as a destination, even though a
later full page reload and fresh Step 1 **Scan** did find it.

The real cause: `populateUsbDestinations()` (`js/sdcard-recover.js`)
skipped any candidate partition whose `parent` matched `sdcr.device` - a
plain device-path string ("/dev/sda") captured once, at Step 1 selection
time, and never updated afterward. `dmesg` from this exact session showed
the destination stick attaching and detaching three separate times
(re-plugged during testing), and Linux reuses device letters as drives
come and go - there is nothing that reserves a letter for a device that
is no longer present. If the source card was originally assigned, say,
`/dev/sda` at Step 1 and later got reassigned `/dev/sdb` (also observed:
the source mounted at `sdb2` in this same session, having used other
letters in earlier sessions), and the destination stick's own later
insertion happened to land on the now-vacated `/dev/sda`, this check
compared the destination's *current* letter against the source's *stale*
one from earlier in the session - matched by coincidence - and silently
dropped a perfectly healthy destination from the list.

The check was also always redundant in the intended flow, independent of
the staleness bug: Step 5 is only reachable after Step 2 has mounted the
source card, and `sdcard_scan.sh`'s own server-side scan already excludes
any disk with a currently-mounted partition (`$hasMountedChild` in the
embedded PHP walk) - using live mount state, not a cached client-side
string, so it can never go stale the same way. The client-side check
could only ever do useful work in a state the server had already handled
correctly, or actively harmful work when a stale letter got reused.

Removed the check entirely. Verified the exact failure mode and the fix
before committing: reproduced the buggy version's output on a synthetic
scenario shaped like the real one (`sdcr.device` left at a stale
`/dev/sda` from an earlier selection, a healthy `/dev/sda1` destination
partition now sitting at that same letter after a replug) in a real
browser JS engine - the old code left the dropdown empty except for the
placeholder, the fixed code correctly listed the destination.

## The source card's own sibling partition could be picked as a USB destination and written to (found in fpp-data review)

A follow-up review on the previous fix caught a real regression it
introduced: removing the stale `sdcr.device` check from
`populateUsbDestinations()` (commit `88f8d34`) was justified there as safe
because "the source disk is only reachable here after Step 2 mounts it,
and the server already excludes a mounted disk" - true for the **Refresh**
path, but wrong for a second call site to the same function:
`populateUsbDestinations()` also runs immediately at Step 1's radio-select
(`js/sdcard-recover.js`, right where `sdcr.device` is set), straight from
the Step 1 scan's data - which still includes the source disk's own
partitions, since nothing is mounted yet and `sdcard_scan.sh` has no
reason to exclude it at that point. Without any client-side filter, the
source card's sibling partition (its untouched boot partition, say
`/dev/sda1`, sitting next to the `/dev/sda2` about to be mounted
read-only) landed in the Step 5 destination dropdown under the same model
string as the card itself.

The more serious half: the server accepted it too. `sdcard_recover.sh`'s
`usb` branch only ever compared the chosen destination against
`findmnt -n -o SOURCE "$MOUNTPOINT"` - the exact mounted partition, not
its siblings. `guard_not_root_device()` (`common.sh`) didn't catch it
either: its per-partition loop only refuses a partition mounted somewhere
*other than* `$MOUNTPOINT`/`$DEST_MOUNTPOINT` - an unmounted sibling like
`/dev/sda1` trips nothing, since it isn't mounted anywhere at all. And
`blockdev --setro` (the read-only guarantee from an earlier finding) only
ever covers the one partition actually passed to `sdcard_mount_ro.sh` -
never a sibling that was never mounted. Picking that sibling as a `usb`
destination would have mounted it read-write and rsynced files onto it -
writing to the very card this entire plugin exists to read safely,
exactly the outcome the read-only mount, `blockdev --setro`, and the
existing exact-partition check were all meant to prevent, just from a
partition none of them were looking at.

Fixed on both sides, matching the reviewer's own framing of it as a
two-layer gap:

- **Server-side (the real enforcement boundary):** added `source_device()`
  to `common.sh` - the same `sed -E 's/p?[0-9]+$//'` pattern
  `root_device()`/`media_device()` already use, resolving the whole disk
  backing `$MOUNTPOINT` - and extended `sdcard_recover.sh`'s existing
  exact-partition check with a second one: refuse `DEST_PART` if its own
  parent disk matches the source's, not just if it's the identical
  partition. This is the check that actually matters - a client-side bug
  or a hand-crafted request bypasses the dropdown entirely, but not this.
- **Client-side (defense in depth + the dropdown itself being correct):**
  restored a filter in `populateUsbDestinations()`, keyed on the freshest
  identity available - `sdcr.partition`'s own parent disk (via a new
  `diskOf()` helper, the same regex family as the bash side) once Mount
  has run, falling back to `sdcr.device` before that - rather than
  reintroducing the original staleness bug the prior fix was solving.
  Also made Step 5's destination list re-scan automatically the moment it
  unlocks (`runEvaluate()`'s success handler now calls
  `refreshUsbDestinations()`), so a destination plugged in during Steps
  2-4 shows up without the user needing to remember to click Refresh, and
  the list reflects the source's now-actually-mounted state rather than
  Step 1's stale snapshot.

Verified both fixes before committing: the bash `sed` pattern against
`/dev/sda2`, `/dev/mmcblk0p2`, and `/dev/nvme0n1p1` (all three real naming
schemes this plugin's own `DEVICE_RE` accepts) all correctly resolved to
their parent disk; and the JS fix against three scenarios in a real
browser engine - Step 1 selection time (both source siblings correctly
excluded, unrelated destination shown), post-Mount (same, via
`sdcr.partition`), and a plain unrelated destination with no source disk
in play (still shown, no false-positive regression).

## Restoring Config could import the source card's own copy of this plugin's scratch state (found in fpp-data review)

This plugin's own scratch directory, `config/plugin.SDCardRecover/` (=
`$STATE_DIR` in `common.sh`, holding `manifest.tsv` and any zips not yet
downloaded), lives inside `config/` exactly like any other plugin's own
settings - so `sdcard_verify.sh`'s recursive walk of `home/fpp/media/config`
verified it right along with everything else, with nothing distinguishing
it from real, wanted configuration.

That is a problem specifically because the SOURCE card can have its own
copy of this exact directory - either because this same plugin was once
installed on that card too, or because that card was itself "this device"
for a completely unrelated SDCardRecover session at some point - holding a
manifest.tsv and zips from that unrelated session, not real recoverable
user data. Restoring the `config` category locally would rsync that stale
`manifest.tsv` straight over **this session's own live `$MANIFEST`** at
the exact same path (`sdcard_recover.sh`'s local-restore rsync writes into
`/home/fpp/media/`, and `$STATE_DIR` is `/home/fpp/media/config/plugin.SDCardRecover`
- the two are literally the same directory). Since `runRecover()`
(`js/sdcard-recover.js`) runs every checked destination sequentially in
one Recover click, checking **local** (with Config) alongside **zip** or
**usb** meant the second destination's `sdcard_recover.sh` invocation
would read whatever the first one had just overwritten `$MANIFEST` with -
the unrelated card's old file list, not this session's - and copy the
wrong files, or none. Even without that specific ordering, any of the
three destinations (local, zip, usb) could bundle the source card's old
zips/carved output as if they were real recovered data, since none of
them filter by anything more specific than "is this file marked OK in the
manifest."

Fixed at the source rather than special-casing every destination that
consumes the manifest: extended `sdcard_verify.sh`'s existing
`is_skipped_file()` (previously only an exact-match list, used for
`cape-eeprom.bin` - see the "Categories cross-checked..." section above)
with a second, prefix-based list, `SKIP_DIR_PREFIXES_RELATIVE`, and added
`config/plugin.SDCardRecover/` to it. Everything under that path -
`manifest.tsv`, any zips, a `carved/` subdirectory - now never enters the
manifest under any category, so it can never be selected for local
restore, bundled into a zip, or copied to a USB destination, regardless
of restore order. Verified the exclusion logic directly against seven
cases before committing: both flagged paths (the exact `cape-eeprom.bin`
match and anything under the new prefix, including a nested `carved/`
file) correctly skipped, and three lookalikes - a `config/co-general.json`
file that merely starts with the same two letters, a *different* plugin's
own `config/plugin.OtherPlugin/` directory, and the top-level `settings`
file - all correctly still verified normally.

## No `platforms` restriction - Installable (and broken) on platforms this plugin cannot run on (found in fpp-data review)

`pluginInfo.json`'s `versions[0]` entry never declared `platforms`.
Confirmed against the real, current `PLUGININFO_FORMAT.md`: leaving it
unset means an entry matches *every* platform FPP reports via
`/etc/fpp/platform` - including the FPP builds for generic Linux
(Fedora) and native macOS, not just the Debian-based SBC images
(Raspberry Pi, BeagleBone) this plugin was actually written for. On those
unsupported platforms, this plugin would have shown as a normal,
Installable card in the Plugin Manager - `pluginInfo.json` itself gave no
signal that anything was wrong - and then failed partway through
install: `fpp_install.sh` calls `apt-get` directly (no such thing on
Fedora or macOS), and every script in `scripts/` depends on `lsblk`,
`blockdev`, `findmnt`, `mount`, `fsck.*`, and `/mnt` existing and
behaving the way they do on a Debian-based image. In practice, the
`testdisk` entry in `dependencies.packages` would have failed the
install outright first, with an FPP-level error to that effect ("does
not support system packages") rather than this plugin's own code ever
running - a confusing failure for anyone on an unsupported platform
who had no way to know before clicking Install.

Fixed by adding `"platforms": ["Raspberry Pi", "BeagleBone Black",
"BeagleBone 64"]` to the `versions[0]` entry - the exact platform strings
`PLUGININFO_FORMAT.md`'s table requires, matched exactly since FPP
compares them as plain strings against `/etc/fpp/platform`. Deliberately
narrower than everywhere this plugin could plausibly work: nothing in the
code is Pi-specific, and Armbian/Debian/Ubuntu Hosts are all apt-based
and would likely work too, but none of them have actually been tested,
and declaring support is also a commitment to field bug reports from
whatever's declared. Raspberry Pi and BeagleBone are the two platform
families this plugin has actually been built and tested against - see
[Installing This Plugin](installing.md#supported-platforms) for the
same reasoning written up for an installer, not a reviewer.

## `blockdev --setro` was never reversed after a normal (non-repair) session (found in fpp-data review, on our own earlier fix)

`blockdev --setro` (added in an earlier fpp-data-review round to make the
read-only source mount a real kernel guarantee, not just a mount option -
see "Read-only mount wasn't a kernel guarantee..." above) was only ever
reversed in one place: `sdcard_fsck_repair.sh`, right before its own
explicit, user-confirmed write. Every other path - a normal Scan -> Mount
-> Verify -> Evaluate -> Recover session with no repair needed, or
uninstalling the plugin outright - left the card block-layer read-only in
the running kernel indefinitely, for as long as it stayed physically
plugged in. Fair to call this one on us: we added `--setro` in the first
place, so reversing it everywhere the mount ends is the same fix's other
half, not a separate pre-existing bug.

Not a correctness problem for this plugin itself - it never intends to
write to the source card at all outside the explicit repair path, so the
flag being "stuck" set never breaks anything this plugin does. The real
issue is for anything else on the box: if the card is left plugged in
after a session (or the plugin is uninstalled while it's still attached),
some other tool or script - a manual `dd`, another plugin, a shell command
over SSH - could try to write to that same device and fail with no
obvious reason why, since `blockdev --getro` isn't something anyone would
think to check first.

Fixed by releasing the flag everywhere a normal session actually ends:

- `sdcard_unmount.sh` (Cleanup - called when the user re-scans, picks a
  different device, or finishes a recovery run) now captures
  `findmnt -n -o SOURCE "$MOUNTPOINT"` before unmounting and runs
  `blockdev --setrw` on it afterward.
- `fpp_uninstall.sh` does the same for `/mnt/DamagedSD` specifically (not
  `/mnt/SDCardRecoverDest`, which is always mounted read-write and never
  gets `--setro` in the first place) - covering the case where the card is
  still attached when the plugin is removed and nothing would otherwise
  ever release it.

Both are best-effort (`2>/dev/null || true`), matching this plugin's own
established convention for cleanup steps that cannot signal failure back
to the UI anyway - a `blockdev --setrw` racing a card that gets physically
unplugged between `umount` and this call is not a failure worth aborting
cleanup over.

## A scan's own results never reached the persistent log file (real bug, found by a user comparing the two)

A user noticed that the raw device/partition JSON lines visible in a live
scan (`{"device":"/dev/sda", ...}`, one per line) simply were not present
in the downloaded `plugin-fpp-plugin-SDCardRecover.log` - only the
`log()`-produced "Scanning for removable USB storage.../Scan complete."
bookends around them were.

Root cause, confirmed by re-reading `sdcard_scan.sh`'s own recent history:
those lines are printed with a plain `echo`, not `log()`, deliberately -
the browser-facing stream has to stay raw, unprefixed JSON that
`js/sdcard-recover.js`'s `parseScanLines()` can `JSON.parse()`
line-by-line; a `log()`-style `"[timestamp] {...}"` line would fail that
parse. `log()` is also the only thing that ever appends to `$LOG_FILE` -
so a scan's actual findings, unlike every other message this plugin logs,
never reached the persistent log at all. This had been silently
hampering troubleshooting through this exact round of real-hardware
testing: several earlier sessions in this doc had to be diagnosed from
raw `dmesg`/`lsblk` snapshots in FPP's own `troubleshootingCommands.log`
specifically *because* the plugin's own log never recorded what a scan
had actually found - the single most useful piece of information for
"why didn't my drive show up," missing from every log bundle sent so far.

Fixed by adding `log_file_only()` to `common.sh` - the same timestamp
format as `log()`, but appending to `$LOG_FILE` only, never echoing to
stdout - and using it in `sdcard_scan.sh` to persist a `"Scan found:"`
block listing every line of that scan's real output (device and
partition entries alike), separately from the raw stream the browser
already gets. Verified directly before committing: fed the exact device
lines from the report that surfaced this (a real `sda`/`sda1`/`sda2` plus
`sdc`/`sdc1` scan) through both the stdout path and the new logging
path - stdout came back unchanged, still valid, parseable JSON per line
(no duplication, no corruption), and the log file gained the full,
timestamped device listing it had never had before.

## A corrupted directory's files vanished from the count instead of showing as unreadable (real bug, real hardware)

Deliberate real-hardware test to exercise the deep-scan/carving path
(previously one of this plugin's least-tested corners): rather than
damaging file *content*, corrupted a directory's own entries directly -
`debugfs -R "stat /home/fpp/media/sequences" /dev/sda2` to find the
directory's own data block, then `dd if=/dev/urandom of=/dev/sda2
bs=4096 count=1 seek=<that block>` to scramble it, leaving every file
that had been listed there physically untouched elsewhere on the card.

The card still mounted fine (only one directory's metadata was touched,
not the superblock or journal), but `find` hit the damage:
`find: '/mnt/DamagedSD/home/fpp/media/sequences': Bad message` -
`EBADMSG`, ext4's own directory-entry checksum feature correctly
detecting the corruption and refusing to return garbage entries as if
they were real. `sdcard_verify.sh` walks each category with
`find "$dir" -type f -print0` piped straight into a `while read` loop and
never checked `find`'s own exit status or stderr - so the files that had
been in that directory did not come back `UNREADABLE` (that only happens
to a file `find` actually discovers and then fails to `dd`-read); they
just silently never appeared to `find` at all, and were never counted as
anything. The result: `Verification complete: 12 readable, 0 unreadable,
12 total files.` - a falsely clean report, on a card that had just lost
an entire directory's worth of accessible data. The deep-scan offer,
gated on `unreadableFiles > 0`, would not have appeared on its own
either, even though raw signature carving is exactly the tool for this
case (it doesn't depend on directory structure at all).

Fixed by capturing `find`'s stderr per directory in `sdcard_verify.sh`:
a non-empty capture logs an explicit `WARNING: could not fully list
<dir> - <find's own error> - ...` and increments a new
`DIRS_WITH_ERRORS` counter, reported as an additive clause appended
*after* the existing `Verification complete: ...` sentence (not inserted
into it, so `js/sdcard-recover.js`'s established regex against that
sentence keeps matching unchanged). `runVerify()` parses that new clause
separately and now shows the deep-scan offer if *either* the unreadable
count *or* the directory-error count is nonzero, with the summary line
itself calling out the directory failure explicitly rather than staying
silent about it.

Verified both sides before committing: the bash counting/logging logic
against a synthetic `find` failure shaped exactly like the real
`Bad message` case, and the JS regex/UI logic in a real browser engine
against the actual log text from this session (`1 directory could not be
fully listed`) alongside three regression cases (a normal clean card, an
unreadable-files-only card, and the plural `2 directories` case) -
the real case now correctly surfaces the warning and reveals the
deep-scan offer, and none of the existing behaviors changed.

**Confirmed on the real hardware that surfaced this**: re-ran Verify
against the same corrupted `sequences` directory with the fix deployed.
The log now reads exactly as designed - the `WARNING: could not fully
list home/fpp/media/sequences - find: '...': Bad message` line, the
`Verification complete: 12 readable, 0 unreadable, 12 total files. 1
directory could not be fully listed - see warnings above.` summary, and
the multi-line deep-scan `NOTE:` all appear, in place of the old
falsely-clean "0 unreadable" result. The one piece not yet independently
confirmed is the UI side specifically - that the deep-scan offer button
actually renders visibly in the browser from this real output, as
opposed to just the log text being correct.

## A stale browser tab can run old JS after a plugin update - not a bug, a testing gotcha

Not a defect in this plugin, but worth writing down since it produced a
genuinely confusing false negative while testing the `DIRS_WITH_ERRORS`
fix above: right after updating and re-running Verify, the log clearly
showed the new server-side behavior (the `WARNING` line, the new summary
clause), but the page's own rendered summary text and the deep-scan offer
still showed the *old* behavior, as if the fix hadn't taken effect.

Confirmed against FPP core's real `www/plugin.php`: it generates this
plugin's `<script src="plugin.php?plugin=...&file=js/sdcard-recover.js&nopage=1">`
tag with no cache-busting (no `?ref=<filemtime>` the way FPP's own core
JS/CSS files get). A browser tab that was already open across a plugin
update just keeps running whatever JS it loaded when the page was last
opened - nothing about updating the files on disk causes an already-open
tab to go fetch the new copy, and there's no cache-busting to force a
fresh fetch even on a plain reload in some browsers. This is a gap in FPP
core's plugin-loading mechanism, not something fixable from this
plugin's own code.

**Update, found to be worse than first described** (during the real
`fsck -y` exit-code investigation below): this file's own `file=` handler
does send a `Cache-Control` header, and it's aggressive -
`max-age=31536000` (one year), with no `ETag`/`Last-Modified` validator
for the browser to check against at all. That combination means a
browser that has ever loaded this file will keep serving it from its own
disk cache for up to a year, for any URL that ever loaded it, not just a
tab that happened to stay open - confirmed the hard way: reinstalling the
plugin on `GPIOTest`, then testing from a brand new tab, a JS-triggered
`location.reload(true)`, and a `Ctrl+Shift+R` keypress (sent via this
session's browser-automation tool, not a physical keyboard - a real
user's own hardware shortcut may behave differently) all kept executing
the same stale, pre-update script. Confirmed directly against a plain
`fetch()` of the same URL with `cache: 'no-store'`, which correctly
returned the current file every time - only requests that respect the
browser's own HTTP cache were affected.

**For any future JS-touching change**: don't trust a same-tab reload, a
new tab, or even a hard-refresh keypress to prove a JS fix landed -
verify with a `fetch(url, {cache: 'no-store'})` from the console instead,
or a genuinely clean browser profile/private window. The bash/server-side
scripts never have this problem - `sudo`-invoked scripts always run
whatever is currently on disk, no caching concept applies to them - so a
log showing new behavior while the page's own rendering doesn't is close
to a decisive tell that this is what's going on, not a real regression.

## photorec's `fileopt` extension list silently disabled every real file type (real bug, real hardware)

The first real end-to-end test of deep scan/carving, on the same
directory-corruption test that surfaced the `DIRS_WITH_ERRORS` finding
above: `sdcard_carve.sh`'s `photorec` invocation completed in under a
second and carved 0 files - on a card whose actual file data was still
physically present (only a directory's own entries had been corrupted,
not the file content). No `photorec.log` was ever written despite `/log`
being passed. That combination - near-instant completion, zero output,
no log file - is the signature of a rejected command string, not a
genuine "found nothing" scan.

Traced directly against photorec's own source
(`cgsecurity/testdisk`, `src/phcli.c` and the `src/file_*.c` modules,
not just the man page) rather than guessed at. The `/cmd` invocation was:

```
fileopt,everything,disable,fseq,enable,mp3,enable,wav,enable,mp4,enable,avi,enable,mov,enable,jpg,enable,png,enable,json,enable,search
```

`fseq` and `json` were never real photorec-recognized extensions -
confirmed by the absence of any `src/file_fseq.c` or `src/file_json.c`
in photorec's ~350-module file-type registry. FPP's own sequence format
has no public signature a generic tool would know, and plain JSON has no
fixed magic bytes to key off of at all. That alone would just mean those
two types get skipped - except `phcli.c`'s `file_select_cli()` (the
function that parses the `fileopt,...` command list) stops consuming
tokens the instant it hits one it does not recognize, rather than
skipping just that one and continuing. `fseq` was the very first token
after `everything,disable`, so it silently aborted the **entire rest of
the list** - `enable,mp3`, `enable,wav`, every subsequent `enable,X`
never ran at all. The net configuration actually sent to photorec's scan
engine was "disable everything, enable nothing" - a scan with zero file
signatures loaded to search for, which explains the sub-second runtime
and the complete absence of a log file (nothing to log).

Two more of the original tokens were subtly wrong in a different way,
confirmed by reading each module's own registration rather than assuming
the extension name matches the option name: `wav` and `avi` are not
their own extensions either - both are RIFF containers, handled under
photorec's single `riff` hint (`src/file_riff.c`:
`"RIFF audio/video: wav, cdr, avi"`). `mp4` is likewise folded into the
`mov` hint (`src/file_mov.c`: `"mov/mp4/3gp/3g2/jp2"`) - a recovered MP4
comes back named with a `.mov` extension regardless, since photorec has
no way to tell the two apart from the container format alone. Those
would have caused the exact same total-command-abort failure had `fseq`
not already triggered it first.

Fixed the `/cmd` string itself:

```
fileopt,everything,disable,mp3,enable,riff,enable,mov,enable,jpg,enable,png,enable,search
```

Every token in this list was individually confirmed against a real
`src/file_*.c` registration before being included. This makes deep scan
actually search for something for the first time - `mp3`, `riff`
(wav/avi/cdr), `mov` (mov/mp4/3gp/3g2/jp2), `jpg`, and `png` - instead of
silently scanning for nothing while reporting a false "0 found" as if
that were a real result.

**What this does not and cannot fix**: `fseq` and `json` are not merely
misspelled or misordered - there is no photorec extension that covers
either, because signature-based carving fundamentally requires a fixed
byte pattern to search for, and neither FPP's own sequence format nor
generic JSON has one. This means deep scan/carving, as a whole approach,
cannot recover FSEQ show sequences or JSON config files under any
`/cmd` syntax - arguably the two categories of file an operator would
most want back. Updated `status.php`'s deep-scan offer text,
`README.md`, and `docs/how-it-works.md` to say this plainly rather than
implying deep scan covers "FPP's own file types" in general, which it
never fully did.

## "I have to unplug and replug the reader every time" was a stale mount, not a hardware quirk (real bug, real hardware)

A user reported needing to physically remove and reinsert the USB SD
card reader every time they started a new session, or the card would
not show up in Step 1's Scan. Initial hypothesis was a hardware/USB
issue (autosuspend, boot-time enumeration timing, power budget - all
real, well-documented Raspberry Pi USB quirks) - but the actual `dmesg`
evidence pointed somewhere else entirely: every single capture showing
"it works after I replug it" also showed `EXT4-fs (sdX2): shut down
requested (2)` immediately after the `USB disconnect` line - the kernel
forcibly tearing down a mount because the device was physically yanked
out from under it, not a fresh, clean enumeration solving anything.

Root cause: `scripts/sdcard_unmount.sh`'s own header comment has always
claimed it runs "when the user re-scans, picks a different device, or
finishes a recovery run" - but nothing in `js/sdcard-recover.js` ever
actually called the `unmount` backend command, anywhere. A card mounted
at Step 2 stayed mounted at `$MOUNTPOINT` indefinitely - across page
reloads, across entirely new sessions, until something forced it off.
`sdcard_scan.sh` correctly, by design, excludes an already-mounted disk
from its results (that guard is real and intentional - see the earlier
sibling-partition and root-device-guard findings). So the *same* card
used in a previous session stayed invisible to a fresh Scan, looking
exactly like a detection failure, when the actual state was "still
mounted from before, and correctly hidden as already in use." Unplugging
the reader "fixed" it purely as a side effect - the forced disconnect is
what actually cleared the stale mount, not anything about the USB
enumeration itself succeeding where it had failed before.

Fixed by finally wiring up what the header comment always claimed:
`runScan()` now calls `unmount` and waits for it to complete before
calling `scan`, so every Step 1 Scan/Rescan click starts from a
guaranteed-clean state regardless of what a previous session left
mounted. Deliberately scoped to `runScan()` only, not
`refreshUsbDestinations()` (Step 5's "Refresh," which shares the same
`scan` backend command but must never touch the source while the user is
only looking for a destination drive) - confirmed the two functions stay
independent before committing. Verified the call ordering itself (unmount
strictly before scan, result still flows through to the rendered device
list) with a stubbed `streamCommand` in a real browser JS engine.

**Deliberately not done in this same pass**: the header comment's third
claimed trigger, "finishes a recovery run," was not wired up. Unlike
starting a fresh scan, auto-unmounting right after Recover completes has
a real downside - `sdcard_recover.sh`'s sibling-partition guard (see
above) and its same-partition check are both gated on `$MOUNTPOINT`
actually being mounted; a user running a second Recover pass afterward
(e.g., zip first, then usb as a separate follow-up action rather than
checking both at once) without remounting would silently lose that
protection. Not reported as a problem and not touched here, to avoid
trading a confirmed real bug for a new, subtler one.

## photorec was scanning the boot partition, not the disk, and its own log wasn't landing anywhere findable (real bug, real hardware)

The fixed `fileopt` list above was necessary but not sufficient - a
second, independent bug in the same invocation. A user retested deep
scan after that fix and reported two things: the raw photorec terminal
output streamed live but never appeared in the plugin's own persistent
log, and (more importantly, visible directly in that same raw output)
photorec's own on-screen partition table showed it operating on
`1 P FAT32 LBA ... [boot]` - the tiny boot partition, not the actual
ext4 media partition where any real recoverable data would be. `/log`
also never produced a `photorec.log` anywhere inside `$OUTDIR`.

Both traced to the real photorec/testdisk source rather than assumed:

- **Wrong partition, confirmed via `src/phcli.c` and `src/photorec.c`.**
  `menu_photorec_cli()`'s own initialization -
  `params->partition=(list_part->next!=NULL ? list_part->next->part :
  list_part->part);` - defaults to the *first real partition* on the
  disk whenever one exists. `init_list_part()` (`src/photorec.c`) does
  insert a synthetic "Whole disk" partition (offset 0, spanning the
  entire disk) ahead of the real ones specifically so it can be
  selected - but the CLI's own default selection logic skips straight
  past it. That synthetic partition's `order` field is left at its
  default, `NO_ORDER` (`src/common.h`: `#define NO_ORDER 255`, confirmed
  never reassigned anywhere after creation), and `phcli.c`'s digit-based
  selection command (`else if(isdigit(params->cmd_run[0]))`) matches a
  partition by exactly this field. Neither `sdcard_carve.sh`'s original
  `/cmd` string nor the fixed one from the previous finding ever
  supplied this selector, so both silently scanned only the small boot
  partition - never the media partition - regardless of the fileopt fix.
- **Missing log, confirmed via the real `photorec.8` man page**: `/log`
  is documented as "create a photorec.log file," with no path control -
  it writes relative to the process's current working directory, not to
  `/d`'s destination. `sdcard_carve.sh` never changed directory before
  invoking photorec, so the log landed wherever the script's own ambient
  working directory happened to be - not inside `$OUTDIR`, where every
  message in the plugin's own log told the user to look, and not
  visible in the plugin's own persistent log either, since it is
  photorec's own file, entirely outside the `log()` mechanism.

Fixed both: added `255,` as the first token in the `/cmd` string,
explicitly selecting the "Whole disk" pseudo-partition instead of
relying on the wrong default - the correct behavior for a tool meant to
recover from a card whose filesystem may be damaged or unmountable in
the first place, not just carve within whatever partition happens to be
listed first. Wrapped the `photorec` call in a subshell that `cd`s into
`$OUTDIR` first, so its `/log` output lands there, next to the carved
files, matching where the script's own messages already point. Adjusted
the candidate-file count to exclude `photorec.log` now that it lives
inside the same directory being counted, and added an explicit `log()`
line stating the scan targets the whole disk, so that fact is visible
in the plugin's persistent log without needing to parse photorec's own
raw terminal output.

Verified the subshell/exit-code mechanics directly before committing:
a successful run's exit code propagates out through the subshell
correctly, a `cd` failure exits the subshell (not the whole script) with
status 1, and the candidate count correctly excludes `photorec.log`
while still counting real carved output.

## photorec's real output landed next to $OUTDIR, not inside it - deep scan was working all along (real bug, real hardware)

A third bug in the same invocation, found on the very next real-hardware
retest after the whole-disk-selection fix above. This time photorec's
live output clearly showed genuine recovery happening - `png: 103
recovered`, `jpg: 12`, `riff: 9 recovered`, climbing into the hundreds by
the end of the run - yet `sdcard_carve.sh` still reported
`0 candidate file(s) carved to $OUTDIR`. Confirmed on the user's own box:
`ls -la` of the state directory showed `carved/` (this run's `$OUTDIR`,
nearly empty) sitting next to `carved.1/` and `carved.2/` - sibling
directories nobody told the user to expect, one of them (12288 bytes,
many entries) clearly holding the real recovered files from this exact
run.

Traced directly against photorec's own source rather than guessed at
again:

- `src/phmain.c`'s parsing of `/d <path>`: if `<path>` does **not** end
  in a trailing slash, `recup_dir` is set to that path *verbatim* - not
  treated as a container directory to create numbered subfolders inside.
- `src/photorec.c`'s `photorec_mkdir()`: its real output directory is
  built as `snprintf(..., "%s.%u", recup_dir, dir_num)` - literally
  `recup_dir` with `.<N>` appended directly onto the end. With
  `$OUTDIR` = `.../carved` (no trailing slash, exactly what
  `sdcard_carve.sh` passed), that produces `.../carved.1` - a **sibling**
  of `carved/`, not anything inside it. `find "$OUTDIR" -type f` was
  searching the one directory photorec never wrote a single byte into.
- With a trailing slash, `phmain.c`'s own parsing instead appends
  photorec's built-in default name first (`src/photorec.h`:
  `#define DEFAULT_RECUP_DIR "recup_dir"`), landing the numbered output
  at `.../carved/recup_dir.1` - genuinely inside `$OUTDIR`, exactly where
  the existing recursive `find` already looks.

Fixed by passing `"$OUTDIR/"` (trailing slash added) to `/d` instead of
`"$OUTDIR"`. Verified the exact path-construction difference directly
before committing - simulated both the argument-parsing and the
`.<N>`-suffix logic from source, confirmed the no-slash case produces a
sibling path and the with-slash case produces a path genuinely inside
`$OUTDIR`, then confirmed with a real `find` invocation that only the
latter gets discovered by this script's own counting logic.

Also added a stray-sibling-directory check for exactly the situation
this bug already caused on real hardware: after every run,
`sdcard_carve.sh` now globs for `$OUTDIR.[0-9]*` and logs a `WARNING`
naming any it finds, so real recovered data left behind by a pre-fix run
(or any future regression of the same kind) doesn't just sit there
silently undiscovered. Verified the glob against both a populated
two-sibling case (matching the user's own `carved.1`/`carved.2`
situation exactly) and a clean case with nothing to report.

**What this means for everything tested up to this point**: deep
scan/carving was never actually broken at finding files - once the
fileopt and whole-disk-selection fixes landed, it was successfully
recovering hundreds of real PNG/JPG/RIFF files on every run. It was
only ever failing to tell the user where they ended up.

## Added: Recovery Artifacts section, after a real user asked why nothing gets cleaned up

Direct follow-on from two real-hardware findings earlier in this round:
FPP's File Manager cannot browse into `config/plugin.SDCardRecover/` to
retrieve or delete anything inside it (confirmed against
`www/filemanager.php`/`www/js/fpp.js` - the Config tab is `maxdepth=1`,
and no category outside the Images thumbnail view has any click-to-open
behavior for a folder row at all), and old recovery zips (one real
example: 360 MB) and deep-scan `carved.N` output were piling up in that
same directory with no way to remove them short of SSH.

The plugin already deletes nothing automatically, on purpose - there is
no reliable signal that a browser download actually completed,
especially for a large zip over WiFi to this device, so auto-deleting
risks destroying the only copy of something the user never actually got
off the box. That reasoning is sound and unchanged. What was missing was
any way to clean up *deliberately*, once the operator actually knows
they're done with something.

Added a new, un-numbered "Recovery Artifacts" section to `status.php`,
independent of wizard progress:

- `ajax.php` gained a new read-only `artifacts` endpoint (`sdcr_api_artifacts()`)
  that lists zips and carved-output directories in `$STATE_DIR` (excluding
  `manifest.tsv`, this session's own live state, not a leftover artifact),
  with size, file count (for directories), and modified time. Runs as the
  unprivileged `fpp` user like every other `ajax.php` endpoint - safe,
  since listing/`stat`-ing a 755 root-owned directory only needs
  read+traverse permission, which `fpp` (as "other") already has.
- A new `scripts/sdcard_delete_artifact.sh`, dispatched through
  `stream.php`/`scripts_dispatch.php` like every other real action in this
  plugin (not through `ajax.php`), specifically because `sdcard_carve.sh`'s
  own output directories are **root-owned** (confirmed live:
  `drwxr-xr-x 2 root root ... carved.1`) - a plain PHP `unlink()`/`rmdir()`
  running as `fpp` could list them but not delete their contents, only
  root (via `sudo`, the same mechanism every other script here already
  uses) can. `fsck_repair` was already documented as "the only destructive
  action in this plugin"; this is the second, and gets the same treatment:
  a strict allowlist regex (`^(SDCardRecover-[0-9]{8}-[0-9]{6}\.zip|carved(\.[0-9]+)?)$`)
  checked in **both** `scripts_dispatch.php` (before it ever reaches a
  shell command) and the script itself (defense in depth) - anchored, no
  wildcards, no path separators, so it can only ever match exactly one of
  this plugin's own two known artifact shapes, never an arbitrary path.
- The JS requires an explicit `confirm()` per item before deleting -
  matching the weight of an irreversible action - and refreshes the list
  automatically after a carve or a zip-recovery completes, so newly
  created artifacts show up without a manual refresh.

Verified directly before committing: the allowlist regex against a dozen
real and adversarial names (valid zip/carved names all matched; path
traversal attempts, `manifest.tsv`, and near-miss names like `carvedX`
all correctly rejected) in both bash (matching the shell script's own
check) and by inspection against the equivalent PCRE syntax
(`scripts_dispatch.php`/`ajax.php`'s checks); the full render/delete flow
in a real browser JS engine using data shaped exactly like this session's
own real artifacts (a 360 MB zip, a populated `carved.2`, an empty
`carved.1`) - correct sizes, file counts, and confirmed the delete button
fires `delete_artifact` with the right name and disables itself.

**Not yet validated**: an actual delete against a real root-owned
`carved.N` directory on real hardware, confirming `sudo rm -rf` in the
new script actually succeeds where a plain `fpp`-user delete would fail,
and that the artifacts list correctly reflects removal afterward.

## `stream.php`'s own `Content-Type` header silently never applied (real bug, found from a real-hardware log bundle)

Not a hardware test aimed at finding this - a routine real-hardware
session on `GPIOTest` (the same session that confirmed the `/d`
trailing-slash fix and the scan-log-bundle item below), reviewed from its
downloaded log zip afterward. Every single wizard action in that
session - 48 of 49 script invocations, every scan/mount/verify/carve/
recover/unmount routed through `stream.php` - logged `PHP Warning: Cannot
modify header information - headers already sent in .../stream.php on
line 38` to `apache2-error.log`. 100% reproducible, and not new: the
session's own `logs/fpp_plugin_manager.log` shows six live git
fast-forwards of this plugin mid-session, none of which touched any PHP
file, and the warning fired identically before and after every one of
them. The one invocation with no matching warning was
`sdcard_evaluate.sh`, which runs through `ajax.php`, not `stream.php` -
consistent with the bug being specific to this one file.

Line 38 is `header('Content-Type: text/plain');`, called right after
`DisableOutputBuffering()`. Traced against FPP's own real
`www/common.php` rather than guessed at: `DisableOutputBuffering()` ends
with

```php
ob_implicit_flush(true);
flush();
```

an unconditional `flush()`, which forces PHP to commit and send whatever
headers exist at that point to the client - even with zero bytes of body
written yet. Any `header()` call issued afterward is too late. This isn't
a guess: `DisableOutputBuffering()`'s own `header('X-Accel-Buffering:
no')` (a few lines earlier in the same function, before its `flush()`)
never produced a matching warning anywhere in the log - it ran while
headers were still open; `stream.php`'s own header call, issued after
`DisableOutputBuffering()` returned, did not.

Confirmed against the pattern this file's own header comment says it was
copied from: FPP core's real `www/copystorage.php` sets its one header
(`Access-Control-Allow-Origin`) *before* calling `DisableOutputBuffering()`,
never after. `stream.php` had the two calls in the wrong order relative to
the very pattern it claimed to follow.

Not a functional bug - all 48 affected requests in this session still
completed and streamed their output correctly, since a failed `header()`
call doesn't block the response body, only the browser never actually got
`Content-Type: text/plain` (falling back to PHP's default `text/html`,
harmless for a `<pre>`/log-panel display that never renders its content
as markup). The real cost is unconditional log noise: one warning line
per user action, for as long as the plugin stays installed - smaller in
volume than the earlier `api.php` finding (which fired on every automatic
status poll, not just user-driven actions), but the same shape of
problem, and present since this file was first written, not introduced by
anything in this test session.

Fixed by moving `header('Content-Type: text/plain');` to before
`DisableOutputBuffering()` in `stream.php`, matching `copystorage.php`'s
own ordering, with a comment explaining why the order matters so it
doesn't drift back.

**Not yet validated**: the fix reorders two lines against a
source-confirmed mechanism, but hasn't been re-run against real hardware
yet to confirm `apache2-error.log` actually goes quiet.

## A failed artifact delete left no trace anywhere a user would think to look (real bug, found from a real user report)

A real user clicked Delete on a leftover recovery zip in the Recovery
Artifacts section on `GPIOTest`. The zip was still on disk afterward
(confirmed via `ls -la` on the box), and - the detail that actually
pinned this down - `plugin-fpp-plugin-SDCardRecover.log` had no record of
the attempt at all, not even a failed one.

That second fact ruled out the two obvious suspects quickly: the
artifact-name allowlist regex (`^(SDCardRecover-[0-9]{8}-[0-9]{6}\.zip|carved(\.[0-9]+)?)$`,
checked in both `scripts_dispatch.php` and `sdcard_delete_artifact.sh`
itself) matches the real filename correctly (verified directly against
the exact string), and a rejection there would still reach
`sdcard_delete_artifact.sh`'s own `log "Deleting artifact ..."` line if
the script itself had started at all. "No trace whatsoever" pointed
somewhere the log couldn't reach in the first place, and `common.sh` had
exactly one such place:

```bash
exec {SDCR_LOCK_FD}>"$LOCKFILE"
if ! flock -n "$SDCR_LOCK_FD"; then
    echo "ERROR: another SDCard Recover operation is already running ..." >&2
    exit 1
fi

ensure_log_file
SDCR_SCRIPT_NAME=$(basename "$0")
log "=== $SDCR_SCRIPT_NAME started: $* ==="
```

The global `flock` lock (added earlier this round so two tabs/sessions
can't race each other - see "`LOCKFILE` was declared and never used"
above) is checked **before** `ensure_log_file()`/the first `log()` call
exists at all. Any script that loses that lock race prints its refusal to
stderr (still visible live in the browser's own log panel, merged into
the response by `scripts_dispatch.php`'s `2>&1`) and exits - without ever
reaching the one place this plugin promises every step goes to
(`README.md`/`docs/how-it-works.md`: "Every step logs to
`media/logs/plugin-fpp-plugin-SDCardRecover.log`"). This isn't specific
to `delete_artifact` - any script that loses the lock has the same gap -
delete just happened to be the one a real user hit it through.

A second, compounding bug made this fully invisible instead of just
under-logged. `js/sdcard-recover.js`'s delete button ignored
`streamCommand`'s own `(ok, text)` result entirely - the same result
`mount_ro`/`verify`/`fsck_check` all already branch on:

```js
streamCommand('delete_artifact', { name: item.name }, 'sdcr-log-artifacts', null, function () {
    refreshArtifacts();
});
```

So even with the lock-contention error correctly streamed to the
browser, the UI took no notice of it - it just re-fetched and redrew the
(unchanged) artifact list, which looks identical to "there was nothing to
delete." No error, no stuck button, nothing to suggest the click hadn't
worked exactly as asked.

Fixed both:

- `common.sh` now calls `ensure_log_file()` and resolves
  `SDCR_SCRIPT_NAME` **before** attempting the lock, so a lock-contention
  refusal can `log()` itself like everything else this plugin does,
  instead of only reaching stderr.
- The delete button's callback now takes `(ok, text)` like its siblings:
  on failure it re-enables the button (so the user can just retry once
  whatever was holding the lock finishes) and shows the actual streamed
  output via `alert()`, instead of silently calling `refreshArtifacts()`
  either way.

**Worth being honest about the gap this doesn't close**: `carve` and
`fsck_repair`'s own `streamCommand` callbacks have this same
ignore-the-result shape and were not touched here - out of scope for the
report that surfaced this one. Same class of bug, not yet fixed; tracked
as a follow-up, not assumed away. (Since fixed - see "`carve` and
`fsck_repair` closed the same `(ok, text)` gap..." below.)

**Not yet validated**: whether lock contention was actually what this
specific user hit (plausible and now impossible to rule back in after the
fact, since the old code left no trace either way) versus some other
pre-log failure - and whether the fix above actually produces a
`log()`ged refusal and a visible `alert()` the next time a real lock
collision happens on real hardware.

## `carve` and `fsck_repair` closed the same `(ok, text)` gap the delete button had (real bug, not yet validated on real hardware)

Item 18 in "Not yet validated" below, closed out - the gap flagged but
deliberately left open in the section above. `runFsckRepair()` and
`runCarve()` in `js/sdcard-recover.js` had the exact same shape as the
delete button's bug: both `streamCommand` callbacks took no arguments at
all, so a failed run was indistinguishable from a successful one at the
UI layer.

- `runFsckRepair()` was the worse of the two: on failure it still called
  `scrollToMountLog()` and immediately retried the mount - so a repair
  that genuinely failed (`fsck -y` exiting nonzero) looked identical to
  one that succeeded, right up until the retried mount itself failed
  again for reasons the user had no way to connect back to the repair
  that just silently didn't work. It also passes `null` for `progressId`
  (no progress bar exists for this sub-step), so there was no visual
  signal of any kind on failure - not even the red bar item 20 validated
  elsewhere.
- `runCarve()` had progressId (turns the deep-scan progress bar red on
  failure, same mechanism as item 20), but still called
  `refreshArtifacts()` unconditionally either way - a failed carve just
  silently re-rendered the same (unchanged) artifact list, with nothing
  telling the user the run itself hadn't produced anything.

Fixed both the same way the delete button was fixed: both callbacks now
take `(ok, text)`, and on failure show the actual streamed output via
`alert()` and return early instead of proceeding into the success path
(retrying the mount / refreshing artifacts).

**Not yet validated**: neither path has been exercised against a genuine
failure on real hardware yet - a real `fsck -y` that still exits nonzero
after running, and a real `photorec`/`sdcard_carve.sh` failure (e.g. a
device unplugged mid-carve). Both are harder to trigger deliberately
than the delete-button lock-contention case was.

## Pulling the reader mid-carve - attempted, genuinely inconclusive (real hardware)

Deliberate real-hardware attempt at the `runCarve()` half of item 18
above: corrupted `home/fpp/media/sequences`'s own directory block on the
same real source card used for earlier tests (`debugfs -R "stat
/home/fpp/media/sequences" /dev/sda2` to find its data block under
`EXTENTS:`, then `dd if=/dev/urandom of=/dev/sda2 bs=4096 count=1
seek=<that block>` to scramble it - same method as "A corrupted
directory's files vanished from the count..." above), which correctly
produced the `1 directory could not be fully listed` warning and
revealed the "Run deep scan" button. Started a deep scan of the whole
63 GB disk, watched real progress climb in the live log (`png: 8
recovered`, `riff: 9 recovered`, over 200 files found), then physically
pulled the USB SD-card reader from `GPIOTest` about 70 seconds in.

The disconnect itself was completely real, confirmed in `syslog`:

```
11:37:05  sd 0:0:0:0: [sda] tag#0 ... I/O error, dev sda, sector 6870848 op READ ...
11:37:05  Buffer I/O error on dev sda, logical block 858856, async page read
          (repeated across many more sectors)
11:37:06  sda: detected capacity change from 124735488 to 0
11:37:06  udisksd: ... Failed to assign the new context to disk '/dev/sda': No medium found
```

But `sdcard_carve.sh` still finished cleanly about 47 seconds later:
`Deep scan complete (exit 0). 326 candidate file(s) carved`. `photorec`
itself apparently treated the sudden loss of readable sectors as having
reached the end of scannable data rather than as a fatal error, and
returned exit 0 regardless - so `$?` genuinely was `0`, and `runCarve()`'s
new `(ok, text)` failure-alert code (see the section above) never had a
reason to fire. Not a bug in this plugin's own handling - `RC=$?`
faithfully captured photorec's real exit code - but a real limitation on
testing it this way: a resilient carving tool built to work through bad
sectors doesn't reliably surface "the device disappeared" as a failure
exit code the way `fsck -y` or a simpler script would.

**Honest status**: same shape as "Config restore racing a live `fppd`..."
below - a real attempt, real evidence gathered (the disconnect
genuinely happened, at the kernel level, mid-scan), but it didn't
exercise the code path it set out to test. `runCarve()`'s failure
branch remains unvalidated on real hardware; `runFsckRepair()`'s
entirely so. A more promising angle for next time: interrupt much
earlier in a longer-running scan (this 63 GB whole-disk scan finished
in under 90 seconds against a mostly-empty test card, far faster than
photorec's own early "2h58m" estimate suggested, leaving a narrower
window than expected to react in).

## A large real fsck -y response lost its own exit-code marker (real bug, found and fixed on real hardware)

The `runFsckRepair()` half of item 18, attempted on the same real
`GPIOTest` source card: re-trashed the partition's primary superblock
(`sudo dd if=/dev/urandom of=/dev/sda2 bs=4096 count=1` - same method as
"The fsck fallback UI could never actually appear..." above, the
original test that proved this exact corruption reliably makes `fsck -y`
exit nonzero), which correctly failed the mount, correctly showed the
`fsck -n` fallback box (exit 12), and correctly offered "Attempt repair."
Clicking it ran a real `fsck -y` against a genuinely 63 GB, heavily
corrupted ext4 filesystem - by far the largest response this plugin has
ever streamed back to a browser (~28 KB, thousands of `Free blocks count
wrong ... Fix? yes` lines) - and it finished with a real, logged
`fsck -y exit code: 1` (errors corrected - a normal, successful e2fsck
repair, not code 0).

Before checking the alert this session expected to see, one detour was
necessary: `fsck.ext2`'s own diagnostic text read `checking journal for
rootfs` and `rootfs: ***** FILE SYSTEM WAS MODIFIED *****` - alarming
phrasing that could easily be misread as "ran against the Pi's own boot
filesystem," a `guard_not_root_device()` failure. It wasn't. That guard
calls `root_device()` (`findmnt -n -o SOURCE /`) fresh on every
invocation, not a cached value, and it did not refuse this run - direct,
live evidence `/dev/sda2` genuinely isn't `GPIOTest`'s root device.
"rootfs" here is e2fsck's own generic internal placeholder for a
filesystem it can't otherwise name, unrelated to device identity. Worth
recording because it is a realistic way to scare yourself reading real
`fsck -y` output on a raw device path, not because it turned out to be
anything.

The actual surprise: instead of the item-18 alert firing for a nonzero
exit, `js/sdcard-recover.js`'s `runFsckRepair()` silently took the
**success** branch - `scrollToMountLog()` and `runMount()` ran
immediately, and the retried mount/verify both succeeded, logged at the
very same second the repair itself finished. Traced directly rather than
guessed at:

- The deployed JS was confirmed correct and unchanged (re-fetched the
  live file from `GPIOTest` and diffed the `runFsckRepair()` body against
  source - no typo, no inverted condition).
- `scripts_dispatch.php`'s `sdcr_passthru()` appends `SDCR_EXITCODE:$rc`
  unconditionally, every time, with no conditional skip.
- `apache2-error.log` showed nothing around the request window - no
  proxy timeout, no truncation at that layer.
- The literal string `SDCR_EXITCODE` was confirmed **absent anywhere**
  in the final displayed log panel's `textContent` - not just stripped
  from the visible tail, genuinely not present at all, checked via
  `indexOf` across the whole element.
- The regex/parsing logic itself was confirmed correct in isolation
  (tested live against a reconstructed `"...\nSDCR_EXITCODE:1\n"` string
  in the same browser - matched, captured `"1"`, `exitOk` correctly
  `false`).

That combination only makes sense one way: `streamCommand()`'s `onload`
handler reads `logEl.textContent` - a copy of the response body *this
plugin* reconstructs incrementally inside `onprogress`, not the
browser's own response buffer. `onprogress` is not guaranteed to fire
for every byte; browsers may coalesce or throttle it. For every smaller
response earlier in this same session (`mount_ro`'s 3-line failure,
`fsck_check -n`'s ~15-line failure), `onprogress` easily kept up and both
correctly detected their real nonzero exit codes - only the ~28 KB
response, arriving in a rapid final burst of thousands of lines, lost
its trailing marker from `logEl.textContent` before `onload`'s snapshot
ran. `exitOk` fell back to the always-true `xhr.status === 200` path,
silently converting a real, successful-but-not-zero repair into a
false "everything's fine, retry the mount" - the exact failure mode the
`SDCR_EXITCODE` marker was originally built to prevent, reopened by
response size rather than by the original missing-exit-code gap.

**Fixed** in `streamCommand()`'s `onload`: resync from `xhr.responseText`
first (the same diffing `onprogress` does), before reading
`logEl.textContent` - `xhr.responseText` is the browser's own buffer and
is guaranteed complete by the time `onload` fires, regardless of how many
`onprogress` events actually fired along the way.

**Re-validated, with a real detour along the way.** Re-corrupting the
superblock and re-running `fsck -y` through the actual page, twice, kept
reproducing the *exact* original failure even after a plugin reinstall -
which looked at first like the fix genuinely didn't work. It wasn't the
fix: see "A stale browser tab can run old JS after a plugin update..."
above, updated with what was actually going on - a one-year
`Cache-Control` on this plugin's own JS meant the real page kept
executing the pre-fix script no matter how it was reloaded.

Rather than keep fighting the browser's cache, validated the fix
directly against the real protocol instead: issued the exact same
`XMLHttpRequest` `streamCommand()` builds - same URL, same
`cmd=fsck_repair&args[device]=/dev/sda2` body - by hand from the browser
console, against the same real corrupted `/dev/sda2` on `GPIOTest`, with
`onprogress`/`onload` instrumented to report `xhr.responseText`'s own
length and whether it contained `SDCR_EXITCODE` at each point. Real
result: a genuine `fsck -y exit code: 1` run, `xhr.responseText` **did**
contain the trailing `SDCR_EXITCODE:1` marker in full by the time
`onload` fired (confirmed in both the final `onprogress` event and
`onload` itself - `hasMarker: true` both times, exact tail
`...=== sdcard_fsck_repair.sh finished (exit 1) ===\n\nSDCR_EXITCODE:1\n`)
- the fixed parsing logic, run against this exact real response, correctly
computes `exitOk = false`.

**Honest scope of what this does and doesn't prove**: this confirms the
fix's actual parsing logic is correct against a real large response on
real hardware - the same logic `streamCommand()` now runs, exercised the
same way, over the same wire. It does not independently reconfirm that
`runFsckRepair()`'s `alert()`-and-return branch fires correctly end-to-end
through the literal page UI, since the browser-caching issue above
blocked getting a genuinely fresh page to click through - that part
relies on code review (the branch is simple, unconditional `if (!ok)`
logic, already read carefully once already) rather than a fresh
real-hardware UI observation.

## The real cause of the failed delete: the script itself was never executable (real bug, confirmed on real hardware)

Direct follow-on from the section above, and worth being honest about how
it played out: lock contention was a reasonable guess given the evidence
at the time (no trace anywhere in the log), but it was wrong. The actual
cause was much simpler, and the alert-on-failure fix from the section
above is exactly what surfaced it - a real user hard-refreshed, retried
the same delete, and this time got a real `alert()` with real content
instead of silence:

```
Delete failed for "SDCardRecover-20260920-095624.zip":

sudo: /home/fpp/media/plugins/fpp-plugin-SDCardRecover/scripts/sdcard_delete_artifact.sh: command not found
```

(A manually-typed, misremembered path tried over SSH first produced a
similar-looking but subtly different error and briefly pointed the
investigation the wrong way - worth flagging as its own small testing
gotcha: always get the *exact*, copy-pasted error text, from the actual
UI, not a retyped approximation, before treating a path in an error
message as evidence of anything.)

The path in the real `alert()` was exactly correct - confirmed against
`ls -la /home/fpp/media/plugins/` on `GPIOTest` - which meant `sudo`
itself disagreed that a script at a real, existing path was runnable.
`sudo` (and `execve()` generally) reports a non-executable target the
same way it reports a missing one - "command not found," not "Permission
denied" - a well-known point of confusion, not a sign the path was wrong.
That pointed at the executable bit, and `git ls-files -s scripts/`
confirmed it directly: every script in `scripts/` is tracked at mode
`100755` except one -

```
100644 ... scripts/sdcard_delete_artifact.sh
```

`sdcard_delete_artifact.sh` was committed without the executable bit when
it was first added (the "Added: Recovery Artifacts section" change). Git
tracks the executable bit as part of the tree itself, independent of
whatever the committing machine's filesystem shows - it checks out
exactly as recorded on the target machine, `chmod` and all. On a real
Linux box, that meant the file always landed as `-rw-r--r--`, never
runnable by `sudo`, regardless of anything about locking, logging, or the
allowlist regex - **the Delete button has never worked on real hardware,
since the feature was first added**, and no amount of retrying, hard
refreshing, or waiting out a lock could have fixed it, because none of
those were ever the actual problem.

Fixed with `git update-index --chmod=+x scripts/sdcard_delete_artifact.sh`,
correcting the tracked mode to `100755` to match every other script here.

Worth being clear about what the previous section's fixes still did and
didn't do: they didn't cause or fix this bug, but the log-ordering and
`alert()` changes are the entire reason this got diagnosed at all instead
of staying invisible forever - the user's retest under the *old* code
would have shown nothing, same as the very first report.

**Confirmed**: a real retest on `GPIOTest` with the executable bit fixed
deleted the leftover recovery zip successfully - the Delete button works
end to end for the first time since the Recovery Artifacts section was
added. Closes out items 15 and 19 below.

## The global `flock` lock, confirmed under genuine concurrency (real hardware)

Item 5 in "Not yet validated" below had sat open the longest - the lock
itself (see "`LOCKFILE` was declared and never used..." above) had never
actually been exercised by two overlapping operations on real hardware,
only reasoned about. A real deliberate test on `GPIOTest` closed it out
properly: started a deep scan (`sdcard_carve.sh`, a genuinely slow
operation - this run took nearly 9 minutes) in one browser tab, then from
a second tab triggered `runScan()`'s own unmount -> scan chain (see "I
have to unplug and replug the reader every time..." above) while the
carve was still running.

```
[11:01:54] === sdcard_carve.sh started: /dev/sda ... ===
[11:01:56] ERROR: sdcard_unmount.sh could not start - another SDCard Recover operation is already running ...
[11:01:57] ERROR: sdcard_scan.sh could not start - another SDCard Recover operation is already running ...
[11:10:47] Deep scan complete (exit 0). 359 candidate file(s) carved ...
[11:10:47] === sdcard_carve.sh finished (exit 0) ===
```

Both halves of the second tab's chained request were correctly refused,
back to back, one second apart - and, thanks to the log-ordering fix from
"A failed artifact delete left no trace..." above, both refusals are
right there in `plugin-fpp-plugin-SDCardRecover.log`, not just the
browser. More importantly, the carve holding the lock ran for another
nine minutes after being contended against and finished cleanly at
`exit 0` with the same 359-candidate count a previous confirmed run
found - completely undisturbed. The lock isn't just rejecting latecomers;
it's actually protecting the operation that got there first.

## The progress bar always turned green, even on failure (real bug, found from a real user question)

A real question - "is there a color change of this line on failure, maybe
red?" - had an honest answer of no, and that turned out to be worth
fixing rather than just explaining. `setProgress()` (`js/sdcard-recover.js`)
only ever took a plain boolean, and every caller passed `false` - which
turns the bar **green** (`sdcr-progress-done`) - the instant the HTTP
response finished, in both `xhr.onload` and `xhr.onerror`:

```js
xhr.onload = function () {
    setProgress(progressId, false);   // before exitOk is even computed
    ...
    var exitOk = ...;                 // real result, checked after
    onDone(exitOk, text);
};
xhr.onerror = function () {
    setProgress(progressId, false);   // a genuine network failure - still green
    onDone(false, logEl.textContent);
};
```

No `sdcr-progress-fail`/red state existed anywhere in
`css/sdcard-recover.css` either. So a failed mount, a failed carve, or
the request itself erroring out (`xhr.onerror`) all looked visually
identical to success - solid green - with only the log text underneath
ever saying otherwise, and nothing distinguishing "it worked" from "it
didn't" at a glance.

Fixed by giving `setProgress()` a real third state instead of a boolean:
`true` (blue, animated, in progress), `false` (green, real exit code was
`0`), or `'fail'` (red, nonzero exit or a network-level error). `xhr.onload`
now computes `exitOk` from the real `SDCR_EXITCODE:<n>` marker *before*
setting the bar's state, instead of after; `xhr.onerror` now reports
`'fail'` instead of `false`. `docs/architecture.md`'s "Progress UI"
section, which described the animation but never the color meanings
(there was no third meaning to describe until now), was updated to
document all three states.

**Confirmed** on real hardware: removed the source card after Scan but
before clicking Mount, so `sdcard_mount_ro.sh`'s own `validate_device()`
correctly failed (`ERROR: /dev/sda2 is not a block device`, `exit 1`).
The fsck-fallback box appeared as designed, and - once past a false start
caused by the stale-JS-tab gotcha above (the first attempt, before a real
`Ctrl+Shift+R`, still showed green; same plugin update, same real
`exit 1` server-side, different result, which is itself further
confirmation of what that gotcha actually does) - Step 2's progress bar
turned solid red.

## The sibling-partition destination guard, confirmed on real hardware - and a real logging gap it surfaced

Item 8 in "Not yet validated" below (see "The source card's own sibling
partition..." above for the original fix) had only ever been verified
directly against source, never actually exercised. Real test on
`GPIOTest`: mounted the source card's `/dev/sda2` as usual, confirmed
`/dev/sda1` - the same physical card's own boot partition - never appears
in Step 5's destination dropdown (the client-side filter in
`populateUsbDestinations()` working as designed), then bypassed that
filter deliberately via the browser console to force `/dev/sda1` into the
destination select and clicked Recover anyway - exercising the
*server-side* guard independently, not just trusting the UI never sends
a bad value.

`sdcard_recover.sh` refused it correctly:

```
[11:37:54] === sdcard_recover.sh started: usb /dev/sda1 ===
[11:37:54] === sdcard_recover.sh finished (exit 1) ===
```

`exit 1`, progress bar red, no write ever reached the card. The guard
itself works. But comparing that log excerpt against what the browser
actually showed live at the time turned up a real, separate gap: the
browser displayed the actual reason -
`ERROR: destination /dev/sda1 is a sibling partition on the same
physical card (/dev/sda) as the source mounted at /mnt/DamagedSD.
Refusing to write to the card being recovered.` - and that line is
**entirely missing** from the downloaded log file. Only the generic
`started`/`finished (exit 1)` bookends made it there.

Checked how widespread this was rather than patching just the one line:
every `ERROR:` message in this entire plugin - 23 of them across 8
scripts (`common.sh`, `sdcard_carve.sh`, `sdcard_delete_artifact.sh`,
`sdcard_evaluate.sh`, `sdcard_fsck_check.sh`, `sdcard_fsck_repair.sh`,
`sdcard_mount_ro.sh`, `sdcard_recover.sh`, `sdcard_verify.sh`) - used
plain `echo "ERROR: ..." >&2` instead of `log()`. Every one of them
reached the live browser stream (via `scripts_dispatch.php`'s `2>&1`
merge) but never the persistent log file - meaning **every hard-failure
reason this plugin has ever produced** has been invisible in a
downloaded log bundle, the primary way these logs actually get diagnosed
after the fact.

Fixed all 23, with one deliberate exception in how: `common.sh`'s
`validate_device()` is called via command substitution at all 5 of its
call sites (`PART=$(validate_device "$PART")`) - `log()`'s own
`echo "$line"` to stdout would land *inside* the captured return value,
right next to the real device path, corrupting it. Its two `ERROR:`
messages keep their existing `echo ... >&2` (unchanged behavior: visible
live, never captured) and additionally call `log_file_only()` -
`common.sh`'s existing helper that writes to `$LOG_FILE` only, never
stdout - alongside it. `guard_not_root_device()` (called directly, not
via `$(...)`, confirmed against its own already-documented history) and
every other call site across the other 7 scripts converted straight to
`log("ERROR: ...")`, safe since nothing else captures their stdout the
way `validate_device()`'s callers do. All 9 touched scripts pass
`bash -n`.

**Not yet validated**: a fresh real-hardware failure since this landed,
confirming its actual `ERROR:` text now shows up in a downloaded log
bundle - not just the generic exit-code bookends.

## Config restore racing a live `fppd` - attempted, genuinely inconclusive (real hardware)

Item 4 below (see "Config restore wrote straight to disk with fppd
possibly still running, no restart flag" above for the original finding
and the `restartFlag` mitigation) is a genuine timing race, not something
reproducible on demand through the UI the way the sibling-partition guard
or the flock lock were. Three real attempts on `GPIOTest` rather than
leave it purely theoretical:

1. Restored Config locally while, in a second browser tab, changing
   FPP's global log levels (Info -> Debug) as close to simultaneously as
   manually possible. Result: `HostName = Pi3Test` (the restore landed
   correctly) and every `LogLevel_*` field showed the new value cleanly.
2. Repeated the same restore, timed as tightly as manageable by hand
   after restoring `GPIOTest` back to a clean pre-test state first.
   Result: same clean restore, this time with no `LogLevel_*` fields
   present at all - consistent with the *source card's own* settings
   file simply never having them set, not with any collision.
3. A related but different race: started an FPP File Copy Backup to a
   second device (reading `GPIOTest`'s files) and clicked the plugin's
   local Config restore (writing to those same files) while it was
   running - a concurrent read/write race, not `fppd`'s own write/write
   race specifically. The resulting backup showed `HostName = Pi3Test` -
   a clean, consistent read of the fully-restored file, not a torn or
   partial one.

None of the three caught anything wrong - but watching the restore's own
`rsync --progress` output live during attempt 1 showed why that's not
surprising, and corrected an assumption made going into this: `settings`
was transferred **first** (`xfr#1 of 27`), not last, despite being
appended to the end of the shell script's own file list (`rsync
--files-from` does not reliably preserve source-list order for transfer)
- and the entire operation, config backup through `restartFlag`, is fast
enough that its own logged start/finish timestamps are identical to the
second. That is a genuinely sub-second write window. Landing a
manually-timed browser click, or even a short scripted loop, inside a
window that narrow, by chance, across three attempts, isn't strong
evidence either way - three misses are exactly what you'd expect whether
the race is real or not, given how small the actual target is.

**Honest status**: not proven unsafe (no corruption observed across three
real attempts) and not proven safe either (a sub-second window that's
hard to hit by hand isn't the same as a window that doesn't exist).
`restartFlag` remains the real, shipped mitigation for normal use - it
shrinks the risk window and makes the "restart before trusting what's
loaded" step hard to miss, which is what it was always meant to do. The
underlying race itself stays a real, understood, but essentially
unfalsifiable-by-hand risk without tooling built specifically to
synchronize the two operations (e.g. a wrapper pausing `sdcard_recover.sh`
mid-`rsync`, or `fppd` instrumented to log exactly when it re-reads and
patches the settings file).

## A fourth attempt, scripted instead of hand-timed - still inconclusive, but more rigorous (real hardware)

The three manual attempts above all missed a confirmed sub-second window
by hand - not surprising, and not strong evidence either way. A fourth
attempt on `GPIOTest`, this time scripted rather than manually timed,
using a real backup/restore cycle (the operator's own `GPIOTest` backup)
to make repeating the real, live Config-restore-onto-`GPIOTest` case
safe to attempt twice:

- **Racy run**: a tight loop of real `PUT /api/settings/LogLevel_General`
  calls (FPP's own live settings API, confirmed genuine by first probing
  its request/response shape directly) - 832 calls over ~15.8 seconds, a
  new call roughly every 19ms - started at the same moment as clicking
  Recover (local restore, Config category) on the real, previously-used
  source card. The restore itself logged start-to-finish inside a single
  second (`05:06:08`), confirming the same sub-second window as before -
  and this loop's density and duration comfortably spanned it many times
  over, not just once by chance.
- **Result**: `HostName` correctly read `Pi3Test` (the restore's real
  content, matching the source card) - not reverted to the pre-restore
  `GPIOTest`. The hammering loop's own last write also survived cleanly.
  No corruption in either direction.
- **Control run**: restored the operator's `GPIOTest` backup to reset
  state, then repeated the *exact same* Config restore with no hammering
  at all, to have a clean baseline to compare against rather than relying
  on assumptions about what "should" happen. Result: identical
  `HostName`/`HostDescription` to the racy run. `LogLevel_General` in the
  control run stayed at its pre-test value (`info`, never touched by the
  restore at all) - confirming that field was never actually part of what
  `sdcard_recover.sh`'s file list restores, so its survival in the racy
  run isn't itself meaningful; `HostName` was the real comparison point,
  and it matched cleanly between both runs.

**Why this still doesn't close the item**, despite being denser and
better-targeted than the three manual attempts: only *final* state was
checked after each run, not continuous state during it - a transient
mid-loop reversion that a later iteration of the same loop happened to
silently re-correct (by re-reading the by-then-correct file and patching
its own key back in) would be invisible to this method. Separately,
whether the HTTP settings API's `PUT` genuinely funnels through the same
whole-file read-patch-write path `fppd`'s internal `setSetting()` uses -
the actual mechanism the original finding is about - was never
independently confirmed; it was assumed reasonable given `restartFlag`'s
own precedent of going through this exact API, but not verified against
`fppd`'s own source or logs for this session. A real find either way
would need continuous polling during the write window and/or independent
confirmation of the write path, not just a denser retry of the same
approach.

Two live Config restores onto `GPIOTest` in this pass (racy run, then
control run) both left it carrying the source card's `Pi3Test` identity -
restoring the operator's own backup afterward is the way back, same as
after the original three attempts.

## Added: capped Step 5 at 2 destinations, with a fixed run order and a zip-ready prompt

Not a bug - a requested UX change to Step 5, once real-hardware testing
above had exercised recovering to local/USB/zip individually enough to
trust the underlying `recover` command itself. Previously all 3
destination checkboxes could be checked at once, and `runRecover()` ran
them in whatever order `selectedDestinations()` happened to return
(document order, so effectively always local -> usb -> zip regardless of
which you actually checked first) - local, the one destination that
overwrites *this device's own* media/config rather than copying
somewhere else, could end up running first or in the middle of a
multi-destination run with no way to change that from the UI.

Three changes, all in `js/sdcard-recover.js` (plus a one-line hint in
`status.php`):

- `enforceDestinationLimit()` caps the 3 checkboxes at 2 checked at once -
  disables whichever aren't checked once 2 are, re-enables all of them
  the moment one gets unchecked. Wired into the existing
  `input[name="sdcr-dest"]` change handler, alongside the USB-select
  enable/disable it already did.
- `DEST_RUN_ORDER = ['zip', 'usb', 'local']` replaces the old
  document-order destination list in `runRecover()` with a fixed
  priority, filtered down to whichever 2 (or fewer) are actually checked:
  zip always first, local always last, usb in between either way.
- The zip branch of `runRecover()`'s per-destination callback now shows
  `alert('Zip ready: ' + name + '\n\nClick OK to continue.')` after
  setting up the existing Download button and refreshing the artifacts
  list, before moving on to the next destination. `alert()` is already
  this plugin's established pattern for a blocking native dialog (the
  delete confirmation, the delete-failure message) - it needs no new
  state machine, since it's synchronous: `next(i + 1)` genuinely doesn't
  run until the user clicks OK.

**Confirmed** on real hardware - the destination cap, fixed run order,
and zip-ready `alert()` all worked as expected.

## Added: capped log panels at ~20 lines with a visible scrollbar

Real user report, right after confirming the Step 5 change above worked:
a long-running command (a big `rsync` or `photorec` run especially) can
stream enough output that `.sdcr-log` grows tall enough to push the rest
of the page - including the progress bar sitting right above it - out of
view, with nothing obviously telling you there's a scrollbar to find.

`.sdcr-log` already had a height cap (`max-height: 220px`) and
`overflow-y: auto`, so this wasn't a totally uncapped panel - but 220px
was a guessed pixel value, not tied to an actual line count, and `auto`
scrollbars are easy to miss depending on OS/browser (some only appear on
hover, or as a thin overlay). Fixed by giving the panel an explicit
`line-height: 1.4` and computing the cap from that instead of a guess -
`max-height: 28em` (1.4 x 20 lines, in `em` so it tracks this element's
own `font-size` rather than a hardcoded pixel count) - and switching
`overflow-y` from `auto` to `scroll`, so the scrollbar is always visibly
present as an affordance rather than only appearing once you've already
noticed something's cut off. `min-height: 2em` and `max-height` (not a
fixed `height`) are both kept, so a panel with little or no output yet
still starts small instead of showing as a big empty box the moment its
step becomes visible. The existing auto-scroll-to-newest-line behavior
(`streamCommand()`'s `onprogress` handler) is untouched - this only
changes how much is visible at once and how obvious it is that there's
more to scroll back through.

Applied to `.sdcr-log` itself, so it's shared by every log panel in the
plugin (mount, verify, carve, fsck, recover, artifacts, usb-refresh), not
special-cased to just the recover page that surfaced it - all of them
have the same "long streamed output" shape.

**Not yet validated at the time this was written** - see the section
directly below for what actually happened when it was: the design here
was correct, but a separate, real, pre-existing bug meant none of it
ever took effect at all until that bug was found and fixed too.

## `.sdcr-log`'s own dark styling never applied at all - a stray `*/` inside a comment (real bug, predates this whole session)

The line-count cap above looked completely correct by inspection, and
still is - but confirming it on real hardware turned into one of the
longest real-hardware investigations in this document, because the
actual symptom (`#sdcr-log-recover` rendering as a plain white,
completely uncapped block during a large recover) had nothing to do with
the change being tested. Ruled out, in order, each with real evidence
before moving to the next: a stale browser tab (closed and reopened -
still broken), browser cache (DevTools "Clear site data" - still broken),
gzip corruption of the served response (`gzip -t` on the raw compressed
bytes from a real request - valid), a stale file on disk (`wc -c` on the
real file on `GPIOTest` - matched the correct, current byte count), a
missing or duplicate `<link>` tag (View Source on the real page - present
exactly once, correct `href`), a full browser restart (still broken), and
a style-rewriting browser extension (Incognito, which disables extensions
by default - still broken). Every one of those checks came back clean.

The actual cause was sitting in the CSS file itself the entire time,
predating this session: the comment directly above `.sdcr-log` explained
that its dark styling doesn't need a Bootstrap or FPP design-system
token, naming both prefixes back to back separated by a bare forward
slash with no space - which means the asterisk ending the first prefix's
own wildcard sits directly next to that slash. Written out that way,
those two characters ARE CSS's comment-close sequence, so the comment
actually closed right there, mid-sentence - not at the real `*/` a few
words later. Everything from that accidental early close up to the next
occurrence of that same sequence (the rest of the original sentence, plus
the rule's own real closing marker) became invalid raw CSS text, which
the browser's parser had to recover from - and every real browser's CSS
parser recovers from that kind of garbage by skipping forward to the next
rule boundary, discarding whatever rule was in progress. The rule
immediately after was `.sdcr-log` itself - so its entire declaration
block was silently dropped, in every browser, on every device, every
single time the file was parsed. Confirmed directly: counting `/*` and
`*/` in the file found 8 opens and 9 closes, and a full depth-tracking
walk pinpointed the extra close to exactly this comment.

This was never anything to do with browser caching, stale tabs, or
extensions - the file the server was sending was correct and byte-for-
byte identical every single test, and every browser correctly parsed it
exactly the same (wrong) way, every time, because the file itself was
wrong. It also predates this entire session: this comment, and this typo,
were part of the plugin's very first real-hardware dark-theme fix, long
before any of today's changes - `.sdcr-log` has likely never actually
rendered dark in any browser, on any device, since that original fix
landed.

Fixed by rewriting the comment to describe the two token prefixes without
ever writing the literal two-character comment-close sequence anywhere in
the explanation - including, on the first attempt, inside the new comment
written to explain the bug, which reintroduced the exact same problem by
quoting the broken text verbatim. The real fix needed a second pass that
describes the sequence in words instead of ever typing it out. Verified
this time with a full comment-depth walk of the file (not just counting
opens vs. closes, which can coincidentally match while still being out of
order) confirming every comment closes at depth 0 with nothing left open.

**Confirmed** on real hardware, on the very next real recover after the
fix: every log panel on the page renders dark now, and the ~20-line cap
with its scrollbar is actually working - both this fix and the
line-count-cap change it was blocking are validated together.

## Added: Evaluate now shows free space on an already-attached USB drive too

Requested feature, once real-hardware testing above had exercised the
`recover` command enough to trust it as a foundation: Step 4 only ever
compared recoverable data against this device's own local free space -
if a destination USB drive was already plugged in, its free space stayed
unknown until Step 5, after the destination was actually picked.

An unmounted partition's free space isn't knowable generically across
vfat/exfat/ntfs/ext4 any other way, so `sdcard_evaluate.sh` now finds
real destination candidates (reusing `sdcard_scan.sh`'s own root/media/
already-mounted exclusion filter, plus one more exclusion that script
doesn't need: the source card's own disk, via `source_device()`, so this
never touches the card being recovered) and, for each one, briefly mounts
it read-only at a new dedicated `EVAL_MOUNTPOINT` (`common.sh`) - never
`DEST_MOUNTPOINT`, Step 5's own read-write destination mount, kept
separate so an evaluate/recover pair in the same session never contends
over the same mountpoint path - runs one `df`, and unmounts immediately.
`guard_not_root_device` still runs per candidate as defense in depth, but
inside a subshell rather than called directly: that function's real
`exit` is correct everywhere else it's used (right before a write), but
here a redundant safety check tripping on one candidate shouldn't cost
the already-computed local-storage numbers or any other candidate still
to check.

Results are added to the same `EVALJSON:` payload
(`ajax.php`/`sdcr_api_evaluate()` needed no changes - it already passes
the script's JSON straight through) as a `usbCandidates` array, each
entry's `model` traced straight back to `lsblk`'s own `MODEL` field - the
same untrusted, USB-device-controlled string `renderDeviceList()`/
`populateUsbDestinations()` already had a real XSS bug around (see "
`renderDeviceList` built HTML by string concatenation..." above). The
existing eval-results table is still built via `innerHTML` for its
original rows (safe - every value there is a number this plugin computed
itself), but the new USB rows are appended afterward as real DOM nodes
via `createElement`/`textContent`, the same safe pattern already
established elsewhere in this file, specifically because this is the
first time that table has ever needed to include a raw device-reported
string.

Verified before committing without real hardware to test against yet:
the two new `php -r` blocks (the candidate-detection scan and the
JSON-assembly rewrite) checked for balanced braces/parens/brackets *and*
zero literal single-quote characters (which would end the surrounding
bash single-quoted string early) - the same class of mistake as the
`.sdcr-log` comment bug above, just in a different quoting context. The
JS change was parsed with a real parser (`esprima`) instead of just
eyeballing the diff, after that same lesson.

**Confirmed** on real hardware: with the source card mounted at
`/mnt/DamagedSD` and the Cruzer stick already attached as `/dev/sdb1`
(freshly reformatted vfat, otherwise untouched), Evaluate correctly
added `Free space on /dev/sdb1 (Cruzer) - 7.4 GB - fits` to the results
table - the real candidate-detection scan found it, correctly excluded
the mounted source card, and the brief read-only mount/`df`/unmount
cycle reported real free space. All plugin-related network requests
(`.../page=ajax.php&endpoint=evaluate`, the streamed commands around it)
came back clean 200s, no JS console errors.

**Not yet validated**: a candidate with no real filesystem, or one that
fails to mount, being skipped gracefully rather than breaking the rest
of Evaluate (this session's candidate mounted cleanly on the first try,
so that path was never actually exercised) - and that `EVAL_MOUNTPOINT`
genuinely never collides with a concurrent Step 5 recovery to the same
drive.

## Sudo/permissions, checked against real log history (real hardware)

Item 3 in "Not yet validated" below was really two separate claims worth
untangling: whether a per-plugin sudoers entry needs to exist (it
doesn't - see [privacy.md](privacy.md#not-declared-privilege): FPP's
stock images already grant every plugin passwordless sudo, and this
plugin never adds a sudoers rule, group, or key of its own on top of
that), and whether that stock grant has actually held up across real
invocations rather than just being assumed. Only the second half is
something real hardware can confirm.

Rather than trigger a fresh session, checked the evidence real testing
had already generated: pulled `plugin-fpp-plugin-SDCardRecover.log`
(1,903 lines), `apache2-error.log`, and `fpp_plugin_manager.log`
directly from `GPIOTest` via its own `/api/file/Logs/...` endpoint (the
same one File Manager's Logs -> View uses) and searched all three for
`sudo`, `permission denied`, `not in the sudoers`, `password is
required`, and `no tty present` - the specific text sudo prints when a
caller isn't authorized or a TTY it expects isn't there. Zero matches in
any of the three files.

That's meaningful coverage, not just an absence of counter-evidence: the
plugin's own log alone spans every real-hardware session behind the
"Validated on real hardware" list below - `scan`, `mount_ro`, `verify`,
`evaluate`, `recover` (all three destinations), `carve`, `fsck -n`/
`fsck -y`, and `sdcard_delete_artifact.sh` all shell out via `sudo`
(`scripts_dispatch.php`'s `sdcr_passthru()`, or `ajax.php` directly for
`evaluate`), and every one of them ran to completion in these logs with
no sudo-shaped failure anywhere in the history the device still retains.
The stock passwordless-sudo grant this plugin relies on has been
exercised dozens of times for real and never once been the thing that
broke.

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
- **Deep scan/carving actually recovering real files** - once the
  `fileopt` extension list and the `255,` whole-disk selector were both
  fixed (see the sections above), a real run against `GPIOTest` recovered
  hundreds of genuine png/jpg/riff files, confirmed live in photorec's own
  progress output (`png: 103 recovered`, growing past 300 by the end of
  the run) and again by finding them on disk afterward. The only
  remaining gap was `sdcard_carve.sh` itself failing to report where they
  landed (the `$OUTDIR` vs `$OUTDIR.N` sibling-directory bug, fixed in the
  same section) - the actual recovery was working the whole time

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
3. ~~Sudo/permissions~~ (see "Sudo/permissions, checked against real log
   history..." above) - **confirmed**, with the caveat narrowed by that
   section: no per-plugin sudoers entry is needed (FPP's stock images
   already grant every plugin passwordless sudo, and this plugin adds
   nothing of its own on top - see
   [privacy.md](privacy.md#not-declared-privilege)), and a real-hardware
   log history search across 1,903+ log lines spanning every script this
   plugin runs via `sudo` turned up zero sudo-shaped failures anywhere.
4. **Routing local Config restore through FPP's own restore tooling**
   (`/api/backups` JSON restore, or `copy_settings_to_storage.sh`'s restore
   path) instead of a raw `rsync` straight to disk - see the section above.
   `restartFlag` is set now, which shrinks the risk window, but doesn't
   change that fppd could in principle still be running when the write
   happens. A real architectural change, still not attempted. Separately,
   the underlying race itself (not this fix) got four real attempts on
   real hardware now - three manual (see "Config restore racing a live
   `fppd`..." above) and one scripted, denser, and confirmed to actually
   span the real sub-second write window (see "A fourth attempt, scripted
   instead of hand-timed..." above) - still genuinely inconclusive: no
   corruption caught in any of the four, but final-state-only checking
   and an unconfirmed write-path assumption keep even the scripted
   attempt from being a real test of whether this specific fix is needed.
5. ~~The new global `flock` lock in `common.sh`~~ - **confirmed** on real
   hardware (see "The global `flock` lock, confirmed under genuine
   concurrency..." above): a deep scan held the lock for nearly 9 minutes
   while two chained requests from a second tab were both correctly
   refused and logged, and the carve itself finished cleanly (`exit 0`,
   359 candidates) completely undisturbed.
6. ~~The new superfloppy-media branch in `sdcard_scan.sh`~~ (see
   "Destination dropdown never populated..." above) - **confirmed** on
   real hardware: reformatted the Cruzer with `wipefs -a` +
   `mkfs.vfat -I` directly on `/dev/sdb` (no partition table at all -
   `lsblk` showed `FSTYPE=vfat` on the disk line itself, no `sdb1`
   child). `sdcard_scan.sh` correctly emitted the synthetic
   `"device":"/dev/sdb","parent":"/dev/sdb",...,"partition":true` line,
   and Step 5's Refresh correctly listed it as
   `/dev/sdb - Cruzer (vfat) - 7.5 GB` (`value="/dev/sdb"`, the whole
   disk) - selectable as a real destination, not just detected. The
   corrupted-partition-table `NOTE:` path was already confirmed earlier
   against the real Cruzer stick that surfaced this whole finding.
7. ~~Removing the stale `sdcr.device` exclusion from
   `populateUsbDestinations()`~~ (see "Destination dropdown could
   silently exclude a healthy drive..." above) - **confirmed** on real
   hardware: with the source mounted, physically unplugged and replugged
   the destination Cruzer stick, then clicked Refresh at Step 5. The
   dropdown correctly listed `/dev/sdb1 - Cruzer (vfat) - 7.5 GB` -
   the old buggy code would have left it empty.
8. ~~The sibling-partition destination guard~~ (`source_device()` in
   `common.sh`, the new check in `sdcard_recover.sh`, and the restored
   client-side filter - see "The sibling-partition destination guard,
   confirmed on real hardware..." above) - **confirmed**: the dropdown
   correctly never offered the source card's own sibling partition, and
   bypassing that filter deliberately to force it through anyway got a
   clean, correct real-hardware refusal from `sdcard_recover.sh` itself,
   `exit 1`, no write ever reached the card.
9. ~~The `config/plugin.SDCardRecover/` exclusion in `sdcard_verify.sh`~~ -
   **confirmed** on real hardware: manually mounted the source card
   read-write outside the plugin (a one-time, deliberate step the plugin
   itself never does) just long enough to plant
   `home/fpp/media/config/plugin.SDCardRecover/dummy.txt`, then ran the
   normal Scan -> Mount (read-only) -> Verify flow. Verification reported
   the same `100 readable, 0 unreadable, 100 total files` as every prior
   baseline run - not 101 - and `grep`ing the real manifest for
   `plugin.SDCardRecover`/`dummy` on the device came back empty. The
   source card's own copy of this plugin's scratch state is genuinely
   excluded, not just excluded in theory.
10. ~~The `blockdev --setrw` reversal in `sdcard_unmount.sh`~~ (see
    "`blockdev --setro` was never reversed after a normal (non-repair)
    session..." above) - **confirmed** on real hardware: right after a
    normal Scan-triggered unmount of the source card, `sudo blockdev
    --getro /dev/sda2` reported `0` - block-layer writable again, not
    stuck read-only. The `fpp_uninstall.sh` half of this same fix (the
    card still attached at uninstall time) remains unexercised.
11. ~~`log_file_only()` and `sdcard_scan.sh`'s new "Scan found:" block~~
    (see "A scan's own results never reached the persistent log file..."
    above) - **confirmed** from a real `GPIOTest` session's downloaded log
    bundle (2026-09-20): every real scan in that session logged its full,
    timestamped device listing, and the listing was there in the actual
    zip downloaded from FPP's own Logs tab, not just live in the browser.
12. ~~The deep-scan offer actually rendering from the `DIRS_WITH_ERRORS`
    fix~~ - **confirmed** on the real hardware that surfaced the bug: after
    a hard refresh (see the stale-JS testing gotcha above), the offer
    rendered and "Run deep scan" ran successfully, which is what surfaced
    the next finding below.
13. ~~The `/d` trailing-slash fix and stray-directory warning in
    `sdcard_carve.sh`~~ (see "photorec's real output landed next to
    $OUTDIR, not inside it..." above) - **confirmed** on the same real
    `GPIOTest` session (2026-09-20): a carve run with the fix in place
    correctly reported 359 candidate file(s) - the first nonzero count
    that session - with no `STRAY_DIRS` warning, meaning no leftover
    sibling directory was created.
14. ~~The auto-unmount-before-scan fix in `runScan()`~~ (see "I have to
    unplug and replug the reader every time..." above) - **confirmed**
    from the same real `GPIOTest` session (2026-09-20): the plugin log
    shows three separate `sdcard_unmount.sh` -> `sdcard_scan.sh` chains,
    each finding the card again immediately afterward (07:33:06, 07:43:08,
    09:44:56). Cross-checked against `logs/syslog.log` for all three -
    none show a matching `USB disconnect`/`New USB device found` pair,
    unlike a real replug elsewhere in the same session (06:56:54, a clean
    disconnect/reconnect that explains that session's own `sda`->`sdb`
    device-letter change). The card became visible again purely from the
    software unmount, with the reader never physically touched - exactly
    the scenario this fix was for.
15. ~~The Recovery Artifacts section's actual delete action~~ - **confirmed**
    on real hardware: with the executable bit fixed (see item 19 below),
    a real retest on `GPIOTest` deleted the leftover recovery zip
    successfully. The full arc - broken since the feature was first added
    (see "The real cause of the failed delete..." above), diagnosed via a
    real user report, fixed, and now confirmed working - is closed.
16. ~~The `stream.php` header-ordering fix~~ - **confirmed** on real
    hardware (see "`stream.php`'s own `Content-Type` header silently
    never applied..." above): checked `apache2-error.log` via FPP's own
    File Manager -> Logs -> View directly. Every `headers already sent`
    warning for `stream.php` in the file is timestamped before 09:56:24
    on 2026-09-20, exactly when the fix landed - zero occurrences since,
    across dozens more real `stream.php` calls (mount, verify, carve,
    recover, multiple real-hardware test sessions) spanning the rest of
    that day and all of the next.
17. ~~The delete button's `(ok, text)` error-visibility fix~~ - **confirmed**
    on real hardware, sooner than expected: it's the reason "The real
    cause of the failed delete..." above could be diagnosed at all. A real
    retry on `GPIOTest` produced a real `alert()` with the actual streamed
    `sudo: ...: command not found` text, exactly as designed, where the
    old code would have shown nothing. The other half of that same fix -
    `common.sh`'s log-ordering change for a genuine lock-contention
    refusal specifically - is still unconfirmed, since that was never what
    this particular failure turned out to be.
18. **`carve` and `fsck_repair`'s `streamCommand` callbacks ignoring
    `(ok, text)`** - fixed (see "`carve` and `fsck_repair` closed the
    same `(ok, text)` gap..." above), same shape and same fix as the
    delete button's. A real attempt was made at the `carve` half (see
    "Pulling the reader mid-carve - attempted, genuinely inconclusive..."
    above): a genuine mid-scan USB disconnect, confirmed at the kernel
    level in `syslog`, still didn't produce a nonzero exit from
    `sdcard_carve.sh` - `photorec` finished cleanly anyway. The
    `fsck_repair` half surfaced a real, separate bug first - see "A large
    real `fsck -y` response lost its own exit-code marker..." above -
    fixed, and the fix's actual parsing logic was verified directly
    against a real repair on real hardware (`exitOk` computed `false` for
    a genuine exit code 1). Still not independently confirmed through the
    literal page UI end-to-end, blocked by the browser-caching issue in
    "A stale browser tab..." above rather than by anything wrong with the
    fix itself. `runCarve()`'s own failure branch also remains
    unvalidated (the disconnect attempt didn't hit it).
19. ~~The `sdcard_delete_artifact.sh` executable-bit fix~~ - **confirmed**
    on real hardware (see "The real cause of the failed delete..." above):
    `git update-index --chmod=+x` corrected the tracked mode, and a real
    retest on `GPIOTest` afterward deleted a real artifact successfully.
20. ~~The progress-bar red/failed state~~ - **confirmed** on real hardware
    (see "The progress bar always turned green, even on failure..."
    above): a real `mount_ro` failure (card removed after Scan, before
    Mount) turned Step 2's bar solid red, matching the fsck-fallback box
    that correctly appeared alongside it.
21. ~~The `ERROR:` -> `log()`/`log_file_only()` conversion across all 9
    scripts~~ - **confirmed** on real hardware, and specifically the
    trickiest case: removed the card after Scan but before Mount,
    triggering `validate_device()`'s `ERROR: /dev/sda2 is not a block
    device`. Checked the actual persistent log file directly (not the
    live browser panel, which was never the part in question) -
    `[timestamp] ERROR: /dev/sda2 is not a block device` is right there
    between the `started`/`finished` lines, confirming `log_file_only()`
    correctly persists it without corrupting `validate_device()`'s own
    command-substitution-captured return value.
22. ~~The Step 5 destination limit, fixed run order, and zip-ready
    prompt~~ - **confirmed** on real hardware (see "Added: capped Step 5
    at 2 destinations..." above): the cap, the fixed run order, and the
    `alert()` all worked as expected.
23. ~~The `.sdcr-log` line-count cap, and the stray-`*/`-in-a-comment bug
    that silently blocked it from ever applying~~ - **confirmed** on real
    hardware (see "Added: capped log panels..." and "`.sdcr-log`'s own
    dark styling never applied at all..." above): every log panel renders
    dark now, and the ~20-line cap with its scrollbar actually works.
24. ~~Evaluate showing free space on an already-attached USB drive~~ -
    **confirmed** on real hardware (see "Added: Evaluate now shows free
    space on an already-attached USB drive too" above): a real attached
    Cruzer stick correctly showed `Free space on /dev/sdb1 (Cruzer) -
    7.4 GB - fits` in the results table. Two narrower pieces are still
    open: an unmountable candidate being skipped gracefully (never
    exercised - this session's candidate mounted cleanly), and confirming
    `EVAL_MOUNTPOINT` never collides with a concurrent Step 5 recovery.
