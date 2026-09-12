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

## Known gaps before this runs on real hardware

This was written without access to a live FPP checkout or a Raspberry Pi to
test against, so before trusting it on an actual damaged card:

1. **photorec's `/cmd` micro-syntax is finicky and version-dependent** - the
   exact extension-whitelist syntax in `sdcard_carve.sh` needs to be tested
   against the `testdisk` package version FPP actually ships, and may need
   `partition_order` / `search` flags adjusted.
2. **`sdcard_evaluate.sh`'s target directory list** (`TARGET_DIRS` in
   `sdcard_verify.sh`) assumes a standard FPP media layout; confirm against
   whatever FPP version/config the target systems run.
3. **Sudo/permissions**: every script assumes it's invoked via `sudo` from the
   web server user, matching FPP core's own pattern in `backups.php` - the
   plugin's sudoers entry (if FPP requires one per-plugin) isn't set up here.
4. No automated tests - this needs to be exercised against a real second SD
   card (ideally one deliberately corrupted in a VM/loopback device first)
   before pointing it at an irreplaceable show's card.

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

## Suggested repo name

FPP's plugin-manager convention names repos `fpp-plugin-<Name>` (see
`fpp-plugin-Template`) so FPP can recognize and install it - this scaffold
uses `fpp-plugin-SDCardRecover` for that reason, with "SDCard Recover" kept
as the human-facing name in `pluginInfo.json`.
