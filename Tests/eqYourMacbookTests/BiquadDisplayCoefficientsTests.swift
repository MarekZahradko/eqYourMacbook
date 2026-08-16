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
        // exactly what the audio engine applies for these three types. This is trivially
        // true today (displayCoefficients delegates straight to coefficients(for:)), but
        // pins the contract so a future special-case for one of these types breaks this
        // test rather than silently shipping a UI/audio mismatch.
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
