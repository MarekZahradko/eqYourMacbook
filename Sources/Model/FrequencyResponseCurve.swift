// Frequency-axis sampling and composite dB-response curve, for the UI curve view.

import Foundation

extension BiquadResponse {
    /// Generate log-spaced frequencies across EQBand.frequencyRange (20 Hz–20 kHz).
    static func logFrequencies(count: Int = 512) -> [Double] {
        let minFreq = Double(EQBand.frequencyRange.lowerBound)
        let maxFreq = Double(EQBand.frequencyRange.upperBound)
        let ratio = maxFreq / minFreq
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return minFreq * pow(ratio, t)
        }
    }

    /// Composite frequency response: sum of all bands' dB contributions.
    static func compositeResponse(
        bands: [EQBand], sampleRate: Double, frequencies: [Double]
    ) -> [Double] {
        guard !bands.isEmpty else {
            return [Double](repeating: 0.0, count: frequencies.count)
        }

        let allCoeffs = bands.map { coefficients(for: $0, sampleRate: sampleRate) }
        return frequencies.map { freq in
            var total = 0.0
            for coeffs in allCoeffs {
                total += coeffs.gainDB(at: freq, sampleRate: sampleRate)
            }
            return total
        }
    }
}
