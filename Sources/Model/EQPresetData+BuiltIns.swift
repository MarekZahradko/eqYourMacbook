// Built-in EQ presets and the new-band frequency-suggestion algorithm.

import Foundation

extension EQPresetData {
    /// Identity preset — no EQ applied.
    static let flat = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Flat",
        bands: [],
        isBuiltIn: true
    )

    /// Starting point for MacBook Air built-in speakers. Tune by ear in M2.
    /// high-shelf −4 dB @ 8 kHz Q 0.9 + peaking −2 dB @ 2.5 kHz Q 1.0
    static let mbaTameTheHighs = EQPresetData(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "MBA tame-the-highs",
        bands: [
            EQBand(frequency: 8000, gain: -4, bandwidth: EQBand.qToOctaves(0.9), filterType: .highShelf),
            EQBand(frequency: 2500, gain: -2, bandwidth: EQBand.qToOctaves(1.0), filterType: .parametric),
        ],
        isBuiltIn: true
    )

    static let builtInPresets: [EQPresetData] = [.flat, .mbaTameTheHighs]

    /// Suggest a frequency for a new band inserted into `bands`.
    /// Delegates to the static form so callers that hold a raw array
    /// (e.g. addBand in the view layer) need not construct a throwaway preset.
    func suggestNewBandFrequency() -> Float {
        EQPresetData.suggestFrequency(for: bands)
    }

    /// Finds the largest gap (in octaves) between the given bands and returns
    /// the geometric midpoint. Empty input → 1 kHz default.
    static func suggestFrequency(for bands: [EQBand]) -> Float {
        guard !bands.isEmpty else { return 1000 }
        let sorted = bands.map(\.frequency).sorted()
        let range = EQBand.frequencyRange

        // Check gap below lowest
        var bestFreq: Float = sorted[0] / 2
        var bestGap: Float = log2(sorted[0] / range.lowerBound) // gap from range floor

        // Check gaps between bands
        for i in 1..<sorted.count {
            let gap = log2(sorted[i] / sorted[i - 1])
            if gap > bestGap {
                bestGap = gap
                bestFreq = sqrt(sorted[i] * sorted[i - 1]) // geometric midpoint
            }
        }

        // Check gap above highest
        let topGap = log2(range.upperBound / sorted.last!)
        if topGap > bestGap {
            bestFreq = sorted.last! * 2
        }

        return bestFreq.clamped(to: range)
    }
}
