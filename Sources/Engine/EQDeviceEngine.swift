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

    // Shared, short-TTL-cached answer to "is any OTHER process outputting audio right
    // now?", consulted by every engine's watchdog tick (see EQDeviceEngine+Watchdog.swift).
    // All engines would otherwise compute the IDENTICAL CoreAudio answer independently on
    // their own 5 s timers, so the delegate (one OutputDeviceEQCoordinator fanning out to
    // every engine) memoizes it for a short window instead — same semantics as the free
    // function `anyOtherProcessOutputtingAudio(excluding:)` in CoreAudioHelpers.swift,
    // which this should defer to on a cache miss.
    func anyOtherProcessOutputtingAudio(excluding processObjectID: AudioObjectID) -> Bool
}

// MARK: - EQDeviceEngine
//
// One instance per enabled output device (OutputDeviceEQCoordinator owns the set).
// RT state the IOProc touches lives in a per-instance `EQDeviceRTContext`
// (see EQDeviceRTContext.swift).
//
// NOTE: the tap is a `stereoGlobalTapButExcludeProcesses` GLOBAL tap — it captures ALL
// system audio (minus this app's own process), not audio specific to this device. So with
// N devices enabled, N taps all see the same source signal, each independently EQ'd and
// routed to its own aggregate/IOProc. Intentional: the product is "apply this app's EQ to
// this output," not per-device source routing.
//
// Split across files: stored state, init, stop()/teardown here; start-up in
// EQDeviceEngine+Lifecycle.swift; live coefficient updates/coalescing/bypass in
// EQDeviceEngine+LiveUpdate.swift; RT-scratch/biquad-setup lifecycle in
// EQDeviceEngine+RTState.swift; watchdog in EQDeviceEngine+Watchdog.swift; sleep/wake in
// EQDeviceEngine+SleepWake.swift. Extensions can't hold stored properties, so all state
// lives here even though some of it is only touched from extension files (hence several
// properties are `internal` rather than `private`, and `state`'s own transitions from
// other files go through the `transition(to:)` hook below rather than widening its
// `private(set)` setter beyond this file).
@MainActor final class EQDeviceEngine {

    weak var delegate: EQDeviceEngineDelegate?
    private(set) var state: EngineState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.engine(self, didChangeState: state)
        }
    }

    /// State-transition hook for the extension files: `state`'s setter is `private`
    /// (matching docs/CONTRACT.md's `private(set) var state`, satisfiable only from
    /// same-file extensions), so EQDeviceEngine+Lifecycle.swift's finishStart()/
    /// failStart() would otherwise have no way to drive a transition. Kept `internal`
    /// like the rest of the cross-file-touched surface in this class.
    func transition(to newState: EngineState) {
        state = newState
    }

    // Target device, injected by the coordinator — the caller decides which device
    // this instance EQs.
    let deviceID: AudioObjectID
    let deviceUID: String
    let deviceName: String

    // Touched by EQDeviceEngine+Lifecycle.swift (performStart/finishStart) → internal.
    let tapService: CoreAudioTapServicing

    // Core Audio handles owned by the engine. Set/read from
    // EQDeviceEngine+Lifecycle.swift (performStart/finishStart) and from
    // teardownCoreAudio() below → internal.
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var tapUUID = UUID()

    // Our own process object (translated from getpid() at phase-A start). Cached so the
    // watchdog can exclude us when checking whether OTHER processes output audio.
    // Touched by EQDeviceEngine+Watchdog.swift → internal.
    var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)

    // Last bands and the sample rate the current setup was built for — needed to
    // rebuild coefficients on update() and to rebuild the whole stack on watchdog.
    // currentBands is read by rebuild() in EQDeviceEngine+Watchdog.swift → internal.
    var currentBands: [EQBand] = []
    // Fallback used both as the initial value below and when the device read in
    // performStart() fails/returns 0; kept as one named constant rather than two
    // independent literals. Unrelated to EQCurveView.UIConstants.referenceSampleRate, a
    // deliberately-decoupled UI-only approximation (see its own comment). Both read from
    // EQDeviceEngine+Lifecycle.swift's performStart() and EQDeviceEngine+LiveUpdate.swift's
    // flushPendingUpdate() → internal.
    static let fallbackSampleRate: Double = 48_000
    var currentSampleRate: Double = EQDeviceEngine.fallbackSampleRate

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

    // Coalescing of update(bands:). Sliders fire ~60 Hz; store the latest bands and apply
    // at most once per ~50 ms (latest-wins). `coalesceScheduled` guards against scheduling
    // more than one pending apply. Both vars are also written from gainStagingEnabled's
    // didSet below (a stored property, so it can't move to EQDeviceEngine+LiveUpdate.swift)
    // as well as from that extension file itself → internal.
    static let coalesceInterval: TimeInterval = 0.050
    var pendingUpdateBands: [EQBand]?
    var coalesceScheduled = false

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

    /// Main-actor SSOT for the bypass intent. The RT flag (rtContext.bypass) mirrors it but
    /// is zeroed by releaseRTState() on every teardown/rebuild; this stored value survives,
    /// so finishStart() can re-publish it. The `isBypassed` computed property wrapping this
    /// lives in EQDeviceEngine+LiveUpdate.swift, free to move even though its backing store
    /// can't → internal.
    var bypassIntent = false

    // MARK: - Gain-staging

    /// Auto-compensation for positive band gain: attenuates the overall output by the
    /// largest positive non-muted band gain, so a boosted band can't clip; never boosts,
    /// and disabled means no compensation at all. Recomputed via the normal coalesced
    /// update path (masterGainDB(for:enabled:) is read at every installBiquadSetup/
    /// flushPendingUpdate call), so flipping this just needs a coefficient recompute, not
    /// a restart. Stays a stored property here (extensions can't hold stored properties)
    /// even though its didSet drives EQDeviceEngine+LiveUpdate.swift's coalescing machinery.
    var gainStagingEnabled: Bool = true {
        didSet {
            guard oldValue != gainStagingEnabled, case .running = state else { return }
            pendingUpdateBands = currentBands
            scheduleCoalescedApply()
        }
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
}
