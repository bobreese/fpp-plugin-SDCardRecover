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
   - **Optional deep scan**: if the filesystem still won't mount, or
     verification found files the filesystem can no longer locate, a raw
     signature-based scan (`photorec`) can search the card directly for
     recognizable file data, independent of the filesystem's health. Slower,
     and recovered files come back with generic names since there's no
     directory structure left to recover them from - see
     [Architecture](architecture.md) for how this is scoped to FPP's own
     file types.
4. **Evaluate (Step 4).** Click **Evaluate** to compare how much data was
   found recoverable against free space on this device's own local storage,
   before committing to anything.
5. **Recover (Step 5).** Pick one or more destinations:
   - **Restore directly into this device's own media folders** -
     category-selective: only the categories you check are touched, and
     only files already confirmed readable in Step 2. Including **Config**
     needs its own explicit confirmation, since it overwrites this device's
     own name, network settings, and other core configuration - see the
     in-app warning for the full rollback procedure, and
     [Privacy Declaration](privacy.md) for what else that can carry along
     with it (this device's saved WiFi password, and FPP's Initial Setup
     wizard reappearing once after a reboot).
   - **A second attached USB drive** - it must already have a filesystem on
     it; this won't format one for you.
   - **A zip file**, downloaded straight to your computer.

   Click **Recover** once you've made your choices. Every step along the
   way is also written to
   `media/logs/plugin-fpp-plugin-SDCardRecover.log`, viewable and
   downloadable from FPP's own File Manager -> Logs tab, not just the live
   log panel on this page.
