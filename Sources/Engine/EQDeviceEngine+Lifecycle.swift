// EQDeviceEngine's start-up path: tap/aggregate construction, stream-format
// verification, own-process (PID) translation, and the phase-A/phase-B state
// transitions those drive. `state`'s setter is `private` to EQDeviceEngine.swift
// (`state` is deliberately `private(set)`), so finishStart()/failStart()
// drive transitions through the `transition(to:)` hook defined there instead.

import AudioToolbox
import CoreAudio
import Foundation
import os.log

extension EQDeviceEngine {

    // MARK: - start()

    /// Idempotent. Builds own-PID-excluded global tap → private aggregate (this
    /// engine's target device as main sub-device + tap in the CREATION dict) →
    /// IOProc → start.
    func start(bands: [EQBand]) {
        guard case .running = state else {
            performStart(bands: bands)
            return
        }
        // Already running: the target device is fixed at init and never changes for
        // this instance's lifetime, so just refresh coefficients live (no rebuild).
        update(bands: bands)
    }

    /// Phase A is fully synchronous (translate PID, create tap, create aggregate,
    /// allocate RT state). Phase B (create IOProc + start + state → .running) is deferred
    /// ~0.3 s so the freshly-created aggregate has time to come alive, without blocking
    /// the main thread. Not private: called from rebuild() in EQDeviceEngine+Watchdog.swift.
    func performStart(bands: [EQBand]) {
        currentBands = bands
        do {
            // 1. pid → AudioObjectID so we can exclude ourselves (prevents feedback:
            //    our own rendered output must never be re-captured by the tap). Cached
            //    on the engine so the watchdog can also exclude us.
            ownProcessObjectID = try translateOwnPIDToProcessObject()

            // 2. Global tap, muted-on-tap, excluding our own process plus the two
            //    dynamic exclusion sources (see TapExclusionMonitor.swift for both, and
            //    CoreAudioHelpers.swift for the CoreAudio reads behind them):
            //      - hog-mode holders: a hog holder plays to the device it locked while
            //        macOS re-routes the default output elsewhere, so without the
            //        exclusion this global tap would mute it on that device and re-render
            //        its audio through our aggregate on a different one (foobar2000
            //        exclusive mode on a USB DAC came out of the built-in speakers);
            //      - voice sessions: tapping a process that is in a call moves its call
            //        audio into OUR process, which macOS's VoiceProcessingIO then ducks as
            //        "other audio" — the call ducks itself (WhatsApp, 2026-08-26).
            //    Neither is an optimization; both are observed bugs.
            tapUUID = UUID()
            excludedProcessObjectIDs = Self.tapExcludedProcessObjects(
                own: ownProcessObjectID,
                hoggers: tapService.hoggingProcessObjectIDs(),
                voiceSessions: tapService.voiceSessionProcessObjectIDs())
            let tapDesc = CATapDescription(
                stereoGlobalTapButExcludeProcesses: excludedProcessObjectIDs)
            tapDesc.uuid = tapUUID
            // ADJUDICATED (M1 kill -9 test): .mutedWhenTapped keeps audio playing
            // uninterrupted on a crash — the fail-safe we want. Do NOT switch to
            // iqualize's .muted (needs explicit unmute on teardown; fails the kill -9 rule).
            tapDesc.muteBehavior = .mutedWhenTapped
            tapDesc.name = "eqYourMacbook-EQ-\(deviceUID)"
            // VERIFY ON FIRST MAC BUILD: private tap. ObjC `@property(getter=isPrivate)
            // BOOL privateTap;` → Swift `isPrivate`. Not set (we rely solely on
            // kAudioAggregateDeviceIsPrivateKey below, same as AudioCap/iqualize);
            // enable if a stray Audio-MIDI-Setup entry appears.
            // tapDesc.isPrivate = true

            tapID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(tapService.createProcessTap(tapDesc, &tapID),
                        "Failed to create process tap")

            // 3. Aggregate device with the tap IN THE CREATION DICT (adding the tap
            //    later delivers zero-filled buffers). Main sub-device is this engine's
            //    target device (injected at init), not a hardcoded lookup.
            let aggregateUID = UUID().uuidString
            let aggregateDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "eqYourMacbook-Aggregate-\(deviceUID)",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,   // clock master
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: deviceUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapUUID.uuidString,
                    ],
                ],
            ]

            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(
                tapService.createAggregateDevice(aggregateDesc as CFDictionary, &aggregateDeviceID),
                "Failed to create aggregate device")

            // 3.5. Verify the aggregate delivers what the IOProc assumes (Float32,
            // EQCoefficients.channels channels) — a mismatch would otherwise silently
            // reinterpret bytes as garbage floats via makeIOBlock's
            // `assumingMemoryBound(to: Float.self)`. Fail loudly instead.
            guard let format = tapService.getStreamFormat(aggregateDeviceID) else {
                throw NSError(domain: "eqYourMacbook", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not read aggregate device stream format"
                ])
            }
            let isFloat32PCM = format.mFormatID == kAudioFormatLinearPCM
                && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && format.mBitsPerChannel == 32
            guard isFloat32PCM, format.mChannelsPerFrame == UInt32(EQCoefficients.channels) else {
                throw NSError(domain: "eqYourMacbook", code: -2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unsupported audio format: expected Float32/\(EQCoefficients.channels)ch, got "
                        + "\(format.mBitsPerChannel)-bit/\(format.mChannelsPerFrame)ch "
                        + "(formatID \(format.mFormatID))"
                ])
            }

            // 4. Output nominal sample rate → compute coefficients for it. Read from the
            //    target device rather than assume — a non-built-in device may not be
            //    fixed 48 kHz.
            let rate = tapService.getDeviceNominalSampleRate(deviceID)
            currentSampleRate = rate > 0 ? rate : Self.fallbackSampleRate
            // 4.5. Pin OUR client's IO buffer size on the aggregate (CLAUDE.md § Invariants,
            //    "IO buffer size"). Non-fatal by design: the pin is a tuning of wake-up
            //    rate vs. added latency, not something the EQ depends on, so a HAL that
            //    refuses it must not stop the engine — but it is logged loudly, because
            //    an un-pinned engine is exactly the "works by accident" state the pin exists
            //    to end.
            pinIOBufferFrameSize(sampleRate: currentSampleRate)

            // 5. Pre-allocate ALL RT state (channel-pointer scratch + biquad setup) into
            //    a fresh per-instance context.
            allocateRTScratch()
            installBiquadSetup(for: bands, sampleRate: currentSampleRate)
            rtContext?.channelCount = EQCoefficients.channels
            rtContext?.callbackCounter = 0
            lastWatchdogCounter = 0
            consecutiveSilentChecks = 0
            didRebuildForSilence = false
            consecutiveIdleLatchChecks = 0
            didRebuildForIdleLatch = false
            rtContext?.resetMaxAbsInputAssumingStopped()
        } catch {
            failStart(error)
            return
        }

        // 6. Phase B deferred ~0.3 s. Capture the current generation; if stop()/rebuild
        //    bumps it in the gap, the closure no-ops and leaves the already-allocated
        //    handles for that teardown to release.
        startGeneration &+= 1
        let generation = startGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.startGeneration == generation else { return }
                self.finishStart()
            }
        }
    }

    /// Phase B: create the IOProc, start the device, install timers/observer and
    /// transition to .running. Runs only if the generation token still matches (no
    /// teardown happened in the deferral gap).
    private func finishStart() {
        guard let context = rtContext else {
            failStart(NSError(domain: "eqYourMacbook", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "RT context missing at phase B"
            ]))
            return
        }
        do {
            procID = nil
            try caCheck(
                tapService.createIOProcIDWithBlock(&procID, aggregateDeviceID, nil, makeIOBlock(context: context)),
                "Failed to create IOProc")

            // A/B bypass survives a watchdog rebuild. releaseRTState() zeroed the RT
            // flag, so re-publish it here from the public property (the SSOT) BEFORE
            // starting the device — the IOProc can begin firing the instant
            // startDevice() returns, so publishing after that call leaves a window
            // where the RT thread could read the stale (zeroed) bypass flag and run
            // un-bypassed for one or more callbacks despite isBypassed == true.
            context.bypass = isBypassed ? 1 : 0

            try caCheck(tapService.startDevice(aggregateDeviceID, procID),
                        "Failed to start aggregate device")

            startWatchdog()
            installWakeObserver()
            installTapExclusionMonitor()
            startExclusionBackstop()
            transition(to: .running)
        } catch {
            failStart(error)
        }
    }

    /// Shared failure path: clean up any partial state and surface .failed.
    private func failStart(_ error: Error) {
        teardownCoreAudio()
        releaseRTState()
        let message = (error as NSError).localizedDescription
        os_log(.error, log: engineLog, "start failed: %{public}@", message as NSString)
        transition(to: .failed(message))
    }

    // MARK: - IO buffer size

    /// Wall-clock length of one IO cycle we ask the aggregate for, independent of the
    /// output device's sample rate (a frame count would silently halve the cycle at
    /// 96 kHz). Rounded to the nearest power of two in frames by
    /// `ioBufferFrameSize(targetDuration:sampleRate:range:)`.
    ///
    /// CURRENT VALUE = coreaudiod's usual default (512 frames at 48 kHz ≈ 10.7 ms): this
    /// pins the behavior the app has shipped with so far, so nothing changes until a
    /// measured figure replaces it. Raising it cuts IOProc wake-ups proportionally (the
    /// dominant idle cost of a running engine); the hard ceiling is audio/video sync,
    /// since players cannot compensate for latency they don't know about — keep the
    /// end-to-end added latency reported by `scripts/eqym-ctl.sh latency` under ~45 ms
    /// (ITU-R BT.1359 detectability threshold for late audio). Calls are NOT a
    /// constraint: voice-session processes are excluded from the tap and never pass
    /// through this buffer (CLAUDE.md § Invariants, "Tap exclusions").
    static let ioBufferTargetDuration: TimeInterval = 512.0 / 48_000.0

    /// Pure: the frame count to request for `targetDuration` at `sampleRate` — the power
    /// of two nearest (in log2, i.e. ratio) to the exact frame count, clamped into the
    /// HAL-reported `range` when one is known. Power of two because that is what every
    /// HAL driver is known to grant verbatim; arbitrary counts may be rounded by the
    /// driver in ways the read-back would then have to reconcile.
    nonisolated static func ioBufferFrameSize(targetDuration: TimeInterval, sampleRate: Double,
                                              range: ClosedRange<UInt32>?) -> UInt32 {
        let exact = max(targetDuration * sampleRate, 1)
        let exponent = (log2(exact)).rounded()
        var frames = UInt32(clamping: Int(pow(2.0, exponent)))
        if let range { frames = min(max(frames, range.lowerBound), range.upperBound) }
        return frames
    }

    /// Step 4.5 of performStart(): request the pinned buffer size, read back what the
    /// HAL granted and log both plus the aggregate's reported output latency figures.
    private func pinIOBufferFrameSize(sampleRate: Double) {
        let range = tapService.getBufferFrameSizeRange(aggregateDeviceID)
        let requested = Self.ioBufferFrameSize(targetDuration: Self.ioBufferTargetDuration,
                                               sampleRate: sampleRate, range: range)
        let status = tapService.setBufferFrameSize(aggregateDeviceID, requested)
        let granted = tapService.getBufferFrameSize(aggregateDeviceID)
        ioBufferFrames = granted
        let latency = tapService.getOutputLatencyFrames(aggregateDeviceID)
        let grantedMs = granted.map { Double($0) / sampleRate * 1000 } ?? .nan
        let rangeText = range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "unknown"
        if status != noErr || granted != requested {
            os_log(.error, log: engineLog,
                   "io buffer: requested %u frames, HAL granted %{public}@ (status %d, range %{public}@) — running un-pinned",
                   requested, (granted.map { String($0) } ?? "nil") as NSString, status, rangeText as NSString)
        }
        os_log(.default, log: engineLog,
               "io buffer: %{public}@ frames = %.1f ms @ %.0f Hz (requested %u, range %{public}@); aggregate output latency %u + safety offset %u frames",
               (granted.map { String($0) } ?? "nil") as NSString, grantedMs, sampleRate, requested, rangeText as NSString,
               latency?.latency ?? 0, latency?.safetyOffset ?? 0)
    }

    // MARK: - PID translation

    private func translateOwnPIDToProcessObject() throws -> AudioObjectID {
        try translatePIDToProcessObject(getpid())
    }

    // MARK: - Tap process exclusions

    /// Pure: the exclusion list a tap should be built with, given our own process object,
    /// the current hog-mode holders and the processes currently in a voice session.
    /// Unknown entries are dropped and the result is deduplicated and sorted, so two calls
    /// observing the same processes in a different HAL-returned order compare equal — the
    /// staleness checks in TapExclusionMonitor's callback and rebuild()'s re-check rely on that to
    /// avoid rebuild loops. Our own process object is unioned in unconditionally, so it does
    /// not matter for the LIST that `voiceSessions` may contain us (our aggregate's tap side
    /// is an input stream, so the HAL reports us as duplex once the tap has carried audio).
    /// The classification itself is NOT harmless, though — see the watchdog's idle-latch
    /// path (CLAUDE.md § Invariants, "Idle latch").
    nonisolated static func tapExcludedProcessObjects(
        own: AudioObjectID, hoggers: [AudioObjectID], voiceSessions: [AudioObjectID]
    ) -> [AudioObjectID] {
        var set = Set(hoggers)
        set.formUnion(voiceSessions)
        set.insert(own)
        set.remove(AudioObjectID(kAudioObjectUnknown))
        return set.sorted()
    }

    /// Installs (idempotently) the watcher that keeps the tap's exclusion list current
    /// (hog mode + voice sessions). Rebuilds the whole stack when the live set drifts from
    /// what the running tap was built with — CATapDescription's exclusion list is fixed at
    /// creation time, so there is no cheaper way to change it.
    func installTapExclusionMonitor() {
        tapExclusionMonitor?.start { [weak self] in
            self?.rebuildIfTapExclusionsStale()
        }
    }

    func removeTapExclusionMonitor() {
        tapExclusionMonitor?.stop()
    }

    /// Polling backstop behind the monitor's listeners (see `exclusionBackstopTimer`'s doc
    /// comment): every `exclusionBackstopInterval` re-read the live exclusion set and rebuild
    /// if it moved. The listeners stay the fast path; this bounds the damage when one of
    /// them never fires, which was measured to happen for a process object that appeared
    /// after the monitor started (a Teams call tapped for 291 s, 2026-09-04). The scan is
    /// one device list + three reads per output device, plus one process list + two reads
    /// per audio process; coreaudiod showed 0.0 % with the old 5 s scan in place, so the
    /// interval is chosen for how long a starting call may be tapped, not for cost.
    func startExclusionBackstop() {
        stopExclusionBackstop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + exclusionBackstopInterval, repeating: exclusionBackstopInterval,
                       leeway: .milliseconds(Int(exclusionBackstopInterval * 100)))   // 10 %: 200 ms in production
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.rebuildIfTapExclusionsStale()
            }
        }
        exclusionBackstopTimer = timer
        timer.resume()
    }

    func stopExclusionBackstop() {
        exclusionBackstopTimer?.cancel()
        exclusionBackstopTimer = nil
    }

    /// Shared by the exclusion monitor's callback and rebuild()'s one-shot re-check when
    /// its reentrancy guard clears (which covers a change that arrived while
    /// `rebuildInProgress` was swallowing callbacks). No-ops unless the exclusion set
    /// actually changed. Returns whether a rebuild was requested; note that a request made
    /// while another rebuild is in flight is absorbed by rebuild()'s guard and picked up
    /// by that rebuild's own re-check.
    @discardableResult
    func rebuildIfTapExclusionsStale() -> Bool {
        guard case .running = state else { return false }
        let live = Self.tapExcludedProcessObjects(
            own: ownProcessObjectID,
            hoggers: tapService.hoggingProcessObjectIDs(),
            voiceSessions: tapService.voiceSessionProcessObjectIDs())
        guard live != excludedProcessObjectIDs else { return false }
        os_log(.default, log: engineLog, "tap exclusions changed, rebuilding tap")
        rebuild()
        return true
    }
}
