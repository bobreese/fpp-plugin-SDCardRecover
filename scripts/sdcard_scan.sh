#!/bin/bash
# Step 1: Scan (and rescan) for a USB-attached SD card candidate to recover from.
# Lists removable block devices other than the one FPP is currently running on.
# Output: one JSON object per line (easy for the PHP layer to parse progressively).
source "$(dirname "$0")/common.sh"

log "Scanning for removable USB storage..."

ROOT_DEV=$(root_device)

lsblk -J -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,RM,MODEL,TRAN 2>/dev/null | \
php -r '
$data = json_decode(file_get_contents("php://stdin"), true);
$rootDev = $argv[1];
function walk($devices, $rootDev) {
    foreach ($devices as $d) {
        $path = "/dev/" . $d["name"];
        $isRemovable = (isset($d["rm"]) && $d["rm"]) || (isset($d["tran"]) && $d["tran"] === "usb");
        $isRoot = (strpos($rootDev, $d["name"]) !== false);
        // Multi-slot USB card readers (SD/microSD/CF/MS in one unit) enumerate
        // one SCSI disk per slot even when empty, reporting size 0 - not a
        // real candidate, so skip listing them at all rather than showing
        // the user three unusable "0.0 B" entries alongside the real card.
        $hasMedia = isset($d["size"]) && $d["size"] > 0;
        if ($d["type"] === "disk" && $isRemovable && !$isRoot && $hasMedia) {
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
walk($data["blockdevices"] ?? [], $rootDev);
' "$ROOT_DEV"

log "Scan complete."
