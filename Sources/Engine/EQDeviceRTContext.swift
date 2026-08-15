// RT (real-time, audio-thread) state for ONE device's EQDeviceEngine.
//
// Each EQDeviceEngine owns its own instance and its own IOProc block (built by
// `makeIOBlock`, see EQIOProcFactory.swift), since N devices can run simultaneously,
// each with its own aggregate/tap/IOProc.
//
// MUST be a class: held (indirectly) in OutputDeviceEQCoordinator's
// `[AudioObjectID: EQDeviceEngine]` dictionary, and the IOProc block captures it
// directly. A struct could be copied/relocated by a dictionary resize, invalidating
// any pointer a concurrently-running IOProc holds; a class's storage never moves.
//
// RT rules for everything reached from the IOProc block: NO allocation, NO locks, NO
// logging, NO Objective-C / Swift runtime calls — plain C math and memcpy only. This
// class is intentionally not an actor/@MainActor: it's written from the main actor
// only while stopped, and read/written from the RT thread only while running
// (EQDeviceEngine's stop() tears down Core Audio *before* releasing the context).

import Accelerate
import AudioToolbox
import CoreAudio

final class EQDeviceRTContext {

    /// vDSP biquad setup pointer (created on the main actor, read on the RT thread).
    /// Written only while the device is stopped, read only while running → no tearing
    /// of a live setup. `OpaquePointer` because vDSP_biquadm_Setup is opaque.
    var biquadSetup: vDSP_biquadm_Setup?

    /// Channel count the setup was built for (2). Read-only during a run.
    var channelCount: Int = EQCoefficients.channels

    /// Section count the setup was built for (EQCoefficients.maxSections = 16).
    /// Read-only during a run; needed by the RT-thread SetTargetsDouble call.
    var maxSections: Int = EQCoefficients.maxSections

    /// Scratch channel-pointer arrays for vDSP_biquadm. Pre-allocated at start() so the
    /// callback never allocates. Element type is NON-Optional (seeded with a sentinel):
    /// casting Optional<UnsafePointer<Float>> via withMemoryRebound is UB per Swift's
    /// pointer-rebinding contract, so we hold the exact type vDSP wants directly.
    var inputPtrs: UnsafeMutablePointer<UnsafePointer<Float>>?
    var outputPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?

    /// A/B bypass flag. Aligned Int32 so loads/stores are single-instruction atomic on
    /// ARM64; we only need publication of a flag flip, not a full fence — a one-callback
    /// delay is inaudible.
    var bypass: Int32 = 0

    /// Live-coefficient handoff. SetTargetsDouble on the main thread while vDSP_biquadm
    /// reads the same setup on the RT thread is documented-unsafe, so the update is
    /// instead applied FROM the RT thread, in the same callback that runs vDSP_biquadm —
    /// exactly one writer of the setup's target state, never racing the process call.
    ///
    /// Protocol:
    ///   - Main thread writes new coefficients into `pendingCoeffs` only when
    ///     `pendingFlag == 0`, then sets `pendingFlag = 1` (publish).
    ///   - IOProc, at callback start, checks `pendingFlag`; if 1, calls SetTargetsDouble
    ///     from the RT thread, then sets `pendingFlag = 0` (consume).
    ///   - If main finds the flag still 1 (RT hasn't consumed yet — rare), it stashes the
    ///     latest bands and retries on the next coalesce tick.
    /// Buffer capacity is the full pre-allocated 5 * channels * maxSections doubles.
    ///
    /// VERIFY ON FIRST MAC BUILD: vDSP_biquadm_SetTargetsDouble must not allocate (Apple
    /// documents it as the live-ramp path). If profiling shows it allocates, fall back to
    /// double-buffered-setup + atomic-pointer-swap (PLAN.md §DSP).
    var pendingCoeffs: UnsafeMutablePointer<Double>?
    var pendingFlag: Int32 = 0

    /// Watchdog telemetry. Counter advances every callback; maxAbs is the loudest input
    /// sample seen since the watchdog last reset it (running max, so a brief transient
    /// between checks isn't masked by a quiet final callback). Read on the main actor.
    var callbackCounter: Int64 = 0
    var maxAbsInput: Float = 0

    /// Sentinel sample backing the non-Optional scratch pointer arrays: a valid address
    /// until the IOProc overwrites all channel slots with real buffer pointers each callback.
    static let sentinelSample: UnsafePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafePointer(p)
    }()
    static let sentinelSampleMutable: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()
}
