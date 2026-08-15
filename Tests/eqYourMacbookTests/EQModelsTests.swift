import Testing
import Foundation
@testable import eqYourMacbook

@Suite struct EQModelsTests {

    @Test func builtInPresetCount() {
        #expect(EQPresetData.builtInPresets.count == 2)
    }

    @Test func flatPresetHasNoBands() {
        #expect(EQPresetData.flat.bands.isEmpty)
        #expect(EQPresetData.flat.isFlat)
    }

    @Test func mbaPresetHasTwoBands() {
        let preset = EQPresetData.mbaTameTheHighs
        #expect(preset.bands.count == 2)
        // high-shelf at 8 kHz
        #expect(preset.bands[0].filterType == .highShelf)
        #expect(preset.bands[0].frequency == 8000)
        #expect(preset.bands[0].gain == -4)
        // peaking at 2.5 kHz
        #expect(preset.bands[1].filterType == .parametric)
        #expect(preset.bands[1].frequency == 2500)
        #expect(preset.bands[1].gain == -2)
    }

    @Test func eqBandCodableRoundtrip() throws {
        let band = EQBand(frequency: 1000, gain: -3, bandwidth: 1.5, filterType: .lowShelf)
        let data = try JSONEncoder().encode(band)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)
        #expect(decoded == band)
        // id is freshly minted on decode — that's expected
    }

    @Test func qOctavesConversion() {
        // Independent anchor: BW = 2*asinh(1/(2Q))/ln(2). For Q=1.0, asinh(0.5) ≈
        // 0.4812118, so BW ≈ 2*0.4812118/0.6931472 ≈ 1.388484 octaves. A pure
        // round-trip (below) can't catch two consistently-wrong mutual inverses,
        // so this hand-computed value anchors the actual formula.
        let q: Float = 1.0
        let oct = EQBand.qToOctaves(q)
        #expect(abs(oct - 1.388484) <= 1e-4)
        let backFromAnchor = EQBand.octavesToQ(1.388484)
        #expect(abs(backFromAnchor - 1.0) <= 1e-3)

        // round-trip: Q → octaves → Q should be stable (secondary check)
        let back = EQBand.octavesToQ(oct)
        #expect(abs(back - q) <= 1e-5)
    }
}

// MARK: - EQBand range clamping (construction + decode)

@Suite struct EQBandClampingTests {

    @Test func memberwiseInitClampsAboveRange() {
        let band = EQBand(frequency: 999_999, gain: -100, bandwidth: 50, filterType: .parametric)
        #expect(band.frequency == EQBand.frequencyRange.upperBound)   // 20000
        #expect(band.gain == EQBand.gainRange.lowerBound)             // -24
        #expect(band.bandwidth == EQBand.bandwidthRange.upperBound)   // 4.0
    }

    @Test func memberwiseInitClampsBelowRange() {
        let band = EQBand(frequency: -5, gain: 100, bandwidth: -1, filterType: .parametric)
        #expect(band.frequency == EQBand.frequencyRange.lowerBound)   // 20
        #expect(band.gain == EQBand.gainRange.upperBound)             // 24
        #expect(band.bandwidth == EQBand.bandwidthRange.lowerBound)   // 0.05
    }

    @Test func decodeClampsOutOfRangeValues() throws {
        // Hand-built malformed-but-decodable payload: every field out of range on the
        // same side used by memberwiseInitClampsAboveRange, to confirm the Decodable
        // init enforces the SAME clamps as the memberwise init, independently.
        let json = """
        {"frequency": 999999, "gain": -100, "bandwidth": 50, "filterType": "parametric"}
        """
        let band = try JSONDecoder().decode(EQBand.self, from: json.data(using: .utf8)!)
        #expect(band.frequency == EQBand.frequencyRange.upperBound)
        #expect(band.gain == EQBand.gainRange.lowerBound)
        #expect(band.bandwidth == EQBand.bandwidthRange.upperBound)
    }

    @Test func decodeClampsBelowRangeValues() throws {
        let json = """
        {"frequency": -5, "gain": 100, "bandwidth": -1, "filterType": "parametric"}
        """
        let band = try JSONDecoder().decode(EQBand.self, from: json.data(using: .utf8)!)
        #expect(band.frequency == EQBand.frequencyRange.lowerBound)
        #expect(band.gain == EQBand.gainRange.upperBound)
        #expect(band.bandwidth == EQBand.bandwidthRange.lowerBound)
    }

    @Test func decodeUnknownFilterTypeFallsBackToParametric() throws {
        // EQModels.swift's Decodable init: `decodeIfPresent(FilterType.self, ...) ??
        // .parametric` — an unrecognized raw string fails FilterType's own decode, so
        // decodeIfPresent returns nil (not an error) and the fallback kicks in.
        let json = """
        {"frequency": 1000, "gain": 0, "bandwidth": 1.0, "filterType": "unknownWobbleFilter"}
        """
        let band = try JSONDecoder().decode(EQBand.self, from: json.data(using: .utf8)!)
        #expect(band.filterType == .parametric)
    }

    @Test func decodeMissingFilterTypeKeyFallsBackToParametric() throws {
        let json = """
        {"frequency": 1000, "gain": 0, "bandwidth": 1.0}
        """
        let band = try JSONDecoder().decode(EQBand.self, from: json.data(using: .utf8)!)
        #expect(band.filterType == .parametric)
    }

    @Test func decodeMissingRequiredKeyThrows() {
        // `frequency` has no decodeIfPresent fallback — omitting it must throw, not crash
        // or silently default.
        let json = """
        {"gain": 0, "bandwidth": 1.0, "filterType": "parametric"}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(EQBand.self, from: json.data(using: .utf8)!)
        }
    }
}

// MARK: - EQPresetData.isFlat false-path

@Suite struct EQPresetDataIsFlatTests {

    @Test func isFlatFalseWithNonzeroGain() {
        let preset = EQPresetData(id: UUID(), name: "x",
                                   bands: [EQBand(frequency: 1000, gain: 3)], isBuiltIn: false)
        #expect(!preset.isFlat)
    }

    @Test func isFlatFalseWithNonParametricFilterType() {
        // Zero gain, but a non-parametric filter type still shapes the response —
        // isFlat must be false even though the gain check alone would pass.
        let preset = EQPresetData(id: UUID(), name: "x",
                                   bands: [EQBand(frequency: 1000, gain: 0, filterType: .lowShelf)],
                                   isBuiltIn: false)
        #expect(!preset.isFlat)
    }
}

// MARK: - EQBand+Formatting (frequencyLabel / gainLabel / bandwidthLabel)

@Suite struct EQBandFormattingTests {

    @Test func frequencyLabelSubKiloHertz() {
        #expect(EQBand(frequency: 500, gain: 0).frequencyLabel == "500 Hz")
        #expect(EQBand(frequency: 63.5, gain: 0).frequencyLabel == "63.5 Hz")
    }

    @Test func frequencyLabelKiloHertz() {
        #expect(EQBand(frequency: 1000, gain: 0).frequencyLabel == "1 kHz")
        #expect(EQBand(frequency: 8000, gain: 0).frequencyLabel == "8 kHz")
        #expect(EQBand(frequency: 2500, gain: 0).frequencyLabel == "2.5 kHz")
        #expect(EQBand(frequency: 20000, gain: 0).frequencyLabel == "20 kHz")
    }

    @Test func gainLabelSignsAndZero() {
        #expect(EQBand(frequency: 1000, gain: 0).gainLabel == "0 dB")
        #expect(EQBand(frequency: 1000, gain: 6).gainLabel == "+6 dB")
        #expect(EQBand(frequency: 1000, gain: -6).gainLabel == "-6 dB")
        #expect(EQBand(frequency: 1000, gain: 3.5).gainLabel == "+3.5 dB")
        #expect(EQBand(frequency: 1000, gain: -3.5).gainLabel == "-3.5 dB")
    }

    @Test func bandwidthLabelOctaveMode() {
        #expect(EQBand(frequency: 1000, gain: 0, bandwidth: 1.0).bandwidthLabel(asQ: false) == "1 oct")
        #expect(EQBand(frequency: 1000, gain: 0, bandwidth: 1.5).bandwidthLabel(asQ: false) == "1.5 oct")
    }

    @Test func bandwidthLabelQModeBelowTen() {
        // octavesToQ(1.0): p = 2^1 = 2, Q = sqrt(2)/(2-1) = sqrt(2) ≈ 1.41421 → "Q 1.41".
        let label = EQBand(frequency: 1000, gain: 0, bandwidth: 1.0).bandwidthLabel(asQ: true)
        #expect(label == "Q 1.41")
    }

    @Test func bandwidthLabelQModeAtOrAboveTenUsesNoDecimals() {
        // octavesToQ(0.05): p = 2^0.05 ≈ 1.0352649, Q = sqrt(p)/(p-1) ≈ 28.85 → rounds
        // to "Q 29" once Q >= 10 switches the format to %.0f.
        let label = EQBand(frequency: 1000, gain: 0, bandwidth: 0.05).bandwidthLabel(asQ: true)
        #expect(label == "Q 29")
    }
}
