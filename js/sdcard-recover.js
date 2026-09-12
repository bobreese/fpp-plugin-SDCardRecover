/**
 * SDCard Recover wizard controller.
 *
 * Streaming model mirrors FPP core's own backup pages: a long-lived XHR whose
 * onprogress handler reads the growing response text and appends only the new
 * chunk (see FPP's StreamURL() in www/js/fpp.js). If FPP's own StreamURL() is
 * already loaded on the page (it is, on any core FPP page), we reuse it so
 * this plugin behaves identically to Copy Settings / Remote Backups; if it
 * isn't available (e.g. testing this page standalone), we fall back to a
 * local implementation of the same pattern.
 *
 * NOTE: FPP's real backup/sync pages don't show a numeric percentage - the
 * "progress" you see there is the live rsync log text itself. There is no
 * byte-accurate progress source for fsck/rsync/photorec output to drive a
 * true percentage bar from, so the progress bars here are indeterminate
 * (animated "working..." stripes) while a step streams, turning solid on
 * completion - visual feedback that something is happening, without a
 * fabricated percentage.
 */

(function () {
    'use strict';

    var sdcr = {
        device: null,
        partition: null,
        usbDevices: [],
    };

    function $(sel) { return document.querySelector(sel); }
    function $all(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

    function setProgress(id, active) {
        var el = document.getElementById(id);
        if (!el) return;
        el.style.display = active === null ? 'none' : 'block';
        el.classList.toggle('sdcr-progress-active', !!active);
        el.classList.toggle('sdcr-progress-done', active === false);
    }

    function enableStep(stepEl) {
        stepEl.classList.remove('sdcr-disabled');
        $all('button', stepEl).forEach(function (b) { b.disabled = false; });
    }

    /**
     * Streams stream.php?cmd=<cmd>&args[...] into the <pre> with id logId.
     * Calls onDone(exitOk, fullText) when the stream closes.
     */
    function streamCommand(cmd, args, logId, progressId, onDone) {
        var logEl = document.getElementById(logId);
        logEl.textContent = '';
        setProgress(progressId, true);

        var qs = 'cmd=' + encodeURIComponent(cmd);
        Object.keys(args || {}).forEach(function (k) {
            qs += '&args[' + encodeURIComponent(k) + ']=' + encodeURIComponent(args[k]);
        });
        // Cache-bust: an identical repeat request (e.g. clicking Rescan right
        // after Scan) could otherwise be served from the browser's HTTP
        // cache instead of actually re-running - the same reason FPP's own
        // StreamURL() sets cache:false on every call.
        qs += '&_=' + Date.now();
        var url = sdcrPageUrl('stream.php', qs);

        // Deliberately NOT using FPP core's window.StreamURL() here: its
        // doneCallback/errorCallback are looked up as GLOBAL FUNCTION NAMES
        // by string (window[doneCallback](id)), not invoked as JS closures -
        // confirmed in www/js/fpp.js. Passing an inline function (as an
        // earlier version of this file did) makes that lookup silently
        // resolve to undefined and throw inside StreamURL's own .done()
        // handler, so onDone() never ran - the request completed on the
        // server (confirmed by running the script directly) but the UI never
        // found out. Same onprogress-diffing technique StreamURL() uses
        // internally, just wired through a real callback closure instead.
        var xhr = new XMLHttpRequest();
        var lastLen = 0;
        xhr.open('GET', url, true);
        xhr.onprogress = function (e) {
            var full = e.currentTarget.responseText || e.currentTarget.response || '';
            if (full.length > lastLen) {
                logEl.textContent += full.substring(lastLen);
                lastLen = full.length;
                logEl.scrollTop = logEl.scrollHeight;
            }
        };
        xhr.onload = function () {
            setProgress(progressId, false);
            onDone(xhr.status === 200, logEl.textContent);
        };
        xhr.onerror = function () {
            setProgress(progressId, false);
            onDone(false, logEl.textContent);
        };
        xhr.send();
    }

    // Confirmed against FPP's actual www/plugin.php: there is no clean static
    // URL for a plugin's own PHP files - file=... only ever readfile()s raw
    // bytes (a .php file requested that way is served as its own source
    // text, never executed). The only way to run a plugin's PHP dynamically
    // is page=<file>&nopage=1, routed back through plugin.php itself. The
    // repoName comes from this page's own URL (it's how we were loaded),
    // not hardcoded, so this keeps working under whatever name the plugin
    // is actually installed as.
    function sdcrRepoName() {
        return new URLSearchParams(window.location.search).get('plugin') || 'fpp-plugin-SDCardRecover';
    }

    function sdcrPageUrl(page, extraQs) {
        var url = 'plugin.php?plugin=' + encodeURIComponent(sdcrRepoName()) + '&page=' + encodeURIComponent(page) + '&nopage=1';
        return extraQs ? url + '&' + extraQs : url;
    }

    function renderDeviceList(lines) {
        var list = $('#sdcr-device-list');
        list.innerHTML = '';
        sdcr.usbDevices = [];
        lines.filter(Boolean).forEach(function (line) {
            var obj;
            try { obj = JSON.parse(line); } catch (e) { return; }
            if (obj.partition) {
                sdcr.usbDevices.push(obj);
                return;
            }
            var row = document.createElement('label');
            row.className = 'sdcr-device-row';
            row.innerHTML = '<input type="radio" name="sdcr-device" value="' + obj.device + '"> ' +
                '<strong>' + obj.device + '</strong> - ' + obj.model + ' (' + humanSize(obj.size) + ', ' + obj.tran + ')';
            list.appendChild(row);
        });

        // Populate the USB-destination <select> in step 5 from the same scan,
        // excluding whatever device the user ends up selecting as the source.
        var usbSelect = $('#sdcr-usb-target');
        usbSelect.innerHTML = '<option value="">Select a mounted USB drive...</option>';
        sdcr.usbDevices.forEach(function (p) {
            if (p.mounted) {
                var opt = document.createElement('option');
                opt.value = p.mounted;
                opt.textContent = p.device + ' (' + p.mounted + ')';
                usbSelect.appendChild(opt);
            }
        });

        $all('input[name="sdcr-device"]').forEach(function (radio) {
            radio.addEventListener('change', function () {
                sdcr.device = radio.value;
                enableStep($('#sdcr-step-mount'));
                $('#sdcr-btn-mount').disabled = false;
            });
        });
    }

    function humanSize(bytes) {
        bytes = parseInt(bytes, 10) || 0;
        var units = ['B', 'KB', 'MB', 'GB', 'TB'];
        var i = 0;
        while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
        return bytes.toFixed(1) + ' ' + units[i];
    }

    function runScan() {
        streamCommand('scan', {}, 'sdcr-log-scan', 'sdcr-progress-scan', function (ok, text) {
            renderDeviceList(text.split('\n'));
            $('#sdcr-btn-rescan').style.display = 'inline-block';
        });
    }

    function guessPartition(device) {
        // First child partition of the selected disk, from the same scan data.
        var part = sdcr.usbDevices.find(function (p) { return p.parent === device; });
        return part ? part.device : device;
    }

    function runMount() {
        sdcr.partition = guessPartition(sdcr.device);
        streamCommand('mount_ro', { device: sdcr.partition }, 'sdcr-log-mount', 'sdcr-progress-mount', function (ok) {
            if (ok) {
                $('#sdcr-mountpoint-status').textContent = sdcr.partition + ' mounted read-only at /mnt/DamagedSD';
                enableStep($('#sdcr-step-mountpoint'));
                runVerify();
            } else {
                $('#sdcr-fsck-fallback').style.display = 'block';
            }
        });
    }

    function runVerify() {
        streamCommand('verify', {}, 'sdcr-log-mount', 'sdcr-progress-mount', function (ok, text) {
            var m = text.match(/Verification complete: (\d+) readable, (\d+) unreadable, (\d+) total/);
            var summary = $('#sdcr-verify-summary');
            summary.style.display = 'block';
            if (m) {
                summary.innerHTML = '<strong>' + m[1] + '</strong> readable / <strong>' + m[2] +
                    '</strong> unreadable out of ' + m[3] + ' files checked.';
                if (parseInt(m[2], 10) > 0) {
                    $('#sdcr-deepscan-offer').style.display = 'block';
                }
            }
            enableStep($('#sdcr-step-evaluate'));
            $('#sdcr-btn-evaluate').disabled = false;
        });
    }

    function runFsckCheck() {
        streamCommand('fsck_check', { device: sdcr.partition }, 'sdcr-log-fsck-check', null, function (ok, text) {
            if (!ok) {
                $('#sdcr-fsck-repair-offer').style.display = 'block';
            } else {
                runMount(); // retry mount now that we've confirmed it's clean
            }
        });
    }

    function runFsckRepair() {
        streamCommand('fsck_repair', { device: sdcr.partition }, 'sdcr-log-fsck-repair', null, function () {
            runMount(); // retry mount after repair
        });
    }

    function runCarve() {
        streamCommand('carve', { device: sdcr.device }, 'sdcr-log-carve', 'sdcr-progress-carve', function () {
            // deep-scan results are reported in the log; evaluate step still
            // reflects the verify manifest for the "fits locally?" check.
        });
    }

    function runEvaluate() {
        fetch(sdcrPageUrl('api.php', 'endpoint=evaluate&_=' + Date.now()), { cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var el = $('#sdcr-evaluate-result');
                el.innerHTML =
                    '<table class="sdcr-eval-table">' +
                    '<tr><td>Recoverable data found</td><td>' + humanSize(data.recoverableBytes) + ' (' + data.recoverableFiles + ' files)</td></tr>' +
                    '<tr><td>Unreadable (skipped)</td><td>' + data.unreadableFiles + ' files</td></tr>' +
                    '<tr><td>Free space on this FPP\'s storage</td><td>' + humanSize(data.localFreeBytes) + '</td></tr>' +
                    '<tr><td>Fits on local storage?</td><td>' + (data.fitsLocally ? 'Yes' : 'No - consider USB or zip instead') + '</td></tr>' +
                    '</table>';
                enableStep($('#sdcr-step-recover'));
                if (!data.fitsLocally) {
                    $('input[name="sdcr-dest"][value="local"]').disabled = true;
                }
            })
            .catch(function (err) {
                // A silently-rejected promise here (e.g. the backend
                // returning something r.json() can't parse) is exactly what
                // made "Evaluate does nothing" invisible the first time -
                // surface it instead of swallowing it.
                $('#sdcr-evaluate-result').innerHTML =
                    '<span class="sdcr-danger">Evaluate failed: ' + (err && err.message ? err.message : err) + '</span>';
            });
    }

    function selectedDestinations() {
        return $all('input[name="sdcr-dest"]:checked').map(function (cb) { return cb.value; });
    }

    function runRecover() {
        var dests = selectedDestinations();
        if (dests.length === 0) return;

        function next(i) {
            if (i >= dests.length) return;
            var destType = dests[i];
            var destArg = destType === 'usb' ? $('#sdcr-usb-target').value : '';
            streamCommand('recover', { destType: destType, destArg: destArg },
                'sdcr-log-recover', 'sdcr-progress-recover', function (ok, text) {
                    if (destType === 'zip') {
                        var m = text.match(/ZIPPATH:(.+\.zip)/);
                        if (m) {
                            var name = m[1].split('/').pop();
                            var link = $('#sdcr-download-link');
                            link.style.display = 'block';
                            var downloadUrl = sdcrPageUrl('api.php', 'endpoint=' + encodeURIComponent('download/' + name));
                            link.innerHTML = '<a class="btn btn-primary" href="' + downloadUrl + '">Download ' + name + '</a>';
                        }
                    }
                    next(i + 1);
                });
        }
        next(0);
    }

    document.addEventListener('DOMContentLoaded', function () {
        $('#sdcr-btn-scan').addEventListener('click', runScan);
        $('#sdcr-btn-rescan').addEventListener('click', runScan);
        $('#sdcr-btn-mount').addEventListener('click', runMount);
        $('#sdcr-btn-fsck-check').addEventListener('click', runFsckCheck);
        $('#sdcr-fsck-repair-confirm').addEventListener('change', function (e) {
            $('#sdcr-btn-fsck-repair').disabled = !e.target.checked;
        });
        $('#sdcr-btn-fsck-repair').addEventListener('click', runFsckRepair);
        $('#sdcr-btn-carve').addEventListener('click', runCarve);
        $('#sdcr-btn-evaluate').addEventListener('click', runEvaluate);
        $('#sdcr-btn-recover').addEventListener('click', runRecover);

        $all('input[name="sdcr-dest"]').forEach(function (cb) {
            cb.addEventListener('change', function () {
                $('#sdcr-usb-target').disabled = !$('input[value="usb"]').checked;
                $('#sdcr-btn-recover').disabled = selectedDestinations().length === 0;
            });
        });
    });
})();
