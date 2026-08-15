// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
import Foundation

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

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

    /// Filter types for which `gain` has no meaning — these shape the frequency
    /// response purely via cutoff/bandwidth, with no separate amplitude control.
    /// SINGLE POINT OF TRUTH: BiquadResponse (DSP-boundary clamp) and BandRowView
    /// (UI disable/reset) both read this rather than re-enumerating the case set.
    static let gainless: Set<FilterType> = [.bandPass, .notch, .lowPass, .highPass]
}

// MARK: - EQ Band

struct EQBand: Codable, Equatable, Sendable, Identifiable {
    var frequency: Float   // Hz, clamped to Self.frequencyRange
    var gain: Float        // dB, clamped to Self.gainRange
    var bandwidth: Float   // octaves, clamped to Self.bandwidthRange
    var filterType: FilterType
    var muted: Bool
    /// In-memory identity for SwiftUI / animation. Not persisted; freshly minted on decode and copy.
    var id: UUID

    /// Enforced invariants, not just UI slider bounds — a hand-edited or corrupted preset
    /// bypasses the UI, so these are clamped here too, in addition to BiquadResponse's own
    /// DSP-boundary clamp.
    static let frequencyRange: ClosedRange<Float> = 20...20000
    static let gainRange: ClosedRange<Float> = -24...24
    static let bandwidthRange: ClosedRange<Float> = 0.05...4.0

    enum CodingKeys: String, CodingKey {
        case frequency, gain, bandwidth, filterType
    }

    init(frequency: Float, gain: Float, bandwidth: Float = 1.0, filterType: FilterType = .parametric, muted: Bool = false, id: UUID = UUID()) {
        self.frequency = frequency.clamped(to: Self.frequencyRange)
        self.gain = gain.clamped(to: Self.gainRange)
        self.bandwidth = bandwidth.clamped(to: Self.bandwidthRange)
        self.filterType = filterType
        self.muted = muted
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Float.self, forKey: .frequency).clamped(to: Self.frequencyRange)
        gain = try container.decode(Float.self, forKey: .gain).clamped(to: Self.gainRange)
        bandwidth = try container.decode(Float.self, forKey: .bandwidth).clamped(to: Self.bandwidthRange)
        // Decoded as a raw String first: decodeIfPresent(FilterType.self, ...) throws
        // (rather than returning nil) when the key is present but the value doesn't
        // match any case, so it alone can't guard against a corrupted/unknown filterType.
        let rawFilterType = try container.decodeIfPresent(String.self, forKey: .filterType)
        filterType = rawFilterType.flatMap(FilterType.init(rawValue:)) ?? .parametric
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
    let isBuiltIn: Bool

    var isFlat: Bool {
        bands.allSatisfy { $0.gain == 0 && $0.filterType == .parametric }
    }
}

// MARK: - Constants

extension EQPresetData {
    static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// CONTRACT.md upper bound; 0 bands = flat passthrough allowed.
    /// CANONICAL for this ceiling — EQCoefficients.maxSections (Sources/Engine) mirrors
    /// it rather than re-declaring 16 independently, since the RT coefficient buffer
    /// must be sized to hold at least this many bands.
    static let maxBandCount = 16
    static let minBandCount = 0
}
