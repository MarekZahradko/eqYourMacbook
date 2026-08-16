import Testing
import Foundation
@testable import eqYourMacbook

/// Tests for Sources/Model/FrequencyResponseCurve.swift (BiquadResponse.logFrequencies /
/// .compositeResponse) — the UI curve view's frequency-axis sampling and per-frequency
/// composite dB response.
@Suite struct FrequencyResponseCurveTests {

    // MARK: - logFrequencies: count, endpoints, log-spacing

    @Test func logFrequenciesCountAndEndpoints() {
        // Endpoints are EQBand.frequencyRange's bounds exactly (t=0 → minFreq*ratio^0 =
        // minFreq; t=1 → minFreq*ratio^1 = maxFreq).
        let freqs = BiquadResponse.logFrequencies(count: 512)
        #expect(freqs.count == 512)
        #expect(abs(freqs.first! - 20.0) <= 1e-9)
        #expect(abs(freqs.last! - 20000.0) <= 1e-6)
    }

    @Test func logFrequenciesAreEvenlyLogSpaced() {
        // freqs[i] = minFreq * ratio^(i/(count-1)), so consecutive ratios
        // freqs[i]/freqs[i-1] = ratio^(1/(count-1)) are constant across the whole array.
        let count = 100
        let freqs = BiquadResponse.logFrequencies(count: count)
        let expectedStepRatio = pow(20000.0 / 20.0, 1.0 / Double(count - 1))
        for i in 1..<count {
            let stepRatio = freqs[i] / freqs[i - 1]
            #expect(abs(stepRatio - expectedStepRatio) <= 1e-9,
                    "step \(i): ratio \(stepRatio) != expected \(expectedStepRatio)")
        }
    }

    // MARK: - compositeResponse: empty-bands early return

    @Test func compositeResponseEmptyBandsReturnsAllZeros() {
        let freqs = [20.0, 1000.0, 20000.0]
        let response = BiquadResponse.compositeResponse(bands: [], sampleRate: 48_000, frequencies: freqs)
        #expect(response == [0.0, 0.0, 0.0])
    }

    // MARK: - compositeResponse: single band cross-checked against the already-tested
    // lower-level BiquadCoefficients.gainDB(at:sampleRate:) — not a fresh magic number.
    // Uses .parametric, which is identical under displayCoefficients and coefficients
    // (only shelf/LP/HP diverge — see compositeResponseMultipleBandsSumsEachBandsContribution).

    @Test func compositeResponseSingleBandMatchesLowerLevelGainDB() {
        let sampleRate = 48_000.0
        let band = EQBand(frequency: 1000, gain: 6, bandwidth: 1.0, filterType: .parametric)
        let coeffs = BiquadResponse.displayCoefficients(for: band, sampleRate: sampleRate)
        let freqs = [100.0, 1000.0, 10000.0]

        let composite = BiquadResponse.compositeResponse(bands: [band], sampleRate: sampleRate, frequencies: freqs)

        #expect(composite.count == freqs.count)
        for (i, f) in freqs.enumerated() {
            let expected = coeffs.gainDB(at: f, sampleRate: sampleRate)
            #expect(abs(composite[i] - expected) <= 1e-9,
                    "frequency \(f): composite \(composite[i]) != coeffs.gainDB \(expected)")
        }
    }

    // MARK: - compositeResponse: multiple bands sum, cross-checked term-by-term.
    // Uses displayCoefficients, not coefficients: compositeResponse feeds the UI curve,
    // which intentionally shows the pre-Vicanek (RBJ cookbook) shelf/LP/HP shape rather
    // than the Vicanek-matched shape actually applied to audio — see displayCoefficients'
    // doc comment in BiquadResponse.swift.

    @Test func compositeResponseMultipleBandsSumsEachBandsContribution() {
        let sampleRate = 48_000.0
        let bandA = EQBand(frequency: 200, gain: 4, bandwidth: 1.0, filterType: .lowShelf)
        let bandB = EQBand(frequency: 5000, gain: -3, bandwidth: 0.8, filterType: .parametric)
        let coeffsA = BiquadResponse.displayCoefficients(for: bandA, sampleRate: sampleRate)
        let coeffsB = BiquadResponse.displayCoefficients(for: bandB, sampleRate: sampleRate)
        let freqs = [100.0, 1000.0, 8000.0]

        let composite = BiquadResponse.compositeResponse(bands: [bandA, bandB], sampleRate: sampleRate, frequencies: freqs)

        for (i, f) in freqs.enumerated() {
            let expected = coeffsA.gainDB(at: f, sampleRate: sampleRate) + coeffsB.gainDB(at: f, sampleRate: sampleRate)
            #expect(abs(composite[i] - expected) <= 1e-9)
        }
    }
}
