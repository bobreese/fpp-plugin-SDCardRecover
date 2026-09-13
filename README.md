# SDCard Recover (fpp-plugin-SDCardRecover)

An FPP plugin that reads a second, possibly-damaged FPP SD card attached
over a USB SD-card reader, and helps you recover what's still good from it -
without running any destructive repair unless you explicitly ask for it.

- Reads every file on the card end-to-end before calling anything
  "recoverable" - filesystem metadata and directory listings alone aren't
  trusted.
- fsck is a fallback, not a default: it only runs if the read-only mount
  itself fails, and destructive repair (`fsck -y`) needs its own explicit,
  separately-confirmed action.
- Two recovery modes: filesystem-level read-verification (fast, needs a
  mountable partition) and raw signature-based carving via `photorec`
  (slower, works even when the filesystem won't mount at all).
- Three destinations, your choice: restore directly into this device's own
  media folders (category-selective), copy to a second USB drive, or
  download a zip.
- Config is special-cased: it holds this device's own name, IP, and other
  core settings, so including it requires an explicit "I understand"
  confirmation, and this device's current config/settings/timezone are
  always backed up first, regardless of what was confirmed.
- Every step logs to `media/logs/SDCardRecover.log`, so it shows up
  automatically in FPP's own File Manager -> Logs tab, not just the live
  browser stream.

## Documentation

- [How This Plugin Works](docs/how-it-works.md) - pluginInfo.json schema and FPP page routing, confirmed against live FPP source
- [Directory Layout](docs/directory-layout.md)
- [Installing This Plugin](docs/installing.md) - manual install, since it isn't in FPP's Plugin Manager search yet
- [Privacy Declaration](docs/privacy.md) - what's declared in pluginInfo.json's privacy block, and why
- [Testing & Real-Hardware Findings](docs/testing.md) - every real bug found on real hardware, what's validated, and what still isn't

## License

MIT - see [LICENSE](LICENSE).
