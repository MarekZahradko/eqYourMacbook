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
    // HAND DERIVATION of the expected ≈ +6.02 dB at f0 (RBJ peaking cookbook):
    //   w0 = 2π·1000/48000 = π/24 rad = 7.5°  →  cosW0 = 0.9914449, sinW0 = 0.1305262
    //   bw = 1 octave, Q = 1/(2·sinh((ln2/2)·bw·w0/sinW0))
    //      w0/sinW0 = 1.0028567;  (ln2/2)=0.3465736;  product = 0.3475634
    //      sinh(0.3475634) ≈ 0.354734  →  Q ≈ 1/(2·0.354734) = 1.40952
    //   alpha = sinW0/(2Q) = 0.130526/2.81904 = 0.046302
    //   A = 10^(6/40) = 10^0.15 = 1.412538
    //   b0=1+alpha·A=1.065396, b1=-2cosW0=-1.9828898, b2=1-alpha·A=0.934604
    //   a0=1+alpha/A=1.032776, a1=b1=-1.9828898, a2=1-alpha/A=0.967224
    //   Evaluating H(e^jw0) via BiquadCoefficients.gainDB's own formula (numReal/numImag/
    //   denReal/denImag at w=w0, using cos2W0=0.965926, sin2W0=0.258819) gives
    //   numMagSq/denMagSq ≈ 0.0002742/0.00006853 ≈ 4.0012 → 10·log10(4.0012) ≈ +6.02 dB.
    //   (This matches the codebase's own audited invariant, EngineCoefficientTests.swift's
    //   peakingNonzeroGainBandwidthEdgeIsHalfGain, which pins RBJ peaking's center-frequency
    //   gain as equal to the configured band gain to within ~0.3 dB of trig rounding.)
    // Tolerance ±0.75 dB covers hand-calc rounding (~0.02 dB) plus RMS-window estimation
    // noise (negligible at 45+ periods, but kept generous rather than brittle).
    @Test func sineAtCenterFrequencyMatchesAnalyticGain() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let measured = measureGainDB(band: band, probeFrequency: 1000)
        #expect(abs(measured - 6.02) <= 0.75,
                "measured \(measured) dB at f0, expected ≈ +6.02 dB (RBJ peaking center-gain)")
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
    //   • 1000 Hz (f0): ≈ +6.02 dB, same derivation as the test above.
    @Test func bracketFrequenciesMatchHandDerivedGains() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let cases: [(freq: Double, expectedDB: Double, label: String)] = [
            (30, 0.0, "≈DC"),
            (1000.0 / pow(2.0, 0.5), 3.0, "lower bandwidth edge (f0/√2)"),
            (1000, 6.02, "center (f0)"),
            (1000 * pow(2.0, 0.5), 3.0, "upper bandwidth edge (f0·√2)"),
        ]
        for c in cases {
            let measured = measureGainDB(band: band, probeFrequency: c.freq)
            #expect(abs(measured - c.expectedDB) <= 0.75,
                    "\(c.label) @ \(c.freq) Hz: measured \(measured) dB, expected ≈ \(c.expectedDB) dB")
        }
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
