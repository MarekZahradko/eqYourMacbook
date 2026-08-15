import XCTest
@testable import eqYourMacbook

final class EQModelsTests: XCTestCase {

    func testBuiltInPresetCount() {
        XCTAssertEqual(EQPresetData.builtInPresets.count, 2)
    }

    func testFlatPresetHasNoBands() {
        XCTAssertTrue(EQPresetData.flat.bands.isEmpty)
        XCTAssertTrue(EQPresetData.flat.isFlat)
    }

    func testMbaPresetHasTwoBands() {
        let preset = EQPresetData.mbaTameTheHighs
        XCTAssertEqual(preset.bands.count, 2)
        // high-shelf at 8 kHz
        XCTAssertEqual(preset.bands[0].filterType, .highShelf)
        XCTAssertEqual(preset.bands[0].frequency, 8000)
        XCTAssertEqual(preset.bands[0].gain, -4)
        // peaking at 2.5 kHz
        XCTAssertEqual(preset.bands[1].filterType, .parametric)
        XCTAssertEqual(preset.bands[1].frequency, 2500)
        XCTAssertEqual(preset.bands[1].gain, -2)
    }

    func testEQBandCodableRoundtrip() throws {
        let band = EQBand(frequency: 1000, gain: -3, bandwidth: 1.5, filterType: .lowShelf)
        let data = try JSONEncoder().encode(band)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)
        XCTAssertEqual(decoded, band)
        // id is freshly minted on decode — that's expected
    }

    func testQOctavesConversion() {
        // Independent anchor: BW = 2*asinh(1/(2Q))/ln(2). For Q=1.0, asinh(0.5) ≈
        // 0.4812118, so BW ≈ 2*0.4812118/0.6931472 ≈ 1.38857 octaves. A pure
        // round-trip (below) can't catch two consistently-wrong mutual inverses,
        // so this hand-computed value anchors the actual formula.
        let q: Float = 1.0
        let oct = EQBand.qToOctaves(q)
        XCTAssertEqual(oct, 1.38857, accuracy: 1e-4)
        let backFromAnchor = EQBand.octavesToQ(1.38857)
        XCTAssertEqual(backFromAnchor, 1.0, accuracy: 1e-3)

        // round-trip: Q → octaves → Q should be stable (secondary check)
        let back = EQBand.octavesToQ(oct)
        XCTAssertEqual(back, q, accuracy: 1e-5)
    }
}
