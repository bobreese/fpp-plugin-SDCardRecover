<?php
/**
 * Streaming worker. Confirmed against FPP's actual www/plugin.php: a plugin
 * page is only ever reached via ?page=<file>&nopage=1, which include_once's
 * this file into the SAME request plugin.php is already handling - it is
 * never requested as a standalone URL. plugin.php has already required
 * config.php by that point (both its wrapped and nopage branches do), but
 * only the wrapped branch also pulls in common.php, so this still needs to
 * require it explicitly here. Both are bare filenames, not paths relative to
 * this file - PHP resolves them the same way plugin.php's own requires do,
 * against FPP's www root, since that's the top-level script for this
 * request. (An earlier version of this file used
 * dirname(__FILE__) . '/../../common.php', which resolves outside the
 * plugin entirely and would fatal.)
 *
 * disables output buffering and shells a whitelisted script out via sudo so
 * the browser's StreamURL() can tail live progress exactly the way FPP's own
 * Copy Settings / Remote Backups pages do.
 *
 * cmd/args come from POST, not GET - found in fpp-data review: every action
 * dispatched from here, including fsck_repair (fsck -y) and recover (which
 * can overwrite this device's own Config), used to be reachable via a plain
 * GET with cmd/args in the query string, meaning a bare <img src="..."> on
 * any page the logged-in admin's browser loaded could fire one. See
 * js/sdcard-recover.js's streamCommand() for the client-side half of this
 * fix.
 */

require_once "config.php";
require_once "common.php";
require_once dirname(__FILE__) . '/scripts_dispatch.php';

DisableOutputBuffering();

$cmd  = isset($_POST['cmd']) ? $_POST['cmd'] : '';
$args = isset($_POST['args']) ? $_POST['args'] : [];

header('Content-Type: text/plain');

try {
    sdcr_dispatch($cmd, $args);
} catch (Exception $e) {
    echo "ERROR: " . $e->getMessage() . "\n";
    exit(1);
}
