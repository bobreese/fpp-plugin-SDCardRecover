#!/bin/bash
# Deletes one named artifact (an old recovery zip, or a deep-scan output
# directory - including a stray carved.N sibling left behind by a
# pre-fix run) from this plugin's own scratch state ($STATE_DIR), on
# explicit user request from the UI's "Recovery Artifacts" section.
#
# Found from a real user question: nothing in this plugin ever deleted
# these on its own (deliberately - see the UI text this section pairs
# with: there is no reliable signal that a download actually finished,
# so auto-deleting risks losing data that was never really saved
# anywhere else), but that left old zips and carved output piling up
# with no way to clean them up short of SSH, since FPP's own File
# Manager can't browse into this plugin's state directory at all (see
# docs/testing.md). This script is the explicit, user-confirmed cleanup
# action - run as root (via sudo, like every other script here)
# specifically because sdcard_carve.sh's own output directories are
# root-owned (photorec creates them): a plain PHP unlink()/rmdir()
# running as the fpp user can list and read them but cannot delete their
# contents.
source "$(dirname "$0")/common.sh"

NAME="$1"
if [ -z "$NAME" ]; then
    echo "ERROR: usage: sdcard_delete_artifact.sh <name>" >&2
    exit 1
fi

# Same allowlist as scripts_dispatch.php's own validation - defense in
# depth, not the only check. Deliberately strict (anchored, no wildcards,
# no path separators): this can only ever match exactly one of this
# plugin's own two known artifact shapes, never an arbitrary path.
if ! [[ "$NAME" =~ ^(SDCardRecover-[0-9]{8}-[0-9]{6}\.zip|carved(\.[0-9]+)?)$ ]]; then
    echo "ERROR: refusing to delete unrecognized artifact name '$NAME'" >&2
    exit 1
fi

TARGET="$STATE_DIR/$NAME"
if [ ! -e "$TARGET" ]; then
    echo "ERROR: $TARGET does not exist." >&2
    exit 1
fi

log "Deleting artifact $NAME ($TARGET) on user request..."
rm -rf "$TARGET"
log "Deleted $NAME."
exit 0
