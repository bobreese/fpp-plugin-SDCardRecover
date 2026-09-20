#!/bin/bash
# Deep-scan fallback: raw signature-based carving, offered by the UI after a
# successful mount when sdcard_verify.sh found files the filesystem can no
# longer locate. Works directly against the block device, independent of the
# filesystem's health - so it could in principle also cover the "won't mount
# at all" case, but the UI (status.php/js/sdcard-recover.js) doesn't currently
# offer that path there; see docs/testing.md for the gap. Scoped to file types
# FPP actually uses so the user isn't handed thousands of irrelevant carved
# fragments. Output has no manifest and isn't wired into sdcard_recover.sh -
# retrieve it manually from $OUTDIR.
#
# Requires testdisk/photorec (photorec is testdisk's CLI recovery binary).
source "$(dirname "$0")/common.sh"

DEV="$1"
OUTDIR="$2"
if [ -z "$DEV" ] || [ -z "$OUTDIR" ]; then
    echo "ERROR: usage: sdcard_carve.sh <device> <output-dir>" >&2
    exit 1
fi

DEV=$(validate_device "$DEV") || exit 1
guard_not_root_device "$DEV"

if ! command -v photorec >/dev/null 2>&1; then
    echo "ERROR: photorec not found. Install the 'testdisk' package." >&2
    exit 1
fi

mkdir -p "$OUTDIR"
log "Starting deep scan (raw carving) of $DEV -> $OUTDIR"
log "This does not require a working filesystem and can take a long time"
log "depending on card size; progress below is photorec's own log output."

# photorec's scripted/non-interactive mode: targets specific extensions
# rather than "everything", to keep the output relevant and the scan
# faster than a full recover-every-file-type pass.
#
# Found on real hardware, confirmed against photorec's own source
# (src/phcli.c's file_select_cli(), and the actual extensions each
# src/file_*.c module registers): "fseq" and "json" were never real
# photorec-recognized extensions - FPP's own sequence format has no
# public signature any generic carving tool would know, and neither does
# plain JSON (no fixed magic bytes to key off of). That is not merely
# "those two types get skipped" - file_select_cli() stops consuming the
# fileopt command list the moment it hits a token it does not recognize,
# so "fseq" (listed first, right after "everything,disable") silently
# aborted the ENTIRE rest of the list. Nothing after it - not even the
# genuinely valid mp3/mp4/jpg/png entries - ever actually got enabled.
# Confirmed live: a scan configured this way completed in under a second
# with 0 candidates found and no photorec.log ever written, on a card
# with real, intact file data still present - the unmistakable signature
# of a rejected command string, not a real "found nothing" scan.
#
# "wav" and "avi" were ALSO never their own extensions - both are RIFF
# containers, handled under photorec's single "riff" hint (confirmed via
# src/file_riff.c: "RIFF audio/video: wav, cdr, avi"). "mp4" is likewise
# folded into the "mov" hint (src/file_mov.c: "mov/mp4/3gp/3g2/jp2") -
# carved MP4s come back named with a .mov extension regardless, since
# photorec has no way to tell them apart from the container format alone.
#
# Net effect: FSEQ sequence files and JSON config files - arguably the
# two things most worth deep-scanning an FPP card FOR - cannot be
# recovered by this or any other generic signature-based carving tool.
# There is no fileopt syntax that fixes that; it is a real, permanent
# limitation of the whole approach, not a configuration mistake. See
# docs/testing.md and docs/how-it-works.md for this spelled out for an
# operator, not just a future maintainer of this script.
# "255," selects the "Whole disk" pseudo-partition before the fileopt/
# search commands run - found on real hardware, confirmed against
# photorec's own source, and just as serious as the fileopt bug above.
# Without it, photorec's own CLI init (src/phcli.c:
# `params->partition=(list_part->next!=NULL ? list_part->next->part :
# list_part->part);`) silently defaults to the FIRST REAL partition on
# the disk - confirmed live: photorec's own on-screen partition table
# showed it scanning "1 P FAT32 LBA ... [boot]", the small boot
# partition, never the actual ext4 media partition where real
# recoverable files would be. `src/photorec.c`'s `init_list_part()`
# inserts a synthetic "Whole disk" partition (offset 0, spanning the
# entire disk) ahead of the real ones in the sorted list specifically so
# it CAN be selected - but the CLI's own default selection logic skips
# straight past it to the first real partition whenever one exists.
# That synthetic partition's `->order` field is left at its default,
# `NO_ORDER` (`src/common.h`: `#define NO_ORDER 255` - confirmed never
# reassigned by `new_whole_disk()` or anything after it), and
# `src/phcli.c`'s own digit-handling command (`else if(isdigit(...))`)
# selects a partition by matching exactly this field - so "255" as the
# first command explicitly overrides the wrong default and searches the
# entire disk, ignoring partition boundaries, which is the actually
# correct behavior for recovering from a card whose filesystem may be
# damaged or unmountable in the first place.
log "Deep scan will search the whole disk ($DEV), not just its first partition - see this script's own comments for why that distinction needed an explicit fix."

# Run inside $OUTDIR so photorec's own /log output (photorec.log) lands
# there too, next to the carved files - confirmed against the real
# photorec.8 man page ("/log: create a photorec.log file") that it writes
# relative to the process's current directory, not /d's destination.
# Found from a real user report: without this, /log silently wrote
# nowhere near $OUTDIR, leaving an empty output directory with no trace
# of photorec's own run even existing.
(
    cd "$OUTDIR" || exit 1
    photorec /log /d "$OUTDIR" /cmd "$DEV" \
        255,fileopt,everything,disable,mp3,enable,riff,enable,mov,enable,jpg,enable,png,enable,search
)

RC=$?
# Excludes photorec.log itself now that it lands inside $OUTDIR too (see
# above) - otherwise it would count as its own "candidate file carved".
FOUND=$(find "$OUTDIR" -type f -not -name 'photorec.log' | wc -l)
log "Deep scan complete (exit $RC). $FOUND candidate file(s) carved to $OUTDIR."
if [ -f "$OUTDIR/photorec.log" ]; then
    log "photorec's own detailed log is at $OUTDIR/photorec.log."
fi
log "Carved files have generic names (photorec cannot recover original paths);"
log "review them before moving into your show's media folders."
exit $RC
