<?php
/**
 * Quick synchronous JSON endpoints - used for things that finish fast enough
 * not to need the stream.php/StreamURL() treatment. Registered the way
 * FalconChristmas/fpp-plugin-Template expects: getEndpointsSDCardRecover()
 * returns a list the FPP API router auto-mounts under
 * /api/plugin/SDCardRecover/...
 *
 * NOTE FOR IMPLEMENTER: confirm the exact router signature against a current
 * fpp-plugin-Template checkout before relying on this file as-is.
 */

function getEndpointsSDCardRecover() {
    return [
        [
            'method'   => 'GET',
            'endpoint' => 'evaluate',
            'callback' => 'SDCardRecover_Evaluate',
        ],
        [
            'method'   => 'GET',
            'endpoint' => 'download/:zipname',
            'callback' => 'SDCardRecover_Download',
        ],
    ];
}

function SDCardRecover_Evaluate() {
    $out = [];
    exec('sudo ' . escapeshellarg(dirname(__FILE__) . '/scripts/sdcard_evaluate.sh') . ' 2>&1', $out, $rc);
    $json = end($out);
    header('Content-Type: application/json');
    echo $json !== false ? $json : json_encode(['error' => 'evaluate failed', 'rc' => $rc]);
}

function SDCardRecover_Download($zipname) {
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
