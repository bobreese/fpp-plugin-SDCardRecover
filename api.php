<?php
/**
 * Quick synchronous JSON/file endpoints - used for things that finish fast
 * enough not to need stream.php's StreamURL() treatment.
 *
 * This is invoked the same way stream.php is: only ever reachable as
 * plugin.php?plugin=<repoName>&page=api.php&nopage=1&endpoint=<name>[&...],
 * which include_once's this file into plugin.php's own request. There is no
 * standalone URL for it and no auto-registration - an earlier version of
 * this file assumed a getEndpoints<Plugin>() convention that auto-mounts
 * routes under /api/plugin/<name>/..., but that turned out to be a different
 * mechanism entirely (fppd's own C++ API, proxied via Apache's
 * /plugin-apis/<name> rule to fppd on :32322 - see e.g. fpp-LoRa's
 * content.php calling fetch('api/plugin-apis/LoRa')). That requires backend
 * C++ registration this plugin doesn't have, so plain ?page=api.php&endpoint=
 * dispatch is what actually works for a pages-only plugin like this one.
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
