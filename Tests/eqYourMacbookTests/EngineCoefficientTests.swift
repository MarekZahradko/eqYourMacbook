import Accelerate
import Testing
@testable import eqYourMacbook

/// Tests for the engine's coefficient pipeline and the vDSP_biquadm sign/order
/// convention. The convention test (`testVDSPBiquadmMatchesScalarReference`) is the
/// CANARY: it empirically pins how vDSP interprets the 5 coefficients per section.
/// If Apple's convention ever differs from what we assume, this is the test that
/// catches it on the first Mac run.
@Suite struct EngineCoefficientTests {

    private let sampleRate = 48_000.0

    // MARK: - Peaking 0 dB → identity

    @Test func peakingZeroGainIsIdentity() {
        // A peaking (bell) filter at 0 dB gain is a no-op: H(z) == 1.
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .parametric)
        let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
        #expect(abs(n.b0 - 1) <= 1e-5)
        #expect(abs(n.b1 - n.a1) <= 1e-5)   // numerator == denominator
        #expect(abs(n.b2 - n.a2) <= 1e-5)
        // Magnitude response is exactly flat: any probe frequency reads 0 dB.
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)
        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 0) <= 1e-4)
        #expect(abs(coeffs.gainDB(at: 5000, sampleRate: sampleRate) - 0) <= 1e-4)
    }

    // MARK: - Vicanek matched high-shelf: exact gain anchors at f0 and Nyquist

    @Test func highShelfMatchesVicanekGainAnchors() {
        // Matches EQPresetData.mbaTameTheHighs's first band: high-shelf @ 8000 Hz, -4 dB,
        // at 48 kHz. Vicanek's matched design anchors the corner gain at the geometric
        // mean of the DC/Nyquist plateaus (here sqrt(1 * 10^(-4/20)) → -2 dB at f0) and
        // the true -4 dB plateau exactly at Nyquist — unlike the old RBJ cookbook shelf,
        // whose corner gain at f0 is only ever the -3 dB half-power point regardless of
        // the requested dB gain, and whose Nyquist-adjacent gain drifts off-plateau.
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: EQBand.qToOctaves(0.9), filterType: .highShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-2.0)) <= 0.5)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-4.0)) <= 0.3)
    }

    // MARK: - Vicanek matched low-shelf: exact gain anchors at DC/corner/Nyquist

    @Test func lowShelfMatchesVicanekGainAnchors() {
        // Low-shelf @ 200 Hz, +6 dB, at 48 kHz. DC sits at the full plateau (+6 dB),
        // Nyquist at unity (0 dB), and the corner at the geometric-mean point (+3 dB).
        let band = EQBand(frequency: 200, gain: 6, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 6.0) <= 0.5)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - 3.0) <= 0.5)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.3)
    }

    // MARK: - Vicanek matched low-pass / high-pass: passband/stopband rolloff

    @Test func lowPassAttenuatesAboveCutoff() {
        // Low-pass @ 1000 Hz, default (1.0 octave) bandwidth, at 48 kHz.
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .lowPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // Passband (100 Hz) stays near 0 dB. Independently verified: this design's
        // passband droop at 100 Hz is well under 0.1 dB, so a 1.0 dB tolerance is
        // conservative slack for resonance-adjacent behavior, not a loosened check.
        #expect(abs(coeffs.gainDB(at: 100, sampleRate: sampleRate) - 0.0) <= 1.0)
        // 10 kHz is deep in the stopband — independently verified around -42 dB, so
        // "well attenuated" (< -15 dB) is a safe, non-brittle threshold.
        #expect(coeffs.gainDB(at: 10000, sampleRate: sampleRate) < -15.0)
    }

    @Test func highPassAttenuatesBelowCutoff() {
        // High-pass @ 1000 Hz, default (1.0 octave) bandwidth, at 48 kHz — mirror of
        // the low-pass case above.
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .highPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        // Independently verified around -40 dB at 100 Hz.
        #expect(coeffs.gainDB(at: 100, sampleRate: sampleRate) < -15.0)
        // Independently verified near 0 dB (well under 0.1 dB droop) at 10 kHz.
        #expect(abs(coeffs.gainDB(at: 10000, sampleRate: sampleRate) - 0.0) <= 1.0)
    }

    // MARK: - Orfanidis exact-Q peaking: regression test for the exact-Q redesign

    @Test func peakingNonzeroGainBandwidthEdgeIsHalfGain() {
        // Peaking @ 1000 Hz, +12 dB, 1.0 octave bandwidth, at 48 kHz.
        //
        // A prior version of BiquadResponse computed a second, gain-dependent
        // "alphaOrfanidis = tan(bandwidthRad/2)/A" specifically for peaking/BPF/notch,
        // on the theory that matching the bandwidth-edge gain (half the peak gain, in
        // dB) required dividing the bandwidth-derived alpha by A. That was a genuine
        // bug: this test previously pinned the resulting ≈+2.75 dB at the naive edges
        // as a "regression anchor" instead of the intended +6 dB.
        //
        // Independent derivation (solving |H(e^jw1)|^2 = A^2 for alpha analytically,
        // for the standard RBJ peaking transfer function) shows the bandwidth-edge-gain
        // condition is satisfied by
        //     alpha = |cos(w0) - cos(w1)| / sin(w1)
        // which has NO dependence on A/gain at all — confirmed numerically to be
        // independent of gain (same alpha value for +6, +12, +20, -12 dB). That value
        // is (to within a couple hundredths of a dB) exactly what BiquadResponse's
        // existing sinh-based BW→alpha conversion already computes, so the fix reuses
        // that shared `alpha` for .parametric instead of the broken A-divided one.
        // This test now asserts the mathematically correct +6 dB (half of +12) at the
        // naive octave edges, with tolerance for the small (< 0.1 dB) residual
        // asymmetry inherent to the digital (non-linear-in-frequency) filter shape.
        let f0: Float = 1000
        let band = EQBand(frequency: f0, gain: 12, bandwidth: 1.0, filterType: .parametric)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        let fLow = 1000.0 / pow(2.0, 0.5)   // ≈ 707.11 Hz
        let fHigh = 1000.0 * pow(2.0, 0.5)  // ≈ 1414.21 Hz

        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 12.0) <= 0.3)
        #expect(abs(coeffs.gainDB(at: fLow, sampleRate: sampleRate) - 6.0) <= 0.1)
        #expect(abs(coeffs.gainDB(at: fHigh, sampleRate: sampleRate) - 6.0) <= 0.1)
    }

    // MARK: - Normalization by a0 with hand-computable numbers

    @Test func normalizationDividesByA0() {
        // Construct raw coefficients with a0 = 2 and known integers, verify the
        // normalized struct divides every term by a0.
        let raw = BiquadCoefficients(b0: 4, b1: 2, b2: 8, a0: 2, a1: 6, a2: 10)
        let n = NormalizedBiquadCoeffs(from: raw)
        #expect(abs(n.b0 - 2) <= 1e-6)   // 4/2
        #expect(abs(n.b1 - 1) <= 1e-6)   // 2/2
        #expect(abs(n.b2 - 4) <= 1e-6)   // 8/2
        #expect(abs(n.a1 - 3) <= 1e-6)   // 6/2
        #expect(abs(n.a2 - 5) <= 1e-6)   // 10/2
    }

    // MARK: - Section builder: flat / empty → all identity

    @Test func emptyBandsYieldAllIdentitySections() {
        // Single channel keeps the layout 16*5; assertAllIdentity walks every section.
        let coeffs = EQCoefficients.sectionCoefficients(for: [], sampleRate: sampleRate, channels: 1)
        #expect(coeffs.count == 16 * 5)
        assertAllIdentity(coeffs)
    }

    @Test func stereoLayoutIsSectionMajor() {
        // The default (2-channel) array is 5 * channels * sections doubles, laid out
        // SECTION-MAJOR (channel varies fastest) via EQCoefficients.flatIndex. We assert the
        // exact positions of a recognizable section's b0 across both channels.
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1, filterType: .parametric)
        let coeffs = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate)
        #expect(coeffs.count == 5 * 2 * 16)

        let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))

        // Section 0 (the active band) — both channels carry the same RBJ b0, but at
        // section-major positions: s0ch0 at flatIndex(0,0,2)=0, s0ch1 at flatIndex(0,1,2)=5.
        let s0ch0 = EQCoefficients.flatIndex(section: 0, channel: 0, channels: 2)
        let s0ch1 = EQCoefficients.flatIndex(section: 0, channel: 1, channels: 2)
        #expect(s0ch0 == 0)
        #expect(s0ch1 == 5)
        #expect(abs(coeffs[s0ch0 + 0] - Double(n.b0)) <= 1e-9, "s0ch0 b0")
        #expect(abs(coeffs[s0ch1 + 0] - Double(n.b0)) <= 1e-9, "s0ch1 b0")

        // Section 1 (identity) for both channels — s1ch0 at index 10, s1ch1 at index 15.
        let s1ch0 = EQCoefficients.flatIndex(section: 1, channel: 0, channels: 2)
        let s1ch1 = EQCoefficients.flatIndex(section: 1, channel: 1, channels: 2)
        #expect(s1ch0 == 10)
        #expect(s1ch1 == 15)
        #expect(abs(coeffs[s1ch0 + 0] - 1) <= 1e-9, "s1ch0 b0 identity")
        #expect(abs(coeffs[s1ch1 + 0] - 1) <= 1e-9, "s1ch1 b0 identity")

        // Every section's two per-channel blocks must be identical (same EQ on L and R).
        for s in 0..<16 {
            let c0 = EQCoefficients.flatIndex(section: s, channel: 0, channels: 2)
            let c1 = EQCoefficients.flatIndex(section: s, channel: 1, channels: 2)
            for k in 0..<5 {
                #expect(abs(coeffs[c0 + k] - coeffs[c1 + k]) <= 1e-12,
                        "section \(s) coeff \(k): channels must match")
            }
        }
    }

    @Test func allMutedBandsYieldAllIdentitySections() {
        let bands = [
            EQBand(frequency: 1000, gain: 6, bandwidth: 1, filterType: .parametric, muted: true),
            EQBand(frequency: 4000, gain: -6, bandwidth: 1, filterType: .highShelf, muted: true),
        ]
        let coeffs = EQCoefficients.sectionCoefficients(for: bands, sampleRate: sampleRate, channels: 1)
        assertAllIdentity(coeffs)
    }

    // LAYOUT-ONLY test: this reuses the same coefficient call path as the code under
    // test, so it can only catch a wrong array-copy/section-layout, NOT a wrong DSP
    // formula (that's covered independently by the gain-anchor tests below).
    @Test func activeBandPopulatesFirstSectionRestIdentity() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1, filterType: .parametric)
        let coeffs = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate, channels: 1)

        // Section 0 must equal the normalized RBJ coefficients in [b0,b1,b2,a1,a2] order.
        let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
        #expect(abs(coeffs[0] - Double(n.b0)) <= 1e-6)
        #expect(abs(coeffs[1] - Double(n.b1)) <= 1e-6)
        #expect(abs(coeffs[2] - Double(n.b2)) <= 1e-6)
        #expect(abs(coeffs[3] - Double(n.a1)) <= 1e-6)
        #expect(abs(coeffs[4] - Double(n.a2)) <= 1e-6)

        // Sections 1..15 are identity passthrough.
        for s in 1..<16 {
            #expect(abs(coeffs[s * 5 + 0] - 1) <= 1e-9)
            #expect(abs(coeffs[s * 5 + 1] - 0) <= 1e-9)
            #expect(abs(coeffs[s * 5 + 2] - 0) <= 1e-9)
            #expect(abs(coeffs[s * 5 + 3] - 0) <= 1e-9)
            #expect(abs(coeffs[s * 5 + 4] - 0) <= 1e-9)
        }
    }

    // MARK: - Mute toggle must bypass the coefficient cache
    //
    // EQBand.== deliberately ignores `muted` (preset value identity), but muted DOES
    // change sectionCoefficients' output (muted bands are skipped). A cache keyed only
    // on `bands == previous.bands` would treat a mute toggle as a no-op cache hit and
    // silently keep the old (unmuted) coefficients — regression test for that bug.
    @Test func muteToggleBypassesCache() {
        var band = EQBand(frequency: 1000, gain: 6, bandwidth: 1, filterType: .parametric)
        band.muted = false
        let unmuted = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate, channels: 1)
        #expect(abs(unmuted[0] - 1) > 1e-9,
            "sanity: an active +6dB band's b0 should not equal the identity value")

        band.muted = true
        let muted = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate, channels: 1)
        // Muted → identity passthrough in section 0.
        #expect(abs(muted[0] - 1) <= 1e-9)
        #expect(abs(muted[1] - 0) <= 1e-9)
        #expect(abs(muted[2] - 0) <= 1e-9)
        #expect(abs(muted[3] - 0) <= 1e-9)
        #expect(abs(muted[4] - 0) <= 1e-9)

        band.muted = false
        let unmutedAgain = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate, channels: 1)
        for i in 0..<5 {
            #expect(abs(unmutedAgain[i] - unmuted[i]) <= 1e-9,
                "toggling mute back off must restore the original active-band coefficients, not a stale cached value")
        }
    }

    // MARK: - Clamping: 20 bands → 16 sections, the 4 overflow bands dropped

    @Test func clampsTo16Sections() {
        var bands: [EQBand] = []
        for i in 0..<20 {
            bands.append(EQBand(frequency: Float(100 * (i + 1)), gain: 3,
                                bandwidth: 1, filterType: .parametric))
        }
        let coeffs = EQCoefficients.sectionCoefficients(for: bands, sampleRate: sampleRate, channels: 1)
        #expect(coeffs.count == 16 * 5)
        // All 16 sections should be NON-identity (every one was filled by a band).
        for s in 0..<16 {
            let isIdentity = coeffs[s * 5 + 0] == 1 && coeffs[s * 5 + 1] == 0
                && coeffs[s * 5 + 2] == 0 && coeffs[s * 5 + 3] == 0 && coeffs[s * 5 + 4] == 0
            #expect(!isIdentity, "section \(s) should be an active band, not identity")
        }
    }

    // MARK: - CANARY (sign/order): single-section vDSP_biquadm vs scalar reference
    //
    // Build a 1-section vDSP_biquadm setup from a known peaking filter, push an
    // impulse through it, and compare the output against a scalar Direct-Form-II
    // transposed implementation of the SAME normalized coefficients. If vDSP's
    // interpretation of [b0,b1,b2,a1,a2] (especially the sign of a1/a2) matches our
    // assumption, the two outputs agree to within tolerance.
    //
    // Convention asserted: H(z) = (b0 + b1 z⁻¹ + b2 z⁻²)/(1 + a1 z⁻¹ + a2 z⁻²),
    // vDSP subtracts the a-terms internally, so a1/a2 are passed UN-negated. (The
    // multi-channel/multi-section LAYOUT is pinned separately by the definitive stereo
    // canary testVDSPBiquadmStereoMatchesScalarReference below.)
    @Test func vDSPBiquadmMatchesScalarReference() {
        let band = EQBand(frequency: 2000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))

        let b0 = Double(n.b0), b1 = Double(n.b1), b2 = Double(n.b2)
        let a1 = Double(n.a1), a2 = Double(n.a2)

        let count = 48
        var impulse = [Float](repeating: 0, count: count)
        impulse[0] = 1.0

        // --- vDSP path: single-section, single-channel, stride 1.
        let sectionCoeffs: [Double] = [b0, b1, b2, a1, a2]
        guard let setup = vDSP_biquadm_CreateSetup(sectionCoeffs, 1, 1) else {
            Issue.record("vDSP_biquadm_CreateSetup returned nil")
            return
        }
        defer { vDSP_biquadm_DestroySetup(setup) }

        var vdspOut = [Float](repeating: 0, count: count)
        impulse.withUnsafeBufferPointer { inBuf in
            vdspOut.withUnsafeMutableBufferPointer { outBuf in
                var inChannels: [UnsafePointer<Float>] = [inBuf.baseAddress!]
                var outChannels: [UnsafeMutablePointer<Float>] = [outBuf.baseAddress!]
                inChannels.withUnsafeMutableBufferPointer { ip in
                    outChannels.withUnsafeMutableBufferPointer { op in
                        vDSP_biquadm(setup, ip.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(count))
                    }
                }
            }
        }

        // --- Scalar reference: Direct Form II Transposed with the SAME coefficients.
        // y[n]  = b0·x[n] + s1
        // s1    = b1·x[n] − a1·y[n] + s2
        // s2    = b2·x[n] − a2·y[n]
        var s1 = 0.0, s2 = 0.0
        var refOut = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let x = Double(impulse[i])
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            refOut[i] = Float(y)
        }

        // Compare the first 32 samples (impulse tail has decayed well below 1e-4).
        for i in 0..<32 {
            #expect(abs(vdspOut[i] - refOut[i]) <= 1e-4,
                    "sample \(i): vDSP=\(vdspOut[i]) scalar=\(refOut[i]) — sign/order convention mismatch")
        }
    }

    // MARK: - THE DEFINITIVE CANARY: M=2 sections × N=2 channels, section-major
    //
    // This is the authority that adjudicates SECTION-major vs CHANNEL-major on the
    // first Mac run. We build a two-section cascade of two DIFFERENT RBJ peaking
    // filters, identical across both channels, lay the coefficients out via the SAME
    // EQCoefficients.flatIndex the engine uses, and run a stereo impulse through vDSP_biquadm
    // exactly the way the engine calls it (two planar per-channel buffers, stride 1).
    // We then compare BOTH channels' first 32 output samples against an inline scalar
    // Direct-Form-II-transposed cascade (section 0 → section 1).
    //
    // If this FAILS on the Mac, the layout is wrong: flip ONLY EQCoefficients.flatIndex
    // (channel-major would be `(channel * sections + section) * 5`); nothing else
    // changes, because every builder/reader routes through that helper.
    @Test func vDSPBiquadmStereoMatchesScalarReference() {
        let channels = 2
        let sections = 2

        // Two DISTINCT peaking filters as the two cascade sections.
        let bandA = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let bandB = EQBand(frequency: 4000, gain: -4, bandwidth: 0.7, filterType: .parametric)
        let nA = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: bandA, sampleRate: sampleRate))
        let nB = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: bandB, sampleRate: sampleRate))

        // Section-major coefficient array (5 * channels * sections) via flatIndex: the
        // same section's coefficients on both channels are identical.
        var coeffs = [Double](repeating: 0, count: 5 * channels * sections)
        for c in 0..<channels {
            let bases = [(EQCoefficients.flatIndex(section: 0, channel: c, channels: channels), nA),
                         (EQCoefficients.flatIndex(section: 1, channel: c, channels: channels), nB)]
            for (base, n) in bases {
                coeffs[base + 0] = Double(n.b0)
                coeffs[base + 1] = Double(n.b1)
                coeffs[base + 2] = Double(n.b2)
                coeffs[base + 3] = Double(n.a1)
                coeffs[base + 4] = Double(n.a2)
            }
        }

        // CreateSetup takes (coeffs, M=sections, N=channels) — verified on-Mac
        // 2026-06-10 by testVDSPBiquadmCreateSetupTakesSectionsThenChannels below.
        // (2×2 here, so the values coincide; the ORDER is sections first.)
        guard let setup = vDSP_biquadm_CreateSetup(coeffs,
                                                   vDSP_Length(sections),
                                                   vDSP_Length(channels)) else {
            Issue.record("vDSP_biquadm_CreateSetup returned nil")
            return
        }
        defer { vDSP_biquadm_DestroySetup(setup) }

        let count = 48
        // Two planar input buffers (one per channel), each a unit impulse.
        var inL = [Float](repeating: 0, count: count); inL[0] = 1.0
        var inR = [Float](repeating: 0, count: count); inR[0] = 1.0
        var outL = [Float](repeating: 0, count: count)
        var outR = [Float](repeating: 0, count: count)

        inL.withUnsafeBufferPointer { ipL in
            inR.withUnsafeBufferPointer { ipR in
                outL.withUnsafeMutableBufferPointer { opL in
                    outR.withUnsafeMutableBufferPointer { opR in
                        // Channel-pointer arrays exactly as the engine's RT scratch holds
                        // them: per-channel base pointers, stride 1 (planar).
                        var inChannels: [UnsafePointer<Float>] = [ipL.baseAddress!, ipR.baseAddress!]
                        var outChannels: [UnsafeMutablePointer<Float>] = [opL.baseAddress!, opR.baseAddress!]
                        inChannels.withUnsafeMutableBufferPointer { ip in
                            outChannels.withUnsafeMutableBufferPointer { op in
                                vDSP_biquadm(setup, ip.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(count))
                            }
                        }
                    }
                }
            }
        }

        // Scalar reference: DFII-T cascade, section A then section B (same per channel).
        let ref = scalarCascade(impulseLength: count, sectionA: nA, sectionB: nB)

        for i in 0..<32 {
            #expect(abs(outL[i] - ref[i]) <= 1e-4,
                    "L sample \(i): vDSP=\(outL[i]) scalar=\(ref[i]) — section/channel layout or sign mismatch")
            #expect(abs(outR[i] - ref[i]) <= 1e-4,
                    "R sample \(i): vDSP=\(outR[i]) scalar=\(ref[i]) — section/channel layout or sign mismatch")
        }
    }

    // MARK: - CANARY (argument order): CreateSetup is (coeffs, M=SECTIONS, N=CHANNELS)
    //
    // The stereo canary above uses 2×2, which is blind to a swapped M/N — that swap
    // shipped and crashed in the IOProc (vDSP read N=16 "channel" pointers from the
    // 2-slot scratch arrays). This test pins the order with ASYMMETRIC dimensions:
    // 2 sections × 1 channel, section 0 = gain 1.0, section 1 = gain 0.5.
    //
    //   - Correct order (2 sections, 1 channel): one channel through a two-section
    //     cascade → impulse out = 1.0 × 0.5 = 0.5, and out[1] (sentinel) untouched.
    //   - Swapped order (1 section, 2 channels): vDSP would write BOTH outputs
    //     (out0=1.0, out1=0.5) and the cascade assertion fails.
    //
    // NOTE: the archived vDSP Programming Guide documents M/N the other way around;
    // the implementation (verified on-Mac 2026-06-10) wins. Do not "fix" this back
    // to match the guide.
    @Test func vDSPBiquadmCreateSetupTakesSectionsThenChannels() {
        // Two pure-gain sections, channel count 1: [b0,b1,b2,a1,a2] per section.
        let coeffs: [Double] = [1.0, 0, 0, 0, 0,
                                0.5, 0, 0, 0, 0]
        guard let setup = vDSP_biquadm_CreateSetup(coeffs,
                                                   2,    // M = sections
                                                   1) else {  // N = channels
            Issue.record("vDSP_biquadm_CreateSetup returned nil")
            return
        }
        defer { vDSP_biquadm_DestroySetup(setup) }

        let count = 8
        var inA = [Float](repeating: 0, count: count); inA[0] = 1.0
        var inB = [Float](repeating: 0, count: count); inB[0] = 1.0
        var outA = [Float](repeating: 99, count: count)
        var outB = [Float](repeating: 99, count: count)  // sentinel: must stay untouched

        inA.withUnsafeBufferPointer { iA in
            inB.withUnsafeBufferPointer { iB in
                outA.withUnsafeMutableBufferPointer { oA in
                    outB.withUnsafeMutableBufferPointer { oB in
                        // Two pointer slots provided (like the engine's scratch), but a
                        // correctly-built 1-channel setup must only ever read slot 0.
                        var inChannels: [UnsafePointer<Float>] = [iA.baseAddress!, iB.baseAddress!]
                        var outChannels: [UnsafeMutablePointer<Float>] = [oA.baseAddress!, oB.baseAddress!]
                        inChannels.withUnsafeMutableBufferPointer { ip in
                            outChannels.withUnsafeMutableBufferPointer { op in
                                vDSP_biquadm(setup, ip.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(count))
                            }
                        }
                    }
                }
            }
        }

        #expect(abs(outA[0] - 0.5) <= 1e-6,
                "channel 0 impulse should pass a 1.0×0.5 two-section cascade — M is not being read as the section count")
        #expect(outB[0] == 99,
                "a 1-channel setup wrote to a second channel slot — N is not being read as the channel count")
    }

    // MARK: - Helpers

    /// Inline scalar DFII-T two-section cascade (section A feeds section B) over a unit
    /// impulse. Mirrors the convention asserted for vDSP: a1/a2 subtracted internally.
    private func scalarCascade(impulseLength count: Int,
                               sectionA nA: NormalizedBiquadCoeffs,
                               sectionB nB: NormalizedBiquadCoeffs) -> [Float] {
        var a1s = 0.0, a2s = 0.0   // section A delay state
        var b1s = 0.0, b2s = 0.0   // section B delay state
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let x = i == 0 ? 1.0 : 0.0
            // Section A
            let yA = Double(nA.b0) * x + a1s
            a1s = Double(nA.b1) * x - Double(nA.a1) * yA + a2s
            a2s = Double(nA.b2) * x - Double(nA.a2) * yA
            // Section B (input is section A's output)
            let yB = Double(nB.b0) * yA + b1s
            b1s = Double(nB.b1) * yA - Double(nB.a1) * yB + b2s
            b2s = Double(nB.b2) * yA - Double(nB.a2) * yB
            out[i] = Float(yB)
        }
        return out
    }

    // Checks every 5-double block, so it is layout- and channel-count-agnostic for
    // the all-identity case; the "section" label is only accurate for channels == 1.
    // sourceLocation defaults to the caller's site so failures point at the real test.
    private func assertAllIdentity(_ coeffs: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        let sections = coeffs.count / 5
        for s in 0..<sections {
            #expect(abs(coeffs[s * 5 + 0] - 1) <= 1e-9, "section \(s) b0", sourceLocation: sourceLocation)
            #expect(abs(coeffs[s * 5 + 1] - 0) <= 1e-9, "section \(s) b1", sourceLocation: sourceLocation)
            #expect(abs(coeffs[s * 5 + 2] - 0) <= 1e-9, "section \(s) b2", sourceLocation: sourceLocation)
            #expect(abs(coeffs[s * 5 + 3] - 0) <= 1e-9, "section \(s) a1", sourceLocation: sourceLocation)
            #expect(abs(coeffs[s * 5 + 4] - 0) <= 1e-9, "section \(s) a2", sourceLocation: sourceLocation)
        }
    }
}
