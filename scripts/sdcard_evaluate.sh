#!/bin/bash
# Step 4: compare free space on this FPP's own storage against how much
# recoverable data was actually found, so the UI can warn before the user
# picks "Local FPP storage" as a destination that can't fit it.
source "$(dirname "$0")/common.sh"

LOCAL_MEDIA="/home/fpp/media"

if [ ! -f "$MANIFEST" ]; then
    log "ERROR: no manifest found. Run verification or deep scan first."
    exit 1
fi

RECOVERABLE_BYTES=$(awk -F'\t' '$3=="OK"{sum+=$2} END{print sum+0}' "$MANIFEST")
RECOVERABLE_FILES=$(awk -F'\t' '$3=="OK"{c++} END{print c+0}' "$MANIFEST")
UNREADABLE_FILES=$(awk -F'\t' '$3=="UNREADABLE"{c++} END{print c+0}' "$MANIFEST")

LOCAL_FREE_BYTES=$(df --output=avail -B1 "$LOCAL_MEDIA" | tail -1 | tr -d ' ')

log "Recoverable data found: $RECOVERABLE_FILES file(s), $RECOVERABLE_BYTES bytes"
log "Unreadable (skipped): $UNREADABLE_FILES file(s)"
log "Free space on this FPP's local storage ($LOCAL_MEDIA): $LOCAL_FREE_BYTES bytes"

# Found from a real user question: if a destination USB drive is already
# plugged in when Evaluate is clicked, show its actual free space here too,
# not just local storage - saves a trip to Step 5 just to discover it won't
# fit. An unmounted partition's free space isn't knowable generically across
# vfat/exfat/ntfs/ext4 any other way, so each real candidate gets a brief
# read-only mount at EVAL_MOUNTPOINT, one `df`, then an immediate unmount -
# never DEST_MOUNTPOINT (that's Step 5's own read-write destination mount,
# kept separate so an evaluate/recover pair in the same session never
# contends over the same mountpoint path).
#
# Candidate detection mirrors sdcard_scan.sh's own filter exactly (skip
# root device, FPP's own media device, anything with a mounted partition
# already), plus one more exclusion scan.sh doesn't need: the source card's
# own disk, so this never touches the card actually being recovered.
ROOT_DEV=$(root_device)
MEDIA_DEV=$(media_device)
SRC_DISK=$(source_device)
USB_CANDIDATES=$(lsblk -J -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,RM,MODEL,TRAN 2>/dev/null | \
php -r '
$data = json_decode(file_get_contents("php://stdin"), true);
$rootDev = $argv[1];
$mediaDev = $argv[2];
$srcDisk = $argv[3];
function walk($devices, $rootDev, $mediaDev, $srcDisk) {
    foreach ($devices as $d) {
        $isRemovable = (isset($d["rm"]) && $d["rm"]) || (isset($d["tran"]) && $d["tran"] === "usb");
        $isRoot = (strpos($rootDev, $d["name"]) !== false);
        $isMedia = ($mediaDev !== "" && strpos($mediaDev, $d["name"]) !== false);
        $isSource = ($srcDisk !== "" && strpos($srcDisk, $d["name"]) !== false);
        $hasMountedChild = false;
        foreach ($d["children"] ?? [] as $c) {
            if (!empty($c["mountpoint"])) { $hasMountedChild = true; break; }
        }
        $inUse = $isRoot || $isMedia || $isSource || $hasMountedChild || !empty($d["mountpoint"]);
        $hasMedia = isset($d["size"]) && $d["size"] > 0;
        if ($d["type"] !== "disk" || !$isRemovable || $inUse || !$hasMedia) {
            continue;
        }
        $model = $d["model"] ?? "Unknown";
        if (!empty($d["children"])) {
            foreach ($d["children"] as $c) {
                if (!empty($c["fstype"]) && empty($c["mountpoint"])) {
                    echo "/dev/" . $c["name"] . "\t" . $model . "\n";
                }
            }
        } elseif (!empty($d["fstype"]) && empty($d["mountpoint"])) {
            // Superfloppy media - filesystem directly on the whole disk,
            // no partition table (see sdcard_scan.sh for the same case).
            echo "/dev/" . $d["name"] . "\t" . $model . "\n";
        }
    }
}
walk($data["blockdevices"] ?? [], $rootDev, $mediaDev, $srcDisk);
' "$ROOT_DEV" "$MEDIA_DEV" "$SRC_DISK")

USB_RESULTS=""
if [ -n "$USB_CANDIDATES" ]; then
    while IFS=$'\t' read -r CAND_DEV CAND_MODEL; do
        [ -z "$CAND_DEV" ] && continue
        CAND_PART=$(validate_device "$CAND_DEV") || continue
        # Defense in depth, not the only check - candidates here already
        # came from the same root/media/source exclusion filter
        # sdcard_scan.sh uses, so this should never actually trip. Run in
        # a subshell specifically so it CAN'T: guard_not_root_device exits
        # the whole process on a violation by design (correct everywhere
        # else it's used, right before a write), but this loop may still
        # have other, unrelated candidates worth checking after this one -
        # one candidate tripping a redundant safety check shouldn't cost
        # the user the local-storage numbers this script already computed.
        ( guard_not_root_device "$CAND_PART" ) || continue
        mkdir -p "$EVAL_MOUNTPOINT"
        if mountpoint -q "$EVAL_MOUNTPOINT"; then
            umount "$EVAL_MOUNTPOINT" 2>/dev/null
        fi
        if mount -o ro "$CAND_PART" "$EVAL_MOUNTPOINT" 2>/dev/null; then
            CAND_FREE=$(df --output=avail -B1 "$EVAL_MOUNTPOINT" | tail -1 | tr -d ' ')
            umount "$EVAL_MOUNTPOINT"
            log "Free space on $CAND_PART ($CAND_MODEL): $CAND_FREE bytes"
            USB_RESULTS="${USB_RESULTS}${CAND_PART}|${CAND_MODEL}|${CAND_FREE}"$'\n'
        else
            log "Could not mount $CAND_PART ($CAND_MODEL) to check free space - skipping it."
        fi
    done <<< "$USB_CANDIDATES"
    rmdir "$EVAL_MOUNTPOINT" 2>/dev/null
fi

# Prefixed marker line, not just "the last line of output": common.sh's own
# EXIT trap logs "=== ... finished ===" *after* this, which would otherwise
# be mistaken for the payload by anything doing end($out)-style parsing.
php -r '
$recoverableBytes = (int)$argv[1];
$recoverableFiles = (int)$argv[2];
$unreadableFiles  = (int)$argv[3];
$localFree        = (int)$argv[4];
$usbLines         = trim($argv[5]) === "" ? [] : explode("\n", trim($argv[5]));
$usbCandidates = [];
foreach ($usbLines as $line) {
    $parts = explode("|", $line);
    if (count($parts) !== 3) {
        continue;
    }
    [$device, $model, $free] = $parts;
    $free = (int)$free;
    $usbCandidates[] = [
        "device"    => $device,
        "model"     => $model,
        "freeBytes" => $free,
        "fitsOnUsb" => $free > ($recoverableBytes * 1.05), // same 5% headroom as fitsLocally
    ];
}
echo "EVALJSON:" . json_encode([
    "recoverableBytes" => $recoverableBytes,
    "recoverableFiles" => $recoverableFiles,
    "unreadableFiles"  => $unreadableFiles,
    "localFreeBytes"   => $localFree,
    "fitsLocally"       => $localFree > ($recoverableBytes * 1.05), // 5% headroom
    "usbCandidates"     => $usbCandidates,
]) . "\n";
' "$RECOVERABLE_BYTES" "$RECOVERABLE_FILES" "$UNREADABLE_FILES" "$LOCAL_FREE_BYTES" "$USB_RESULTS"
