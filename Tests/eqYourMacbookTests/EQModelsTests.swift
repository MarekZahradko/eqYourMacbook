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
        // round-trip: Q → octaves → Q should be stable
        let q: Float = 1.0
        let oct = EQBand.qToOctaves(q)
        let back = EQBand.octavesToQ(oct)
        XCTAssertEqual(back, q, accuracy: 1e-5)
    }
}
