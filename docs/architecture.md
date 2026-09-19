# How This Plugin Is Built

Notes on the FPP plumbing this plugin relies on, confirmed against FPP's
own real source rather than guessed at - useful if you're maintaining this
plugin or building another one against the same conventions.

## Progress UI

Reuses FPP's actual streaming mechanism (`StreamURL()` in `www/js/fpp.js` -
a long-poll `xhr.onprogress` diff, not WebSocket/SSE) the same way Copy
Settings and the Remote Backups page do. Note: FPP's real backup pages
don't show a numeric percentage - what looks like "progress" there is the
live log text. This plugin's progress bars are indeterminate ("working..."
animation) while a step streams, turning solid on completion, since
there's no byte-accurate source to compute a true percentage from
fsck/rsync/photorec output.

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
  which `include_once`s it into the same request - `stream.php`, `ajax.php`,
  and the JS that calls them were rewritten around this.
- **`js`/`css` assets need no manual `<link>`/`<script>` tags at all** -
  `plugin.php` auto-scans the plugin's `js/` and `css/` directories and
  injects a tag per file it finds, each pointing at
  `plugin.php?plugin=<repo>&file=js/<name>&nopage=1`. `status.php`'s manual
  tags (via the nonexistent `pluginBaseURL()`) were redundant on top of being
  broken.
- **A file literally named `api.php` is not just "a different mechanism
  that doesn't apply here" - it gets swept into a real one whether you want
  it to or not.** An earlier version of this doc's own reasoning was wrong
  about this: it correctly ruled out fppd's C++ `/plugin-apis/<name>` API
  (proxied to fppd on :32322, requiring backend registration this plugin
  doesn't have - confirmed via `fpp-LoRa`'s `fetch('api/plugin-apis/LoRa')`)
  but wrongly treated that as the only alternative mechanism, and concluded
  a plain `?page=api.php&nopage=1&endpoint=...` dispatcher was therefore
  safe. It isn't: `www/api/index.php` calls `addPluginEndpoints()` ->
  `collectPluginEndpoints()` (`controllers/plugin.php`) on **every**
  `/api/*` request, for every plugin, unconditionally - scanning every
  installed plugin's directory and `require_once`-ing any file it finds
  literally named `api.php`, looking for a `getEndpoints<repoName>()`
  registrar (a real, PHP-only mechanism, distinct from the C++ one). A file
  with that name gets included this way regardless of whether it was ever
  written to be a registrar. This plugin's endpoints file is deliberately
  named `ajax.php` instead, specifically to stay out of that scan - see
  [Testing & Real-Hardware Findings](testing.md) for the real bug this
  caused before the rename.
- **`stream.php`'s `require_once` path was wrong.** It used
  `dirname(__FILE__) . '/../../common.php'`, which resolves two directories
  above the plugin - outside it entirely - and would fatal. Since this file
  is only ever `include_once`'d by `plugin.php` (never requested directly),
  the fix is the same bare `require_once "common.php";` `plugin.php` itself
  uses, which PHP resolves against FPP's www root as the request's top-level
  script.

## Developing from Windows: watch the executable bit

This repo's git config has `core.filemode=false` (Windows/NTFS default), so
a plain `chmod +x` on a new script is silently ignored by git and it gets
committed as `100644` - it'll clone fine but `sudo`/exec on Linux fails
with "command not found". This bit every script the first time
(`sdcard_scan.sh` and friends all had to be fixed after the fact). Force it
explicitly per file instead: `git update-index --chmod=+x path/to/script.sh`.
