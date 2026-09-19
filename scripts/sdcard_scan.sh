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
lsblk -J -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,RM,MODEL,TRAN 2>/dev/null | \
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
            }
        }
    }
}
walk($data["blockdevices"] ?? [], $rootDev, $mediaDev);
' "$ROOT_DEV" "$MEDIA_DEV"

log "Scan complete."
