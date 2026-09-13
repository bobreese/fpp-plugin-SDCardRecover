# Installing This Plugin

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

## Suggested repo name

FPP's plugin-manager convention names repos `fpp-plugin-<Name>` (see
`fpp-plugin-Template`) so FPP can recognize and install it - this scaffold
uses `fpp-plugin-SDCardRecover` for that reason, with "SDCard Recover" kept
as the human-facing name in `pluginInfo.json`.
