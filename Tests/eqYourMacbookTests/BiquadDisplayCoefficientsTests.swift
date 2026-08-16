import Foundation
import Testing
@testable import eqYourMacbook

/// Tests for `BiquadResponse.displayCoefficients(for:sampleRate:)` — the UI-curve-only
/// counterpart to `coefficients(for:sampleRate:)` (see that function's doc comment in
/// BiquadResponse.swift; `coefficients` itself is covered in EngineCoefficientTests.swift).
/// This suite covers displayCoefficients' own contract: it diverges from coefficients only
/// where expected, reproduces the classic RBJ cookbook shape, and stays monotonic near
/// Nyquist for shelf bands — the property Vicanek matching can't guarantee and the reason
/// this function exists at all.
@Suite struct BiquadDisplayCoefficientsTests {

    private let sampleRate = 48_000.0

    // MARK: - Divergence from coefficients(for:) for shelf/LP/HP

    @Test func displayCoefficientsDivergesFromVicanekForShelfTypes() {
        // lowPass/highPass are deliberately excluded: their classic RBJ forms already anchor
        // to the same DC/Nyquist/corner values Vicanek matching enforces, so the two paths
        // produce numerically identical biquads for those two types. Only shelf types diverge.
        let types: [FilterType] = [.lowShelf, .highShelf]
        for filterType in types {
            let band = EQBand(frequency: 8000, gain: -4, bandwidth: 0.9, filterType: filterType)
            let vicanek = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)
            let display = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
            // At least one coefficient must differ meaningfully — proves displayCoefficients
            // isn't accidentally just forwarding to the Vicanek path for these types.
            let differs = abs(display.b0 - vicanek.b0) > 1e-6
                || abs(display.b1 - vicanek.b1) > 1e-6
                || abs(display.b2 - vicanek.b2) > 1e-6
                || abs(display.a0 - vicanek.a0) > 1e-6
                || abs(display.a1 - vicanek.a1) > 1e-6
                || abs(display.a2 - vicanek.a2) > 1e-6
            #expect(differs, "\(filterType): displayCoefficients should differ from the Vicanek-matched coefficients")
        }
    }

    // MARK: - Equivalence with coefficients(for:) for parametric/bandPass/notch/lowPass/highPass

    @Test func displayCoefficientsPreservesParametricBandPassNotchInvariant() {
        // Contract, not implementation detail: parametric/bandPass/notch have no
        // Vicanek-vs-RBJ divergence to correct for, so the UI curve must always show
        // exactly what the audio engine applies for these three types — pinned here so a
        // future special-case for one of them breaks this test rather than silently
        // shipping a UI/audio mismatch.
        let types: [FilterType] = [.parametric, .bandPass, .notch]
        for filterType in types {
            let band = EQBand(frequency: 1000, gain: filterType == .parametric ? 6 : 0, bandwidth: 1.0, filterType: filterType)
            let vicanek = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)
            let display = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
            #expect(display.b0 == vicanek.b0)
            #expect(display.b1 == vicanek.b1)
            #expect(display.b2 == vicanek.b2)
            #expect(display.a0 == vicanek.a0)
            #expect(display.a1 == vicanek.a1)
            #expect(display.a2 == vicanek.a2)
        }
    }

    @Test func displayCoefficientsMatchesWithinToleranceForLowPassAndHighPass() {
        // lowPass/highPass go through a structurally different derivation (classic RBJ
        // closed form vs. Vicanek's sqrt-based numerator solve) that's mathematically
        // equivalent but not bit-identical — hence a tolerance, not ==, here.
        let types: [FilterType] = [.lowPass, .highPass]
        for filterType in types {
            let band = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0, filterType: filterType)
            let vicanek = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)
            let display = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
            #expect(abs(display.b0 - vicanek.b0) <= 1e-6)
            #expect(abs(display.b1 - vicanek.b1) <= 1e-6)
            #expect(abs(display.b2 - vicanek.b2) <= 1e-6)
            #expect(abs(display.a0 - vicanek.a0) <= 1e-6)
            #expect(abs(display.a1 - vicanek.a1) <= 1e-6)
            #expect(abs(display.a2 - vicanek.a2) <= 1e-6)
        }
    }

    // MARK: - Classic RBJ shape: corner gain lands at half the target gain in dB (the
    // geometric mean of the DC/Nyquist plateaus) — same anchor Vicanek matching enforces
    // (see highShelfMatchesVicanekGainAnchors in EngineCoefficientTests.swift). Confirms
    // displayCoefficients still hits the expected corner gain rather than drifting off.

    @Test func highShelfDisplayCornerIsHalfTargetGain() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: EQBand.qToOctaves(0.9), filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-2.0)) <= 0.5)
    }

    @Test func lowShelfDisplayCornerIsHalfTargetGain() {
        let band = EQBand(frequency: 200, gain: 6, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - 3.0) <= 0.5)
    }

    // MARK: - Monotonicity near Nyquist: the actual bug this function exists to avoid.
    // Vicanek's matched quadratic can dip-and-recover approaching its forced Nyquist anchor
    // when the corner sits close to Nyquist; the RBJ cookbook form has no such forced
    // anchor, so it should approach its Nyquist-adjacent gain monotonically instead.

    @Test func highShelfDisplayIsMonotonicApproachingNyquistForCornerNearNyquist() {
        // Corner at 18 kHz is a large fraction of 44.1 kHz's Nyquist (22.05 kHz) —
        // exactly the "corner close to Nyquist" regime that makes Vicanek's fit dip.
        let sr = 44_100.0
        let band = EQBand(frequency: 18000, gain: 12, bandwidth: 1.0, filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sr)

        let frequencies = (0..<24).map { i -> Double in
            let t = Double(i) / 23.0
            return 18000.0 * pow((sr / 2 * 0.999) / 18000.0, t)
        }
        let samples = frequencies.map { coeffs.gainDB(at: $0, sampleRate: sr) }
        for i in 1..<samples.count {
            #expect(samples[i] >= samples[i - 1] - 1e-6,
                    "boosting high-shelf display curve dipped between \(frequencies[i-1]) Hz (\(samples[i-1]) dB) and \(frequencies[i]) Hz (\(samples[i]) dB)")
        }
    }

    // MARK: - Nyquist-safe clamp: displayCoefficients must clamp identically to
    // coefficients(for:) — both derive f0/w0/cosW0/sinW0 from the same private PoleParams
    // struct, so a clamp bug in either function's own application would show up here.
    //
    // Method (mirrors EngineCoefficientTests.nyquistClampMatchesExplicitlyClampedFrequency):
    // a band requesting 20000 Hz (above sampleRate*0.49 = 15680 Hz at fs=32000) must
    // produce byte-for-byte identical coefficients to a band built directly AT 15680 Hz —
    // an unclamped w0 (2π·20000/32000 = 1.25π, past Nyquist, aliased) would produce a
    // DIFFERENT result. Checked for both lowShelf/highShelf and both coefficients(for:)/
    // displayCoefficients(for:). bw=0.05 (not the 1.0 default) stays out of the
    // extreme-sinh blowup regime the BW→Q formula hits near true Nyquist.
    @Test func displayCoefficientsClampsIdenticallyToCoefficientsAtNyquist() {
        let lowSampleRate = 32_000.0
        let clampedFreq = Float(lowSampleRate * 0.49)   // 15680, exactly representable in Float

        for (filterType, gain) in [(FilterType.lowShelf, Float(6)), (FilterType.highShelf, Float(-4))] {
            let aboveClamp = EQBand(frequency: 20000, gain: gain, bandwidth: 0.05, filterType: filterType)
            let atClamp = EQBand(frequency: clampedFreq, gain: gain, bandwidth: 0.05, filterType: filterType)

            let vicanekAbove = BiquadResponse.coefficients(for: aboveClamp, sampleRate: lowSampleRate)
            let vicanekAtClamp = BiquadResponse.coefficients(for: atClamp, sampleRate: lowSampleRate)
            #expect(abs(vicanekAbove.b0 - vicanekAtClamp.b0) <= 1e-9, "\(filterType): coefficients(for:) b0")
            #expect(abs(vicanekAbove.b1 - vicanekAtClamp.b1) <= 1e-9, "\(filterType): coefficients(for:) b1")
            #expect(abs(vicanekAbove.b2 - vicanekAtClamp.b2) <= 1e-9, "\(filterType): coefficients(for:) b2")
            #expect(abs(vicanekAbove.a0 - vicanekAtClamp.a0) <= 1e-9, "\(filterType): coefficients(for:) a0")
            #expect(abs(vicanekAbove.a1 - vicanekAtClamp.a1) <= 1e-9, "\(filterType): coefficients(for:) a1")
            #expect(abs(vicanekAbove.a2 - vicanekAtClamp.a2) <= 1e-9, "\(filterType): coefficients(for:) a2")

            let displayAbove = BiquadResponse.displayCoefficients(for: aboveClamp, sampleRate: lowSampleRate)
            let displayAtClamp = BiquadResponse.displayCoefficients(for: atClamp, sampleRate: lowSampleRate)
            #expect(abs(displayAbove.b0 - displayAtClamp.b0) <= 1e-9, "\(filterType): displayCoefficients b0")
            #expect(abs(displayAbove.b1 - displayAtClamp.b1) <= 1e-9, "\(filterType): displayCoefficients b1")
            #expect(abs(displayAbove.b2 - displayAtClamp.b2) <= 1e-9, "\(filterType): displayCoefficients b2")
            #expect(abs(displayAbove.a0 - displayAtClamp.a0) <= 1e-9, "\(filterType): displayCoefficients a0")
            #expect(abs(displayAbove.a1 - displayAtClamp.a1) <= 1e-9, "\(filterType): displayCoefficients a1")
            #expect(abs(displayAbove.a2 - displayAtClamp.a2) <= 1e-9, "\(filterType): displayCoefficients a2")

            for c in [displayAbove.b0, displayAbove.b1, displayAbove.b2,
                      displayAbove.a0, displayAbove.a1, displayAbove.a2] {
                #expect(c.isFinite, "\(filterType): clamp must prevent a blow-up near true Nyquist")
            }
        }
    }

    // MARK: - Independent golden-value checks for displayCoefficients' OWN RBJ math
    // (lowShelf/highShelf only — the two types whose formula diverges from
    // coefficients(for:)). Unlike the divergence/corner-gain tests above, these assert the
    // function's own b0/b1/b2/a0/a1/a2 output against an independent hand derivation of
    // the classic RBJ cookbook shelf formula, closing the gap where only relative/
    // behavioral checks would otherwise exist for this path.
    //
    // Unlike coefficients(for:)'s Vicanek path (a discriminant/sqrt solve with no closed
    // form), the RBJ cookbook shelf form here is a direct closed-form substitution:
    //   twoSqrtAAlpha = 2·√A·alpha
    //   lowShelf:  b0=A·((A+1)-(A-1)·cosW0+twoSqrtAAlpha), b1=2A·((A-1)-(A+1)·cosW0),
    //              b2=A·((A+1)-(A-1)·cosW0-twoSqrtAAlpha),
    //              a0=(A+1)+(A-1)·cosW0+twoSqrtAAlpha, a1=-2·((A-1)+(A+1)·cosW0),
    //              a2=(A+1)+(A-1)·cosW0-twoSqrtAAlpha
    //   highShelf: mirrors lowShelf with the cosW0 sign flipped in b0/b2/a0/a2 and the
    //              sign of a1/b1 flipped (see the source for the exact form).
    // Values below were cross-checked with a Python double-precision mirror of this
    // formula (exact IEEE-754 double arithmetic via a second independent implementation,
    // not mental arithmetic prone to transcription error — same method EngineCoefficientTests
    // uses for its bandwidth-extreme derivations).

    // lowShelf @ 200 Hz, +24 dB, bw=1.0: w0=0.0261799388, cosW0=0.9996573250,
    // A=10^(24/40)=3.9810717055, alpha=0.0092560481 (same alpha as the Vicanek path — it's
    // gain-independent, shared via PoleParams), twoSqrtAAlpha=2·√3.9810717055·0.0092560481
    // = 0.0369364880.
    @Test func lowShelfDisplayMaxPositiveGainBoundaryGoldenValues() {
        let band = EQBand(frequency: 200, gain: 24, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 8.1132570377) <= 1e-6)
        #expect(abs(coeffs.b1 - (-15.9106963282)) <= 1e-6)
        #expect(abs(coeffs.b2 - 7.8191634230) <= 1e-6)
        #expect(abs(coeffs.a0 - 7.9980583603) <= 1e-6)
        #expect(abs(coeffs.a1 - (-15.9208730444)) <= 1e-6)
        #expect(abs(coeffs.a2 - 7.9241853842) <= 1e-6)
        // Unlike the Vicanek path (whose corner anchor breaks under disc2 flooring at this
        // same gain — EngineCoefficientTests.lowShelfMaxPositiveGainBoundary), the closed-form
        // RBJ display path has no discriminant to floor: DC/corner/Nyquist all land exactly
        // on the classic half-gain-at-corner shape.
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 24.2436807982) <= 0.01)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - 12.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.001)
    }

    // lowShelf @ 200 Hz, -24 dB, bw=1.0: same w0/cosW0/alpha as above, A=10^(-24/40)=
    // 0.2511886432, twoSqrtAAlpha=2·√0.2511886432·0.0092560481=0.0092780263.
    @Test func lowShelfDisplayMaxNegativeGainBoundaryGoldenValues() {
        let band = EQBand(frequency: 200, gain: -24, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 0.5046433664) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.0045391778)) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.4999822967) <= 1e-6)
        #expect(abs(coeffs.a0 - 0.5119119116) <= 1e-6)
        #expect(abs(coeffs.a1 - (-1.0038970704)) <= 1e-6)
        #expect(abs(coeffs.a2 - 0.4933558589) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - (-24.2436807982)) <= 0.01)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - (-12.0)) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.001)
    }

    // highShelf @ 8000 Hz, +24 dB, bw=1.0: w0=1.0471975512, cosW0=0.5 (exactly — w0=π/3),
    // A=3.9810717055, alpha=0.3736479992, twoSqrtAAlpha=2·√3.9810717055·0.3736479992
    // = 1.4910515438.
    @Test func highShelfDisplayMaxPositiveGainBoundaryGoldenValues() {
        let band = EQBand(frequency: 8000, gain: 24, bandwidth: 1.0, filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 31.6999168523) <= 1e-6)
        #expect(abs(coeffs.b1 - (-43.5657240683)) <= 1e-6)
        #expect(abs(coeffs.b2 - 19.8279506271) <= 1e-6)
        #expect(abs(coeffs.a0 - 4.9815873966) <= 1e-6)
        #expect(abs(coeffs.a1 - 0.9810717055) <= 1e-6)
        #expect(abs(coeffs.a2 - 1.9994843089) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - 12.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 24.4759542563) <= 0.01)
    }

    // highShelf @ 8000 Hz, -24 dB, bw=1.0: same w0/cosW0/alpha as above, A=0.2511886432,
    // twoSqrtAAlpha=2·√0.2511886432·0.3736479992=0.3745352142.
    @Test func highShelfDisplayMaxNegativeGainBoundaryGoldenValues() {
        let band = EQBand(frequency: 8000, gain: -24, bandwidth: 1.0, filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 0.3143169155) <= 1e-6)
        #expect(abs(coeffs.b1 - 0.0619014398) <= 1e-6)
        #expect(abs(coeffs.b2 - 0.1261589310) <= 1e-6)
        #expect(abs(coeffs.a0 - 2.0001295357) <= 1e-6)
        #expect(abs(coeffs.a1 - (-2.7488113568)) <= 1e-6)
        #expect(abs(coeffs.a2 - 1.2510591074) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-12.0)) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-24.4759542563)) <= 0.01)
    }

    // lowShelf @ 200 Hz, +6 dB, bw=0.05 (narrowest): A=1.4125375446 (gain-independent of
    // the ±24 dB tests above), alpha=0.0004536865 (tiny — narrow bandwidth), twoSqrtAAlpha
    // = 2·√1.4125375446·0.0004536865 = 0.0010784148. No discriminant in this closed form,
    // so — unlike coefficients(for:)'s Vicanek path at this same narrow bandwidth
    // (EngineCoefficientTests.lowShelfNarrowestBandwidthAnchorsPartiallyHoldAndAreFinite,
    // whose corner anchor breaks) — the corner here still lands exactly on +3 dB.
    @Test func lowShelfDisplayNarrowestBandwidthGoldenValues() {
        let band = EQBand(frequency: 200, gain: 6, bandwidth: 0.05, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 2.8267980758) <= 1e-6)
        #expect(abs(coeffs.b1 - (-5.6478146427)) <= 1e-6)
        #expect(abs(coeffs.b2 - 2.8237514731) <= 1e-6)
        #expect(abs(coeffs.a0 - 2.8260121377) <= 1e-6)
        #expect(abs(coeffs.a1 - (-5.6484967458)) <= 1e-6)
        #expect(abs(coeffs.a2 - 2.8238553082) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 6.0618107154) <= 0.01)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - 3.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.001)
    }

    // lowShelf @ 200 Hz, +6 dB, bw=4.0 (widest): same A as above, alpha=0.0490905883,
    // twoSqrtAAlpha=2·√1.4125375446·0.0490905883=0.1166885470.
    @Test func lowShelfDisplayWidestBandwidthGoldenValues() {
        let band = EQBand(frequency: 200, gain: 6, bandwidth: 4.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 2.9901017281) <= 1e-6)
        #expect(abs(coeffs.b1 - (-5.6478146427)) <= 1e-6)
        #expect(abs(coeffs.b2 - 2.6604478209) <= 1e-6)
        #expect(abs(coeffs.a0 - 2.9416222699) <= 1e-6)
        #expect(abs(coeffs.a1 - (-5.6484967458)) <= 1e-6)
        #expect(abs(coeffs.a2 - 2.7082451760) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 5.6719574731) <= 0.01)
        #expect(abs(coeffs.gainDB(at: 200, sampleRate: sampleRate) - 3.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - 0.0) <= 0.001)
    }

    // highShelf @ 8000 Hz, -4 dB, bw=0.05 (narrowest): A=0.7943282347 (gain-independent of
    // the ±24 dB tests above), alpha=0.0181478787, twoSqrtAAlpha=2·√0.7943282347·0.0181478787
    // = 0.0323486278. Same "no discriminant, corner anchor holds exactly" property as
    // lowShelf's narrowest case above — contrast with EngineCoefficientTests'
    // highShelfNarrowestBandwidthAnchorsPartiallyHoldAndAreFinite, whose Vicanek corner
    // anchor breaks (reads ≈+18.895 dB, not the naive -2 dB) at this exact same band.
    @Test func highShelfDisplayNarrowestBandwidthGoldenValues() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: 0.05, filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 1.3692955625) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.0985437987)) <= 1e-6)
        #expect(abs(coeffs.b2 - 1.3179047056) <= 1e-6)
        #expect(abs(coeffs.a0 - 1.9295127452) <= 1e-6)
        #expect(abs(coeffs.a1 - (-2.2056717653)) <= 1e-6)
        #expect(abs(coeffs.a2 - 1.8648154895) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-2.0)) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-4.0989172322)) <= 0.01)
    }

    // highShelf @ 8000 Hz, -4 dB, bw=4.0 (widest): same A as above, alpha=2.2337876138
    // (Q < 0.5 here — a heavily damped, low-Q shelf), twoSqrtAAlpha=
    // 2·√0.7943282347·2.2337876138=3.9817306127.
    @Test func highShelfDisplayWidestBandwidthGoldenValues() {
        let band = EQBand(frequency: 8000, gain: -4, bandwidth: 4.0, filterType: .highShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)

        for c in [coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a0, coeffs.a1, coeffs.a2] {
            #expect(c.isFinite)
        }
        #expect(abs(coeffs.b0 - 4.5064011828) <= 1e-6)
        #expect(abs(coeffs.b1 - (-1.0985437987)) <= 1e-6)
        #expect(abs(coeffs.b2 - (-1.8192009147)) <= 1e-6)
        #expect(abs(coeffs.a0 - 5.8788947301) <= 1e-6)
        #expect(abs(coeffs.a1 - (-2.2056717653)) <= 1e-6)
        #expect(abs(coeffs.a2 - (-2.0845664954)) <= 1e-6)
        #expect(abs(coeffs.gainDB(at: 20, sampleRate: sampleRate) - 0.0) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 8000, sampleRate: sampleRate) - (-2.0)) <= 0.001)
        #expect(abs(coeffs.gainDB(at: 20000, sampleRate: sampleRate) - (-3.2563758426)) <= 0.01)
    }

    @Test func lowShelfDisplayIsMonotonicApproachingNyquistForCornerNearNyquist() {
        // Cut low-shelf with the same near-Nyquist corner: gain should rise
        // monotonically from the cut plateau back toward 0 dB at Nyquist.
        let sr = 44_100.0
        let band = EQBand(frequency: 18000, gain: -12, bandwidth: 1.0, filterType: .lowShelf)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sr)

        let frequencies = (0..<24).map { i -> Double in
            let t = Double(i) / 23.0
            return 18000.0 * pow((sr / 2 * 0.999) / 18000.0, t)
        }
        let samples = frequencies.map { coeffs.gainDB(at: $0, sampleRate: sr) }
        for i in 1..<samples.count {
            #expect(samples[i] >= samples[i - 1] - 1e-6,
                    "cut low-shelf display curve dipped between \(frequencies[i-1]) Hz (\(samples[i-1]) dB) and \(frequencies[i]) Hz (\(samples[i]) dB)")
        }
    }
}
