// Adapted in part from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
// Tap/aggregate/PID-exclusion construction follows iQualize's proven code closely
// (AudioEngine.swift:186–271); the DSP path is ours: we process directly in the
// aggregate device's IOProc with vDSP_biquadm — no ring buffer, no AVAudioEngine.

import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os.log

let engineLog = OSLog(subsystem: "com.zdenekkops.eqyourmacbook", category: "engine")

// MARK: - Engine state & delegate (SSOT: docs/CONTRACT.md)

enum EngineState: Equatable {
    case stopped              // no tap, zero footprint
    case running              // tap + aggregate + IOProc active, EQ applied
    case failed(String)       // last start() attempt failed
}

@MainActor protocol EQDeviceEngineDelegate: AnyObject {
    func engine(_ engine: EQDeviceEngine, didChangeState state: EngineState)
    // Watchdog rebuilt once and input is still all-zero → TCC denial likely.
    func engineSuspectsPermissionDenied(_ engine: EQDeviceEngine)
}

// MARK: - EQDeviceEngine
//
// One instance per enabled output device (OutputDeviceEQCoordinator owns the set).
// RT state the IOProc touches lives in a per-instance `EQDeviceRTContext`
// (see EQDeviceRTContext.swift).
//
// NOTE: the tap is a `stereoGlobalTapButExcludeProcesses` GLOBAL tap — it captures
// ALL system audio (minus this app's own process), not audio specific to this device.
// So with N devices enabled, N taps all see the same source signal, each independently
// EQ'd and routed to its own aggregate/IOProc. Intentional: the product is "apply this
// app's EQ to this output," not per-device source routing.
//
// Split across files: core lifecycle here; RT-scratch/biquad-setup lifecycle in
// EQDeviceEngine+RTState.swift; watchdog in EQDeviceEngine+Watchdog.swift;
// sleep/wake in EQDeviceEngine+SleepWake.swift. Extensions can't hold stored
// properties, so all state lives here even though some of it is only touched from
// the extension files (hence several properties are `internal` rather than `private`).
@MainActor final class EQDeviceEngine {

    weak var delegate: EQDeviceEngineDelegate?
    private(set) var state: EngineState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.engine(self, didChangeState: state)
        }
    }

    // Target device, injected by the coordinator — the caller decides which device
    // this instance EQs.
    let deviceID: AudioObjectID
    let deviceUID: String
    let deviceName: String

    private let tapService: CoreAudioTapServicing

    // Core Audio handles owned by the engine.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    // Our own process object (translated from getpid() at phase-A start). Cached so the
    // watchdog can exclude us when checking whether OTHER processes output audio.
    // Touched by EQDeviceEngine+Watchdog.swift → internal.
    var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)

    // Last bands and the sample rate the current setup was built for — needed to
    // rebuild coefficients on update() and to rebuild the whole stack on watchdog.
    // currentBands is read by rebuild() in EQDeviceEngine+Watchdog.swift → internal.
    var currentBands: [EQBand] = []
    private var currentSampleRate: Double = 48_000

    // Per-instance RT-shared state. Allocated in allocateRTScratch()/performStart(),
    // released in releaseRTState(). Non-nil only while a run is at least partially
    // built; guaranteed non-nil while `.running`. Touched from
    // EQDeviceEngine+RTState.swift → internal.
    var rtContext: EQDeviceRTContext?

    // Deferred phase-B start guard. Phase B fires ~0.3 s after phase A via asyncAfter;
    // it captures `startGeneration` at schedule time and only runs if it still matches
    // at fire time, so a teardown in the gap cancels a stale phase B (no polling).
    // Touched by rebuild() in EQDeviceEngine+Watchdog.swift → internal.
    var startGeneration = 0

    // Reentrancy guard for rebuild(); also blocks a second wake notification from
    // racing the first into a double rebuild. Touched by EQDeviceEngine+Watchdog.swift.
    var rebuildInProgress = false

    // Coalescing of update(bands:). Sliders fire ~60 Hz; store the latest bands and
    // apply at most once per ~50 ms (latest-wins). `coalesceScheduled` guards against
    // scheduling more than one pending apply.
    private static let coalesceInterval: TimeInterval = 0.050
    private var pendingUpdateBands: [EQBand]?
    private var coalesceScheduled = false

    // Did the watchdog raise a permission-suspected condition? When audio returns
    // (maxAbs > 0) we clear it and re-notify the controller with .running.
    // Touched only from EQDeviceEngine+Watchdog.swift → internal.
    var permissionSuspected = false

    // Watchdog. Touched only from EQDeviceEngine+Watchdog.swift → internal.
    var watchdogTimer: DispatchSourceTimer?
    var lastWatchdogCounter: Int64 = 0
    var consecutiveSilentChecks = 0
    var didRebuildForSilence = false

    // Sleep/wake. Touched only from EQDeviceEngine+SleepWake.swift → internal.
    var wakeObserver: NSObjectProtocol?

    init(deviceID: AudioObjectID, deviceUID: String, deviceName: String,
         tapService: CoreAudioTapServicing = LiveCoreAudioTapService()) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.tapService = tapService
    }

    deinit {
        // nonisolated; timer/observer are torn down in stop(), called by the
        // controller before releasing the engine.
    }

    // MARK: - isBypassed (RT-read atomic flag)

    /// Main-actor SSOT for the bypass intent. The RT flag (rtContext.bypass) mirrors it
    /// but is zeroed by releaseRTState() on every teardown/rebuild; this stored value
    /// survives, so finishStart() can re-publish it.
    private var bypassIntent = false

    var isBypassed: Bool {
        // Read/write of a naturally-aligned Int32 is atomic on ARM64; we only need
        // the RT thread to eventually observe the flip, not a full barrier.
        get { bypassIntent }
        set {
            bypassIntent = newValue
            rtContext?.bypass = newValue ? 1 : 0
        }
    }

    // MARK: - Gain-staging

    /// Auto-compensation for positive band gain: attenuates the overall output by the
    /// largest positive non-muted band gain, so a boosted band can't clip. Never boosts;
    /// disabled → no compensation at all. Recomputed via the normal coalesced update path
    /// (masterGainDB(for:enabled:) is read at every installBiquadSetup/flushPendingUpdate
    /// call), so flipping this just needs a coefficient recompute, not a restart.
    var gainStagingEnabled: Bool = true {
        didSet {
            guard oldValue != gainStagingEnabled, case .running = state else { return }
            pendingUpdateBands = currentBands
            scheduleCoalescedApply()
        }
    }

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
    /// allocate RT state). Phase B (create IOProc + start + state → .running) is
    /// deferred ~0.3 s so the freshly-created aggregate has time to come alive,
    /// without blocking the main thread.
    ///
    /// Not private: called from rebuild() in EQDeviceEngine+Watchdog.swift.
    func performStart(bands: [EQBand]) {
        currentBands = bands
        do {
            // 1. pid → AudioObjectID so we can exclude ourselves (prevents feedback:
            //    our own rendered output must never be re-captured by the tap). Cached
            //    on the engine so the watchdog can also exclude us.
            ownProcessObjectID = try translateOwnPIDToProcessObject()

            // 2. Global tap, our process excluded, muted-on-tap.
            tapUUID = UUID()
            let excludeProcesses: [AudioObjectID] = ownProcessObjectID != kAudioObjectUnknown
                ? [ownProcessObjectID] : []
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
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
            guard let format = getStreamFormat(aggregateDeviceID) else {
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
            let rate = getDeviceNominalSampleRate(deviceID)
            currentSampleRate = rate > 0 ? rate : 48_000

            // 5. Pre-allocate ALL RT state (channel-pointer scratch + biquad setup) into
            //    a fresh per-instance context.
            allocateRTScratch()
            installBiquadSetup(for: bands, sampleRate: currentSampleRate)
            rtContext?.channelCount = EQCoefficients.channels
            rtContext?.callbackCounter = 0
            lastWatchdogCounter = 0
            consecutiveSilentChecks = 0
            didRebuildForSilence = false
            rtContext?.maxAbsInput = 0
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
            try caCheck(tapService.startDevice(aggregateDeviceID, procID),
                        "Failed to start aggregate device")

            // A/B bypass survives a watchdog rebuild. releaseRTState() zeroed the RT
            // flag, so re-publish it here from the public property (the SSOT).
            context.bypass = isBypassed ? 1 : 0

            startWatchdog()
            installWakeObserver()
            state = .running
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
        state = .failed(message)
    }

    // MARK: - update() — live coefficient swap (no restart, no glitch)

    /// Live coefficient swap. CONTRACT allows the engine to coalesce; sliders fire
    /// ~60 Hz, so we store the latest bands (latest-wins) and apply at most once every
    /// ~50 ms. The actual apply hands the new coefficients to the RT thread, which calls
    /// SetTargetsDouble itself (see flushPendingUpdate / makeIOBlock), so the setup's
    /// target state has exactly one writer and never races vDSP_biquadm. RT thread
    /// never blocks on this.
    func update(bands: [EQBand]) {
        currentBands = bands
        pendingUpdateBands = bands
        guard case .running = state else { return }
        scheduleCoalescedApply()
    }

    /// Schedule a single coalesced apply ~50 ms out (latest-wins). Guarded so at most
    /// one apply is in flight; the apply reads `pendingUpdateBands` at fire time.
    private func scheduleCoalescedApply() {
        guard !coalesceScheduled else { return }
        coalesceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coalesceScheduled = false
                self.flushPendingUpdate()
            }
        }
    }

    /// Apply the latest pending bands by writing targets into the RT handoff buffer.
    ///
    /// Only writes when the RT thread has consumed the previous update
    /// (`pendingFlag == 0`). If not (rare — the ~50 ms coalesce window is far longer
    /// than an IO callback period), keep `pendingUpdateBands` and reschedule so the
    /// latest value still lands on the next tick.
    private func flushPendingUpdate() {
        guard case .running = state, let bands = pendingUpdateBands,
              let context = rtContext, let pending = context.pendingCoeffs else { return }

        // RT hasn't drained the previous update yet → retry on the next coalesce tick
        // (keep pendingUpdateBands so the latest value wins).
        guard context.pendingFlag == 0 else {
            scheduleCoalescedApply()
            return
        }

        let coeffs = EQCoefficients.sectionCoefficients(
            for: bands, sampleRate: currentSampleRate,
            masterGainDB: EQCoefficients.masterGainDB(for: bands, enabled: gainStagingEnabled))
        let count = min(coeffs.count, 5 * EQCoefficients.channels * EQCoefficients.maxSections)
        coeffs.withUnsafeBufferPointer { src in
            pending.update(from: src.baseAddress!, count: count)
        }
        pendingUpdateBands = nil
        // Publish: RT will pick this up at the start of its next callback.
        context.pendingFlag = 1
    }

    // MARK: - stop() — strict teardown order (CONTRACT.md)

    /// Idempotent. AudioDeviceStop → AudioDeviceDestroyIOProcID →
    /// AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap →
    /// only THEN release RT buffers/setup (fixes iqualize's nil-while-running race).
    func stop() {
        let wasRunning: Bool = { if case .running = state { return true }; return false }()

        // Bump the generation so any pending phase-B closure scheduled by a performStart
        // still in its 0.3 s deferral gap no-ops when it fires.
        startGeneration &+= 1
        // Drop any coalesced update intent (a stale apply must not fire post-stop). Also
        // clear the schedule flag: a stop→start within the 50 ms coalesce window must
        // not make the next update() skip scheduling (latest-wins guarantee).
        pendingUpdateBands = nil
        coalesceScheduled = false

        // Idempotent: always tear down in strict order regardless of state, so a
        // .failed start with half-built handles also gets fully cleaned.
        stopWatchdog()
        removeWakeObserver()
        teardownCoreAudio()
        releaseRTState()

        // Only transition to .stopped from .running; a prior .failed stays .failed
        // (it carries the last error message the UI shows) until the next start().
        if wasRunning { state = .stopped }
    }

    /// Core Audio teardown in strict order. Safe to call with partial state.
    /// Not private: called from rebuild() in EQDeviceEngine+Watchdog.swift.
    func teardownCoreAudio() {
        if aggregateDeviceID != kAudioObjectUnknown, procID != nil {
            _ = tapService.stopDevice(aggregateDeviceID, procID)
        }
        if let procID, aggregateDeviceID != kAudioObjectUnknown {
            _ = tapService.destroyIOProcID(aggregateDeviceID, procID)
        }
        procID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = tapService.destroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = tapService.destroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - PID translation

    private func translateOwnPIDToProcessObject() throws -> AudioObjectID {
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var myPID = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try caCheck(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &translateAddress,
                UInt32(MemoryLayout<pid_t>.size), &myPID,
                &size, &processObjectID),
            "Failed to translate PID to process object")
        return processObjectID
    }
}
