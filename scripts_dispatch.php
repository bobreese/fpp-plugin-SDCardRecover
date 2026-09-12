<?php
/**
 * Whitelisted dispatch from stream.php's ?cmd= to an actual shell script.
 * Never builds a shell command from raw user input - every argument is
 * validated (device-name regex) or escapeshellarg()'d before it reaches sudo.
 */

define('SDCR_PLUGIN_DIR', dirname(__FILE__));
define('SDCR_SCRIPTS', SDCR_PLUGIN_DIR . '/scripts');

$SDCR_DEVICE_RE = '/^\/dev\/(sd[a-z][0-9]*|mmcblk[0-9]+p?[0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*)$/';

function sdcr_require_device($args, $key) {
    global $SDCR_DEVICE_RE;
    $dev = isset($args[$key]) ? $args[$key] : '';
    if (!preg_match($SDCR_DEVICE_RE, $dev)) {
        throw new Exception("invalid device argument '$key'");
    }
    return $dev;
}

function sdcr_passthru($script, $shellArgs) {
    $cmd = 'sudo ' . escapeshellarg(SDCR_SCRIPTS . '/' . $script) . ' ' . implode(' ', $shellArgs);
    passthru($cmd);
}

function sdcr_dispatch($cmd, $args) {
    switch ($cmd) {
        case 'scan':
            sdcr_passthru('sdcard_scan.sh', []);
            break;

        case 'mount_ro':
            $dev = sdcr_require_device($args, 'device');
            sdcr_passthru('sdcard_mount_ro.sh', [escapeshellarg($dev)]);
            break;

        case 'fsck_check':
            $dev = sdcr_require_device($args, 'device');
            sdcr_passthru('sdcard_fsck_check.sh', [escapeshellarg($dev)]);
            break;

        case 'fsck_repair':
            // Deliberately the only destructive action in this plugin -
            // the UI must require a separate explicit confirmation before
            // ever issuing this request.
            $dev = sdcr_require_device($args, 'device');
            sdcr_passthru('sdcard_fsck_repair.sh', [escapeshellarg($dev)]);
            break;

        case 'verify':
            sdcr_passthru('sdcard_verify.sh', []);
            break;

        case 'carve':
            $dev = sdcr_require_device($args, 'device');
            $out = '/home/fpp/media/config/plugin.SDCardRecover/carved';
            sdcr_passthru('sdcard_carve.sh', [escapeshellarg($dev), escapeshellarg($out)]);
            break;

        case 'recover':
            $destType = isset($args['destType']) ? $args['destType'] : '';
            if (!in_array($destType, ['local', 'usb', 'zip'], true)) {
                throw new Exception('invalid destType');
            }
            $destArg = isset($args['destArg']) ? $args['destArg'] : '';
            sdcr_passthru('sdcard_recover.sh', [escapeshellarg($destType), escapeshellarg($destArg)]);
            break;

        case 'unmount':
            sdcr_passthru('sdcard_unmount.sh', []);
            break;

        default:
            throw new Exception("unknown command '$cmd'");
    }
}
