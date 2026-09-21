/**
 * SDCard Recover wizard controller.
 *
 * Streaming model mirrors FPP core's own backup pages: a long-lived XHR whose
 * onprogress handler reads the growing response text and appends only the new
 * chunk (see FPP's StreamURL() in www/js/fpp.js). Deliberately NOT calling
 * StreamURL() itself, though - see streamCommand() below for why.
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
        disks: {}, // device path -> {model, tran} - so the destination list
                   // can show a model, not just a bare /dev/sdX path, to
                   // actually distinguish e.g. two same-size USB sticks.
    };

    function $(sel) { return document.querySelector(sel); }
    function $all(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

    // state: true (in progress - blue, animated), false (done - green),
    // 'fail' (finished with a real error - red), or null (hidden).
    // Found from a real user question: this used to only ever take a plain
    // boolean, and every caller passed `false` the instant a request's HTTP
    // response finished - before anything checked the real exit code inside
    // it - so the bar turned green on a failed mount, a failed carve, even a
    // genuine network error (xhr.onerror also passed `false`). It looked
    // identical to success in every failure case; only the log text below it
    // ever said otherwise.
    function setProgress(id, state) {
        var el = document.getElementById(id);
        if (!el) return;
        el.style.display = state === null ? 'none' : 'block';
        el.classList.toggle('sdcr-progress-active', state === true);
        el.classList.toggle('sdcr-progress-done', state === false);
        el.classList.toggle('sdcr-progress-fail', state === 'fail');
    }

    function enableStep(stepEl) {
        stepEl.classList.remove('sdcr-disabled');
        $all('button', stepEl).forEach(function (b) { b.disabled = false; });
    }

    /**
     * Streams stream.php (cmd/args in the POST body) into the <pre> with id
     * logId. Calls onDone(exitOk, fullText) when the stream closes.
     */
    function streamCommand(cmd, args, logId, progressId, onDone) {
        var logEl = document.getElementById(logId);
        logEl.textContent = '';
        setProgress(progressId, true);

        var url = sdcrPageUrl('stream.php');

        var body = 'cmd=' + encodeURIComponent(cmd);
        Object.keys(args || {}).forEach(function (k) {
            body += '&args[' + encodeURIComponent(k) + ']=' + encodeURIComponent(args[k]);
        });

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
        //
        // POST, not GET - found in fpp-data review: every one of these
        // actions, including fsck_repair (fsck -y) and recover (which can
        // overwrite this device's own Config), used to run as a plain GET
        // with cmd/args in the query string. FPP core does the same for some
        // of its own destructive endpoints (e.g. GET /api/system/reboot,
        // confirmed in www/api/controllers/system.php), so this wasn't a
        // novel mistake - but a GET request needs nothing more than a plain
        // <img src="..."> on any page the logged-in admin's browser loads to
        // fire, no JS or CORS check required. POST isn't a complete CSRF fix
        // on its own (a same-origin form could still forge one), but it
        // closes off that single-tag drive-by case for free. It also drops
        // the old GET version's cache-busting `_=Date.now()` query param -
        // browsers don't cache POST responses, so it's no longer needed.
        var xhr = new XMLHttpRequest();
        var lastLen = 0;
        xhr.open('POST', url, true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.onprogress = function (e) {
            var full = e.currentTarget.responseText || e.currentTarget.response || '';
            if (full.length > lastLen) {
                logEl.textContent += full.substring(lastLen);
                lastLen = full.length;
                logEl.scrollTop = logEl.scrollHeight;
            }
        };
        xhr.onload = function () {
            // xhr.status is just "did the HTTP request succeed" - always 200
            // here regardless of what the wrapped shell script actually
            // exited with. scripts_dispatch.php now appends a parseable
            // SDCR_EXITCODE:<n> marker after passthru() returns; that real
            // exit code, not HTTP status, is what "ok" means from here on -
            // without this, a failed mount/fsck always looked like success
            // and the fallback UI (fsck -n box, repair-offer box) could
            // never appear.
            var text = logEl.textContent;
            var m = text.match(/\r?\nSDCR_EXITCODE:(-?\d+)\s*$/);
            var exitOk;
            if (m) {
                exitOk = parseInt(m[1], 10) === 0;
                text = text.slice(0, m.index);
                logEl.textContent = text;
            } else {
                exitOk = (xhr.status === 200);
            }
            // Progress bar itself now reflects the real result too, not
            // just the log text underneath it - see setProgress() above.
            setProgress(progressId, exitOk ? false : 'fail');
            onDone(exitOk, text);
        };
        xhr.onerror = function () {
            setProgress(progressId, 'fail');
            onDone(false, logEl.textContent);
        };
        xhr.send(body);
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

    // Populates sdcr.usbDevices/sdcr.disks from a scan's output lines.
    // Shared by the Step 1 scan (which also builds the source-card radio
    // list) and the Step 5 destination refresh (which must NOT touch Step 1
    // - by then the source card is likely already mounted/verified, and
    // rebuilding that radio list would silently lose the selection).
    // Returns the whole-disk entries, in case the caller wants to render them.
    function parseScanLines(lines) {
        var disks = [];
        sdcr.usbDevices = [];
        sdcr.disks = {};
        lines.filter(Boolean).forEach(function (line) {
            var obj;
            try { obj = JSON.parse(line); } catch (e) { return; }
            if (obj.partition) {
                sdcr.usbDevices.push(obj);
                return;
            }
            sdcr.disks[obj.device] = { model: obj.model, tran: obj.tran };
            disks.push(obj);
        });
        return disks;
    }

    function renderDeviceList(lines) {
        var list = $('#sdcr-device-list');
        list.innerHTML = '';
        var disks = parseScanLines(lines);
        disks.forEach(function (obj) {
            var row = document.createElement('label');
            row.className = 'sdcr-device-row';

            var radio = document.createElement('input');
            radio.type = 'radio';
            radio.name = 'sdcr-device';
            radio.value = obj.device;
            row.appendChild(radio);

            // obj.model comes straight from lsblk's MODEL field - the
            // attached USB device's own self-reported string, not something
            // this plugin controls. Found in fpp-data review: building this
            // row with innerHTML meant a crafted device (fake vendor/product
            // string) could inject markup into this admin page. textContent/
            // createTextNode never parses their input as HTML, so this is
            // safe regardless of what a device claims its model is - same
            // pattern populateUsbDestinations() below already used.
            var strong = document.createElement('strong');
            strong.textContent = obj.device;
            row.appendChild(document.createTextNode(' '));
            row.appendChild(strong);
            row.appendChild(document.createTextNode(
                ' - ' + obj.model + ' (' + humanSize(obj.size) + ', ' + obj.tran + ')'));

            list.appendChild(row);
        });

        // Sits next to Rescan so it's obvious a rescan is the fix - hidden
        // again the moment any scan (not just this one) actually finds a
        // card, rather than staying stuck on screen after the real problem
        // is gone.
        $('#sdcr-no-card-msg').style.display = disks.length === 0 ? 'inline' : 'none';

        $all('input[name="sdcr-device"]').forEach(function (radio) {
            radio.addEventListener('change', function () {
                sdcr.device = radio.value;
                enableStep($('#sdcr-step-mount'));
                $('#sdcr-btn-mount').disabled = false;
                populateUsbDestinations();
            });
        });
    }

    // Rescans for destination-drive candidates only - for a USB stick
    // plugged in after Step 1 already ran. Deliberately doesn't touch
    // #sdcr-device-list/the source radio buttons, since the source card may
    // already be mounted and verified by the time someone needs this.
    function refreshUsbDestinations() {
        streamCommand('scan', {}, 'sdcr-log-usb-refresh', 'sdcr-progress-usb-refresh', function (ok, text) {
            parseScanLines(text.split('\n'));
            populateUsbDestinations();
        });
    }

    // Given a partition path like /dev/sda2 or /dev/mmcblk0p2, returns its
    // parent disk (/dev/sda, /dev/mmcblk0) - same regex family as
    // common.sh's root_device()/media_device() (`sed -E 's/p?[0-9]+$//'`),
    // kept in sync deliberately since both sides need to agree on what
    // "the same physical disk" means.
    function diskOf(partitionPath) {
        return partitionPath.replace(/p?\d+$/, '');
    }

    // Lists partitions belonging to disks OTHER than the chosen source card,
    // as raw device paths (e.g. /dev/sdb1) - NOT by which ones scan happened
    // to see already mounted. FPP has no automount daemon, so a freshly
    // inserted destination USB stick is normally unmounted, and
    // sdcard_recover.sh now mounts it itself; a `.mounted`-only list
    // previously found nothing for a real second drive but could offer back
    // the source card's own (read-only) mount as if it were a destination.
    //
    // A prior version of this function excluded the source disk by comparing
    // against `sdcr.device` and was removed here after that comparison went
    // stale across a device-letter reuse (see git history) - but removing it
    // outright was itself wrong, found in a follow-up review: this function
    // also runs at Step 1 radio-select time (see below), before anything is
    // mounted, straight from scan data that still lists the source disk's
    // OWN partitions (nothing excludes them server-side yet, since
    // sdcard_scan.sh only excludes a disk once one of its partitions is
    // actually mounted). Without any client-side filter, the source card's
    // sibling partition (e.g. its untouched boot partition) sat in this
    // dropdown with the same model string as the card itself, and - the
    // more serious half - the server accepted it: sdcard_recover.sh's own
    // check only ever compared against the exact partition mounted at
    // $MOUNTPOINT, not its siblings (fixed separately there). Restored the
    // filter here too, but keyed on the freshest identity available -
    // `sdcr.partition` (the actual mounted partition, set by runMount())
    // once it exists, falling back to `sdcr.device` (fresh as of the same
    // Step 1 click that calls this) before that - rather than reintroducing
    // the original staleness risk.
    function populateUsbDestinations() {
        var usbSelect = $('#sdcr-usb-target');
        usbSelect.innerHTML = '<option value="">Select a destination USB drive...</option>';
        var sourceDisk = sdcr.partition ? diskOf(sdcr.partition) : sdcr.device;
        sdcr.usbDevices.forEach(function (p) {
            if (sourceDisk && p.parent === sourceDisk) return; // never offer a sibling partition of the source card
            var disk = sdcr.disks[p.parent] || {};
            var opt = document.createElement('option');
            opt.value = p.device;
            opt.textContent = p.device + (disk.model ? ' - ' + disk.model : '') +
                (p.fstype ? ' (' + p.fstype + ')' : '') + ' - ' + humanSize(p.size);
            usbSelect.appendChild(opt);
        });
    }

    function humanSize(bytes) {
        bytes = parseInt(bytes, 10) || 0;
        var units = ['B', 'KB', 'MB', 'GB', 'TB'];
        var i = 0;
        while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
        return bytes.toFixed(1) + ' ' + units[i];
    }

    // Found from a real user report: sdcard_unmount.sh's own header comment
    // has always claimed it runs "when the user re-scans, picks a different
    // device, or finishes a recovery run" - but nothing ever actually called
    // it. A card mounted at Step 2 stayed mounted at $MOUNTPOINT indefinitely,
    // across page reloads and new sessions, since nothing here ever ran the
    // 'unmount' command. sdcard_scan.sh correctly (by design) excludes an
    // already-mounted disk from its results, so the SAME card that was used
    // last session stayed invisible to a fresh Scan - looking exactly like a
    // detection failure. Confirmed on real hardware: every dmesg capture
    // showing "it works after I unplug and replug the reader" also showed
    // "EXT4-fs (sdX2): shut down requested" immediately after the physical
    // disconnect - the replug wasn't fixing a USB problem, it was forcing the
    // kernel to tear down the stale mount that a proper unmount call should
    // have cleared already. Unmounting first, unconditionally, on every Scan/
    // Rescan click matches that documented original intent: this is Step 1's
    // own "start looking for a source card" action, and re-running it is a
    // reasonable signal that whatever was mounted before is being abandoned.
    // Deliberately NOT applied to refreshUsbDestinations() below, which
    // shares the same 'scan' backend command but must never touch the
    // already-mounted source while the user is only looking for a
    // destination drive.
    function runScan() {
        streamCommand('unmount', {}, 'sdcr-log-scan', null, function () {
            streamCommand('scan', {}, 'sdcr-log-scan', 'sdcr-progress-scan', function (ok, text) {
                renderDeviceList(text.split('\n'));
                $('#sdcr-btn-rescan').style.display = 'inline-block';
            });
        });
    }

    function guessPartition(device) {
        // An FPP SD card is boot (small vfat: bootloader/kernel only) + root
        // (ext4: everything else, including /home/fpp/media/config,
        // sequences, etc.) - config/media never live on the boot partition.
        // Picking "the first partition" (sda1) grabbed the boot partition
        // every time, which is why verify always found 0 files even on a
        // card with real data on it. Prefer the ext4 partition; if none is
        // found (not an FPP layout), fall back to the largest partition
        // rather than blindly the first.
        var parts = sdcr.usbDevices.filter(function (p) { return p.parent === device; });
        if (parts.length === 0) return device;
        var ext = parts.find(function (p) { return /^ext[234]$/.test(p.fstype || ''); });
        if (ext) return ext.device;
        parts.sort(function (a, b) { return (b.size || 0) - (a.size || 0); });
        return parts[0].device;
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
            // Found on real hardware, deliberately corrupting a directory's
            // own entries: sdcard_verify.sh's find can hit a directory it
            // can no longer list (ext4 metadata-checksum catching the
            // damage, "Bad message") - those files never show up as
            // unreadable, they just silently never get counted at all, so
            // the sentence above alone would report a falsely-clean "0
            // unreadable" while real data was inaccessible. Parsed as a
            // separate, additive match (see sdcard_verify.sh's own comment
            // on why it's appended rather than inserted into the existing
            // sentence) so this doesn't disturb the main regex above.
            var dirErr = text.match(/(\d+) directory could not be fully listed|(\d+) directories could not be fully listed/);
            var dirErrCount = dirErr ? parseInt(dirErr[1] || dirErr[2], 10) : 0;
            var summary = $('#sdcr-verify-summary');
            summary.style.display = 'block';
            if (m) {
                summary.innerHTML = '<strong>' + m[1] + '</strong> readable / <strong>' + m[2] +
                    '</strong> unreadable out of ' + m[3] + ' files checked' +
                    (dirErrCount > 0 ? ' - <strong class="sdcr-danger">' + dirErrCount +
                        ' director' + (dirErrCount === 1 ? 'y' : 'ies') +
                        ' could not be fully listed</strong>, so these counts do not include everything on the card' : '') +
                    '.';
                if (parseInt(m[2], 10) > 0 || dirErrCount > 0) {
                    $('#sdcr-deepscan-offer').style.display = 'block';
                }
            }
            enableStep($('#sdcr-step-evaluate'));
            $('#sdcr-btn-evaluate').disabled = false;
        });
    }

    // The retried mount/verify write into Step 2's own main log panel, not
    // the nested fsck sub-box the user is actually looking at when this
    // fires - confirmed confusing on real hardware (a repair that actually
    // worked read as "nothing happened" because the success played out in a
    // different, out-of-view panel). Scroll there so the retry is visible.
    function scrollToMountLog() {
        var el = $('#sdcr-log-mount');
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    function runFsckCheck() {
        streamCommand('fsck_check', { device: sdcr.partition }, 'sdcr-log-fsck-check', null, function (ok, text) {
            if (!ok) {
                $('#sdcr-fsck-repair-offer').style.display = 'block';
            } else {
                scrollToMountLog();
                runMount(); // retry mount now that we've confirmed it's clean
            }
        });
    }

    function runFsckRepair() {
        streamCommand('fsck_repair', { device: sdcr.partition }, 'sdcr-log-fsck-repair', null, function () {
            scrollToMountLog();
            runMount(); // retry mount after repair
        });
    }

    function runCarve() {
        streamCommand('carve', { device: sdcr.device }, 'sdcr-log-carve', 'sdcr-progress-carve', function () {
            // deep-scan results are reported in the log; evaluate step still
            // reflects the verify manifest for the "fits locally?" check.
            refreshArtifacts();
        });
    }

    // Lists old recovery zips and deep-scan output sitting in this plugin's
    // own scratch state, with a Delete button for each - added after a real
    // user question about why nothing here ever gets cleaned up
    // automatically. It deliberately never does: there is no reliable
    // signal that a browser download actually finished (especially for a
    // large zip over WiFi to this device), so auto-deleting risks losing
    // something that was never really saved anywhere else - the same
    // reasoning behind the uninstall-rescue fix elsewhere in this plugin.
    // This makes cleanup an explicit, one-click-plus-confirm action instead,
    // since FPP's own File Manager cannot browse into this plugin's state
    // directory to do it any other way (see docs/testing.md).
    function refreshArtifacts() {
        fetch(sdcrPageUrl('ajax.php', 'endpoint=artifacts&_=' + Date.now()), { cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                renderArtifacts(data.items || []);
            })
            .catch(function (err) {
                var list = $('#sdcr-artifacts-list');
                if (list) {
                    list.innerHTML = '<span class="sdcr-danger">Failed to load: ' +
                        (err && err.message ? err.message : err) + '</span>';
                }
            });
    }

    function renderArtifacts(items) {
        var list = $('#sdcr-artifacts-list');
        if (!list) return;
        if (items.length === 0) {
            list.innerHTML = '<span class="sdcr-hint">Nothing here yet - recovery zips and deep-scan output will show up here once you create them.</span>';
            return;
        }
        list.innerHTML = '';
        items.forEach(function (item) {
            var row = document.createElement('div');
            row.className = 'sdcr-artifact-row';

            var label = document.createElement('span');
            var detail = item.type === 'dir'
                ? (item.fileCount + ' file' + (item.fileCount === 1 ? '' : 's') + ', ')
                : '';
            label.textContent = item.name + ' - ' + detail + humanSize(item.sizeBytes) + ' - ' + item.mtime;
            row.appendChild(label);

            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'btn btn-danger';
            btn.textContent = 'Delete';
            btn.addEventListener('click', function () {
                if (!confirm('Permanently delete "' + item.name + '"? This cannot be undone - make sure you already have a copy of anything you need from it.')) {
                    return;
                }
                btn.disabled = true;
                // Found from a real user report: this used to ignore the
                // (ok, text) result streamCommand's every other caller
                // already checks, so a failed delete (e.g. lock
                // contention - see common.sh) just silently refreshed the
                // unchanged list with no indication anything went wrong.
                streamCommand('delete_artifact', { name: item.name }, 'sdcr-log-artifacts', null, function (ok, text) {
                    if (!ok) {
                        btn.disabled = false;
                        alert('Delete failed for "' + item.name + '":\n\n' +
                            (text && text.trim() ? text.trim() : '(no output - check plugin-fpp-plugin-SDCardRecover.log)'));
                        return;
                    }
                    refreshArtifacts();
                });
            });
            row.appendChild(btn);

            list.appendChild(row);
        });
    }

    function runEvaluate() {
        fetch(sdcrPageUrl('ajax.php', 'endpoint=evaluate&_=' + Date.now()), { cache: 'no-store' })
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
                // Found in fpp-data review, alongside the sibling-partition
                // fix above: Step 5's destination list was otherwise still
                // whatever Step 1's scan saw, which is stale by the time
                // this step unlocks (a destination drive plugged in during
                // Steps 2-4 would not show up until the user thought to
                // click Refresh themselves). A fresh scan here also
                // benefits from the source card now actually being mounted,
                // so sdcard_scan.sh's own server-side exclusion of the
                // source disk applies on top of the client-side filter.
                refreshUsbDestinations();
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

    function selectedLocalCategories() {
        return $all('.sdcr-local-cat:checked').map(function (cb) { return cb.value; });
    }

    // Caps Step 5 at 2 destinations at once (see the hint text in
    // status.php) - disables whichever destination checkboxes aren't
    // already checked once 2 are, so a third can't be picked; re-enables
    // all of them the moment one gets unchecked again.
    var MAX_DESTINATIONS = 2;
    function enforceDestinationLimit() {
        var boxes = $all('input[name="sdcr-dest"]');
        var checkedCount = boxes.filter(function (cb) { return cb.checked; }).length;
        boxes.forEach(function (cb) {
            cb.disabled = !cb.checked && checkedCount >= MAX_DESTINATIONS;
        });
    }

    // Local restore is gated on more than "is a destination checked": if
    // Config is among the chosen categories, the explicit "I understand"
    // checkbox must also be checked, since that overwrites THIS device's
    // own name/IP/plugin settings - see the warning text in status.php.
    // Plugins gets the same gating, found in fpp-data review: restoring it
    // copies raw plugin code onto this device without ever going through
    // FPP's own Plugin Manager install flow (no install hook, no privacy
    // review, no consent screen) - a real risk from a card whose plugin
    // contents you may not have created yourself, not just a data-loss one.
    function updateRecoverButtonState() {
        var localChecked = $('input[name="sdcr-dest"][value="local"]').checked;
        $('#sdcr-local-categories').style.display = localChecked ? 'block' : 'none';

        var configChecked = selectedLocalCategories().indexOf('config') !== -1;
        $('#sdcr-config-warning').style.display = (localChecked && configChecked) ? 'block' : 'none';

        var pluginsChecked = selectedLocalCategories().indexOf('plugins') !== -1;
        $('#sdcr-plugins-warning').style.display = (localChecked && pluginsChecked) ? 'block' : 'none';

        var dests = selectedDestinations();
        var blocked = (localChecked && configChecked && !$('#sdcr-config-confirm').checked) ||
            (localChecked && pluginsChecked && !$('#sdcr-plugins-confirm').checked);
        // Local also needs at least one category checked, not just the box.
        var localNeedsCategory = localChecked && selectedLocalCategories().length === 0;
        $('#sdcr-btn-recover').disabled = dests.length === 0 || blocked || localNeedsCategory;
    }

    // Fixed run order regardless of the order the checkboxes were ticked in
    // (see the hint text in status.php): zip first if chosen, so its
    // "ready to download" info box lands before anything else runs; local
    // last if chosen, since it's this device's own media/config being
    // touched, not a copy elsewhere. usb sits in between either way.
    var DEST_RUN_ORDER = ['zip', 'usb', 'local'];

    function runRecover() {
        var chosen = selectedDestinations();
        if (chosen.length === 0) return;
        var dests = DEST_RUN_ORDER.filter(function (d) { return chosen.indexOf(d) !== -1; });

        function next(i) {
            if (i >= dests.length) return;
            var destType = dests[i];
            var destArg = '';
            if (destType === 'usb') {
                destArg = $('#sdcr-usb-target').value;
            } else if (destType === 'local') {
                destArg = selectedLocalCategories().join(',');
            }
            streamCommand('recover', { destType: destType, destArg: destArg },
                'sdcr-log-recover', 'sdcr-progress-recover', function (ok, text) {
                    if (destType === 'zip') {
                        var m = text.match(/ZIPPATH:(.+\.zip)/);
                        if (m) {
                            var name = m[1].split('/').pop();
                            var link = $('#sdcr-download-link');
                            link.style.display = 'block';
                            var downloadUrl = sdcrPageUrl('ajax.php', 'endpoint=' + encodeURIComponent('download/' + name));
                            link.innerHTML = '<a class="btn btn-primary" href="' + downloadUrl + '">Download ' + name + '</a>';
                        }
                        refreshArtifacts();
                        // alert() blocks until dismissed, so this naturally
                        // pauses the sequence here rather than needing its
                        // own state machine - the next destination (if any)
                        // only starts once the user clicks OK.
                        if (ok && name) {
                            alert('Zip ready: ' + name + '\n\nClick OK to continue.');
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
        $('#sdcr-btn-refresh-usb').addEventListener('click', refreshUsbDestinations);
        $('#sdcr-btn-refresh-artifacts').addEventListener('click', refreshArtifacts);
        // Loaded up front, independent of wizard progress - cleaning up an
        // old zip from a past session shouldn't require running the whole
        // wizard again first.
        refreshArtifacts();

        $all('input[name="sdcr-dest"]').forEach(function (cb) {
            cb.addEventListener('change', function () {
                $('#sdcr-usb-target').disabled = !$('input[value="usb"]').checked;
                enforceDestinationLimit();
                updateRecoverButtonState();
            });
        });
        $all('.sdcr-local-cat').forEach(function (cb) {
            cb.addEventListener('change', updateRecoverButtonState);
        });
        $('#sdcr-config-confirm').addEventListener('change', updateRecoverButtonState);
        $('#sdcr-plugins-confirm').addEventListener('change', updateRecoverButtonState);

        // "(see warning)" next to Config/Plugins was previously just inert
        // text (Config) or didn't exist at all (Plugins, added after
        // fpp-data review flagged that restoring it deserved the same
        // treatment as Config). Both are real links now: checking the
        // category (revealing the warning box, otherwise there's nothing to
        // scroll to - it's display:none until then) and scrolling/flashing
        // it so it's obvious that's what's meant.
        wireCategoryWarningLink('sdcr-config-warning-link', 'config', 'sdcr-config-warning');
        wireCategoryWarningLink('sdcr-plugins-warning-link', 'plugins', 'sdcr-plugins-warning');
    });

    function wireCategoryWarningLink(linkId, categoryValue, warningBoxId) {
        var link = $('#' + linkId);
        if (!link) return;
        link.addEventListener('click', function () {
            var catBox = $('.sdcr-local-cat[value="' + categoryValue + '"]');
            if (!catBox.checked) {
                catBox.checked = true;
                updateRecoverButtonState();
            }
            var warning = $('#' + warningBoxId);
            warning.scrollIntoView({ behavior: 'smooth', block: 'center' });
            warning.classList.remove('sdcr-flash-highlight');
            void warning.offsetWidth; // restart the animation if clicked again
            warning.classList.add('sdcr-flash-highlight');
        });
    }
})();
