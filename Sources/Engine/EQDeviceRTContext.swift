// RT (real-time, audio-thread) state for ONE device's EQDeviceEngine.
//
// Each EQDeviceEngine owns its own instance and its own IOProc block (built by
// `makeIOBlock`, see EQIOProcFactory.swift). At most one EQDeviceEngine ever actually
// runs at a time — the enabled device that's ALSO the OS's current default-output
// route (CLAUDE.md § Invariants) — but this class still
// needs its own per-instance storage regardless of that count:
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
import Darwin

// MARK: - Cross-thread publish/consume fences
//
// The pendingCoeffs/pendingFlag handoff (main thread producer → RT thread consumer)
// and the callbackCounter telemetry (RT thread writer → main-actor watchdog reader,
// single writer/single reader) both need real release/acquire memory ordering, not
// just the per-address atomicity a naturally-aligned Int32/Int64 load/store gets for
// free (maxAbsInput is a separate case — genuine concurrent RMW from both sides — and
// is handled below with CAS instead; see its own doc comment):
// without a fence, ARM64's weak multi-copy-atomic model lets the RT thread's core
// observe the flag flip before it observes the payload writes that (in program
// order) preceded it, which can hand vDSP a torn/stale mix of coefficients.
//
// The obvious fix is Swift 6's `Synchronization.Atomic<T>` (`.storing(_,
// ordering: .releasing)` / `.load(ordering: .acquiring)`) — but that type is
// `@available(macOS 15, *)`, and Package.swift pins this project's deployment
// target at macOS 14.4 (see `platforms:` there and DEPLOYMENT_TARGET in
// scripts/build-config.sh), so it cannot be used as a stored-property type here
// without bumping the deployment target (out of scope for this fix).
//
// Fallback: `OSMemoryBarrier()` (<libkern/OSAtomic.h>) issues a full hardware
// memory fence and — because it is an opaque external call the optimizer cannot
// see through — also acts as a compiler barrier, giving the same happens-before
// guarantee a real atomic release/acquire pair would, with a single instruction,
// no allocation, no lock, no blocking (RT-safe per CLAUDE.md § Rules). It has been
// deprecated since macOS 10.12 in favor of <stdatomic.h>'s C11 atomics, but
// remains present in the SDK; the deprecation warning is expected and accepted
// here. VERIFY ON FIRST MAC BUILD: once the deployment target moves to macOS 15+,
// replace `rtReleaseFence`/`rtAcquireFence` call sites with real
// `Synchronization.Atomic<Int32>` storage instead of plain fields + fences.
@inline(__always) func rtReleaseFence() { OSMemoryBarrier() }
@inline(__always) func rtAcquireFence() { OSMemoryBarrier() }

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
    /// Protocol (see the `rtReleaseFence`/`rtAcquireFence` doc comment above this class
    /// for why plain Int32 load/store isn't enough on its own):
    ///   - Main thread writes new coefficients into `pendingCoeffs` only when
    ///     `pendingFlag == 0`, calls `rtReleaseFence()`, THEN sets `pendingFlag = 1`
    ///     (publish) — the fence guarantees the coefficient writes are visible to any
    ///     thread that later observes the flag flip.
    ///   - IOProc, at callback start, checks `pendingFlag`; if 1, calls
    ///     `rtAcquireFence()` (pairs with the producer's release fence, so the
    ///     coefficient writes above are guaranteed visible here), then calls
    ///     SetTargetsDouble from the RT thread, then `rtReleaseFence()` again before
    ///     setting `pendingFlag = 0` (consume) so the next producer write can't be
    ///     reordered ahead of this thread's own read.
    ///   - If main finds the flag still 1 (RT hasn't consumed yet — rare), it stashes the
    ///     latest bands and retries on the next coalesce tick.
    /// Buffer capacity is the full pre-allocated 5 * channels * maxSections doubles.
    ///
    /// VERIFY ON FIRST MAC BUILD: vDSP_biquadm_SetTargetsDouble must not allocate (Apple
    /// documents it as the live-ramp path). If profiling shows it allocates, fall back to
    /// double-buffered-setup + atomic-pointer-swap.
    var pendingCoeffs: UnsafeMutablePointer<Double>?
    var pendingFlag: Int32 = 0

    /// Watchdog telemetry: callback counter. RT thread is the ONLY writer (plain
    /// increment every callback); the main-actor watchdog only ever reads it — a
    /// single-writer/single-reader field, so `rtReleaseFence()`/`rtAcquireFence()`
    /// bracketing (see the doc comment above this class) is enough on its own; no
    /// CAS needed here (contrast with `maxAbsInputBits` below, which DOES have two
    /// concurrent writers).
    var callbackCounter: Int64 = 0

    /// Backing storage for the watchdog's max-abs-input telemetry, held as the raw
    /// Int32 bit pattern of the Float (not a plain `Float`) so it can be updated with
    /// `OSAtomicCompareAndSwap32Barrier`, which is Int32-only. Never touch this
    /// directly — go through `rtUpdateMaxAbsInput(_:)` (RT thread) or
    /// `exchangeMaxAbsInputWithZero()` (watchdog) below.
    ///
    /// Unlike `callbackCounter`, this has TWO genuine concurrent writers: the RT thread
    /// conditionally raises a running max every callback, and the main-actor watchdog
    /// unconditionally resets it to 0 every 5 s tick. A plain read-compare-store on the
    /// RT side racing a plain read-then-store-0 on the watchdog side is a lost-update
    /// hazard: RT can compute a genuine new max, the watchdog's reset lands in between,
    /// and RT's stale-compare store then overwrites the reset — reviving a pre-reset
    /// sample into the post-reset window, which could make the watchdog wrongly read
    /// "audio still playing" during real silence (exactly what this telemetry detects).
    /// CAS closes this: the losing side retries against whichever value actually won,
    /// so neither update is ever silently dropped. `OSAtomicCompareAndSwap32Barrier`
    /// carries its own full memory barrier, so no separate fence bracketing is needed —
    /// same deprecated-but-present-in-SDK tradeoff as `rtReleaseFence`/`rtAcquireFence`
    /// above (`Synchronization.Atomic` needs macOS 15+, deployment target is 14.4).
    private var maxAbsInputBits = Int32(bitPattern: Float(0).bitPattern)

    /// Retry cap for rtUpdateMaxAbsInput's CAS loop below. Contention is between exactly
    /// two threads (this one and the watchdog's reset), so in practice a lost race is
    /// resolved on the very next attempt; the cap just makes the RT thread's worst case
    /// provably bounded rather than relying on that in practice — CLAUDE.md § Rules forbids
    /// unbounded blocking in the IOProc. Giving up after the cap just means this one
    /// callback's sample isn't folded into the running max; the next callback's own
    /// update (or the coalescing across many callbacks per watchdog tick) recovers it,
    /// so no telemetry is permanently lost, only possibly delayed by one callback.
    private static let maxAbsInputCASRetries = 8

    /// RT thread only. Folds `sample` into the running max via a bounded CAS retry —
    /// RT-safe: no allocation, no lock, no unbounded blocking.
    func rtUpdateMaxAbsInput(_ sample: Float) {
        withUnsafeMutablePointer(to: &maxAbsInputBits) { ptr in
            var oldBits = ptr.pointee
            for _ in 0..<Self.maxAbsInputCASRetries {
                let oldValue = Float(bitPattern: UInt32(bitPattern: oldBits))
                guard sample > oldValue else { return }   // not a new max — nothing to do
                let newBits = Int32(bitPattern: sample.bitPattern)
                if OSAtomicCompareAndSwap32Barrier(oldBits, newBits, ptr) { return }
                oldBits = ptr.pointee   // lost the race (watchdog reset) — retry against the fresh value
            }
        }
    }

    /// Main actor (watchdog) only — NOT the RT thread, so no bounded-retry constraint
    /// applies here (CLAUDE.md § Rules' RT rules are scoped to the IOProc). Atomically reads
    /// the running max AND resets it to zero in one step (an exchange, not a separate
    /// read-then-store), so a concurrent RT-thread update can never be silently dropped
    /// by the reset, nor vice versa. Contention is with a single other writer (the RT
    /// thread), so this resolves in one or two iterations in practice.
    func exchangeMaxAbsInputWithZero() -> Float {
        withUnsafeMutablePointer(to: &maxAbsInputBits) { ptr in
            var oldBits = ptr.pointee
            while true {
                if OSAtomicCompareAndSwap32Barrier(oldBits, 0, ptr) {
                    return Float(bitPattern: UInt32(bitPattern: oldBits))
                }
                oldBits = ptr.pointee   // RT updated it concurrently — retry against the new value
            }
        }
    }

    /// Non-atomic reset, safe ONLY while the engine is stopped (no RT thread can be
    /// concurrently touching this context) — used at start()/teardown to zero telemetry
    /// before/after a run, where there is no concurrent writer to race.
    func resetMaxAbsInputAssumingStopped() {
        maxAbsInputBits = Int32(bitPattern: Float(0).bitPattern)
    }

    /// Sentinel sample backing the non-Optional scratch pointer arrays: a valid address
    /// until the IOProc overwrites all channel slots with real buffer pointers each callback.
    nonisolated(unsafe) static let sentinelSample: UnsafePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafePointer(p)
    }()
    nonisolated(unsafe) static let sentinelSampleMutable: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()
}
