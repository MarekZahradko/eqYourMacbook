// EQDeviceEngine's start-up path: tap/aggregate construction, stream-format
// verification, own-process (PID) translation, and the phase-A/phase-B state
// transitions those drive. `state`'s setter is `private` to EQDeviceEngine.swift
// (matching docs/CONTRACT.md's `private(set) var state`), so finishStart()/failStart()
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

            // 2. Global tap, muted-on-tap, excluding our own process AND every process
            //    holding exclusive (hog-mode) access to an output device. The latter is
            //    not an optimization: a hog holder plays to the device it locked while
            //    macOS re-routes the default output elsewhere, so without the exclusion
            //    this global tap would mute it on that device and re-render its audio
            //    through our aggregate on a different one (foobar2000 exclusive mode on a
            //    USB DAC came out of the built-in speakers). See HogModeMonitor.swift.
            tapUUID = UUID()
            excludedProcessObjectIDs = Self.tapExcludedProcessObjects(
                own: ownProcessObjectID, hoggers: tapService.hoggingProcessObjectIDs())
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

            // 5. Pre-allocate ALL RT state (channel-pointer scratch + biquad setup) into
            //    a fresh per-instance context.
            allocateRTScratch()
            installBiquadSetup(for: bands, sampleRate: currentSampleRate)
            rtContext?.channelCount = EQCoefficients.channels
            rtContext?.callbackCounter = 0
            lastWatchdogCounter = 0
            consecutiveSilentChecks = 0
            didRebuildForSilence = false
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
            installHogModeMonitor()
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

    // MARK: - PID translation

    private func translateOwnPIDToProcessObject() throws -> AudioObjectID {
        try translatePIDToProcessObject(getpid())
    }

    // MARK: - Tap process exclusions

    /// Pure: the exclusion list a tap should be built with, given our own process object
    /// and the current hog-mode holders. Unknown entries are dropped and the result is
    /// deduplicated and sorted, so two calls observing the same processes in a different
    /// HAL-returned order compare equal — the staleness checks in HogModeMonitor's
    /// callback and the watchdog rely on that to avoid rebuild loops.
    nonisolated static func tapExcludedProcessObjects(
        own: AudioObjectID, hoggers: [AudioObjectID]
    ) -> [AudioObjectID] {
        var set = Set(hoggers)
        set.insert(own)
        set.remove(AudioObjectID(kAudioObjectUnknown))
        return set.sorted()
    }

    /// Installs (idempotently) the hog-mode watcher that keeps the tap's exclusion list
    /// current. Rebuilds the whole stack when the live set drifts from what the running
    /// tap was built with — CATapDescription's exclusion list is fixed at creation time,
    /// so there is no cheaper way to change it.
    func installHogModeMonitor() {
        hogModeMonitor?.start { [weak self] in
            self?.rebuildIfTapExclusionsStale()
        }
    }

    func removeHogModeMonitor() {
        hogModeMonitor?.stop()
    }

    /// Shared by the hog-mode monitor's callback and the watchdog's 5 s backstop tick
    /// (which covers a change that arrives while `rebuildInProgress` is swallowing
    /// callbacks). No-ops unless the exclusion set actually changed.
    /// Returns whether a rebuild was actually started, so the watchdog can skip the rest
    /// of a tick whose RT state has just been replaced underneath it.
    @discardableResult
    func rebuildIfTapExclusionsStale() -> Bool {
        guard case .running = state else { return false }
        let live = Self.tapExcludedProcessObjects(
            own: ownProcessObjectID, hoggers: tapService.hoggingProcessObjectIDs())
        guard live != excludedProcessObjectIDs else { return false }
        os_log(.default, log: engineLog, "hog-mode exclusions changed, rebuilding tap")
        rebuild()
        return true
    }
}
