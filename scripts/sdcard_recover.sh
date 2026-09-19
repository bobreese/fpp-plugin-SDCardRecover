#!/bin/bash
# Step 5: copy recovered data to one or more destinations the user picked.
# Only copies files the manifest marked OK (see sdcard_verify.sh), or files
# produced by sdcard_carve.sh when running off a deep-scan manifest instead.
# Uses rsync (same tool FPP's own Copy Settings / MultiSync pages use) so
# progress streams the same way the rest of FPP's backup UI already does.
source "$(dirname "$0")/common.sh"

DEST_TYPE="$1"   # local | usb | zip
DEST_ARG="$2"    # usb: target device PARTITION (e.g. /dev/sdb1)
                 # local: comma-separated category list (e.g. "config,sequences")
                 # zip: unused

if [ -z "$DEST_TYPE" ]; then
    echo "ERROR: usage: sdcard_recover.sh <local|usb|zip> [dest-arg]" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: no manifest found. Run verification or deep scan first." >&2
    exit 1
fi

# Manifest paths are like "home/fpp/media/config/..." (needed by
# sdcard_verify.sh to locate files on the mounted ROOT filesystem - see its
# own comment on TARGET_DIRS). Copying that structure verbatim means digging
# through SDCardRecover-<ts>/home/fpp/media/config/ to find anything, instead
# of a folder that mirrors what a normal FPP media/ directory actually looks
# like. Re-root the copy at .../home/fpp/media and strip that prefix from
# every listed path, so recovered output lands as SDCardRecover-<ts>/config/,
# .../sequences/, etc. directly.
SRC_ROOT="$MOUNTPOINT/home/fpp/media"
FILELIST=$(mktemp)
awk -F'\t' '$3=="OK"{print $1}' "$MANIFEST" | sed 's#^home/fpp/media/##' > "$FILELIST"
COUNT=$(wc -l < "$FILELIST")

if [ "$COUNT" -eq 0 ]; then
    log "Nothing marked OK in the manifest - nothing to recover."
    rm -f "$FILELIST"
    exit 1
fi

case "$DEST_TYPE" in
    local)
        # Restores directly into this FPP's OWN real media directories
        # (/home/fpp/media/<category>/...), not a side "Recovered/" staging
        # folder - the user picks which categories to bring in, and only
        # those. Config is special-cased: it holds this device's own
        # identity (name, IP if statically set, plugin settings, channel
        # outputs, everything under Settings), so restoring it overwrites
        # THIS device's own configuration with the damaged card's. The UI
        # is expected to have already made the user explicitly confirm that
        # - this script's job is to make it survivable if they didn't mean
        # to: back up the current config before touching it, unconditionally.
        IFS=',' read -ra REQUESTED_CATS <<< "$DEST_ARG"
        CATS=()
        for c in "${REQUESTED_CATS[@]}"; do
            if [[ "$c" =~ $CATEGORY_RE ]]; then
                CATS+=("$c")
            elif [ -n "$c" ]; then
                log "Ignoring unrecognized category '$c'"
            fi
        done
        if [ ${#CATS[@]} -eq 0 ]; then
            echo "ERROR: no valid category selected for local restore." >&2
            rm -f "$FILELIST"
            exit 1
        fi

        CAT_FILELIST=$(mktemp)
        : > "$CAT_FILELIST"
        for c in "${CATS[@]}"; do
            grep -E "^${c}/" "$FILELIST" >> "$CAT_FILELIST" || true
        done

        RESTORING_CONFIG=0
        for c in "${CATS[@]}"; do
            [ "$c" = "config" ] && RESTORING_CONFIG=1
        done
        # FPP's actual device identity (HostName, network config, everything
        # $settings[] holds) lives in the flat /home/fpp/media/settings file,
        # a sibling of media/config/, not a "config/..." path itself - so it
        # never matches the category grep above. Bundled under the config
        # category since that's conceptually what it is; without this,
        # restoring "config" changes plugin/model JSON but leaves the
        # device's actual name/network settings untouched, which is exactly
        # what happened the first time this ran.
        if [ "$RESTORING_CONFIG" -eq 1 ]; then
            grep -x 'settings' "$FILELIST" >> "$CAT_FILELIST" || true
            grep -x 'timezone' "$FILELIST" >> "$CAT_FILELIST" || true
        fi

        CAT_COUNT=$(wc -l < "$CAT_FILELIST")
        if [ "$CAT_COUNT" -eq 0 ]; then
            log "No recoverable files found in the selected categories (${CATS[*]})."
            rm -f "$FILELIST" "$CAT_FILELIST"
            exit 1
        fi

        if [ "$RESTORING_CONFIG" -eq 1 ]; then
            log "WARNING: config is being restored - this overwrites THIS device's own name, IP (if static), plugin settings, and other core configuration."
            if [ -d /home/fpp/media/config ]; then
                CONFIG_BACKUP="/home/fpp/media/config.before-recover-$(date +%Y%m%d-%H%M%S)"
                log "Backing up this device's CURRENT config to $CONFIG_BACKUP first, in case this wasn't intended."
                cp -a /home/fpp/media/config "$CONFIG_BACKUP"
            fi
            if [ -f /home/fpp/media/settings ]; then
                SETTINGS_BACKUP="/home/fpp/media/settings.before-recover-$(date +%Y%m%d-%H%M%S)"
                log "Backing up this device's CURRENT settings file to $SETTINGS_BACKUP first."
                cp -a /home/fpp/media/settings "$SETTINGS_BACKUP"
            fi
            if [ -f /home/fpp/media/timezone ]; then
                TIMEZONE_BACKUP="/home/fpp/media/timezone.before-recover-$(date +%Y%m%d-%H%M%S)"
                cp -a /home/fpp/media/timezone "$TIMEZONE_BACKUP"
            fi
        fi

        log "Restoring $CAT_COUNT file(s) directly into /home/fpp/media/ (categories: ${CATS[*]})"
        rsync -avh --progress --files-from="$CAT_FILELIST" "$SRC_ROOT/" "/home/fpp/media/"
        RC=$?
        rm -f "$CAT_FILELIST"

        if [ "$RC" -eq 0 ]; then
            log "Done. Restored into /home/fpp/media/ (categories: ${CATS[*]})"
            if [ "$RESTORING_CONFIG" -eq 1 ]; then
                # fppd keeps settings in memory and can patch individual keys
                # back into this same file while it's still running (see
                # docs/testing.md) - setting restartFlag is FPP's own signal
                # for "something changed on disk, restart before trusting
                # what's loaded," surfaced as a banner across the whole web
                # UI rather than only this plugin's own log. Uses FPP's own
                # shell setSetting() (sourced via common.sh's scripts/common),
                # not a hand-rolled sed, so it's the same locked, canonical
                # write every other FPP script/plugin uses for this.
                setSetting restartFlag 1
                log "Config was overwritten - restart FPPD (or reboot) for the new settings (including HostName/network) to take effect."
                [ -n "$CONFIG_BACKUP" ] && log "  Previous config saved to $CONFIG_BACKUP"
                [ -n "$SETTINGS_BACKUP" ] && log "  Previous settings file saved to $SETTINGS_BACKUP"
                [ -n "$TIMEZONE_BACKUP" ] && log "  Previous timezone file saved to $TIMEZONE_BACKUP"
            fi
        else
            log "FAILED (rsync exit $RC). /home/fpp/media/ may be partially updated."
        fi
        ;;
    usb)
        # DEST_ARG is a raw partition device (e.g. /dev/sdb1), not a
        # mountpoint: unlike a desktop, FPP has no automount daemon, so a
        # freshly-inserted destination USB stick is never already mounted
        # anywhere. We have to mount it ourselves, read-write, into its own
        # dedicated mountpoint - separate from $MOUNTPOINT, which stays the
        # read-only SOURCE card being recovered FROM.
        DEST_PART=$(validate_device "$DEST_ARG")
        guard_not_root_device "$DEST_PART"

        if mountpoint -q "$MOUNTPOINT"; then
            CURRENT_SRC=$(findmnt -n -o SOURCE "$MOUNTPOINT")
            if [ "$CURRENT_SRC" = "$DEST_PART" ]; then
                echo "ERROR: destination $DEST_PART is the same partition currently mounted as the source card at $MOUNTPOINT. Refusing to write into the read-only source." >&2
                rm -f "$FILELIST"
                exit 1
            fi
        fi

        mkdir -p "$DEST_MOUNTPOINT"
        if mountpoint -q "$DEST_MOUNTPOINT"; then
            umount "$DEST_MOUNTPOINT" 2>/dev/null
        fi
        log "Mounting destination $DEST_PART read-write at $DEST_MOUNTPOINT..."
        mount "$DEST_PART" "$DEST_MOUNTPOINT"
        if ! mountpoint -q "$DEST_MOUNTPOINT"; then
            echo "ERROR: failed to mount destination $DEST_PART (unformatted, or an unsupported filesystem?)" >&2
            rm -f "$FILELIST"
            exit 1
        fi

        DEST="$DEST_MOUNTPOINT/SDCardRecover-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$DEST"
        log "Recovering $COUNT file(s) to USB drive: $DEST"

        # -a bundles owner/group/permission/symlink preservation, none of
        # which FAT/exFAT/NTFS - the near-universal format for a plain USB
        # flash drive - actually support. rsync doesn't fail the whole
        # transfer over that, but does exit 23 ("partial transfer due to
        # error") even when every file's actual DATA copied fine, which
        # reads as a hard failure when it mostly wasn't one. Drop the
        # metadata-preservation flags on filesystems that can't honor them.
        DEST_FSTYPE=$(lsblk -no FSTYPE "$DEST_PART")
        case "$DEST_FSTYPE" in
            vfat|exfat|ntfs)
                RSYNC_FLAGS="-rth"
                ;;
            *)
                RSYNC_FLAGS="-avh"
                ;;
        esac
        rsync $RSYNC_FLAGS --progress --files-from="$FILELIST" "$SRC_ROOT/" "$DEST/"
        RC=$?

        sync
        umount "$DEST_MOUNTPOINT"
        if [ "$RC" -eq 0 ]; then
            log "Done. Files were written to $DEST_PART under SDCardRecover-*/ - drive safely unmounted, OK to remove."
        else
            log "FAILED (rsync exit $RC). Drive unmounted; files under $DEST_PART may be incomplete."
        fi
        ;;
    zip)
        ensure_state_dir
        ZIPNAME="SDCardRecover-$(date +%Y%m%d-%H%M%S).zip"
        ZIPPATH="$STATE_DIR/$ZIPNAME"
        log "Packaging $COUNT file(s) into $ZIPNAME for download..."
        (cd "$SRC_ROOT" && zip -q "$ZIPPATH" -@ < "$FILELIST")
        RC=$?
        if [ "$RC" -eq 0 ]; then
            log "Done. Zip ready: $ZIPPATH"
            echo "ZIPPATH:$ZIPPATH"
        else
            log "FAILED (zip exit $RC)."
        fi
        ;;
    *)
        echo "ERROR: unknown destination type '$DEST_TYPE'" >&2
        rm -f "$FILELIST"
        exit 1
        ;;
esac

rm -f "$FILELIST"
exit ${RC:-0}
