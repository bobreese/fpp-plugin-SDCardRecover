#!/bin/bash
# Step 1: Scan (and rescan) for a USB-attached SD card candidate to recover from.
# Lists removable block devices other than the one FPP is currently running on,
# the one backing FPP's own media directory (which can be a separate storage
# device entirely), or any device with a currently-mounted partition for any
# other reason - see guard_not_root_device() in common.sh for the same
# exclusions enforced server-side, not just filtered out of this listing.
# Output: one JSON object per line (easy for the PHP layer to parse progressively).
source "$(dirname "$0")/common.sh"

log "Scanning for removable USB storage..."

ROOT_DEV=$(root_device)
MEDIA_DEV=$(media_device)

# Found in fpp-data review: FPP's media directory can be on its own USB
# storage device (www/settings-storage.php's storageDevice setting) - same
# transport type as any other removable candidate, so it was showing up here
# as if it were a damaged card to recover from. Excluded by device path
# (MEDIA_DEV) AND by "does any partition already have a mountpoint" - the
# latter is the more general guard (also covers a device mounted for some
# other reason entirely), using data lsblk already reports per partition
# rather than an extra system call per device.
# Captured rather than streamed straight through, unlike the slow scripts
# (fsck/rsync/photorec) - this is a single near-instant lsblk+PHP pass, so
# buffering the whole (small) output to separate out NOTE: lines below costs
# nothing noticeable, and lets those notes also reach $LOG_FILE like every
# other message this plugin logs (see common.sh's log()) instead of only
# ever showing up in the live browser panel and being lost afterward.
SCAN_OUTPUT=$(lsblk -J -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,RM,MODEL,TRAN 2>/dev/null | \
php -r '
$data = json_decode(file_get_contents("php://stdin"), true);
$rootDev = $argv[1];
$mediaDev = $argv[2];
function walk($devices, $rootDev, $mediaDev) {
    foreach ($devices as $d) {
        $path = "/dev/" . $d["name"];
        $isRemovable = (isset($d["rm"]) && $d["rm"]) || (isset($d["tran"]) && $d["tran"] === "usb");
        $isRoot = (strpos($rootDev, $d["name"]) !== false);
        $isMedia = ($mediaDev !== "" && strpos($mediaDev, $d["name"]) !== false);
        $hasMountedChild = false;
        foreach ($d["children"] ?? [] as $c) {
            if (!empty($c["mountpoint"])) {
                $hasMountedChild = true;
                break;
            }
        }
        $inUse = $isRoot || $isMedia || $hasMountedChild || !empty($d["mountpoint"]);
        // Multi-slot USB card readers (SD/microSD/CF/MS in one unit) enumerate
        // one SCSI disk per slot even when empty, reporting size 0 - not a
        // real candidate, so skip listing them at all rather than showing
        // the user three unusable "0.0 B" entries alongside the real card.
        $hasMedia = isset($d["size"]) && $d["size"] > 0;
        if ($d["type"] === "disk" && $isRemovable && !$inUse && $hasMedia) {
            echo json_encode([
                "device"  => $path,
                "size"    => $d["size"],
                "model"   => $d["model"] ?? "Unknown",
                "tran"    => $d["tran"] ?? "",
            ]) . "\n";
            if (!empty($d["children"])) {
                foreach ($d["children"] as $c) {
                    echo json_encode([
                        "device"   => "/dev/" . $c["name"],
                        "parent"   => $path,
                        "size"     => $c["size"],
                        "fstype"   => $c["fstype"] ?? "",
                        "mounted"  => $c["mountpoint"] ?? null,
                        "partition"=> true,
                    ]) . "\n";
                }
            } elseif (!empty($d["fstype"])) {
                // "Superfloppy" media - a filesystem written directly on the
                // whole disk, no partition table at all (some USB sticks,
                // especially smaller/cheaper ones, ship this way). No
                // separate partition device node exists for the kernel to
                // report as a child, but the disk itself is a real,
                // recoverable destination - offer it as its own "partition".
                echo json_encode([
                    "device"   => $path,
                    "parent"   => $path,
                    "size"     => $d["size"],
                    "fstype"   => $d["fstype"],
                    "mounted"  => $d["mountpoint"] ?? null,
                    "partition"=> true,
                ]) . "\n";
            } else {
                // Neither a partition the kernel exposed a device node for,
                // nor a filesystem directly on the disk - found on real
                // hardware with a USB stick whose partition table was
                // corrupted (fdisk showed a partition starting past the end
                // of the 7.45 GiB disk; the kernel logged a bare "sda:" with
                // no children and created no /dev/sda1). Nothing this script
                // can offer as a destination - the drive needs to be
                // repartitioned/reformatted on another computer first (this
                // plugin does not format one, by design). Logged so "why is
                // my drive missing from the list" has an answer instead of
                // silence.
                echo "NOTE: $path (" . ($d["model"] ?? "unknown model") . ", " . $d["size"] . " bytes) has no partitions and no filesystem of its own - skipping as a destination candidate. If this is a drive you expected to see, its partition table may be corrupted; repartition/format it on another computer first.\n";
            }
        }
    }
}
walk($data["blockdevices"] ?? [], $rootDev, $mediaDev);
' "$ROOT_DEV" "$MEDIA_DEV")

echo "$SCAN_OUTPUT" | grep -v '^NOTE: '
echo "$SCAN_OUTPUT" | grep '^NOTE: ' | while IFS= read -r note; do log "$note"; done

# Persist what was actually found, not just the two log() bookends around
# it - found from a real user question comparing a live scan's raw output
# against the downloaded log file and noticing the device list itself was
# missing. Uses log_file_only() (common.sh), not log(), so this doesn't
# also re-echo to stdout and duplicate/corrupt the raw-JSON stream the
# browser's JS parses above.
if [ -n "$SCAN_OUTPUT" ]; then
    log_file_only "Scan found:"
    echo "$SCAN_OUTPUT" | grep -v '^NOTE: ' | while IFS= read -r line; do
        [ -n "$line" ] && log_file_only "  $line"
    done
else
    log_file_only "Scan found: no removable candidates."
fi

log "Scan complete."
