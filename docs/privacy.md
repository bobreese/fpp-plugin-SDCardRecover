# Privacy Declaration

`pluginInfo.json`'s `privacy` block is what FPP builds the six-light install
dialog from (Sends data, Collects data, Camera & mic, Remote access, System
changes, Can it be checked?), and what an eventual `fpp-data` listing review
greps the code against. It was built using FPP's own
[Privacy declaration builder](https://falconchristmas.github.io/fpp-data/plugin_privacy_builder/)
and cross-checked field by field against `PLUGININFO_FORMAT.md` rather than
guessed at - this doc records what's declared and, more importantly, *why*,
so a future change to this plugin (or a listing reviewer's question) doesn't
have to re-derive the reasoning from scratch.

## What's declared, and why

- **`sends: []`, `collects: []`, `sensors: []`, `remoteAccess: "none"`** -
  this plugin makes no network connections of its own, keeps nothing about
  anyone beyond the operator's own device settings, has no camera/mic
  involvement, and every route it serves goes through FPP's own web server
  (`plugin.php?plugin=...&page=...`) rather than opening a listener of its
  own.
- **`closedCode: false`** - everything that runs is either this plugin's own
  visible source or standard open Debian packages (`e2fsprogs`,
  `dosfstools`, `exfatprogs`, `testdisk`, `zip`, `rsync`).
- **`systemChanges`** - six entries, each mapped to the closest fit in
  FPP's fixed vocabulary (`service`, `network`, `core-settings`, `download`,
  `package-source`, `tunnel`, `reads-core-credentials`, `privilege`):
  - Three `service` entries for the two mount points this plugin owns
    (`/mnt/DamagedSD` read-only, `/mnt/SDCardRecoverDest` read-write) and
    the `fsck -y` repair action.
  - One `core-settings` entry for Config restore overwriting this device's
    own name/network/configuration.
  - One `download` entry for the untracked `apt-get install` in
    `fpp_install.sh` (see [Not declared: `privilege`](#not-declared-privilege)
    below for why these specific packages are installed that way).
  - One `core-settings` entry for `fpp_uninstall.sh` moving an undownloaded
    recovery zip to `media/upload/` instead of deleting it - technically a
    write outside the plugin's own directory, even though it's minor and
    self-generated.
- **`other`** - two things the structured fields above can't say cleanly:
  that a Config export (zip or USB) can carry this device's saved WiFi
  password and other secrets stored in its settings file, and that
  restoring Config from a different physical device will make FPP's own
  Initial Setup wizard run once more (see
  [testing.md](testing.md#initial-setup-reappears-after-a-cross-device-config-restore-expected-not-a-bug)) -
  FPP's behavior, not this plugin's, but worth a neighbour knowing.

## Judgment calls worth knowing about

### Not declared: `privilege`

Every action runs via `sudo` (`scripts_dispatch.php`'s `sdcr_passthru()`),
but the plugin never adds a sudoers rule, group membership, or key of its
own - it only exercises the passwordless sudo FPP's stock images already
grant every plugin, which FPP already discloses generically ("this plugin
is untrusted third-party code that will run on your FPP as root") on every
community install. The `privilege` kind is for a plugin that *grants* new
privilege beyond that baseline; this one doesn't, so it stays undeclared.
Worth revisiting if the plugin ever ships its own sudoers entry (see
`docs/testing.md`'s "Sudo/permissions" not-yet-validated item).

### The `fsck -y` repair doesn't cleanly fit any `systemChanges` kind

It's the single most destructive action this plugin can take (rewrites the
inserted card's filesystem structure, explicitly "not reversible"), but none
of the eight fixed kinds names "runs filesystem repair on a user-inserted
external device" precisely. It's folded into a `service` entry - the
closest fit, since it operates on the same mounted removable device the
other `service` entries describe - with the `what` text spelling out the
irreversibility plainly, per the builder's own guidance to pick the closest
kind for the color and describe the real behavior in the text.

### Why `e2fsprogs`/`dosfstools`/`exfatprogs`/`rsync`/`zip` are a `download` entry, not `dependencies.packages`

These are installed by hand in `fpp_install.sh`, deliberately outside
`pluginInfo.json`'s tracked `dependencies.packages` mechanism - a decision
that came directly out of three real-hardware incidents
(see `docs/testing.md`) where FPP's reference-counted removal of a
tracked package took down `raspi-firmware` on one device, broke a
completely different plugin's (`fpp-plugin-RemoteBackup`) ability to back up
this one on another, and removed `zip` from a box where FPP core itself
uses it (`www/fppEEPROM.php`) regardless of whether this plugin is
installed. Packages declared in `dependencies.packages` are
explicitly exempt from needing their own `download` systemChanges entry per
`PLUGININFO_FORMAT.md` - but a package installed by a plugin's own script,
outside that mechanism, doesn't get that exemption, so it's declared here
instead. This is the same pattern `fpp-plugin-RemoteBackup`'s own privacy
block already uses for its own by-hand package installs.

## Verified against

- FPP's [Privacy declaration builder](https://falconchristmas.github.io/fpp-data/plugin_privacy_builder/),
  loaded directly from this repo.
- `PLUGININFO_FORMAT.md`'s `privacy` section, fetched from
  `fpp-plugin-Template` rather than relied on the builder's own summarized
  copy.
- `fpp-plugin-RemoteBackup`'s own `pluginInfo.json`, for the `download`-kind
  precedent for by-hand package installs.
