import Testing
import Foundation
@testable import eqYourMacbook

// MARK: - DisplayStatus derivation
//
// §5 (multi-output-device EQ) removed OutputRoute/DeviceWatcher and the single-route
// shouldRun/engage policy along with them — engagement is now per-device (checkboxes
// reconciled by OutputDeviceEQCoordinator), not a pure function of one route. What
// remains pure and testable is the aggregate status derivation below.

@Suite struct DisplayStatusTests {

    @Test func disabledAlwaysDisabled() {
        let status = EQController.deriveStatus(
            isEnabled: false,
            permissionSuspected: true,
            errorMessage: "some error"
        )
        #expect(status == .disabled)
    }

    @Test func permissionNeeded() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: true,
            errorMessage: nil
        )
        #expect(status == .permissionNeeded)
    }

    @Test func activeWhenEnabledNoIssues() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: false,
            errorMessage: nil
        )
        #expect(status == .active)
    }

    @Test func errorState() {
        let msg = "device not found"
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: false,
            errorMessage: msg
        )
        #expect(status == .error(msg))
    }

    // TCC denial causes an engine's start() to fail; permissionSuspected must win over
    // errorMessage so the user sees the actionable "grant permission" message, not a
    // generic error string.
    @Test func permissionSuspectedBeatsError() {
        let status = EQController.deriveStatus(
            isEnabled: true,
            permissionSuspected: true,
            errorMessage: "aggregate device error"
        )
        #expect(status == .permissionNeeded)
    }
}

// MARK: - suggestFrequency static

@Suite struct SuggestFrequencyTests {

    @Test func emptyBandsReturns1kHz() {
        let freq = EQPresetData.suggestFrequency(for: [])
        #expect(freq == 1000)
    }

    @Test func singleLowBandSuggestsElsewhere() {
        // One band at 80 Hz: the largest gap is 80–20000, so suggestion is well above 80.
        let bands = [EQBand(frequency: 80, gain: 0)]
        let freq = EQPresetData.suggestFrequency(for: bands)
        #expect(freq > 80,
            "With a band at 80 Hz the suggestion should be somewhere higher in the spectrum")
        #expect(freq <= 20000)
    }

    @Test func instanceMethodDelegatesToStatic() {
        let bands = [EQBand(frequency: 1000, gain: 0)]
        let preset = EQPresetData(id: UUID(), name: "", bands: bands, isBuiltIn: false)
        #expect(preset.suggestNewBandFrequency() == EQPresetData.suggestFrequency(for: bands))
    }

    @Test func resultClampedToAudibleRange() {
        // A band at 20 kHz: next suggestion would exceed range without clamp.
        let bands = [EQBand(frequency: 20000, gain: 0)]
        let freq = EQPresetData.suggestFrequency(for: bands)
        #expect(freq >= 20)
        #expect(freq <= 20000)
    }
}

// MARK: - PresetStore round-trip

@Suite final class PresetStoreTests {

    private var store: PresetStore!
    private let suiteName = "com.zdenekkops.eqyourmacbook.test.\(UUID().uuidString)"

    init() {
        store = PresetStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func saveAndRetrieve() {
        let bands = [EQBand(frequency: 500, gain: -3, bandwidth: 1.5, filterType: .parametric)]
        store.save(name: "My Preset", bands: bands)

        let found = store.all.first(where: { $0.name == "My Preset" })
        #expect(found != nil)
        #expect(found?.bands.count == 1)
        #expect(found?.bands.first?.frequency == 500)
        #expect(found?.bands.first?.gain == -3)
    }

    @Test func deleteCustomPreset() {
        store.save(name: "To Delete", bands: [EQBand(frequency: 1000, gain: 0)])
        let preset = store.customPresets.first!
        store.delete(id: preset.id)
        #expect(store.customPresets.isEmpty)
    }

    @Test func builtInsSurviveDelete() {
        for p in EQPresetData.builtInPresets {
            store.delete(id: p.id)
        }
        let builtIns = store.all.filter(\.isBuiltIn)
        #expect(builtIns.count == EQPresetData.builtInPresets.count)
    }

    @Test func builtInsUndeletable() {
        let initial = store.all.count
        for p in EQPresetData.builtInPresets {
            store.delete(id: p.id)
        }
        #expect(store.all.count == initial, "Built-in presets must not be removable")
    }

    @Test func persistenceAcrossInstances() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let bands = [EQBand(frequency: 250, gain: 2, bandwidth: 0.5, filterType: .lowShelf)]
        store.save(name: "Persisted", bands: bands)

        let store2 = PresetStore(defaults: defaults)
        let found = store2.customPresets.first(where: { $0.name == "Persisted" })
        #expect(found != nil)
        #expect(found?.bands.first?.filterType == .lowShelf)
    }
}

// MARK: - Band JSON round-trip

@Suite struct BandCodableTests {

    @Test func roundTripWithNonDefaultFields() throws {
        let original = EQBand(
            frequency: 440,
            gain: 6.5,
            bandwidth: 0.3,
            filterType: .notch,
            muted: true  // muted is NOT persisted; decoded band will have muted=false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)

        #expect(decoded.frequency == original.frequency)
        #expect(decoded.gain == original.gain)
        #expect(abs(decoded.bandwidth - original.bandwidth) <= 0.001)
        #expect(decoded.filterType == original.filterType)
        // muted is runtime-only — always false after decode (by design in EQBand)
        #expect(!decoded.muted)
        // id is freshly minted on decode — must differ
        #expect(decoded.id != original.id)
    }

    @Test func arrayRoundTrip() throws {
        let bands: [EQBand] = [
            EQBand(frequency: 100, gain: -6, bandwidth: 2.0, filterType: .lowShelf),
            EQBand(frequency: 4000, gain: 3, bandwidth: 1.0, filterType: .parametric),
            EQBand(frequency: 12000, gain: -9, bandwidth: 0.7, filterType: .highShelf),
        ]
        let data = try JSONEncoder().encode(bands)
        let decoded = try JSONDecoder().decode([EQBand].self, from: data)
        #expect(decoded.count == bands.count)
        for (a, b) in zip(decoded, bands) {
            #expect(a == b)  // EQBand.== ignores id and muted
        }
    }
}
