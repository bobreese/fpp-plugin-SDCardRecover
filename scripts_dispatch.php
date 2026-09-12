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
    // Two real bugs fixed by this one change, confirmed on real hardware:
    //
    // 1. No 2>&1: a script's own `echo "ERROR: ..." >&2` (used for every
    //    hard failure - "not mounted", "no manifest found", etc.) went to
    //    Apache's error log, never to the browser or SDCardRecover.log. A
    //    real trashed-superblock test showed sdcard_verify.sh start and
    //    immediately finish (exit 1) with no visible reason why - the
    //    actual error text existed, just not anywhere the user could see it.
    //
    // 2. No exit-code reporting: passthru() streams stdout live, but the
    //    JS side (streamCommand()) was inferring success from the HTTP
    //    request's own status code, which is always 200 regardless of
    //    what the wrapped script actually exited with - passthru() alone
    //    doesn't surface that to the HTTP response at all. So runMount()'s
    //    fsck-fallback UI and runFsckCheck()'s repair-offer box could
    //    NEVER appear, no matter what: the "success" branch always ran.
    //    Capturing the real exit code and appending it as a parseable
    //    marker line lets the JS tell the two apart correctly.
    $cmd = 'sudo ' . escapeshellarg(SDCR_SCRIPTS . '/' . $script) . ' ' . implode(' ', $shellArgs) . ' 2>&1';
    passthru($cmd, $rc);
    echo "\nSDCR_EXITCODE:$rc\n";
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
            if ($destType === 'usb') {
                // destArg is a raw partition device now (e.g. /dev/sdb1) that
                // sdcard_recover.sh mounts itself - validate it the same way
                // every other device argument is validated.
                $destArg = sdcr_require_device($args, 'destArg');
            } elseif ($destType === 'local') {
                // destArg is a comma-separated category list (e.g.
                // "config,sequences") - sdcard_recover.sh re-validates each
                // one against CATEGORY_RE too, but reject anything
                // malformed here before it ever reaches a shell command.
                $destArg = isset($args['destArg']) ? $args['destArg'] : '';
                if ($destArg === '' || !preg_match('/^[a-z]+(,[a-z]+)*$/', $destArg)) {
                    throw new Exception('invalid category list for local restore');
                }
            } else {
                $destArg = isset($args['destArg']) ? $args['destArg'] : '';
            }
            sdcr_passthru('sdcard_recover.sh', [escapeshellarg($destType), escapeshellarg($destArg)]);
            break;

        case 'unmount':
            sdcr_passthru('sdcard_unmount.sh', []);
            break;

        default:
            throw new Exception("unknown command '$cmd'");
    }
}
