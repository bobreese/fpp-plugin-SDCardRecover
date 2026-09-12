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
- **Destinations:** local FPP storage, a second attached USB drive, or a zip
  built for browser download - all three, user's choice, matching FPP's
  existing Copy Settings (USB) and JSON config backup (download) patterns.
  Local restore is category-selective and goes directly into this device's
  real `/home/fpp/media/<category>/` directories (not a side staging
  folder) - the user picks which of config/sequences/music/videos/effects/
  scripts/events/channelmemorymaps/playlists/images/plugins/upload/backups
  to bring in (see `CATEGORY_RE` in `scripts/common.sh` for the current,
  authoritative list - cross-checked against both of FPP's own backup
  tools, see below). **Config is special-cased**: since `/home/fpp/media/config`
  *and* the separate flat `/home/fpp/media/settings` file together hold this
  active device's own name, IP (if statically set), plugin settings, and
  timezone, restoring it overwrites this device's own identity, not just
  adds files. The UI requires an explicit "I understand" confirmation before
  Config can be included, and `sdcard_recover.sh` backs up this device's
  current config directory, `settings` file, and `timezone` file
  unconditionally before ever touching any of them, regardless of what the
  UI already confirmed.
- **Persistent logging.** Every step is appended to `media/logs/SDCardRecover.log`
  (FPP's own log directory - `www/config.php`'s `$logDirectory`, exposed to
  child processes as `$LOGDIR`), so it shows up automatically in FPP's File
  Manager -> Logs tab (that tab just lists whatever's in that directory) - not
  only in the live browser stream. Handled centrally in `scripts/common.sh`'s
  `log()`, plus a start/finish trap per script for traceability.
- **Progress UI** reuses FPP's actual streaming mechanism (`StreamURL()` in
  `www/js/fpp.js` - a long-poll `xhr.onprogress` diff, not WebSocket/SSE) the
  same way Copy Settings and the Remote Backups page do. Note: FPP's real
  backup pages don't show a numeric percentage - what looks like "progress"
  there is the live log text. This scaffold's progress bars are indeterminate
  ("working..." animation) while a step streams, turning solid on completion,
  since there's no byte-accurate source to compute a true percentage from
  fsck/rsync/photorec output.
- **If developing from Windows: watch the executable bit.** This repo's git
  config has `core.filemode=false` (Windows/NTFS default), so a plain
  `chmod +x` on a new script is silently ignored by git and it gets
  committed as `100644` - it'll clone fine but `sudo`/exec on Linux fails
  with "command not found". This bit every script the first time
  (`sdcard_scan.sh` and friends all had to be fixed after the fact). Force it
  explicitly per file instead: `git update-index --chmod=+x path/to/script.sh`.

## Layout

```
pluginInfo.json         Plugin manifest (name, deps: e2fsprogs, dosfstools, testdisk, zip, rsync)
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
  fpp_install.sh         Plugin Manager install hook (apt deps, dirs)
  fpp_uninstall.sh       Plugin Manager uninstall hook (leaves recovered data in place)
```

## pluginInfo.json schema (confirmed against live FPP v10.x source)

The initial scaffold guessed at this schema and got it wrong in ways that
broke installation entirely. Confirmed by pulling FPP's actual
`www/plugins.php` (the code that reads this file) and `fpp-plugin-Template`'s
real `pluginInfo.json`:

- **`repoName` is required** and must exactly match the GitHub repo name
  (`fpp-plugin-SDCardRecover`). FPP's install/uninstall/update/icon lookups
  are all keyed by this field, read directly out of the JSON - not derived
  from `name` or `srcURL`. Omitting it is why "Install anyway" failed with
  *"Could not find plugin in pluginInfo cache"*: the plugin got cached under
  `repoName: undefined`, which doesn't match the string the Install button
  was wired to look up.
- **`description` is a single field**, not `shortDescription`/`longDescription`.
- **`iconURL` must be an absolute URL** (e.g. a `raw.githubusercontent.com`
  link), not a path relative to the repo - a relative one resolves against
  nothing FPP can use and silently falls back to a text-initial avatar.
- **Version compatibility is picky about explicit major-version coverage**:
  a version entry with no explicit `maxFPPVersion` is only treated as
  "compatible" with the FPP major version it was authored against
  (`minFPPVersion`'s major) - an open-ended range starting at an old major
  still gets flagged "not updated for FPP 10" on a v10 box. Since this
  plugin has only ever been tested against v10.x (the original `7.0` minimum
  was an unverified guess made during initial scaffolding, not a real
  compatibility claim), `versions` now honestly declares `10.0` - `0`
  (unbounded) only.

## Page routing (confirmed against live FPP v10.x source, after real install failures)

Getting this plugin to actually load surfaced three more schema/plumbing bugs,
found by pulling FPP's real `www/plugin.php`, `www/menu.inc` conventions, and
a working plugin (`fpp-LoRa`)'s source, rather than guessing:

- **`menu.inc` is not just a data file.** FPP `include`s it directly and
  expects it to `printf` the actual `<li><a>` HTML itself, using `$plugin`/
  `$menu` variables FPP injects - the original scaffold only defined
  `$menuEntries` with no rendering loop, and its `'page'` value was a whole
  pre-built URL instead of the bare filename (`status.php`) FPP's own loop
  turns into `plugin.php?plugin=<repo>&page=<page>`. The bare/pre-built
  mismatch is exactly what produced *"Error with plugin, requesting a page
  that doesn't exist: fpp-plugin-SDCardRecover/plugin.php?_menu=...&page=status.php"*
  - `www/plugin.php` builds that exact `$pluginName/$pageName` error string
    verbatim when `page=` doesn't resolve to a real file.
- **There is no clean static URL for a plugin's own PHP files, and no
  `pluginBaseURL()` helper** (both `status.php` and `js/sdcard-recover.js`
  originally assumed one existed - it doesn't). Confirmed in `plugin.php`:
  `file=...` always ends in `readfile()`, so a `.php` file requested that way
  is served as its own source text, never executed. The only way to run a
  plugin's PHP dynamically is `plugin.php?plugin=<repo>&page=<file>&nopage=1`,
  which `include_once`s it into the same request - `stream.php`, `api.php`,
  and the JS that calls them were rewritten around this.
- **`js`/`css` assets need no manual `<link>`/`<script>` tags at all** -
  `plugin.php` auto-scans the plugin's `js/` and `css/` directories and
  injects a tag per file it finds, each pointing at
  `plugin.php?plugin=<repo>&file=js/<name>&nopage=1`. `status.php`'s manual
  tags (via the nonexistent `pluginBaseURL()`) were redundant on top of being
  broken.
- **`api.php`'s original `getEndpoints<Plugin>()` self-registration doesn't
  apply here.** That's a real FPP convention, but for routes served by
  fppd's own C++ backend and proxied through Apache's `/plugin-apis/<name>`
  rule (confirmed via `fpp-LoRa`, which calls
  `fetch('api/plugin-apis/LoRa')`) - a different mechanism requiring backend
  registration this plugin doesn't have. `api.php` is now a plain
  `?page=api.php&nopage=1&endpoint=...` dispatcher, consistent with how
  `stream.php` actually works.
- **`stream.php`'s `require_once` path was wrong.** It used
  `dirname(__FILE__) . '/../../common.php'`, which resolves two directories
  above the plugin - outside it entirely - and would fatal. Since this file
  is only ever `include_once`'d by `plugin.php` (never requested directly),
  the fix is the same bare `require_once "common.php";` `plugin.php` itself
  uses, which PHP resolves against FPP's www root as the request's top-level
  script.

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

## Validated on real hardware

Real second FPP SD card (`Pi3Test`), read over USB by a second FPP device
(`GPIOTest`), with a full raw `dd` image taken first so corruption tests
were safely reversible. Confirmed working end-to-end:

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

**Not yet validated:**

1. **Config restore actually changing this device's identity on reboot.**
   The original test (restore Config onto `GPIOTest` from `Pi3Test`, reboot,
   check the hostname) is what surfaced the `settings`/`timezone` gap in the
   first place - the code was fixed, but testing then moved on to the File
   Copy Backup cross-check and the corruption/fsck work below rather than
   circling back to redo that exact reboot test with the fix in place. Fixed
   in code and reasoned through, not yet reconfirmed against a real reboot.
2. **The "some files unreadable" path, with a genuine I/O error** (as
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
3. **photorec's `/cmd` micro-syntax is finicky and version-dependent** - the
   exact extension-whitelist syntax in `sdcard_carve.sh` needs to be tested
   against the `testdisk` package version FPP actually ships, and may need
   `partition_order` / `search` flags adjusted. The deep-scan/carving path
   has not been exercised at all yet.
4. **Sudo/permissions**: every script assumes it's invoked via `sudo` from the
   web server user, matching FPP core's own pattern in `backups.php` - the
   plugin's sudoers entry (if FPP requires one per-plugin) isn't set up here.
   (Real testing so far hasn't hit a permissions problem, but that's not the
   same as this being formally set up.)

## Installing this for testing (not yet in FPP's Plugin Manager search)

FPP's "Search Plugins" only searches the community-curated
`pluginList.json` in `FalconChristmas/fpp-data`, which requires a PR and
passing automated checks (license present, tested against latest release +
nightly, safe scripting) - not just having a public repo with a valid
`pluginInfo.json`. Until that submission happens, install manually for
development:

```bash
ssh fpp@<your-fpp-ip>
cd /home/fpp/media/plugins
git clone https://github.com/bobreese/fpp-plugin-SDCardRecover.git
```

Then either reboot, or activate it live without rebooting:

```bash
curl -X POST http://localhost/api/fppd/plugin/fpp-plugin-SDCardRecover/load
```

**Alternative**: FPP's Plugin Manager can also install directly from a
`pluginInfo.json` URL, but only when the device's **UI Level** is set to
**Developer** (Settings -> UI tab) - below that level, pasting a URL into
the search box just runs a plain text search instead. With Developer level
on, paste this into the Plugin Manager's search/URL box:

```
https://raw.githubusercontent.com/bobreese/fpp-plugin-SDCardRecover/main/pluginInfo.json
```

(the raw content URL, not the `github.com/.../blob/main/...` page a browser
normally shows you - see the plugin's own troubleshooting notes for why
that distinction matters).

**Known cosmetic limitation of this path**: the manually-loaded "Available"
card shows initials ("SR") instead of the real icon, and this is not
fixable from the plugin's side. Confirmed in FPP's own
`www/api/controllers/plugin.php` (`PluginServeIcon()`): the icon is resolved
in exactly three tiers - (1) a local `icon.png` in the plugin's own
directory, (2) that installed plugin's own `pluginInfo.json` `iconURL`, (3)
the `iconURL` from the *official, server-cached* `pluginList.json` entry for
that repo. A manually-loaded, not-yet-installed, unlisted plugin satisfies
none of these - the pasted URL only ever lives in the browser's own JS
memory, never reaches the server, and there is no fourth tier for that. The
icon displays correctly the moment the plugin is actually installed (Tier 1
applies as soon as `icon.png` exists on disk) - this is purely a pre-install
preview quirk of the developer-only manual-URL workflow.

## Suggested repo name

FPP's plugin-manager convention names repos `fpp-plugin-<Name>` (see
`fpp-plugin-Template`) so FPP can recognize and install it - this scaffold
uses `fpp-plugin-SDCardRecover` for that reason, with "SDCard Recover" kept
as the human-facing name in `pluginInfo.json`.
