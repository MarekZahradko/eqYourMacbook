// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
import Foundation

// MARK: - Filter Type

enum FilterType: String, Codable, CaseIterable, Equatable, Sendable {
    case parametric
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch

    var displayName: String {
        switch self {
        case .parametric: return "Bell"
        case .lowShelf:   return "Lo Shelf"
        case .highShelf:  return "Hi Shelf"
        case .lowPass:    return "Lo Pass"
        case .highPass:   return "Hi Pass"
        case .bandPass:   return "Band Pass"
        case .notch:      return "Notch"
        }
    }
}

// MARK: - EQ Channel

enum EQChannel: String, Codable, Sendable {
    case left
    case right
}

// MARK: - EQ Band

struct EQBand: Codable, Equatable, Sendable, Identifiable {
    var frequency: Float   // Hz (20...20000)
    var gain: Float        // dB, uncapped; UI constrains to ±24 dB
    var bandwidth: Float   // octaves, default 1.0
    var filterType: FilterType
    var muted: Bool
    /// In-memory identity for SwiftUI / animation. Not persisted; freshly minted on decode and copy.
    var id: UUID

    enum CodingKeys: String, CodingKey {
        case frequency, gain, bandwidth, filterType
    }

    init(frequency: Float, gain: Float, bandwidth: Float = 1.0, filterType: FilterType = .parametric, muted: Bool = false, id: UUID = UUID()) {
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.muted = muted
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Float.self, forKey: .frequency)
        gain = try container.decode(Float.self, forKey: .gain)
        bandwidth = try container.decode(Float.self, forKey: .bandwidth)
        filterType = try container.decodeIfPresent(FilterType.self, forKey: .filterType) ?? .parametric
        muted = false
        id = UUID()
    }

    /// Equality ignores `id` and `muted` — they are runtime-only state, not part of preset value identity.
    static func == (lhs: EQBand, rhs: EQBand) -> Bool {
        lhs.frequency == rhs.frequency &&
        lhs.gain == rhs.gain &&
        lhs.bandwidth == rhs.bandwidth &&
        lhs.filterType == rhs.filterType
    }
}

// MARK: - EQ Preset Data

struct EQPresetData: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var bands: [EQBand]
    /// Right channel bands. When nil, the preset is in linked (stereo) mode.
    /// When non-nil, `bands` represents the left channel and `rightBands` the right.
    var rightBands: [EQBand]? = nil
    let isBuiltIn: Bool

    var isFlat: Bool {
        let bandsFlat = bands.allSatisfy { $0.gain == 0 && $0.filterType == .parametric }
        guard let right = rightBands else { return bandsFlat }
        return bandsFlat && right.allSatisfy { $0.gain == 0 && $0.filterType == .parametric }
    }

    var isSplitChannel: Bool { rightBands != nil }

    func bands(for channel: EQChannel) -> [EQBand] {
        switch channel {
        case .left: return bands
        case .right: return rightBands ?? bands
        }
    }

    mutating func setBands(_ newBands: [EQBand], for channel: EQChannel) {
        switch channel {
        case .left: bands = newBands
        case .right: rightBands = newBands
        }
    }

    /// Enable split channel mode by copying current bands to right channel.
    mutating func enableSplitChannel() {
        guard rightBands == nil else { return }
        rightBands = bands
    }

    /// Disable split channel mode, keeping left channel bands.
    mutating func disableSplitChannel() {
        rightBands = nil
    }
}

// MARK: - Constants

extension EQPresetData {
    static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let maxBandCount = 16    // CONTRACT.md upper bound; 0 bands = flat passthrough allowed
    static let minBandCount = 0
}

// MARK: - Built-in Presets

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

        // Check gap below lowest
        var bestFreq: Float = sorted[0] / 2
        var bestGap: Float = log2(sorted[0] / 20) // gap from 20 Hz

        // Check gaps between bands
        for i in 1..<sorted.count {
            let gap = log2(sorted[i] / sorted[i - 1])
            if gap > bestGap {
                bestGap = gap
                bestFreq = sqrt(sorted[i] * sorted[i - 1]) // geometric midpoint
            }
        }

        // Check gap above highest
        let topGap = log2(20000 / sorted.last!)
        if topGap > bestGap {
            bestFreq = sorted.last! * 2
        }

        return min(max(bestFreq, 20), 20000)
    }
}

// MARK: - Frequency Formatting

extension EQBand {
    var frequencyLabel: String {
        if frequency >= 1000 {
            let k = frequency / 1000
            if k == Float(Int(k)) {
                return "\(Int(k)) kHz"
            } else {
                return String(format: "%.1f kHz", k)
            }
        } else if frequency == Float(Int(frequency)) {
            return "\(Int(frequency)) Hz"
        } else {
            return String(format: "%.1f Hz", frequency)
        }
    }

    /// Convert bandwidth in octaves to Q factor (frequency-independent approximation).
    static func octavesToQ(_ bw: Float) -> Float {
        let p = powf(2, bw)
        return sqrtf(p) / (p - 1)
    }

    /// Convert Q factor to bandwidth in octaves.
    static func qToOctaves(_ q: Float) -> Float {
        return 2 * asinh(1 / (2 * q)) / logf(2)
    }

    func bandwidthLabel(asQ: Bool) -> String {
        if asQ {
            let q = Self.octavesToQ(bandwidth)
            if q >= 10 {
                return String(format: "Q %.0f", q)
            }
            return String(format: "Q %.2f", q)
        } else {
            if bandwidth == Float(Int(bandwidth)) {
                return "\(Int(bandwidth)) oct"
            }
            return String(format: "%.1f oct", bandwidth)
        }
    }

    var gainLabel: String {
        if gain == 0 { return "0 dB" }
        if gain == Float(Int(gain)) {
            return String(format: "%+d dB", Int(gain))
        }
        return String(format: "%+.1f dB", gain)
    }
}
