// EQDeviceEngine's live-update path: coalesced coefficient swaps (no restart, no
// glitch) and the A/B bypass flag they interact with. gainStagingEnabled itself stays
// a stored property on EQDeviceEngine (extensions can't hold stored properties), but
// the coalescing/apply machinery its didSet drives lives here.

import Foundation

extension EQDeviceEngine {

    // MARK: - isBypassed (RT-read atomic flag)

    /// Main-actor SSOT for the bypass intent. The RT flag (rtContext.bypass) mirrors it
    /// but is zeroed by releaseRTState() on every teardown/rebuild; this stored value
    /// survives, so finishStart() can re-publish it.
    var isBypassed: Bool {
        // Read/write of a naturally-aligned Int32 is atomic on ARM64; we only need
        // the RT thread to eventually observe the flip, not a full barrier.
        get { bypassIntent }
        set {
            bypassIntent = newValue
            rtContext?.bypass = newValue ? 1 : 0
        }
    }

    // MARK: - update() — live coefficient swap (no restart, no glitch)

    /// Live coefficient swap. Coalescing is allowed; sliders fire ~60 Hz, so we store
    /// the latest bands (latest-wins) and apply at most once every ~50 ms. The actual
    /// apply hands coefficients to the RT thread, which calls SetTargetsDouble itself (see
    /// flushPendingUpdate / makeIOBlock) — exactly one writer, never racing vDSP_biquadm;
    /// the RT thread never blocks on this.
    func update(bands: [EQBand]) {
        currentBands = bands
        pendingUpdateBands = bands
        guard case .running = state else { return }
        scheduleCoalescedApply()
    }

    /// Schedule a single coalesced apply ~50 ms out (latest-wins). Guarded so at most
    /// one apply is in flight; the apply reads `pendingUpdateBands` at fire time.
    ///
    /// Not private: called from EQDeviceEngine.swift's gainStagingEnabled didSet (a
    /// stored property, so it can't live in this extension file).
    func scheduleCoalescedApply() {
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

    /// Apply the latest pending bands by writing targets into the RT handoff buffer. Only
    /// writes when the RT thread has consumed the previous update (`pendingFlag == 0`); if
    /// not (rare — the ~50 ms coalesce window is far longer than an IO callback period),
    /// keep `pendingUpdateBands` and reschedule so the latest value lands on the next tick.
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
        // rtReleaseFence() pairs with the RT consumer's rtAcquireFence()
        // (EQIOProcFactory.swift) — guarantees the coefficient writes above are
        // visible to the RT thread before it observes the flag flip below. See
        // EQDeviceRTContext.swift's rtReleaseFence/rtAcquireFence doc comment.
        rtReleaseFence()
        context.pendingFlag = 1
    }
}
