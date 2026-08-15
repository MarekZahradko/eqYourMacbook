import XCTest
@testable import eqYourMacbook

// MARK: - DisplayStatus derivation
//
// §5 (multi-output-device EQ) removed OutputRoute/DeviceWatcher and the single-route
// shouldRun/engage policy along with them — engagement is now per-device (checkboxes
// reconciled by OutputDeviceEQCoordinator), not a pure function of one route. What
// remains pure and testable is the aggregate status derivation below.

final class DisplayStatusTests: XCTestCase {

    func testDisabledAlwaysDisabled() {
        let status = EQController.deriveStatus(
            isEnabled: false,
            permissionSuspected: true,
            errorMessage: "some error"
        )
        XCTAssertEqual(status, .disabled)
    }

    func testPermissionNeeded() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: true,
            errorMessage: nil
        )
        XCTAssertEqual(status, .permissionNeeded)
    }

    func testActiveWhenEnabledNoIssues() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: false,
            errorMessage: nil
        )
        XCTAssertEqual(status, .active)
    }

    func testErrorState() {
        let msg = "device not found"
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: false,
            errorMessage: msg
        )
        XCTAssertEqual(status, .error(msg))
    }

    // TCC denial causes an engine's start() to fail; permissionSuspected must win over
    // errorMessage so the user sees the actionable "grant permission" message, not a
    // generic error string.
    func testPermissionSuspectedBeatsError() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: true,
            errorMessage: "aggregate device error"
        )
        XCTAssertEqual(status, .permissionNeeded)
    }
}

// MARK: - suggestFrequency static

final class SuggestFrequencyTests: XCTestCase {

    func testEmptyBandsReturns1kHz() {
        let freq = EQPresetData.suggestFrequency(for: [])
        XCTAssertEqual(freq, 1000)
    }

    func testSingleLowBandSuggestsElsewhere() {
        // One band at 80 Hz: the largest gap is 80–20000, so suggestion is well above 80.
        let bands = [EQBand(frequency: 80, gain: 0)]
        let freq = EQPresetData.suggestFrequency(for: bands)
        XCTAssertGreaterThan(freq, 80,
            "With a band at 80 Hz the suggestion should be somewhere higher in the spectrum")
        XCTAssertLessThanOrEqual(freq, 20000)
    }

    func testInstanceMethodDelegatesToStatic() {
        let bands = [EQBand(frequency: 1000, gain: 0)]
        let preset = EQPresetData(id: UUID(), name: "", bands: bands, isBuiltIn: false)
        XCTAssertEqual(preset.suggestNewBandFrequency(),
                       EQPresetData.suggestFrequency(for: bands))
    }

    func testResultClampedToAudibleRange() {
        // A band at 20 kHz: next suggestion would exceed range without clamp.
        let bands = [EQBand(frequency: 20000, gain: 0)]
        let freq = EQPresetData.suggestFrequency(for: bands)
        XCTAssertGreaterThanOrEqual(freq, 20)
        XCTAssertLessThanOrEqual(freq, 20000)
    }
}

// MARK: - PresetStore round-trip

final class PresetStoreTests: XCTestCase {

    private var store: PresetStore!
    private let suiteName = "com.zdenekkops.eqyourmacbook.test.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        store = PresetStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSaveAndRetrieve() {
        let bands = [EQBand(frequency: 500, gain: -3, bandwidth: 1.5, filterType: .parametric)]
        store.save(name: "My Preset", bands: bands)

        let found = store.all.first(where: { $0.name == "My Preset" })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.bands.count, 1)
        XCTAssertEqual(found?.bands.first?.frequency, 500)
        XCTAssertEqual(found?.bands.first?.gain, -3)
    }

    func testDeleteCustomPreset() {
        store.save(name: "To Delete", bands: [EQBand(frequency: 1000, gain: 0)])
        let preset = store.customPresets.first!
        store.delete(id: preset.id)
        XCTAssertTrue(store.customPresets.isEmpty)
    }

    func testBuiltInsSurviveDelete() {
        for p in EQPresetData.builtInPresets {
            store.delete(id: p.id)
        }
        let builtIns = store.all.filter(\.isBuiltIn)
        XCTAssertEqual(builtIns.count, EQPresetData.builtInPresets.count)
    }

    func testBuiltInsUndeletable() {
        let initial = store.all.count
        for p in EQPresetData.builtInPresets {
            store.delete(id: p.id)
        }
        XCTAssertEqual(store.all.count, initial, "Built-in presets must not be removable")
    }

    func testPersistenceAcrossInstances() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let bands = [EQBand(frequency: 250, gain: 2, bandwidth: 0.5, filterType: .lowShelf)]
        store.save(name: "Persisted", bands: bands)

        let store2 = PresetStore(defaults: defaults)
        let found = store2.customPresets.first(where: { $0.name == "Persisted" })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.bands.first?.filterType, .lowShelf)
    }
}

// MARK: - Band JSON round-trip

final class BandCodableTests: XCTestCase {

    func testRoundTripWithNonDefaultFields() throws {
        let original = EQBand(
            frequency: 440,
            gain: 6.5,
            bandwidth: 0.3,
            filterType: .notch,
            muted: true  // muted is NOT persisted; decoded band will have muted=false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)

        XCTAssertEqual(decoded.frequency, original.frequency)
        XCTAssertEqual(decoded.gain, original.gain)
        XCTAssertEqual(decoded.bandwidth, original.bandwidth, accuracy: 0.001)
        XCTAssertEqual(decoded.filterType, original.filterType)
        // muted is runtime-only — always false after decode (by design in EQBand)
        XCTAssertFalse(decoded.muted)
        // id is freshly minted on decode — must differ
        XCTAssertNotEqual(decoded.id, original.id)
    }

    func testArrayRoundTrip() throws {
        let bands: [EQBand] = [
            EQBand(frequency: 100, gain: -6, bandwidth: 2.0, filterType: .lowShelf),
            EQBand(frequency: 4000, gain: 3, bandwidth: 1.0, filterType: .parametric),
            EQBand(frequency: 12000, gain: -9, bandwidth: 0.7, filterType: .highShelf),
        ]
        let data = try JSONEncoder().encode(bands)
        let decoded = try JSONDecoder().decode([EQBand].self, from: data)
        XCTAssertEqual(decoded.count, bands.count)
        for (a, b) in zip(decoded, bands) {
            XCTAssertEqual(a, b)  // EQBand.== ignores id and muted
        }
    }
}
