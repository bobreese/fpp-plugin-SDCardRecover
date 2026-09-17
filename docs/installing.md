# Installing This Plugin

## FPP version requirements

This plugin needs **FPP 10.0 or newer** to install and run - that's about
the Host you install it on, not the card you're recovering. SD Card
Recover reads a damaged card as plain files on a partition, so it works
recovering a card written by **any** FPP version, old or new. Confirmed on
FPP 9.5: the plugin doesn't appear at all through the Plugin Manager's
manual-URL path there, so a 9.5 (or older) device can't currently serve as
the Host - pick whichever spare or replacement device you're using for
recovery based on what FPP version *it's* running, independent of what
version the damaged card came from.

## Before you install: know which scenario you're in

### Scenario A - it's this device's own card that failed (the common case)

1. **Pull the failing/damaged card** out of the device it was in. Don't
   try to diagnose or recover it in place.
2. **Put a freshly-imaged, working FPP SD card into that same device** so
   it's back online. It doesn't need your show's config or sequences on
   it yet - recovering those is the whole point of this plugin. A plain,
   bootable FPP install is enough for now.
3. **Install SD Card Recover on this same device.** It has no show
   running on it right now - the blank card from step 2 has nothing worth
   protecting - so there's nothing at risk from either concern below.
   Attach the damaged card over USB, run the wizard, and **restore
   directly into local storage, Config included** - that's exactly what
   you want here, since this device's whole job is to become that show
   controller again. No zip/USB shuffle needed; it lands in place in one
   pass. Reboot when done.

### Scenario B - you'd be borrowing a different, currently-active device as the Host

If the only device you'd use to run recovery is itself responsible for a
live show right now - not the one whose card failed, but some other
controller you're tempted to grab for convenience - **don't install it
there.** Use a genuinely spare device instead (a spare Pi, an old laptop
running FPP, anything not currently responsible for output):

- Recover to **a USB drive or a zip**, not local storage - local restore
  would land everything on that device's own storage instead of where you
  actually need it, and Config would overwrite *its* identity, which you
  don't want.
- Then bring the recovered files onto the replacement card from Scenario
  A: copy the zip's contents in through FPP's own File Manager, or plug
  the USB drive into the replacement device and pull from it the same
  way.

If a live device is genuinely your only option - no spare exists - the
same two rules still apply: zip/USB destination only, and do it outside
show hours, not during a live run.

**Why the distinction matters:**

- **Restoring Config overwrites the Host's own identity** - its name,
  network settings, everything under Settings. Desirable on the blank
  replacement card in Scenario A (that's the whole point); destructive on
  a device with its own show to protect in Scenario B. (This plugin
  already refuses to mount, fsck, or repair the device it's *booted
  from* - see `guard_not_root_device()` in
  [`scripts/common.sh`](../scripts/common.sh) - so it can never destroy
  its own boot media by accident, in either scenario. It can still
  overwrite its own configuration if you tell it to, which is exactly
  what makes Scenario B risky and Scenario A fine.)
- **Verify/recover work competes for CPU and disk I/O** with whatever the
  Host is doing at the time - irrelevant on the blank, idle device in
  Scenario A, a real risk to playback smoothness on a device actively
  driving outputs in Scenario B.

Once you know which scenario you're in and the plugin is installed, see
[Your First Recovery Session, End to End](first-recovery-walkthrough.md)
for a full worked example with real log output, or
[How This Plugin Works](how-it-works.md) for a plain step-by-step
reference.

## Not yet in FPP's Plugin Manager search

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
normally shows you - `plugin.php`'s `file=` route only ever serves raw
bytes, it never executes anything, and the same distinction applies here:
the Plugin Manager needs the actual JSON, not a GitHub HTML page).

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
