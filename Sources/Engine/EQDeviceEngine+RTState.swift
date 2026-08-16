// EQDeviceEngine's RT-scratch and biquad-setup allocation/release lifecycle.

import Accelerate
import AudioToolbox

extension EQDeviceEngine {

    // MARK: - RT state lifecycle

    func allocateRTScratch() {
        let context = rtContext ?? EQDeviceRTContext()
        releaseRTScratch(context)
        // Non-Optional element type: a scratch pointer can't be nil, so seed every slot
        // with a sentinel (a static dummy sample's address). The IOProc overwrites all
        // `channels` slots every callback before vDSP reads them.
        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: EQCoefficients.channels)
        inPtrs.initialize(repeating: EQDeviceRTContext.sentinelSample, count: EQCoefficients.channels)
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: EQCoefficients.channels)
        outPtrs.initialize(repeating: EQDeviceRTContext.sentinelSampleMutable, count: EQCoefficients.channels)
        context.inputPtrs = inPtrs
        context.outputPtrs = outPtrs

        // Pre-allocate the pending-coefficients handoff buffer (full setup size,
        // 5 * channels * maxSections doubles). Main writes targets here; the RT thread
        // consumes via SetTargetsDouble. Allocation happens here (at start), never in
        // the callback.
        let pendingCount = 5 * EQCoefficients.channels * EQCoefficients.maxSections
        let pending = UnsafeMutablePointer<Double>.allocate(capacity: pendingCount)
        pending.initialize(repeating: 0, count: pendingCount)
        context.pendingCoeffs = pending
        context.pendingFlag = 0

        rtContext = context
    }

    private func releaseRTScratch(_ context: EQDeviceRTContext) {
        if let p = context.inputPtrs { p.deinitialize(count: EQCoefficients.channels); p.deallocate(); context.inputPtrs = nil }
        if let p = context.outputPtrs { p.deinitialize(count: EQCoefficients.channels); p.deallocate(); context.outputPtrs = nil }
        if let p = context.pendingCoeffs {
            let pendingCount = 5 * EQCoefficients.channels * EQCoefficients.maxSections
            p.deinitialize(count: pendingCount); p.deallocate(); context.pendingCoeffs = nil
        }
        context.pendingFlag = 0
    }

    func installBiquadSetup(for bands: [EQBand], sampleRate: Double) {
        guard let context = rtContext else { return }
        if let old = context.biquadSetup { vDSP_biquadm_DestroySetup(old); context.biquadSetup = nil }
        context.maxSections = EQCoefficients.maxSections
        let coeffs = EQCoefficients.sectionCoefficients(
            for: bands, sampleRate: sampleRate,
            masterGainDB: EQCoefficients.masterGainDB(for: bands, enabled: gainStagingEnabled))
        coeffs.withUnsafeBufferPointer { ptr in
            // VERIFIED ON MAC (asymmetric-dimension probe): __M = SECTIONS (matrix
            // rows), __N = CHANNELS (columns) — the archived vDSP Programming Guide
            // claims the opposite and is WRONG (swapped dims caused a wild-pointer
            // crash in vDSP_biquadm). coeffs stays 5 * channels * sections doubles,
            // section-major (see EQCoefficients.flatIndex), channel-varies-fastest.
            context.biquadSetup = vDSP_biquadm_CreateSetup(ptr.baseAddress!,
                                                           vDSP_Length(EQCoefficients.maxSections),
                                                           vDSP_Length(EQCoefficients.channels))
        }
    }

    /// Release ALL RT-shared state. Called only AFTER Core Audio teardown so no
    /// callback can be running against it.
    func releaseRTState() {
        guard let context = rtContext else { return }
        if let setup = context.biquadSetup { vDSP_biquadm_DestroySetup(setup); context.biquadSetup = nil }
        releaseRTScratch(context)
        context.bypass = 0
        context.callbackCounter = 0
        context.resetMaxAbsInputAssumingStopped()
        rtContext = nil
    }
}
