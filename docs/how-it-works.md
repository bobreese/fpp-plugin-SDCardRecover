# How SDCard Recover Works

What actually happens as you go through the wizard, step by step. Want to
see this played out with real log output instead of a plain reference?
See [Your First Recovery Session, End to End](first-recovery-walkthrough.md).

1. **Attach the second card.** Plug the possibly-damaged FPP SD card into
   this device over a USB SD-card reader.
2. **Scan (Step 1).** Click **Scan** to list removable USB block devices -
   the card should show up as soon as it's detected. Not seeing it? Click
   **Rescan**, or reseat the card/reader; the page shows a "Reattach USB SD
   Card" prompt next to the Scan/Rescan buttons whenever nothing is found.
3. **Mount & verify readability (Step 2).** Click **Mount read-only** to
   mount the card's media partition read-only as `DamagedSD` (Step 3 just
   shows the resulting mount state). Once mounted, every config/media file
   on it is read end-to-end to confirm it's actually readable - a bad
   sector shows up as a real read error here, not a guess based on
   filesystem metadata.
   - **If the mount itself fails**, a non-destructive check
     (`fsck -n`, read-only, changes nothing) is offered. If that finds real
     filesystem problems, a separate, explicitly-confirmed **repair**
     (`fsck -y`) is offered - this one **writes to the card and cannot be
     undone**, so it's never run automatically. See
     [Testing & Real-Hardware Findings](testing.md#the-fsck-fallback-ui-could-never-actually-appear-real-bug-real-corruption-test)
     for how this fallback chain was validated on a genuinely corrupted
     card.
   - **Optional deep scan**: offered after a successful mount, if
     verification found files the filesystem can no longer locate - not
     currently offered from the failed-mount fallback above, despite the
     underlying tool not actually needing a working filesystem (see
     [Testing & Real-Hardware Findings](testing.md#deep-scan-carving-doesnt-do-what-the-docs-claimed-found-in-fpp-data-review)
     for the exact gap). A raw signature-based scan (`photorec`) searches
     the card directly for recognizable file data, independent of the
     filesystem's health - but only for formats it has a known signature
     for: photos, video, and audio, not **FSEQ sequence files or JSON
     config files**, since neither has fixed magic bytes a generic
     carving tool can recognize (see
     [Testing & Real-Hardware Findings](testing.md#photorecs-fileopt-extension-list-silently-disabled-every-real-file-type-real-bug-real-hardware)
     for how this was confirmed against photorec's own source, and why
     it's a real, permanent limitation rather than a configuration
     mistake). Slower, and recovered files come back with generic names
     since there's no directory structure left to recover them from. Its
     output isn't wired into Step 5 below yet either - retrieve it
     manually (over SSH or FPP's File Manager) from
     `config/plugin.SDCardRecover/carved/` before
     uninstalling. If you don't, uninstall moves any undownloaded output to
     `media/upload/` instead of deleting it, so it's still recoverable from
     FPP's File Manager -> Uploads tab afterward - but grabbing it before
     uninstalling avoids the extra step.
4. **Evaluate (Step 4).** Click **Evaluate** to compare how much data was
   found recoverable against free space on this device's own local storage,
   before committing to anything.
5. **Recover (Step 5).** Pick up to 2 destinations (a hint above the
   checkboxes says so; a third grays out once 2 are picked):
   - **Restore directly into this device's own media folders** -
     category-selective: only the categories you check are touched, and
     only files already confirmed readable in Step 2. Including **Config**
     needs its own explicit confirmation, since it overwrites this device's
     own name, network settings, and other core configuration - see the
     in-app warning for the full rollback procedure, and
     [Privacy Declaration](privacy.md) for what else that can carry along
     with it (this device's saved WiFi password, and FPP's Initial Setup
     wizard reappearing once after a reboot). Including **Plugins** needs
     the same explicit confirmation - it copies raw plugin files onto this
     device without running that plugin's own install step or ever showing
     you FPP's normal install/privacy screen for it, so only do this with
     plugins from a card you already trust (see
     [Testing & Real-Hardware Findings](testing.md) for exactly what that
     does and doesn't do).
   - **A second attached USB drive** - it must already have a filesystem on
     it; this won't format one for you.
   - **A zip file**, downloaded straight to your computer.

   Click **Recover** once you've made your choices. If both are picked,
   they run in a fixed order, not the order you checked them in: **zip
   first** (with a "Zip ready" info box - click OK to continue once you've
   used the Download button, or before, since the file's already there
   either way), **then local last** if it's the other one chosen, since
   that's this device's own media/config being overwritten, not a copy
   going somewhere else. USB runs in between either way. Every step along
   the way is also written to
   `media/logs/plugin-fpp-plugin-SDCardRecover.log`, viewable and
   downloadable from FPP's own File Manager -> Logs tab, not just the live
   log panel on this page.

## Recovery Artifacts

A section below Step 5, not part of the numbered wizard flow and always
available regardless of where you are in it. Lists old recovery zips and
deep-scan (carved) output sitting in this plugin's own scratch state
(`config/plugin.SDCardRecover/`), with a **Delete** button for each.

Nothing here is ever deleted automatically - there is no reliable way for
the plugin to know a browser download actually finished (especially for a
large zip over WiFi), so auto-deleting risks losing something you never
actually got a copy of anywhere else. This is the deliberate alternative:
an explicit, one-click-plus-confirm cleanup action, since FPP's own File
Manager can't browse into this folder to do it for you (see
[Testing & Real-Hardware Findings](testing.md) for why). Only delete
something once you're sure you already have what you need from it.
