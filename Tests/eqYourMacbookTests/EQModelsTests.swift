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
        // 0.4812118, so BW ≈ 2*0.4812118/0.6931472 ≈ 1.38857 octaves. A pure
        // round-trip (below) can't catch two consistently-wrong mutual inverses,
        // so this hand-computed value anchors the actual formula.
        let q: Float = 1.0
        let oct = EQBand.qToOctaves(q)
        #expect(abs(oct - 1.38857) <= 1e-4)
        let backFromAnchor = EQBand.octavesToQ(1.38857)
        #expect(abs(backFromAnchor - 1.0) <= 1e-3)

        // round-trip: Q → octaves → Q should be stable (secondary check)
        let back = EQBand.octavesToQ(oct)
        #expect(abs(back - q) <= 1e-5)
    }
}
