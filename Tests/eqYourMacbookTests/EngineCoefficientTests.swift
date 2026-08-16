import Accelerate
import Testing
@testable import eqYourMacbook

/// Tests for the engine's coefficient pipeline and the vDSP_biquadm sign/order
/// convention. The convention test (`testVDSPBiquadmMatchesScalarReference`) is the
/// CANARY: it empirically pins how vDSP interprets the 5 coefficients per section.
/// If Apple's convention ever differs from what we assume, this is the test that
/// catches it on the first Mac run.
///
/// `.serialized`: defense-in-depth. `EQCoefficients`'s static memoization cache is now
/// properly lock-guarded, so parallel `@Test` execution should no longer race on it —
/// but correctness matters more than parallelism speed for a shared static this close
/// to the RT path, so this suite stays serialized regardless.
@Suite(.serialized) struct EngineCoefficientTests {

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
        // at 48 kHz. Vicanek's matched design anchors the corner gain at the geometric mean
        // of the DC/Nyquist plateaus (-2 dB at f0) and the true -4 dB plateau at Nyquist —
        // unlike the old RBJ cookbook shelf, whose corner is always the -3 dB half-power
        // point regardless of requested gain, and whose Nyquist-adjacent gain drifts off-plateau.
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
        // "alphaOrfanidis = tan(bandwidthRad/2)/A" for peaking/BPF/notch, on the theory
        // that matching the bandwidth-edge gain (half the peak gain, in dB) required
        // dividing the bandwidth-derived alpha by A. That was a genuine bug: this test
        // previously pinned the resulting ≈+2.75 dB at the naive edges instead of the
        // intended +6 dB.
        //
        // Independent derivation (solving |H(e^jw1)|^2 = A^2 analytically for the RBJ
        // peaking transfer function) shows the bandwidth-edge-gain condition is satisfied
        // by alpha = |cos(w0) - cos(w1)| / sin(w1), which has NO dependence on A/gain at
        // all — and matches BiquadResponse's existing sinh-based BW→alpha conversion to
        // within a couple hundredths of a dB. The fix reuses that shared `alpha` for
        // .parametric instead of the broken A-divided one; this test now asserts the
        // mathematically correct +6 dB (half of +12) at the naive octave edges, with
        // tolerance for the small residual asymmetry inherent to the digital filter shape.
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

    // MARK: - bandPass: RBJ "constant 0 dB peak gain" BPF — peaks exactly at f0
    //
    // Substituting z0 = e^{jw0} into H(z), numerator and denominator both reduce to
    // z0^-1·2j·alpha·sin(w0) and CANCEL exactly, giving H(z0) = 1 (0 dB) for ANY alpha/Q
    // — an exact algebraic identity, not an approximation. alpha is derived from octave
    // bandwidth via the SAME RBJ "alpha from BW" formula shared with peaking, which the
    // RBJ cookbook defines so the half-power (-3.0103 dB) points land exactly at the
    // requested octave bandwidth's edges for BPF/notch.
    @Test func bandPassPeaksAtF0AndFallsOffSymmetrically() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .bandPass)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        let fLow = 1000.0 / pow(2.0, 0.5)   // ≈ 707.11 Hz
        let fHigh = 1000.0 * pow(2.0, 0.5)  // ≈ 1414.21 Hz

        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 0.0) <= 0.05)
        // Half-power points: 10*log10(0.5) ≈ -3.0103 dB.
        #expect(abs(coeffs.gainDB(at: fLow, sampleRate: sampleRate) - (-3.0103)) <= 0.1)
        #expect(abs(coeffs.gainDB(at: fHigh, sampleRate: sampleRate) - (-3.0103)) <= 0.1)
        // Symmetric falloff in log-frequency: both edges land at (nearly) the same gain.
        #expect(abs(coeffs.gainDB(at: fLow, sampleRate: sampleRate)
                    - coeffs.gainDB(at: fHigh, sampleRate: sampleRate)) <= 0.05)
        // Well away from f0 the band-pass keeps rolling off.
        #expect(coeffs.gainDB(at: 100, sampleRate: sampleRate) < -15.0)
        #expect(coeffs.gainDB(at: 10000, sampleRate: sampleRate) < -15.0)
    }

    // MARK: - notch: exact null at f0, exact unity at DC and Nyquist
    //
    // Substituting z0=e^{jw0}: Num(z0) reduces to 0 EXACTLY — an exact null at f0 for any
    // alpha/Q. At DC (z=1) and Nyquist (z=-1), Num and Den reduce to identical
    // expressions, so |H|=1 (0 dB) exactly at both. So the notch is exactly flat (0 dB)
    // at DC/Nyquist with an exact null at f0; nearby frequencies (well away from f0)
    // should already be very close back to 0 dB.
    @Test func notchHasDeepNullAtF0AndApproachesZeroAway() {
        let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: .notch)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(coeffs.gainDB(at: 1000, sampleRate: sampleRate) < -60.0,
                "exact null at f0 expected (Num(z0)=0 by algebra)")
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.05)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.05)
    }

    // MARK: - Nyquist-safe clamp: f0 = min(frequency, sampleRate*0.49)
    //
    // At a low sample rate the clamp actually engages (EQBand's frequencyRange tops out
    // at 20000, which can legitimately exceed sampleRate*0.49 when sampleRate < ~40800).
    // At fs=32000, sampleRate*0.49 = 15680, so a band requesting 20000 Hz must be clamped
    // internally to 15680 before any trig/pole math runs — without the clamp, w0 =
    // 2π·20000/32000 = 1.25π > π (past Nyquist, aliased), producing DIFFERENT
    // coefficients than a band built directly at 15680 Hz. (bw=0.05, not the 1.0 default,
    // to stay out of the extreme-sinh blowup regime the BW→Q formula hits near true Nyquist.)
    @Test func nyquistClampMatchesExplicitlyClampedFrequency() {
        let lowSampleRate = 32_000.0
        let clampedFreq = Float(lowSampleRate * 0.49)   // 15680, exactly representable in Float
        let aboveClamp = EQBand(frequency: 20000, gain: 6, bandwidth: 0.05, filterType: .parametric)
        let atClamp = EQBand(frequency: clampedFreq, gain: 6, bandwidth: 0.05, filterType: .parametric)

        let coeffsAbove = BiquadResponse.coefficients(for: aboveClamp, sampleRate: lowSampleRate)
        let coeffsAtClamp = BiquadResponse.coefficients(for: atClamp, sampleRate: lowSampleRate)

        #expect(abs(coeffsAbove.b0 - coeffsAtClamp.b0) <= 1e-6)
        #expect(abs(coeffsAbove.b1 - coeffsAtClamp.b1) <= 1e-6)
        #expect(abs(coeffsAbove.b2 - coeffsAtClamp.b2) <= 1e-6)
        #expect(abs(coeffsAbove.a0 - coeffsAtClamp.a0) <= 1e-6)
        #expect(abs(coeffsAbove.a1 - coeffsAtClamp.a1) <= 1e-6)
        #expect(abs(coeffsAbove.a2 - coeffsAtClamp.a2) <= 1e-6)

        // The clamp must also prevent a blow-up (a real risk right at w0 → π): every
        // term stays finite.
        for c in [coeffsAbove.b0, coeffsAbove.b1, coeffsAbove.b2,
                  coeffsAbove.a0, coeffsAbove.a1, coeffsAbove.a2] {
            #expect(c.isFinite)
        }
    }

    // MARK: - Bandwidth-range extremes (EQBand.bandwidthRange: 0.05...4.0 octaves)
    //
    // Hand-derived via BiquadResponse's own formulas (Python cross-check, IEEE-754 double,
    // 7 significant figures): w0 = 2π·1000/48000, A = 10^(12/40); bw=0.05 gives Q≈28.77,
    // alpha≈0.00227; bw=4.0 gives Q≈0.2655, alpha≈0.2458. b0=1+alpha·A, b2=1-alpha·A,
    // a0=1+alpha/A, a2=1-alpha/A, b1=a1=-2cos(w0) (bw-independent).
    //
    // Peak gain at f0 is exactly the nominal dB gain independent of alpha/Q: the same
    // cancellation algebra as the bandPass/notch derivations above gives H(z0) = A²,
    // so gainDB(f0) = 20·log10(A²) = gain exactly.
    @Test func parametricNarrowestBandwidthIsFiniteAndMatchesHandDerivation() {
        let band = EQBand(frequency: 1000, gain: 12, bandwidth: 0.05, filterType: .parametric)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.b0 - 1.0045261189) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.9954738811) <= 1e-6)
        #expect(abs(coeffs.a0 - 1.0011369097) <= 1e-6)
        #expect(abs(coeffs.a1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.a2 - 0.9988630903) <= 1e-6)
        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 12.0) <= 0.1)
    }

    @Test func parametricWidestBandwidthIsFiniteAndMatchesHandDerivation() {
        let band = EQBand(frequency: 1000, gain: 12, bandwidth: 4.0, filterType: .parametric)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.b0 - 1.4905129498) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.5094870502) <= 1e-6)
        #expect(abs(coeffs.a0 - 1.1232112823) <= 1e-6)
        #expect(abs(coeffs.a1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.a2 - 0.8767887177) <= 1e-6)
        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 12.0) <= 0.1)
    }

    // Vicanek matched shelf: the DC and Nyquist anchors are preserved EXACTLY at any
    // bandwidth (algebraically they fall out of the b0+b1+b2/b0-b1+b2 sums, which never
    // depend on how the disc2 floor below splits (b0+b2) into b0 vs b2 individually) —
    // confirmed at 20 Hz and 20000 Hz (the latter within the base test's 0.3 dB tolerance
    // since a narrow bw=0.05 shelf's transition has already settled well before 20 kHz).
    //
    // The CORNER anchor (|H(w0)|²=A² exactly), however, does NOT survive at this extreme:
    // b0/b2's individual split solves `disc2 = u² - 4·(p2/16)`, which is analytically
    // negative here (≈ -0.1013, independently re-derived), so the `max(..., 0.0)` floor
    // engages and the corner value is NOT the naively-expected -2 dB — it's ≈ +18.895 dB
    // (NOT a test bug, a genuine, previously-untested numerical property of this DSP
    // design at the narrow-bandwidth extreme).
    @Test func highShelfNarrowestBandwidthAnchorsPartiallyHoldAndAreFinite() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: 0.05, filterType: .highShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        // DC-adjacent: exact anchor (0 dB, highShelf's DC plateau) survives.
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.01)
        // Nyquist-adjacent: exact anchor (-4 dB) survives, same tolerance as the base test.
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-4.0)) <= 0.3)
        // Corner: the disc2 floor breaks the naive -2 dB anchor here — this IS the
        // correct value for this design at this extreme, not a loosened assertion.
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - 18.895) <= 0.01)
    }

    // At the WIDE extreme the corner anchor survives exactly (disc2 stays positive
    // here), but the wide transition band means 20 kHz — under 1.3 octaves from f0 —
    // hasn't yet settled onto the Nyquist plateau, so that check needs a looser,
    // hand-verified tolerance instead of the base test's tight one.
    @Test func highShelfWidestBandwidthCornerAnchorHoldsAndIsFinite() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: 4.0, filterType: .highShelf)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.01)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-2.0)) <= 0.05)
        // Not yet settled to the true -4 dB Nyquist plateau at 20 kHz (hand-verified
        // ≈ -3.1645 dB) — a wide/low-Q shelf's transition band is broad, so this is
        // expected, not a bug.
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-3.1645)) <= 0.01)
    }

    // MARK: - Extreme gain values (EQBand.gainRange: -24...+24 dB)
    //
    // alpha at f0=1000/bw=1.0/fs=48000 ≈ 0.0462852986 (gain-independent, same value
    // peakingNonzeroGainBandwidthEdgeIsHalfGain relies on). +24 dB: A ≈ 3.9810717055;
    // -24 dB: A ≈ 0.2511886432 (= 1/3.9810717055 exactly).
    @Test func parametricMaxPositiveGainBoundary() {
        let band = EQBand(frequency: 1000, gain: 24, bandwidth: 1.0, filterType: .parametric)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.b0 - 1.1842650925) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.8157349075) <= 1e-6)
        #expect(abs(coeffs.a0 - 1.0116263413) <= 1e-6)
        #expect(abs(coeffs.a1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.a2 - 0.9883736587) <= 1e-6)
        // Peak at f0 equals the nominal gain exactly (see bandwidth-extreme tests above
        // for the H(z0)=A² derivation, which holds for any A).
        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - 24.0) <= 0.1)
    }

    @Test func parametricMaxNegativeGainBoundary() {
        // Same alpha as the +24 dB case; A and 1/A swap roles, so b0/b2 and a0/a2 swap
        // relative to the +24 dB case above.
        let band = EQBand(frequency: 1000, gain: -24, bandwidth: 1.0, filterType: .parametric)
        let coeffs = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)

        #expect(abs(coeffs.b0 - 1.0116263413) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.9883736587) <= 1e-6)
        #expect(abs(coeffs.a0 - 1.1842650925) <= 1e-6)
        #expect(abs(coeffs.a1 - (-1.9828897227)) <= 1e-6)
        #expect(abs(coeffs.a2 - 0.8157349075) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 1000, sampleRate: sampleRate) - (-24.0)) <= 0.1)
    }

    // MARK: - EQCoefficients.masterGainDB: gain-staging compensation policy
    @Test func masterGainDBDisabledIsAlwaysZeroRegardlessOfBands() {
        let bands = [EQBand(frequency: 1000, gain: 12), EQBand(frequency: 2000, gain: -6)]
        #expect(EQCoefficients.masterGainDB(for: bands, enabled: false) == 0)
    }

    @Test func masterGainDBAllNonPositiveGainsIsZero() {
        let bands = [EQBand(frequency: 1000, gain: -6), EQBand(frequency: 2000, gain: 0)]
        #expect(EQCoefficients.masterGainDB(for: bands, enabled: true) == 0)
    }

    @Test func masterGainDBMixedGainsReturnsNegativeOfMaxPositive() {
        let bands = [
            EQBand(frequency: 1000, gain: 9),
            EQBand(frequency: 2000, gain: -6),
            EQBand(frequency: 500, gain: 3),
        ]
        #expect(EQCoefficients.masterGainDB(for: bands, enabled: true) == -9)
    }

    @Test func masterGainDBExcludesMutedBandsFromMax() {
        var loud = EQBand(frequency: 1000, gain: 20)
        loud.muted = true
        let bands = [loud, EQBand(frequency: 2000, gain: 5)]
        // The +20 dB band is muted, so it must NOT count toward the max — the answer
        // is driven by the +5 dB band instead of -20.
        #expect(EQCoefficients.masterGainDB(for: bands, enabled: true) == -5)
    }

    // MARK: - sectionCoefficients: master-gain folding into section 0's numerator
    //
    // masterGainDB is folded as a LINEAR scale (10^(dB/20)) applied only to section 0's
    // b0/b1/b2 (a1/a2 untouched) — series cascade means scaling one section's numerator
    // scales the whole chain by the same factor.
    @Test func sectionCoefficientsFoldsMasterGainIntoSection0Numerator() {
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let masterGainDB = -6.0
        let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
        let linearGain = pow(10.0, masterGainDB / 20.0)   // 10^(-0.3) ≈ 0.5011872336

        let coeffs = EQCoefficients.sectionCoefficients(for: [band], sampleRate: sampleRate,
                                                         channels: 1, masterGainDB: masterGainDB)

        #expect(abs(coeffs[0] - n.b0 * linearGain) <= 1e-9)
        #expect(abs(coeffs[1] - n.b1 * linearGain) <= 1e-9)
        #expect(abs(coeffs[2] - n.b2 * linearGain) <= 1e-9)
        // a1/a2 are NOT scaled by master gain.
        #expect(abs(coeffs[3] - n.a1) <= 1e-9)
        #expect(abs(coeffs[4] - n.a2) <= 1e-9)
    }

    // MARK: - gainDB sentinel branch: guard denMagSq > 1e-30 else { return -120.0 }
    //
    // Reachable only with a pole exactly on the unit circle at the probed frequency — no
    // EQBand-derived filter here produces one, so this is exercised with contrived
    // BiquadCoefficients: a0=1, a1=1, a2=0 normalizes to na1=1, na2=0. At Nyquist (w=π),
    // cos(π) == -1.0 exactly in IEEE-754 double, giving denReal = 0 exactly; sin(π) ≈
    // 1.2246e-16 gives denImag ≈ -1.2246e-16, so denMagSq ≈ 1.5e-32 — safely under the
    // 1e-30 floor, confirming the branch is reachable, not dead code.
    @Test func gainDBSentinelBranchIsReachableWithPoleOnUnitCircle() {
        let coeffs = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a0: 1, a1: 1, a2: 0)
        let gain = coeffs.gainDB(at: sampleRate / 2, sampleRate: sampleRate)
        #expect(gain == -120.0)
    }

    // MARK: - CANARY (sign/order): single-section vDSP_biquadm vs scalar reference
    //
    // Build a 1-section vDSP_biquadm setup from a known peaking filter, push an impulse
    // through it, and compare against a scalar Direct-Form-II-transposed implementation
    // of the SAME normalized coefficients — if vDSP's interpretation of [b0,b1,b2,a1,a2]
    // (especially the sign of a1/a2) matches our assumption, the outputs agree.
    //
    // Convention asserted: H(z) = (b0 + b1 z⁻¹ + b2 z⁻²)/(1 + a1 z⁻¹ + a2 z⁻²), vDSP
    // subtracts the a-terms internally, so a1/a2 are passed UN-negated. (The multi-channel/
    // multi-section LAYOUT is pinned separately by testVDSPBiquadmStereoMatchesScalarReference below.)
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
    // This is the authority that adjudicates SECTION-major vs CHANNEL-major on the first
    // Mac run. We build a two-section cascade of two DIFFERENT RBJ peaking filters,
    // identical across both channels, lay the coefficients out via the SAME
    // EQCoefficients.flatIndex the engine uses, run a stereo impulse through vDSP_biquadm
    // exactly the way the engine calls it, and compare BOTH channels' first 32 output
    // samples against an inline scalar Direct-Form-II-transposed cascade.
    //
    // If this FAILS on the Mac, the layout is wrong: flip ONLY EQCoefficients.flatIndex
    // (channel-major would be `(channel * sections + section) * 5`); nothing else changes,
    // because every builder/reader routes through that helper. NEVER loosen this test's
    // tolerance or skip it to get green — it is the sole adjudicator of this decision.
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
    // 2-slot scratch arrays). This test pins the order with ASYMMETRIC dimensions: 2
    // sections × 1 channel, section 0 = gain 1.0, section 1 = gain 0.5. Correct order
    // (2 sections, 1 channel) produces impulse out = 1.0 × 0.5 = 0.5 with out[1]
    // (sentinel) untouched; a swapped order (1 section, 2 channels) would write BOTH
    // outputs instead and fail the assertion.
    //
    // NOTE: the archived vDSP Programming Guide documents M/N the other way around; the
    // implementation (verified on-Mac 2026-06-10) wins. Do not "fix" this back to match the guide.
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
