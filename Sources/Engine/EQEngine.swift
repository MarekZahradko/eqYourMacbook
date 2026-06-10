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

private let engineLog = OSLog(subsystem: "com.zdenekkops.eqyourmacbook", category: "engine")

// MARK: - Engine state & delegate (SSOT: docs/CONTRACT.md)

enum EngineState: Equatable {
    case stopped              // no tap, zero footprint
    case running              // tap + aggregate + IOProc active, EQ applied
    case failed(String)       // last start() attempt failed
}

enum OutputRoute: Equatable {
    case builtInSpeakers(AudioObjectID)
    case other(String)        // human-readable device name
}

@MainActor protocol EQEngineDelegate: AnyObject {
    func engine(_ engine: EQEngine, didChangeState state: EngineState)
    // Watchdog rebuilt once and input is still all-zero → TCC denial likely.
    func engineSuspectsPermissionDenied(_ engine: EQEngine)
}

// MARK: - Real-time shared state (free-function IOProc, no actor isolation)
//
// The IOProc runs on Core Audio's real-time thread. Under Swift's concurrency
// model a closure that captures `self` (a @MainActor class) inserts isolation
// checks that crash off the main actor, so all state the callback touches lives
// in file-private `nonisolated(unsafe)` globals — the exact pattern iqualize and
// the TapsSpike use. There is a single EQEngine instance (the app's one engine),
// so a single set of globals is correct. Lifetime is managed by start()/stop():
// stop() tears down Core Audio *before* clearing these, so no callback can run
// against a half-released setup.
//
// RT rules for everything reached from the IOProc: NO allocation, NO locks, NO
// logging, NO Objective-C / Swift runtime calls. Only plain C math and memcpy.

/// vDSP biquad setup pointer (created on the main actor, read on the RT thread).
/// Written only while the device is stopped, read only while running → no tearing
/// of a live setup. `OpaquePointer` because vDSP_biquadm_Setup is opaque.
private nonisolated(unsafe) var rtBiquadSetup: vDSP_biquadm_Setup?

/// Channel count the setup was built for (2). Read-only during a run.
private nonisolated(unsafe) var rtChannelCount: Int = 2

/// Section count the setup was built for (EQEngine.maxSections = 16). Read-only
/// during a run; needed by the RT-thread SetTargetsDouble call (FIX 2), which can't
/// reach the @MainActor static.
private nonisolated(unsafe) var rtMaxSections: Int = 16

/// Scratch channel-pointer arrays for vDSP_biquadm. Pre-allocated at start() for
/// the fixed channel count so the callback never allocates. Capacity = channels.
/// Element type is NON-Optional (initialized to a sentinel at allocation): casting
/// Optional<UnsafePointer<Float>> to UnsafePointer<Float> via withMemoryRebound is
/// UB per Swift's pointer-rebinding contract, so we hold the exact type vDSP wants
/// and pass these arrays straight through with no rebind.
private nonisolated(unsafe) var rtInputPtrs: UnsafeMutablePointer<UnsafePointer<Float>>?
private nonisolated(unsafe) var rtOutputPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?

/// A/B bypass flag. Aligned Int32 so loads/stores are single-instruction atomic on
/// ARM64 (naturally-aligned word access is atomic on Apple Silicon); we only need
/// publication of a flag flip, not a full fence — a one-callback delay is inaudible.
private nonisolated(unsafe) var rtBypass = Int32(0)

/// Live-coefficient handoff (FIX 2). The data race was: SetTargetsDouble was called
/// on the MAIN thread while vDSP_biquadm read the same setup on the RT thread —
/// documented-unsafe. Adjudicated design: apply the update FROM the RT thread, in
/// the same callback that runs vDSP_biquadm, so there is exactly one writer of the
/// setup's target state and it never races the process call.
///
/// Protocol:
///   - Main thread (update path) writes the new coefficients into `rtPendingCoeffs`
///     ONLY when `rtPendingFlag == 0`, then sets `rtPendingFlag = 1` (publish).
///   - The IOProc, at callback start, checks `rtPendingFlag`; if 1 it calls
///     SetTargetsDouble from the RT thread, then sets `rtPendingFlag = 0` (consume).
///   - If main finds the flag still 1 (RT hasn't consumed — rare given the ~50 ms
///     coalescing), it stashes the latest bands and retries on the next coalesce tick.
/// The flag is an aligned Int32 (same atomic-word pattern as rtBypass): a one-callback
/// publish/consume delay is inaudible and we only need flag-flip visibility, not a fence.
/// Buffer capacity is the full pre-allocated 5 * channels * maxSections doubles.
///
/// ASSUMPTION (M3 on-device verification item): vDSP_biquadm_SetTargetsDouble does
/// not allocate. Apple documents it as the live-ramp path and it writes only into the
/// setup's per-section target/ramp fields; if profiling on the Mac shows it allocates,
/// fall back to the double-buffered-setup + atomic-pointer-swap approach (PLAN.md §DSP).
private nonisolated(unsafe) var rtPendingCoeffs: UnsafeMutablePointer<Double>?
private nonisolated(unsafe) var rtPendingFlag = Int32(0)

/// Watchdog telemetry. The counter advances every callback; maxAbs is the loudest
/// input sample seen SINCE the watchdog last reset it (running max — FIX 10), so a
/// brief loud transient between two 5 s checks is never lost to a quiet last callback.
/// Both are read on the main actor by the watchdog timer. Int64/Float32 word accesses
/// are atomic enough for "is it advancing / is it zero" — exact values don't matter.
private nonisolated(unsafe) var rtCallbackCounter: Int64 = 0
private nonisolated(unsafe) var rtMaxAbsInput: Float = 0

/// IOProc block. Free closure capturing nothing actor-isolated. Reads tap input,
/// runs the biquad cascade, writes speaker output. Defensive about buffer layout.
private let rtIOBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
    let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

    // --- FIX 2: consume a pending live-coefficient update from THIS (RT) thread, at
    // callback start, before vDSP_biquadm reads the setup. Same thread as the process
    // call → no race with the main-thread writer (which only writes when flag == 0).
    if rtPendingFlag != 0, let setup = rtBiquadSetup, let pending = rtPendingCoeffs {
        vDSP_biquadm_SetTargetsDouble(setup,
                                      pending,
                                      0.005,                          // interp rate (per-sample step toward target)
                                      0.0001,                         // interp threshold (|Δ| considered "reached")
                                      0,                              // start_sec
                                      0,                              // start_chn
                                      vDSP_Length(rtMaxSections),     // nsec
                                      vDSP_Length(rtChannelCount))    // nchn
        rtPendingFlag = 0   // publish consumption so main may write the next update
    }

    // --- FIX 8: with no output buffers there is nothing to render into. Return early;
    // never alias the INPUT buffer as output (that would write into the tap's memory).
    guard outList.count > 0 else { return }

    // --- Read input defensively. Two observed layouts:
    //   (a) one interleaved stereo buffer: mNumberChannels == 2, samples L R L R …
    //   (b) per-channel (deinterleaved) buffers: N buffers, mNumberChannels == 1.
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

    // If there is no input at all, zero the output and bail (silence, not garbage).
    guard inList.count > 0, let firstIn = inList[0].mData else {
        for buf in outList {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        return
    }

    let channels = rtChannelCount
    let inChannelsFirstBuffer = Int(inList[0].mNumberChannels)
    let interleaved = inList.count == 1 && inChannelsFirstBuffer >= channels

    // Frame count from the *output* buffer (what the device wants us to fill).
    let outBuffer0 = outList[0]
    let outInterleaved = outList.count == 1 && Int(outBuffer0.mNumberChannels) >= channels
    let outBytesPerFrame = outInterleaved
        ? channels * MemoryLayout<Float>.size
        : MemoryLayout<Float>.size
    let outFrames = Int(outBuffer0.mDataByteSize) / outBytesPerFrame

    // Frames available in the input's channel-0 buffer (same units as outFrames).
    let inBytesPerFrame = interleaved
        ? inChannelsFirstBuffer * MemoryLayout<Float>.size
        : MemoryLayout<Float>.size
    let inFrames = Int(inList[0].mDataByteSize) / max(inBytesPerFrame, MemoryLayout<Float>.size)

    // A clock-synchronized aggregate delivers equal counts; clamp anyway so vDSP
    // never over-reads input or over-writes output if they ever disagree.
    let frames = min(outFrames, inFrames)

    guard frames > 0 else {
        for buf in outList {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        return
    }

    // --- Watchdog telemetry: max-abs of the input (channel 0 buffer is enough as a
    // liveness probe). vDSP_maxmgv is allocation-free. FIX 10: keep a RUNNING max so
    // a transient between watchdog ticks isn't masked by a quiet final callback; the
    // single RT writer reads-and-keeps-greater, the watchdog reads then resets to 0.
    var maxAbs: Float = 0
    let probeCount = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
    if probeCount > 0 {
        vDSP_maxmgv(firstIn.assumingMemoryBound(to: Float.self), 1, &maxAbs, vDSP_Length(probeCount))
    }
    if maxAbs > rtMaxAbsInput { rtMaxAbsInput = maxAbs }
    rtCallbackCounter = rtCallbackCounter &+ 1

    // --- Build channel pointer arrays for input and output (pre-allocated scratch).
    guard let inPtrs = rtInputPtrs, let outPtrs = rtOutputPtrs else {
        // No scratch (shouldn't happen while running) → passthrough copy.
        copyInputToOutput(inList: inList, outList: outList)
        return
    }

    // Input pointers + per-channel stride. Slots are non-Optional (FIX 9); they hold
    // a sentinel until written here every callback before any read by vDSP.
    let inStride: vDSP_Stride
    if interleaved {
        let base = firstIn.assumingMemoryBound(to: Float.self)
        for c in 0..<channels { inPtrs[c] = UnsafePointer(base + c) }
        inStride = vDSP_Stride(inChannelsFirstBuffer)
    } else {
        // Per-channel buffers: clamp to available, replicate last for any shortfall.
        for c in 0..<channels {
            let srcIdx = min(c, inList.count - 1)
            if let d = inList[srcIdx].mData {
                inPtrs[c] = UnsafePointer(d.assumingMemoryBound(to: Float.self))
            } else {
                inPtrs[c] = UnsafePointer(firstIn.assumingMemoryBound(to: Float.self))
            }
        }
        inStride = 1
    }

    // Output pointers + per-channel stride. Every channel slot MUST end up valid for
    // vDSP to write into; if we can't satisfy that, fall back to a plain copy below.
    let outStride: vDSP_Stride
    var outPtrsValid = true
    if outInterleaved, let d = outBuffer0.mData {
        let base = d.assumingMemoryBound(to: Float.self)
        for c in 0..<channels { outPtrs[c] = base + c }
        outStride = vDSP_Stride(Int(outBuffer0.mNumberChannels))
    } else {
        for c in 0..<channels {
            if c < outList.count, let d = outList[c].mData {
                outPtrs[c] = d.assumingMemoryBound(to: Float.self)
            } else {
                outPtrsValid = false
            }
        }
        outStride = 1
    }

    // --- Bypass: identity copy via memcpy (RT-safe), honor the atomic flag.
    if rtBypass != 0 {
        copyInputToOutput(inList: inList, outList: outList)
        return
    }

    // --- Apply the biquad cascade. vDSP_biquadm processes all N channels with one
    // shared section set, separate delay state per channel. inputs/outputs are
    // arrays of N channel base pointers; strides handle interleaving. The scratch
    // arrays already hold the exact non-Optional pointer types vDSP wants (FIX 9) —
    // pass them straight through, no rebind.
    guard let setup = rtBiquadSetup, outPtrsValid else {
        copyInputToOutput(inList: inList, outList: outList)
        return
    }

    vDSP_biquadm(setup,
                 inPtrs, inStride,
                 outPtrs, outStride,
                 vDSP_Length(frames))
}

/// RT-safe identity copy of input → output. Handles size mismatch by copying the
/// min of the two byte counts and zeroing any remainder. No allocation.
private func copyInputToOutput(inList: UnsafeMutableAudioBufferListPointer,
                               outList: UnsafeMutableAudioBufferListPointer) {
    let n = min(inList.count, outList.count)
    for i in 0..<n {
        guard let dst = outList[i].mData else { continue }
        let outBytes = Int(outList[i].mDataByteSize)
        if let src = inList[i].mData {
            let copyBytes = min(outBytes, Int(inList[i].mDataByteSize))
            memcpy(dst, src, copyBytes)
            if copyBytes < outBytes { memset(dst + copyBytes, 0, outBytes - copyBytes) }
        } else {
            memset(dst, 0, outBytes)
        }
    }
    // Zero any output buffers with no matching input.
    if outList.count > n {
        for i in n..<outList.count {
            if let dst = outList[i].mData { memset(dst, 0, Int(outList[i].mDataByteSize)) }
        }
    }
}

// MARK: - EQEngine

@MainActor final class EQEngine {

    weak var delegate: EQEngineDelegate?
    private(set) var state: EngineState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.engine(self, didChangeState: state)
        }
    }

    // Pre-allocated RT capacities (CONTRACT.md: max 16 sections, 2 channels).
    // Not `private` so the pure `sectionCoefficients` mapping (internal, tested) can
    // reference them in a default argument.
    nonisolated static let maxSections = 16
    nonisolated static let channels = 2

    // Sentinel sample backing the non-Optional scratch pointer arrays (FIX 9). A
    // process-lifetime single-Float allocation each, so the scratch slots always hold
    // a valid address until the IOProc overwrites them with the real buffer pointers
    // (which it does, for all channels, every callback before vDSP reads them).
    fileprivate static let rtSentinelSample: UnsafePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafePointer(p)
    }()
    fileprivate static let rtSentinelSampleMutable: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    // Core Audio handles owned by the engine.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    // Our own process object (translated from getpid() at phase-A start). Cached so the
    // watchdog can exclude us when checking whether OTHER processes output audio (FIX 5).
    private var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)

    // Last bands and the sample rate the current setup was built for — needed to
    // rebuild coefficients on update() and to rebuild the whole stack on watchdog.
    private var currentBands: [EQBand] = []
    private var currentSampleRate: Double = 48_000

    // FIX 4: deferred phase-B start guard. Phase B fires ~0.3 s after phase A via
    // asyncAfter; it captures `startGeneration` at schedule time and only runs if it
    // still matches at fire time. stop()/rebuild bump the generation, so a teardown in
    // the gap cancels a stale phase B (no Thread.sleep poll anywhere).
    private var startGeneration = 0

    // FIX 12: reentrancy guard for rebuild(); also blocks a second wake notification
    // from racing the first into a double rebuild.
    private var rebuildInProgress = false

    // FIX 3: coalescing of update(bands:). Sliders fire ~60 Hz; we store the latest
    // bands and apply at most once per ~50 ms (latest-wins). `coalesceScheduled` guards
    // against scheduling more than one pending apply.
    private static let coalesceInterval: TimeInterval = 0.050
    private var pendingUpdateBands: [EQBand]?
    private var coalesceScheduled = false

    // FIX 6: did the watchdog raise a permission-suspected condition? Used so that when
    // audio returns (maxAbs > 0) we clear it and re-notify the controller with .running.
    private var permissionSuspected = false

    // Watchdog.
    private var watchdogTimer: DispatchSourceTimer?
    private var lastWatchdogCounter: Int64 = 0
    private var consecutiveSilentChecks = 0
    private var didRebuildForSilence = false

    // Sleep/wake.
    private var wakeObserver: NSObjectProtocol?

    init() {}

    deinit {
        // deinit is nonisolated; the timer/observer are torn down in stop(), which
        // the controller calls before releasing the engine. Nothing to do here that
        // is safe to touch from a nonisolated context.
    }

    // MARK: - isBypassed (RT-read atomic flag)

    /// Main-actor SSOT for the bypass intent. The RT flag (rtBypass) mirrors it, but is
    /// zeroed by releaseRTState() on every teardown/rebuild; this stored value survives,
    /// so finishStart() can re-publish it (FIX 7).
    private var bypassIntent = false

    var isBypassed: Bool {
        // Read/write of a naturally-aligned Int32 is atomic on ARM64; we only need
        // the RT thread to eventually observe the flip, not a full barrier.
        get { bypassIntent }
        set {
            bypassIntent = newValue
            rtBypass = newValue ? 1 : 0
        }
    }

    // MARK: - start()

    /// Idempotent. Builds own-PID-excluded global tap → private aggregate (built-in
    /// speakers main sub-device + tap in the CREATION dict) → IOProc → start.
    func start(bands: [EQBand]) {
        guard case .running = state else {
            performStart(bands: bands)
            return
        }
        // Already running: just refresh coefficients live (no rebuild for a device
        // change). FIX 13: this app only ever engages on the built-in speakers, whose
        // AudioObjectID is stable for the app's lifetime (built-in hardware never
        // disconnects / re-enumerates). So a start() while already running is always
        // the SAME device — continuing in place is safe; there is no missed device
        // switch to handle here. (Route changes off built-in are the controller's job:
        // it calls stop(), not start().)
        update(bands: bands)
    }

    /// FIX 4: phase A is fully synchronous (translate PID, create tap, find built-in,
    /// create aggregate, allocate RT state). Phase B (create IOProc + start + state
    /// → .running) is DEFERRED ~0.3 s, replacing the old blocking `waitForDeviceAlive`
    /// poll that could block the main thread up to 3 s. No Thread.sleep anywhere.
    private func performStart(bands: [EQBand]) {
        currentBands = bands
        do {
            // 1. pid → AudioObjectID so we can exclude ourselves (prevents feedback:
            //    our own rendered output must never be re-captured by the tap). Cached
            //    on the engine so the watchdog can also exclude us (FIX 5).
            ownProcessObjectID = try translateOwnPIDToProcessObject()

            // 2. Global tap, our process excluded, muted-on-tap.
            tapUUID = UUID()
            let excludeProcesses: [AudioObjectID] = ownProcessObjectID != kAudioObjectUnknown
                ? [ownProcessObjectID] : []
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
            tapDesc.uuid = tapUUID
            // M1 must A/B this against .muted (audit fact #4): .mutedWhenTapped keeps
            // audio playing if the app dies; .muted needs explicit unmute on teardown.
            tapDesc.muteBehavior = .mutedWhenTapped
            tapDesc.name = "eqYourMacbook-EQ"
            // PLAN.md asks for a private tap. The ObjC property is
            // `@property(getter=isPrivate) BOOL privateTap;` → Swift spelling is
            // `isPrivate`. Neither AudioCap nor iqualize set it (they rely solely on
            // kAudioAggregateDeviceIsPrivateKey, which we set below). We follow the
            // proven path and keep the aggregate private; M1 may enable the tap flag
            // if a stray Audio-MIDI-Setup entry appears.
            // tapDesc.isPrivate = true   // enable in M1 if needed; verify spelling first

            tapID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateProcessTap(tapDesc, &tapID),
                        "Failed to create process tap")

            // 3. Find built-in speakers and its UID.
            let builtInID = try findBuiltInSpeakers()
            let builtInUID = try getDeviceUID(builtInID)

            // 4. Aggregate device with the tap IN THE CREATION DICT (audit fact #1:
            //    adding the tap later delivers zero-filled buffers).
            let aggregateUID = UUID().uuidString
            let aggregateDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "eqYourMacbook-Aggregate",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: builtInUID,   // clock master
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: builtInUID],
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
                AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateDeviceID),
                "Failed to create aggregate device")

            // 5. Output nominal sample rate → compute coefficients for it.
            //    Read from the built-in device; built-in is fixed 48 kHz but read it
            //    rather than assume (audit fact #3: configure at the output rate).
            let rate = getDeviceNominalSampleRate(builtInID)
            currentSampleRate = rate > 0 ? rate : 48_000

            // 6. Pre-allocate ALL RT state (channel-pointer scratch + biquad setup).
            allocateRTScratch()
            installBiquadSetup(for: bands, sampleRate: currentSampleRate)
            rtChannelCount = Self.channels
            rtCallbackCounter = 0
            lastWatchdogCounter = 0
            consecutiveSilentChecks = 0
            didRebuildForSilence = false
            rtMaxAbsInput = 0
        } catch {
            failStart(error)
            return
        }

        // 7. Phase B deferred ~0.3 s (was a blocking alive-poll). Capture the current
        //    generation; if stop()/rebuild bumps it in the gap, the closure no-ops and
        //    leaves the already-allocated handles for that teardown to release.
        startGeneration &+= 1
        let generation = startGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.startGeneration == generation else { return }
                self.finishStart()
            }
        }
    }

    /// FIX 4 phase B: create the IOProc, start the device, install timers/observer and
    /// transition to .running. Runs only if the generation token still matches (no
    /// teardown happened in the deferral gap).
    private func finishStart() {
        do {
            procID = nil
            try caCheck(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, rtIOBlock),
                "Failed to create IOProc")
            try caCheck(AudioDeviceStart(aggregateDeviceID, procID),
                        "Failed to start aggregate device")

            // FIX 7: A/B bypass survives a watchdog rebuild. releaseRTState() zeroed the
            // RT flag, so re-publish it here from the public property (the SSOT).
            rtBypass = isBypassed ? 1 : 0

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
    /// ~50 ms (FIX 3). The actual apply hands the new coefficients to the RT thread,
    /// which calls SetTargetsDouble itself — see flushPendingUpdate / the IOProc — so
    /// the setup's target state has exactly one writer and never races vDSP_biquadm
    /// (FIX 2). RT thread never blocks on this.
    func update(bands: [EQBand]) {
        currentBands = bands
        pendingUpdateBands = bands
        guard case .running = state else { return }
        scheduleCoalescedApply()
    }

    /// FIX 3: schedule a single coalesced apply ~50 ms out (latest-wins). Guarded so at
    /// most one apply is in flight; the apply reads `pendingUpdateBands` at fire time.
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
    /// FIX 2 handoff: only write when the RT thread has consumed the previous update
    /// (`rtPendingFlag == 0`). If it hasn't yet (rare — the ~50 ms coalesce window is
    /// far longer than an IO callback period), keep `pendingUpdateBands` and reschedule
    /// so the latest value still lands on the next tick. The aligned-Int32 flag is the
    /// same atomic-word pattern as rtBypass: store-after-write publishes the data; the
    /// RT thread reads-then-consumes (sets it back to 0).
    ///
    /// ASSUMPTION (M3 on-device verification item): SetTargetsDouble (called on the RT
    /// thread) does not allocate. Writing the targets buffer here is a plain Double copy
    /// into pre-allocated memory — no allocation on the main side either.
    private func flushPendingUpdate() {
        guard case .running = state, let bands = pendingUpdateBands,
              let pending = rtPendingCoeffs else { return }

        // RT hasn't drained the previous update yet → retry on the next coalesce tick
        // (keep pendingUpdateBands so the latest value wins).
        guard rtPendingFlag == 0 else {
            scheduleCoalescedApply()
            return
        }

        let coeffs = Self.sectionCoefficients(for: bands, sampleRate: currentSampleRate)
        let count = min(coeffs.count, 5 * Self.channels * Self.maxSections)
        coeffs.withUnsafeBufferPointer { src in
            pending.update(from: src.baseAddress!, count: count)
        }
        pendingUpdateBands = nil
        // Publish: RT will pick this up at the start of its next callback.
        rtPendingFlag = 1
    }

    // MARK: - stop() — strict teardown order (CONTRACT.md)

    /// Idempotent. AudioDeviceStop → AudioDeviceDestroyIOProcID →
    /// AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap →
    /// only THEN release RT buffers/setup (fixes iqualize's nil-while-running race).
    func stop() {
        let wasRunning: Bool = { if case .running = state { return true }; return false }()

        // FIX 4: bump the generation so any pending phase-B closure scheduled by a
        // performStart still in its 0.3 s deferral gap no-ops when it fires.
        startGeneration &+= 1
        // FIX 3: drop any coalesced update intent (a stale apply must not fire post-stop).
        // Also clear the schedule flag: a stop→start within the 50 ms coalesce window
        // must not make the next update() skip scheduling (latest-wins guarantee).
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
    private func teardownCoreAudio() {
        if aggregateDeviceID != kAudioObjectUnknown, procID != nil {
            AudioDeviceStop(aggregateDeviceID, procID)
        }
        if let procID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        procID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - RT state lifecycle

    private func allocateRTScratch() {
        releaseRTScratch()
        // FIX 9: non-Optional element type. A scratch pointer can't be nil, so we seed
        // every slot with a sentinel — the address of a static dummy sample. The IOProc
        // overwrites all `channels` slots every callback before vDSP reads them, so the
        // sentinel is never actually processed; it exists only to satisfy `initialize`.
        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: Self.channels)
        inPtrs.initialize(repeating: Self.rtSentinelSample, count: Self.channels)
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: Self.channels)
        outPtrs.initialize(repeating: Self.rtSentinelSampleMutable, count: Self.channels)
        rtInputPtrs = inPtrs
        rtOutputPtrs = outPtrs

        // FIX 2: pre-allocate the pending-coefficients handoff buffer (full setup size,
        // 5 * channels * maxSections doubles). Main writes targets here; the RT thread
        // consumes via SetTargetsDouble. Allocation happens here (at start), never in
        // the callback.
        let pendingCount = 5 * Self.channels * Self.maxSections
        let pending = UnsafeMutablePointer<Double>.allocate(capacity: pendingCount)
        pending.initialize(repeating: 0, count: pendingCount)
        rtPendingCoeffs = pending
        rtPendingFlag = 0
    }

    private func releaseRTScratch() {
        if let p = rtInputPtrs { p.deinitialize(count: Self.channels); p.deallocate(); rtInputPtrs = nil }
        if let p = rtOutputPtrs { p.deinitialize(count: Self.channels); p.deallocate(); rtOutputPtrs = nil }
        if let p = rtPendingCoeffs {
            let pendingCount = 5 * Self.channels * Self.maxSections
            p.deinitialize(count: pendingCount); p.deallocate(); rtPendingCoeffs = nil
        }
        rtPendingFlag = 0
    }

    private func installBiquadSetup(for bands: [EQBand], sampleRate: Double) {
        if let old = rtBiquadSetup { vDSP_biquadm_DestroySetup(old); rtBiquadSetup = nil }
        rtMaxSections = Self.maxSections
        let coeffs = Self.sectionCoefficients(for: bands, sampleRate: sampleRate)
        coeffs.withUnsafeBufferPointer { ptr in
            // Header arg order is (coeffs, __M, __N) where __M = channels, __N =
            // sections (Accelerate vDSP guide: "length 5 * M * N, where M is the
            // number of channels and N is the number of sections"). coeffs is
            // 5 * channels * sections doubles, section-major (see flatIndex).
            rtBiquadSetup = vDSP_biquadm_CreateSetup(ptr.baseAddress!,
                                                     vDSP_Length(Self.channels),
                                                     vDSP_Length(Self.maxSections))
        }
    }

    /// Release ALL RT-shared state. Called only AFTER Core Audio teardown so no
    /// callback can be running against it.
    private func releaseRTState() {
        if let setup = rtBiquadSetup { vDSP_biquadm_DestroySetup(setup); rtBiquadSetup = nil }
        releaseRTScratch()
        rtBypass = 0
        rtCallbackCounter = 0
        rtMaxAbsInput = 0
    }

    // MARK: - Coefficient pipeline

    /// SINGLE POINT OF TRUTH for the (section, channel) → flat coefficient index in
    /// the `5 * channels * sections` array vDSP_biquadm wants. We lay it out
    /// SECTION-MAJOR: channel varies fastest, so the per-section 5-double blocks for
    /// every channel are adjacent — s0ch0, s0ch1, s1ch0, s1ch1, … Each returned index
    /// is the START of that (section, channel)'s 5-double block.
    ///
    /// Reviewers disagreed on vDSP_biquadm's expected layout; the orchestrator
    /// adjudicated section-major. This is empirical, not proven: the M=2/N=2 canary
    /// test (testVDSPBiquadmStereoMatchesScalarReference) is the authority. If it
    /// fails on the Mac, flip ONLY this helper (channel-major would be
    /// `(channel * sections + section) * 5`) — every builder/reader routes through it.
    static func flatIndex(section: Int, channel: Int, channels: Int) -> Int {
        (section * channels + channel) * 5
    }

    /// Pure mapping: EQBand list → flat double coefficient array in the layout
    /// vDSP_biquadm_CreateSetup(coeffs, M=channels, N=sections) expects:
    /// `5 * channels * sections` doubles, SECTION-MAJOR via `flatIndex` (channel
    /// varies fastest). Each section is 5 doubles in the order **[b0, b1, b2, a1, a2]**
    /// (header: "S, B0, B1, B2, A1, A2"). We apply the SAME cascade to both channels,
    /// so each section's per-channel blocks are identical.
    ///
    /// Sign convention (THE decision — verified against the Accelerate header's own
    /// pseudo-code and pinned by the canary test in EngineCoefficientTests): vDSP
    /// computes
    ///   y[s][n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
    /// for the transfer function
    ///   H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²).
    /// vDSP SUBTRACTS the a-terms internally, so a1/a2 are passed in their natural
    /// transfer-function sign — we do NOT negate them. This matches the RBJ output of
    /// BiquadResponse / NormalizedBiquadCoeffs and iqualize's scalar DFII-T loop
    /// (s1 = b1·x − a1·y + s2).
    ///
    /// Muted bands are skipped. Unused sections (and any beyond 16) are identity
    /// passthrough (b0=1, rest 0). bands.count > 16 is silently clamped to 16.
    ///
    /// `channels` defaults to the engine's fixed channel count; tests build a single
    /// channel to compare against a scalar reference.
    static func sectionCoefficients(for bands: [EQBand], sampleRate: Double,
                                    channels: Int = EQEngine.channels) -> [Double] {
        var out = [Double](repeating: 0, count: maxSections * 5 * channels)
        // Identity everywhere first (b0=1, rest 0), via the layout helper.
        for s in 0..<maxSections {
            for c in 0..<channels {
                out[flatIndex(section: s, channel: c, channels: channels)] = 1
            }
        }
        let active = bands.filter { !$0.muted }.prefix(maxSections)
        for (s, band) in active.enumerated() {
            let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
            // Same cascade on every channel: write the section's 5 doubles per channel.
            for c in 0..<channels {
                let base = flatIndex(section: s, channel: c, channels: channels)
                out[base + 0] = Double(n.b0)
                out[base + 1] = Double(n.b1)
                out[base + 2] = Double(n.b2)
                out[base + 3] = Double(n.a1)
                out[base + 4] = Double(n.a2)
            }
        }
        return out
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

    // FIX 4: the old blocking `waitForDeviceAlive` poll (Thread.sleep up to 3 s on the
    // main thread) is gone. performStart() now defers phase B ~0.3 s via asyncAfter to
    // give the freshly-created aggregate time to come alive, without blocking.

    // MARK: - Watchdog (CONTRACT.md)

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        guard case .running = state else { return }
        let counter = rtCallbackCounter
        let maxAbs = rtMaxAbsInput
        rtMaxAbsInput = 0   // FIX 10: read-then-reset so each tick sees the max since the last
        let advancing = counter != lastWatchdogCounter
        lastWatchdogCounter = counter

        // FIX 6(b): audio is flowing again. If we'd previously raised a permission-
        // suspected condition, clear it and re-notify the controller with .running so it
        // clears its own flag (the controller treats repeated .running as idempotent).
        if maxAbs > 0 {
            didRebuildForSilence = false
            if permissionSuspected {
                permissionSuspected = false
                os_log(.default, log: engineLog, "watchdog: audio recovered, clearing permission suspicion")
                delegate?.engine(self, didChangeState: .running)
            }
        }

        // FIX 5: zeros are legitimate when nothing is playing. Only treat a silent check
        // as suspicious when some OTHER process is actually outputting audio — otherwise
        // we'd false-trip on an idle but healthy chain.
        let othersOutputting = anyOtherProcessOutputtingAudio(excluding: ownProcessObjectID)
        if advancing && maxAbs == 0 && othersOutputting {
            consecutiveSilentChecks += 1
        } else {
            consecutiveSilentChecks = 0
        }

        guard consecutiveSilentChecks >= 2 else { return }

        if !didRebuildForSilence {
            // One silent rebuild (stop + start), no delegate noise.
            didRebuildForSilence = true
            consecutiveSilentChecks = 0
            os_log(.default, log: engineLog, "watchdog: silent input, rebuilding once")
            rebuild()
        } else {
            // Still silent after a rebuild → likely TCC denial.
            os_log(.error, log: engineLog, "watchdog: still silent after rebuild → permission denial suspected")
            consecutiveSilentChecks = 0
            permissionSuspected = true
            delegate?.engineSuspectsPermissionDenied(self)
        }
    }

    /// Full stack rebuild preserving the current bands, WITHOUT flickering through
    /// .stopped (which would make the UI blink "disabled"). Tears down Core Audio
    /// and RT state in place, then re-runs the start sequence.
    ///
    /// FIX 12: guarded against reentrancy (a second wake notification racing the first,
    /// or a watchdog tick during the deferred phase-B gap) so we never double-rebuild.
    /// FIX 6(a): after a successful rebuild we fire .running UNCONDITIONALLY (bypassing
    /// the state didSet equality guard, since state was already .running throughout the
    /// rebuild), so the controller learns the chain is healthy again.
    private func rebuild() {
        guard !rebuildInProgress else { return }
        rebuildInProgress = true
        let bands = currentBands
        // Same strict order as stop(), minus the state transition and timers/observer
        // (performStart reinstalls those). Bump the generation so any in-flight phase B
        // from a prior start no-ops (FIX 4).
        startGeneration &+= 1
        stopWatchdog()
        removeWakeObserver()
        teardownCoreAudio()
        releaseRTState()
        performStart(bands: bands)
        // performStart defers phase B ~0.3 s; clear the guard and fire the unconditional
        // .running notification once that phase B has actually run and succeeded.
        // Capture MUST stay after performStart — it bumps startGeneration, and the
        // check below must match the NEW phase B, not the pre-rebuild one.
        let generation = startGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildInProgress = false
                // FIX 6(a): only meaningful if the rebuild reached .running.
                if case .running = self.state, self.startGeneration == generation {
                    self.delegate?.engine(self, didChangeState: .running)
                }
            }
        }
    }

    // MARK: - Sleep / wake

    private func installWakeObserver() {
        removeWakeObserver()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // ~1 s after wake (iqualize-proven timing) → preventive rebuild.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .running = self.state { self.rebuild() }
                }
            }
        }
    }

    private func removeWakeObserver() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }
}
