// Real-signal tests against the PRODUCTION IOProc block (EQIOProcFactory.makeIOBlock),
// not a hand-rolled parallel vDSP setup (that's what EngineCoefficientTests.swift already
// covers, at the coefficient-layout level). Each test builds a real EQDeviceRTContext
// with a real vDSP_biquadm_CreateSetup, builds the actual IOBlock via makeIOBlock(context:),
// and feeds it synthetic AudioBufferLists via AudioBufferTestSupport.swift's
// TestAudioBuffer/invokeIOBlock — exercising the exact code path the real hardware IOProc
// runs. `.serialized` is defense-in-depth, matching EngineCoefficientTests: these tests
// don't share mutable static state directly, but EQCoefficients.sectionCoefficients (used
// indirectly below) does, via its lock-guarded cache.
import Accelerate
import AudioToolbox
import Testing
@testable import eqYourMacbook

@Suite(.serialized) struct EQIOProcFactoryTests {

    private let sampleRate = 48_000.0

    // MARK: - RT context construction (mirrors EQDeviceEngine+RTState.swift's
    // allocateRTScratch/installBiquadSetup, but built directly — no EQDeviceEngine
    // instance — since this file exercises makeIOBlock/EQDeviceRTContext directly.

    private func makeContext(band: EQBand, sampleRate: Double, channels: Int = EQCoefficients.channels) -> EQDeviceRTContext {
        let context = EQDeviceRTContext()
        context.channelCount = channels
        context.maxSections = EQCoefficients.maxSections

        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        inPtrs.initialize(repeating: EQDeviceRTContext.sentinelSample, count: channels)
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        outPtrs.initialize(repeating: EQDeviceRTContext.sentinelSampleMutable, count: channels)
        context.inputPtrs = inPtrs
        context.outputPtrs = outPtrs

        let coeffs = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate, channels: channels)
        context.biquadSetup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquadm_CreateSetup(ptr.baseAddress!, vDSP_Length(EQCoefficients.maxSections), vDSP_Length(channels))
        }
        context.bypass = 0
        context.pendingFlag = 0
        return context
    }

    private func releaseContext(_ context: EQDeviceRTContext) {
        if let setup = context.biquadSetup { vDSP_biquadm_DestroySetup(setup) }
        context.inputPtrs?.deallocate()
        context.outputPtrs?.deallocate()
    }

    /// Run a mono-identical-stereo sine of `probeFrequency` through a real
    /// EQDeviceRTContext/makeIOBlock built for `band`, and return the measured gain in dB
    /// (RMS(output)/RMS(input) over a steady-state window, phase-independent).
    ///
    /// frameCount/discard: 4096 frames (85.3 ms @ 48 kHz) with the first 1024 discarded as
    /// transient margin. The biquads under test have Q ≈ 1.4 (1-octave bandwidth), whose
    /// pole radius r ≈ 0.97 gives a settling time constant of ~1/(1-r) ≈ 30 samples;
    /// discarding 1024 (>30x that) leaves 3072 steady-state samples (>45 periods even at
    /// the lowest probe frequency below) for a stable RMS estimate.
    private func measureGainDB(band: EQBand, probeFrequency: Double,
                                frameCount: Int = 4096, discard: Int = 1024) -> Double {
        let context = makeContext(band: band, sampleRate: sampleRate)
        defer { releaseContext(context) }
        let block = makeIOBlock(context: context)

        let inputSamples = makeSineWave(frequency: probeFrequency, sampleRate: sampleRate, frameCount: frameCount)
        let input = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: inputSamples)
        let output = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: nil)
        invokeIOBlock(block, input: input, output: output)

        let inFlat = input.samples
        let outFlat = output.samples
        // Channel 0 only (interleaved, stride 2), steady-state region.
        var inSteady: [Float] = []; var outSteady: [Float] = []
        inSteady.reserveCapacity(frameCount - discard)
        outSteady.reserveCapacity(frameCount - discard)
        for n in discard..<frameCount {
            inSteady.append(inFlat[n * 2])
            outSteady.append(outFlat[n * 2])
        }
        return 20 * log10(rms(outSteady) / rms(inSteady))
    }

    // MARK: - (a) Sine wave at a known frequency: output amplitude matches the filter's
    // analytically-derived gain at that frequency.
    // Band: peaking (bell), f0 = 1000 Hz, gain = +6 dB, bandwidth = 1.0 octave, 48 kHz.
    //
    // HAND DERIVATION of the expected +6.00 dB at f0 (RBJ peaking cookbook):
    //   for ANY peaking-filter coefficients, H(z0) at the center frequency is EXACTLY A²
    //   regardless of alpha/Q — b0+b1·z0⁻¹+b2·z0⁻² and a0+a1·z0⁻¹+a2·z0⁻² both reduce to
    //   the same expression scaled by A vs. 1/A respectively (the ±αA split cancels the
    //   same way it does at DC/Nyquist), so 10·log10(A²) = 40·log10(A) = the configured
    //   gain exactly. For gain=+6dB, A=10^(6/40): the exact peak is +6.00 dB, not the
    //   ~+6.02 dB a naive hand-calc chain (rounding w0/Q/alpha to 6 digits each) suggests.
    //   (Matches the codebase's own audited invariant, EngineCoefficientTests.swift's
    //   peakingNonzeroGainBandwidthEdgeIsHalfGain, which uses the same exact-cancellation
    //   argument for the bandwidth-edge gain.)
    // Tolerance ±0.75 dB covers RMS-window estimation noise (negligible at 45+ periods,
    // but kept generous rather than brittle).
    @Test func sineAtCenterFrequencyMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let measured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(abs(measured - 6.00) <= 0.75,
                "measured \(measured) dB at f0, expected +6.00 dB exactly (RBJ peaking center-gain)")
    }

    // MARK: - (b) 4 frequencies bracketing the filter's center/bandwidth-edge corners.
    //
    // Same band as above (f0=1000 Hz, +6 dB, 1 octave). Hand-derived expected gains:
    //
    //   • 30 Hz  (≈ DC): for ANY peaking-filter coefficients, H(DC) is EXACTLY unity
    //     (0 dB), because b0+b1+b2 = (1+αA)+(-2cosW0)+(1-αA) = 2-2cosW0 = a0+a1+a2
    //     EXACTLY (the ±αA split cancels) — i.e. N(1)=D(1) regardless of gain. 30 Hz is
    //     not literally DC, but w=2π·30/48000=0.003927 rad is close enough to 0 that the
    //     deviation from the exact-DC identity is O(w²) ≈ 1.5e-5 relative — negligible
    //     next to our tolerance.
    //   • 707.107 Hz (= f0/√2, the lower 1-octave bandwidth edge) and
    //     1414.214 Hz (= f0·√2, the upper edge): the codebase's own audited invariant
    //     (EngineCoefficientTests.peakingNonzeroGainBandwidthEdgeIsHalfGain) establishes
    //     that RBJ peaking's bandwidth-edge gain is exactly HALF the configured gain in
    //     dB, independent of the gain value (confirmed there numerically for +6/+12/+20/
    //     -12 dB) — so for our +6 dB band, both edges should read ≈ +3 dB.
    //   • 1000 Hz (f0): +6.00 dB exactly, same derivation as the test above.
    @Test func bracketFrequenciesMatchHandDerivedGains() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let cases: [(freq: Double, expectedDB: Double, label: String)] = [
            (30, 0.0, "≈DC"),
            (1000.0 / pow(2.0, 0.5), 3.0, "lower bandwidth edge (f0/√2)"),
            (1000, 6.00, "center (f0)"),
            (1000 * pow(2.0, 0.5), 3.0, "upper bandwidth edge (f0·√2)"),
        ]
        for c in cases {
            let measured = measureGainDB(band: band, probeFrequency: c.freq)
            #expect(abs(measured - c.expectedDB) <= 0.75,
                    "\(c.label) @ \(c.freq) Hz: measured \(measured) dB, expected ≈ \(c.expectedDB) dB")
        }
    }

    // MARK: - (b') Real-signal coverage for the 6 filter types (b) above doesn't touch.
    //
    // Every test above this point uses ONLY .parametric bands — the other 6 FilterType
    // cases (lowShelf/highShelf/lowPass/highPass/bandPass/notch) never actually ran
    // through vDSP_biquadm_CreateSetup/makeIOBlock at all before this point; they were
    // only exercised at the coefficient level (EngineCoefficientTests.swift). Each test
    // below builds a real EQDeviceRTContext + real vDSP_biquadm_CreateSetup for that
    // filter type, gets the real makeIOBlock(context:), and feeds it a sine wave — the
    // SAME production RT path as (a)/(b) above, just for the remaining filter types.
    //
    // Expected gain at each probe frequency is computed via
    // `BiquadResponse.coefficients(for:sampleRate:).gainDB(at:sampleRate:)` — the
    // already-unit-tested lower-level function (EngineCoefficientTests.swift). This is a
    // legitimate cross-check, not a tautology: gainDB() evaluates the CONTINUOUS transfer
    // function analytically and never touches vDSP_biquadm/makeIOBlock at all, so a real
    // RT-path bug (wrong section layout, wrong vDSP sign convention for a coefficient this
    // suite hasn't exercised before, etc.) would show up as a mismatch here even though
    // gainDB() itself would report the "intended" value regardless.
    //
    // Where a probe frequency is low enough that the default 4096-frame/1024-discard
    // window would leave too few cycles for a stable RMS estimate (the concern
    // measureGainDB's own doc comment flags), frameCount/discard are widened explicitly
    // rather than silently reusing a marginal default.

    // --- lowShelf @ 200 Hz, +6 dB, 1.0 octave (same band as
    // EngineCoefficientTests.lowShelfMatchesVicanekGainAnchors) — corner/DC/Nyquist
    // anchors all hold exactly at this gain/bandwidth (no disc2-floor complication; that
    // only engages beyond ≈7 dB at this freq/bandwidth, see EngineCoefficientTests'
    // lowShelfMaxPositiveGainBoundary comment).
    @Test func lowShelfRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 200, gain: 6, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // 30 Hz (DC plateau, ≈ +6 dB): widened window (32768 frames, discard 8192) so the
        // 24576-sample steady-state region still holds ~15.4 cycles at this low frequency
        // (the default window would only give ~1.9).
        let dcExpected = coeffs.gainDB(at: 30, sampleRate: sampleRate)
        let dcMeasured = measureGainDB(band: band, probeFrequency: 30, frameCount: 32768, discard: 8192)
        #expect(abs(dcMeasured - dcExpected) <= 0.75,
                "30 Hz (DC plateau): measured \(dcMeasured) dB, analytic \(dcExpected) dB (≈ +6.05 dB)")

        // 200 Hz (corner, ≈ +3 dB geometric-mean anchor).
        let cornerExpected = coeffs.gainDB(at: 200, sampleRate: sampleRate)
        let cornerMeasured = measureGainDB(band: band, probeFrequency: 200)
        #expect(abs(cornerMeasured - cornerExpected) <= 0.75,
                "200 Hz (corner): measured \(cornerMeasured) dB, analytic \(cornerExpected) dB (≈ +3.0 dB)")

        // 5000 Hz (Nyquist-adjacent plateau, ≈ 0 dB).
        let nyqExpected = coeffs.gainDB(at: 5000, sampleRate: sampleRate)
        let nyqMeasured = measureGainDB(band: band, probeFrequency: 5000)
        #expect(abs(nyqMeasured - nyqExpected) <= 0.75,
                "5000 Hz (Nyquist plateau): measured \(nyqMeasured) dB, analytic \(nyqExpected) dB (≈ 0 dB)")
    }

    // --- highShelf @ 8000 Hz, -4 dB, 1.0 octave (same band as
    // EngineCoefficientTests.highShelfMatchesVicanekGainAnchors modulo bandwidth: 1.0
    // octave here instead of qToOctaves(0.9), to keep this test's Q/settling-time
    // reasoning identical to the rest of this file's convention — the corner anchor
    // still holds exactly at this gain: the disc2 floor only engages beyond ≈8 dB
    // gain magnitude at this freq/bandwidth, hand-verified via the Python mirror used
    // for EngineCoefficientTests' highShelfMaxNegativeGainBoundary).
    @Test func highShelfRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: 1.0, filterType: .highShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // 500 Hz (DC-adjacent plateau, ≈ 0 dB).
        let dcExpected = coeffs.gainDB(at: 500, sampleRate: sampleRate)
        let dcMeasured = measureGainDB(band: band, probeFrequency: 500)
        #expect(abs(dcMeasured - dcExpected) <= 0.75,
                "500 Hz (DC plateau): measured \(dcMeasured) dB, analytic \(dcExpected) dB (≈ 0 dB)")

        // 8000 Hz (corner, ≈ -2 dB geometric-mean anchor).
        let cornerExpected = coeffs.gainDB(at: 8000, sampleRate: sampleRate)
        let cornerMeasured = measureGainDB(band: band, probeFrequency: 8000)
        #expect(abs(cornerMeasured - cornerExpected) <= 0.75,
                "8000 Hz (corner): measured \(cornerMeasured) dB, analytic \(cornerExpected) dB (≈ -2.0 dB)")

        // 20000 Hz (Nyquist-adjacent, ≈ -4.11 dB — not yet fully settled to -4 dB at
        // 20 kHz vs. Nyquist=24 kHz, same "corner close to Nyquist" effect
        // EngineCoefficientTests.highShelfMatchesVicanekGainAnchors already documents).
        let nyqExpected = coeffs.gainDB(at: 20000, sampleRate: sampleRate)
        let nyqMeasured = measureGainDB(band: band, probeFrequency: 20000)
        #expect(abs(nyqMeasured - nyqExpected) <= 0.75,
                "20000 Hz (Nyquist-adjacent): measured \(nyqMeasured) dB, analytic \(nyqExpected) dB (≈ -4.1 dB)")
    }

    // --- lowPass @ 1000 Hz, 1.0 octave (same band as
    // EngineCoefficientTests.lowPassAttenuatesAboveCutoff). Q≈1.41 at this bandwidth, so
    // the cutoff itself has a mild resonant bump (gainCornerSq=Q² anchor) rather than a
    // flat -3 dB point — asserted against the analytic value, not a naive -3 dB guess.
    @Test func lowPassRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .lowPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // 100 Hz (passband, ≈ 0 dB). Widened window: default would give only ~6.4 cycles
        // at 100 Hz; 16384/4096 gives ~25.6.
        let passExpected = coeffs.gainDB(at: 100, sampleRate: sampleRate)
        let passMeasured = measureGainDB(band: band, probeFrequency: 100, frameCount: 16384, discard: 4096)
        #expect(abs(passMeasured - passExpected) <= 0.75,
                "100 Hz (passband): measured \(passMeasured) dB, analytic \(passExpected) dB (≈ 0 dB)")

        // 1000 Hz (cutoff, resonant bump ≈ +2.98 dB = 20·log10(Q)).
        let cutoffExpected = coeffs.gainDB(at: 1000, sampleRate: sampleRate)
        let cutoffMeasured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(abs(cutoffMeasured - cutoffExpected) <= 0.75,
                "1000 Hz (cutoff): measured \(cutoffMeasured) dB, analytic \(cutoffExpected) dB (≈ +3.0 dB)")

        // 8000 Hz (deep stopband, analytic ≈ -37.7 dB) — a threshold check rather than a
        // tight ±dB match: at this attenuation the RMS estimate's absolute noise floor
        // (windowing/leakage from a non-integer cycle count) can shift the measured dB
        // more than the passband/cutoff points above, so this only asserts "clearly deep
        // in the stopband", with 20 dB of margin below the analytic -37.7 dB.
        let stopbandMeasured = measureGainDB(band: band, probeFrequency: 8000)
        #expect(stopbandMeasured < -15.0,
                "8000 Hz (stopband): measured \(stopbandMeasured) dB, analytic ≈ -37.7 dB — expected deep attenuation")
    }

    // --- highPass @ 1000 Hz, 1.0 octave (same band as
    // EngineCoefficientTests.highPassAttenuatesBelowCutoff) — mirror of lowPass above,
    // stopband below cutoff instead of above.
    @Test func highPassRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .highPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // 100 Hz (deep stopband, analytic ≈ -40.0 dB) — widened window for enough cycles
        // at this low probe frequency, same reasoning as lowPass's 100 Hz passband case.
        let stopbandMeasured = measureGainDB(band: band, probeFrequency: 100, frameCount: 16384, discard: 4096)
        #expect(stopbandMeasured < -15.0,
                "100 Hz (stopband): measured \(stopbandMeasured) dB, analytic ≈ -40.0 dB — expected deep attenuation")

        // 1000 Hz (cutoff, resonant bump ≈ +2.98 dB, same Q as lowPass's cutoff above).
        let cutoffExpected = coeffs.gainDB(at: 1000, sampleRate: sampleRate)
        let cutoffMeasured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(abs(cutoffMeasured - cutoffExpected) <= 0.75,
                "1000 Hz (cutoff): measured \(cutoffMeasured) dB, analytic \(cutoffExpected) dB (≈ +3.0 dB)")

        // 8000 Hz (passband, ≈ 0 dB).
        let passExpected = coeffs.gainDB(at: 8000, sampleRate: sampleRate)
        let passMeasured = measureGainDB(band: band, probeFrequency: 8000)
        #expect(abs(passMeasured - passExpected) <= 0.75,
                "8000 Hz (passband): measured \(passMeasured) dB, analytic \(passExpected) dB (≈ 0 dB)")
    }

    // --- bandPass @ 1000 Hz, 1.0 octave (same band as
    // EngineCoefficientTests.bandPassPeaksAtF0AndFallsOffSymmetrically).
    @Test func bandPassRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .bandPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // f0 = 1000 Hz: exact algebraic peak at 0 dB (see the EngineCoefficientTests
        // comment: numerator/denominator cancel exactly at z0 = e^{jw0} for ANY alpha).
        let peakExpected = coeffs.gainDB(at: 1000, sampleRate: sampleRate)
        let peakMeasured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(abs(peakMeasured - peakExpected) <= 0.75,
                "1000 Hz (peak): measured \(peakMeasured) dB, analytic \(peakExpected) dB (≈ 0 dB)")

        // Lower half-power edge, f0/√2 ≈ 707.11 Hz: analytic ≈ -3.01 dB.
        let fLow = 1000.0 / pow(2.0, 0.5)
        let lowExpected = coeffs.gainDB(at: fLow, sampleRate: sampleRate)
        let lowMeasured = measureGainDB(band: band, probeFrequency: fLow)
        #expect(abs(lowMeasured - lowExpected) <= 0.75,
                "\(fLow) Hz (lower edge): measured \(lowMeasured) dB, analytic \(lowExpected) dB (≈ -3.01 dB)")

        // Upper half-power edge, f0·√2 ≈ 1414.21 Hz: analytic ≈ -3.02 dB.
        let fHigh = 1000.0 * pow(2.0, 0.5)
        let highExpected = coeffs.gainDB(at: fHigh, sampleRate: sampleRate)
        let highMeasured = measureGainDB(band: band, probeFrequency: fHigh)
        #expect(abs(highMeasured - highExpected) <= 0.75,
                "\(fHigh) Hz (upper edge): measured \(highMeasured) dB, analytic \(highExpected) dB (≈ -3.02 dB)")

        // 100 Hz, far from f0: analytic ≈ -22.9 dB — threshold check (see lowPass's
        // stopband comment above for why a deep-attenuation point uses an inequality
        // instead of a tight ±dB match).
        let farMeasured = measureGainDB(band: band, probeFrequency: 100)
        #expect(farMeasured < -10.0,
                "100 Hz (far from f0): measured \(farMeasured) dB, analytic ≈ -22.9 dB — expected deep attenuation")
    }

    // --- notch @ 1000 Hz, 1.0 octave (same band as
    // EngineCoefficientTests.notchHasDeepNullAtF0AndApproachesZeroAway).
    @Test func notchRealSignalMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .notch)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // f0 = 1000 Hz: exact algebraic null (Num(z0) = 0 for ANY alpha — see
        // EngineCoefficientTests' notchHasDeepNullAtF0AndApproachesZeroAway comment). The
        // analytic gainDB() value here is an extreme negative number (well past -100 dB,
        // a byproduct of evaluating a mathematically-exact zero in floating point) that a
        // real-signal RMS measurement over a finite window cannot be expected to
        // reproduce with dB-level precision — this only asserts the measured signal is
        // clearly, deeply nulled, not a tight match to the analytic figure.
        let nullMeasured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(nullMeasured < -30.0,
                "1000 Hz (null): measured \(nullMeasured) dB — expected a deep null at f0")

        // 100 Hz, away from the null (analytic ≈ -0.02 dB, essentially flat). Widened
        // window for enough cycles at this low probe frequency.
        let lowExpected = coeffs.gainDB(at: 100, sampleRate: sampleRate)
        let lowMeasured = measureGainDB(band: band, probeFrequency: 100, frameCount: 16384, discard: 4096)
        #expect(abs(lowMeasured - lowExpected) <= 0.75,
                "100 Hz (away from null): measured \(lowMeasured) dB, analytic \(lowExpected) dB (≈ 0 dB)")

        // 10000 Hz, away from the null (analytic ≈ -0.02 dB, essentially flat).
        let highExpected = coeffs.gainDB(at: 10000, sampleRate: sampleRate)
        let highMeasured = measureGainDB(band: band, probeFrequency: 10000)
        #expect(abs(highMeasured - highExpected) <= 0.75,
                "10000 Hz (away from null): measured \(highMeasured) dB, analytic \(highExpected) dB (≈ 0 dB)")
    }

    // MARK: - (c) Silence in → silence out, regardless of the configured filter.
    // Zero input through an LTI system with zero initial state produces exactly zero
    // output (y[n] = b0·0 + s1, s1 initially 0, inductively 0 forever) — no tolerance
    // needed, exact equality.
    @Test func silenceProducesSilence() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let context = makeContext(band: band, sampleRate: sampleRate)
        defer { releaseContext(context) }
        let block = makeIOBlock(context: context)

        let frameCount = 512
        let input = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: nil)   // all zero
        let output = TestAudioBuffer(frameCount: frameCount, channels: 2,
                                      samples: [Float](repeating: 99, count: frameCount * 2))  // sentinel, must be overwritten
        invokeIOBlock(block, input: input, output: output)

        #expect(output.samples.allSatisfy { $0 == 0 },
                "zero input through any filter must produce exactly zero output")
    }

    // MARK: - (d) Bypass flag: identity passthrough regardless of the configured filter.
    // A +6 dB peaking filter at 1000 Hz would visibly boost a 1000 Hz sine (see test
    // above) — with context.bypass=1, the IOProc must instead memcpy input straight to
    // output, so the SAME sine must come out byte-identical (exact equality, not a gain
    // comparison), proving bypass truly ignores the biquad setup rather than approximating
    // a 0 dB response through it.
    @Test func bypassPassesInputThroughUnmodified() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let context = makeContext(band: band, sampleRate: sampleRate)
        defer { releaseContext(context) }
        context.bypass = 1
        let block = makeIOBlock(context: context)

        let frameCount = 512
        let inputSamples = makeSineWave(frequency: 1000, sampleRate: sampleRate, frameCount: frameCount)
        let input = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: inputSamples)
        let output = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: nil)
        invokeIOBlock(block, input: input, output: output)

        #expect(output.samples == inputSamples,
                "bypass must copy input to output byte-for-byte, ignoring the configured filter")
    }
}
