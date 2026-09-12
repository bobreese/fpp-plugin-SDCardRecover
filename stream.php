<?php
/**
 * Streaming worker endpoint, modeled directly on FPP core's www/copystorage.php
 * (the "Copy Settings" / file-copy-backup page): disables output buffering and
 * shells a whitelisted script out via sudo so the browser's StreamURL() can
 * tail live progress exactly the way FPP's own backup/remote-sync pages do.
 *
 * NOTE FOR IMPLEMENTER: the exact require_once() path for common.php and the
 * precise signature of DisableOutputBuffering() should be copied verbatim from
 * a current checkout of FalconChristmas/fpp (www/copystorage.php) and
 * FalconChristmas/fpp-plugin-Template - this file reproduces the *pattern*
 * from research, not a byte-for-byte copy of core source.
 */

require_once dirname(__FILE__) . '/../../common.php';
require_once dirname(__FILE__) . '/scripts_dispatch.php';

DisableOutputBuffering();

$cmd  = isset($_GET['cmd']) ? $_GET['cmd'] : '';
$args = isset($_GET['args']) ? $_GET['args'] : [];

header('Content-Type: text/plain');

try {
    sdcr_dispatch($cmd, $args);
} catch (Exception $e) {
    echo "ERROR: " . $e->getMessage() . "\n";
    exit(1);
}
