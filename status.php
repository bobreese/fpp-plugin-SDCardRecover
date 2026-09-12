<?php
/**
 * Main SDCard Recover wizard page. Five steps, each with its own live log
 * panel streamed from stream.php the same way FPP's Copy Settings / Remote
 * Backups pages stream rsync output - see js/sdcard-recover.js.
 */
?>
<link rel="stylesheet" type="text/css" href="<?php echo pluginBaseURL('SDCardRecover'); ?>/css/sdcard-recover.css">

<div id="sdcr-root" class="sdcr-wizard">

    <div class="sdcr-intro">
        <strong>SD Card Recover</strong> reads a second, possibly-damaged FPP SD card
        over USB and tries to pull your config and media off it - without running any
        destructive repair unless you explicitly ask for it.
        Everything below is also written to <code>media/logs/SDCardRecover.log</code>,
        viewable/downloadable from FPP's own File Manager &rarr; Logs tab.
    </div>

    <!-- Step 1: Scan -->
    <div class="sdcr-step" id="sdcr-step-scan" data-step="1">
        <div class="sdcr-step-header">
            <span class="sdcr-step-num">1</span>
            <span class="sdcr-step-title">Scan for a USB-attached SD card</span>
            <button type="button" id="sdcr-btn-scan" class="btn btn-primary">Scan</button>
            <button type="button" id="sdcr-btn-rescan" class="btn" style="display:none;">Rescan</button>
        </div>
        <div class="sdcr-step-body">
            <div id="sdcr-device-list" class="sdcr-device-list"></div>
            <div class="sdcr-progress" id="sdcr-progress-scan" style="display:none;">
                <div class="sdcr-progress-bar"><div class="sdcr-progress-fill"></div></div>
            </div>
            <pre class="sdcr-log" id="sdcr-log-scan"></pre>
        </div>
    </div>

    <!-- Step 2: Mount + (fallback) fsck check -->
    <div class="sdcr-step sdcr-disabled" id="sdcr-step-mount" data-step="2">
        <div class="sdcr-step-header">
            <span class="sdcr-step-num">2</span>
            <span class="sdcr-step-title">Mount &amp; verify readability</span>
            <button type="button" id="sdcr-btn-mount" class="btn btn-primary" disabled>Mount read-only</button>
        </div>
        <div class="sdcr-step-body">
            <p class="sdcr-hint">
                Mounts the card's media partition read-only as <code>DamagedSD</code>, then
                checks every config/media file for actual readability (bad sectors show up
                as read errors, not guesses from filesystem metadata).
            </p>

            <div class="sdcr-progress" id="sdcr-progress-mount" style="display:none;">
                <div class="sdcr-progress-bar"><div class="sdcr-progress-fill"></div></div>
            </div>
            <pre class="sdcr-log" id="sdcr-log-mount"></pre>

            <div id="sdcr-fsck-fallback" style="display:none;" class="sdcr-fsck-fallback">
                <p class="sdcr-warn">
                    Read-only mount failed. Run a <strong>non-destructive</strong> check
                    (<code>fsck -n</code>) to see what's wrong? This does not change anything
                    on the card.
                </p>
                <button type="button" id="sdcr-btn-fsck-check" class="btn">Run fsck -n (safe, read-only)</button>
                <pre class="sdcr-log" id="sdcr-log-fsck-check"></pre>

                <div id="sdcr-fsck-repair-offer" style="display:none;">
                    <p class="sdcr-danger">
                        The check above found filesystem problems. Repairing
                        (<code>fsck -y</code>) <strong>writes changes to the card and cannot be
                        undone</strong>. Only do this if you understand the risk - on a badly
                        damaged card, repair can destroy data that a deep scan could otherwise
                        still carve out.
                    </p>
                    <label><input type="checkbox" id="sdcr-fsck-repair-confirm"> I understand this may destroy data</label><br>
                    <button type="button" id="sdcr-btn-fsck-repair" class="btn btn-danger" disabled>Attempt repair (fsck -y)</button>
                    <pre class="sdcr-log" id="sdcr-log-fsck-repair"></pre>
                </div>
            </div>

            <div id="sdcr-verify-summary" class="sdcr-summary" style="display:none;"></div>

            <div id="sdcr-deepscan-offer" style="display:none;" class="sdcr-deepscan-offer">
                <p class="sdcr-hint">
                    Want to also try a deep scan (raw signature search) for files the
                    filesystem can no longer see? This doesn't need a working filesystem,
                    but can take a long time.
                </p>
                <button type="button" id="sdcr-btn-carve" class="btn">Run deep scan</button>
                <div class="sdcr-progress" id="sdcr-progress-carve" style="display:none;">
                    <div class="sdcr-progress-bar"><div class="sdcr-progress-fill"></div></div>
                </div>
                <pre class="sdcr-log" id="sdcr-log-carve"></pre>
            </div>
        </div>
    </div>

    <!-- Step 3 folded into step 2's mount action; kept as its own numbered
         card per the original spec, showing the resulting mount state. -->
    <div class="sdcr-step sdcr-disabled" id="sdcr-step-mountpoint" data-step="3">
        <div class="sdcr-step-header">
            <span class="sdcr-step-num">3</span>
            <span class="sdcr-step-title">Media partition mounted as DamagedSD</span>
        </div>
        <div class="sdcr-step-body">
            <div id="sdcr-mountpoint-status" class="sdcr-hint">Not mounted yet.</div>
        </div>
    </div>

    <!-- Step 4: Evaluate space -->
    <div class="sdcr-step sdcr-disabled" id="sdcr-step-evaluate" data-step="4">
        <div class="sdcr-step-header">
            <span class="sdcr-step-num">4</span>
            <span class="sdcr-step-title">Evaluate space needed vs. available</span>
            <button type="button" id="sdcr-btn-evaluate" class="btn btn-primary" disabled>Evaluate</button>
        </div>
        <div class="sdcr-step-body">
            <div id="sdcr-evaluate-result" class="sdcr-summary"></div>
        </div>
    </div>

    <!-- Step 5: Choose destination & recover -->
    <div class="sdcr-step sdcr-disabled" id="sdcr-step-recover" data-step="5">
        <div class="sdcr-step-header">
            <span class="sdcr-step-num">5</span>
            <span class="sdcr-step-title">Recover data</span>
        </div>
        <div class="sdcr-step-body">
            <div class="sdcr-dest-options">
                <label><input type="checkbox" name="sdcr-dest" value="local"> Local FPP storage (media/Recovered/)</label><br>
                <label><input type="checkbox" name="sdcr-dest" value="usb"> A second attached USB drive
                    <select id="sdcr-usb-target" disabled><option value="">Select a mounted USB drive...</option></select>
                </label><br>
                <label><input type="checkbox" name="sdcr-dest" value="zip"> Zip file (download to your computer)</label>
            </div>
            <button type="button" id="sdcr-btn-recover" class="btn btn-primary" disabled>Recover</button>
            <div class="sdcr-progress" id="sdcr-progress-recover" style="display:none;">
                <div class="sdcr-progress-bar"><div class="sdcr-progress-fill"></div></div>
            </div>
            <pre class="sdcr-log" id="sdcr-log-recover"></pre>
            <div id="sdcr-download-link" style="display:none;"></div>
        </div>
    </div>

</div>

<script type="text/javascript" src="<?php echo pluginBaseURL('SDCardRecover'); ?>/js/sdcard-recover.js"></script>
