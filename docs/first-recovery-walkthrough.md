# Your First Recovery Session, End to End

This follows **Scenario A** from [Installing This Plugin](installing.md):
your own device's card failed, you've put a fresh working FPP card into
that same device, and installed SD Card Recover on it. The damaged card is
attached over USB. Every log line below is real output from actual testing
(see [Testing & Real-Hardware Findings](testing.md)), lightly trimmed -
timestamps and device paths will differ on your own run, but the shape of
the output won't.

Everything here also lands in
`media/logs/plugin-fpp-plugin-SDCardRecover.log` as it happens, so if you
navigate away or lose the page mid-session, that file has the full
record.

## Step 1: Scan

Click **Scan**. Within a second or two, the damaged card should appear in
the device list - a removable USB block device with its partitions
listed. If nothing shows up, the page displays "Reattach USB SD Card"
right next to the Scan/Rescan buttons; reseat the card or the reader and
click **Rescan**.

## Step 2: Mount & verify readability

Click **Mount read-only**. What happens next depends on whether the
card's filesystem is intact.

### The straightforward case

```
[2026-09-12 15:00:05] === sdcard_mount_ro.sh started: /dev/sda2 ===
[2026-09-12 15:00:05] Attempting read-only mount of /dev/sda2 (fstype: ext4) at /mnt/DamagedSD...
[2026-09-12 15:00:05] Mounted /dev/sda2 read-only at /mnt/DamagedSD.
[2026-09-12 15:00:05] === sdcard_mount_ro.sh finished (exit 0) ===
[2026-09-12 15:00:05] === sdcard_verify.sh started:  ===
[2026-09-12 15:00:05] Verifying home/fpp/media/config ...
[2026-09-12 15:00:05] Verifying home/fpp/media/sequences ...
[2026-09-12 15:00:05] Verifying home/fpp/media/music ...
                        ... (one line per category) ...
[2026-09-12 15:00:05] Verification complete: 13 readable, 0 unreadable, 13 total files.
[2026-09-12 15:00:05] Manifest written to /home/fpp/media/config/plugin.SDCardRecover/manifest.tsv
[2026-09-12 15:00:05] === sdcard_verify.sh finished (exit 0) ===
```

The mount succeeded, and every file the plugin checked was actually
readable end to end - not just present in a directory listing. "0
unreadable" here means exactly that: nothing on this card raised a real
I/O error during a full read.

### If the mount fails: the fsck fallback

```
[2026-09-12 15:27:39] === sdcard_mount_ro.sh started: /dev/sda2 ===
[2026-09-12 15:27:39] Attempting read-only mount of /dev/sda2 (fstype: unknown) at /mnt/DamagedSD...
[2026-09-12 15:27:39] Read-only mount of /dev/sda2 failed.
[2026-09-12 15:27:39] === sdcard_mount_ro.sh finished (exit 2) ===
```

A failed-mount box appears, offering a non-destructive check. Click **Run
fsck -n (safe, read-only)**:

```
[2026-09-12 15:33:46] === sdcard_fsck_check.sh started: /dev/sda2 ===
[2026-09-12 15:33:46] Running non-destructive check (fsck -n) on /dev/sda2 (fstype: unknown)...
[2026-09-12 15:33:46] No changes will be written to the card during this step.
[2026-09-12 15:33:58] fsck -n exit code: 4 (0/1 = clean or non-fatal, higher = filesystem problems present)
[2026-09-12 15:33:58] === sdcard_fsck_check.sh finished (exit 4) ===
```

Exit code 4 means real filesystem problems were found - nothing was
changed yet. A repair offer appears, with its own separate confirmation
checkbox ("I understand this may destroy data"). Only after checking that
box does **Attempt repair (fsck -y)** become clickable:

```
[2026-09-12 15:35:57] === sdcard_fsck_repair.sh started: /dev/sda2 ===
[2026-09-12 15:35:57] WARNING: running repair (fsck -y) on /dev/sda2 (fstype: unknown).
[2026-09-12 15:35:57] This writes changes to the card and is not reversible.
[2026-09-12 15:35:57] fsck -y exit code: 12
[2026-09-12 15:35:57] === sdcard_fsck_repair.sh finished (exit 12) ===
[2026-09-12 15:35:58] === sdcard_mount_ro.sh started: /dev/sda2 ===
[2026-09-12 15:35:58] Attempting read-only mount of /dev/sda2 (fstype: ext4) at /mnt/DamagedSD...
[2026-09-12 15:35:58] Mounted /dev/sda2 read-only at /mnt/DamagedSD.
[2026-09-12 15:35:58] === sdcard_mount_ro.sh finished (exit 0) ===
```

A nonzero repair exit code (12 here) doesn't necessarily mean the repair
failed outright - the plugin retries the mount regardless, and in this
real case it succeeded afterward. Verify then runs automatically against
the newly-mounted card, the same as the straightforward case above. If
you were watching the fsck sub-box, the retried mount/verify log lines
appear back up in Step 2's main panel - scroll up if it looks like nothing
happened. See [Testing & Real-Hardware Findings](testing.md#the-fsck-fallback-ui-could-never-actually-appear-real-bug-real-corruption-test)
for the full story behind this chain.

*(Step 3 is just a status card confirming the card is mounted as
`DamagedSD` - nothing to click there, so it's skipped here.)*

## Step 4: Evaluate

Click **Evaluate**:

```
[2026-09-12 15:01:19] === sdcard_evaluate.sh started:  ===
[2026-09-12 15:01:19] Recoverable data found: 30 file(s), 408830888 bytes
[2026-09-12 15:01:19] Unreadable (skipped): 0 file(s)
[2026-09-12 15:01:19] Free space on this FPP's local storage (/home/fpp/media): 26220216320 bytes
[2026-09-12 15:01:19] === sdcard_evaluate.sh finished (exit 0) ===
```

This just compares what Step 2 found readable against free space on
*this* device - nothing is copied yet.

## Step 5: Recover

In Scenario A, this device is the replacement controller itself, so the
right choice is **local storage**, categories selected as needed,
**including Config** - that's what actually restores this device's show
identity, not just its media:

```
[2026-09-13 09:16:07] === sdcard_recover.sh started: local config,sequences,music,videos,effects,scripts,events,channelmemorymaps,playlists,images,plugins,upload,backups ===
[2026-09-13 09:16:08] WARNING: config is being restored - this overwrites THIS device's own name, IP (if static), plugin settings, and other core configuration.
[2026-09-13 09:16:08] Backing up this device's CURRENT config to /home/fpp/media/backups/config.before-recover-20260913-091608 first, in case this wasn't intended.
[2026-09-13 09:16:08] Backing up this device's CURRENT settings file to /home/fpp/media/backups/settings.before-recover-20260913-091608 first.
[2026-09-13 09:16:08] Restoring 27 file(s) directly into /home/fpp/media/ (categories: config sequences music videos effects scripts events channelmemorymaps playlists images plugins upload backups)
[2026-09-13 09:16:23] Done. Restored into /home/fpp/media/ (categories: config sequences music videos effects scripts events channelmemorymaps playlists images plugins upload backups)
[2026-09-13 09:16:23] Config was overwritten - restart FPPD (or reboot) for the new settings (including HostName/network) to take effect.
[2026-09-13 09:16:23]   Previous config saved to /home/fpp/media/backups/config.before-recover-20260913-091608
[2026-09-13 09:16:23]   Previous settings file saved to /home/fpp/media/backups/settings.before-recover-20260913-091608
[2026-09-13 09:16:23] === sdcard_recover.sh finished (exit 0) ===
```

Note the backup lines happen unconditionally, before anything is
overwritten - that's true even though the UI already made you confirm
"I understand" before Recover became clickable.

(If you were instead in **Scenario B** - a borrowed, currently-active
device - this step looks the same except you'd pick **USB drive** or
**zip** here instead of local storage, then carry the result over to the
real replacement card afterward, per Scenario B in
[Installing This Plugin](installing.md).)

## What "done" looks like

Reboot (or restart FPPD) when the log says to. If Config was included,
expect two things on the way back up: this device's header now shows the
damaged card's old name, and **FPP's Initial Setup wizard may run once
more** - that's FPP's own privacy-consent design working as intended, not
a sign anything went wrong. See
[Testing & Real-Hardware Findings](testing.md#initial-setup-reappears-after-a-cross-device-config-restore-expected-not-a-bug)
for why. Once through that (if it appears), browse File Manager to confirm
your sequences/media actually came back, and you're done.
