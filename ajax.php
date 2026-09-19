<?php
/**
 * Quick synchronous JSON/file endpoints - used for things that finish fast
 * enough not to need stream.php's StreamURL() treatment.
 *
 * This is invoked the same way stream.php is: only ever reachable as
 * plugin.php?plugin=<repoName>&page=ajax.php&nopage=1&endpoint=<name>[&...],
 * which include_once's this file into plugin.php's own request. There is no
 * standalone URL for it and no auto-registration.
 *
 * Deliberately NOT named api.php. FPP core's www/api/index.php calls
 * addPluginEndpoints() -> collectPluginEndpoints() (controllers/plugin.php)
 * on every single /api/* request, for every plugin - not just this one, and
 * not gated by which page you're actually on. It scans every installed
 * plugin directory and, for any that contains a file literally named
 * api.php, unconditionally require_once's it looking for a
 * getEndpoints<repoName>() registrar (a real, PHP-only mechanism, distinct
 * from fppd's separate C++ /plugin-apis/<name> API). A file named api.php
 * gets swept into that scan whether or not it was ever written to be a
 * registrar - ours wasn't, so its top-level require_once "config.php" (a
 * bare relative path that only resolves correctly when reached via
 * plugin.php's own page dispatch) failed to open on every single /api/*
 * call anywhere on the device, logging a warning to apache2-error.log each
 * time. Confirmed live: 10 calls to /api/system/status produced 12 new
 * error-log lines, and FPP's own status page polls that endpoint about once
 * a second - roughly 40 MB/day of log noise from a file this plugin never
 * intended to be reachable that way at all. Renaming it is the whole fix;
 * nothing else about how it's invoked changes.
 */

require_once "config.php";
require_once "common.php";

$endpoint = isset($_GET['endpoint']) ? $_GET['endpoint'] : '';

switch (true) {
    case $endpoint === 'evaluate':
        sdcr_api_evaluate();
        break;

    case strpos($endpoint, 'download/') === 0:
        sdcr_api_download(substr($endpoint, strlen('download/')));
        break;

    default:
        http_response_code(400);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'unknown endpoint']);
}

function sdcr_api_evaluate() {
    $out = [];
    exec('sudo ' . escapeshellarg(dirname(__FILE__) . '/scripts/sdcard_evaluate.sh') . ' 2>&1', $out, $rc);
    header('Content-Type: application/json');
    // Not end($out): common.sh's own EXIT trap logs a "=== ... finished ==="
    // line AFTER the script body's own output, so the actual last line is
    // that trap message, not the JSON - end($out) silently fed the browser
    // an unparseable non-JSON string here, which is why Evaluate did nothing
    // (the fetch's .json() rejected with no .catch() to report it).
    foreach (array_reverse($out) as $line) {
        if (strpos($line, 'EVALJSON:') === 0) {
            echo substr($line, strlen('EVALJSON:'));
            return;
        }
    }
    echo json_encode(['error' => 'evaluate failed', 'rc' => $rc, 'output' => $out]);
}

function sdcr_api_download($zipname) {
    if (!preg_match('/^SDCardRecover-[0-9]{8}-[0-9]{6}\.zip$/', $zipname)) {
        http_response_code(400);
        echo 'invalid zip name';
        return;
    }
    $path = '/home/fpp/media/config/plugin.SDCardRecover/' . $zipname;
    if (!file_exists($path)) {
        http_response_code(404);
        echo 'not found';
        return;
    }
    header('Content-Type: application/zip');
    header('Content-Disposition: attachment; filename="' . $zipname . '"');
    header('Content-Length: ' . filesize($path));
    readfile($path);
}
