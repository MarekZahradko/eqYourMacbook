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
        // Independent hand derivation (not a call to the function under test): bands at
        // 100 and 1000 Hz. Gaps in octaves: below-lowest log2(100/20)=log2(5)≈2.3219,
        // interior log2(1000/100)=log2(10)≈3.3219, above-highest log2(20000/1000)=
        // log2(20)≈4.3219. The above-highest gap is the largest, so the algorithm takes
        // the "double the top band" branch: suggestion = 1000*2 = 2000 Hz.
        let bands = [EQBand(frequency: 100, gain: 0), EQBand(frequency: 1000, gain: 0)]
        let preset = EQPresetData(id: UUID(), name: "", bands: bands, isBuiltIn: false)
        #expect(preset.suggestNewBandFrequency() == 2000)
    }

    @Test func largestGapBetweenInteriorBandsWins() {
        // Bands at 200, 400, 8000 Hz. Gaps in octaves: below-lowest log2(200/20)=
        // log2(10)≈3.3219, 200→400 = log2(2) = 1.0, 400→8000 = log2(20)≈4.3219,
        // above-highest log2(20000/8000)=log2(2.5)≈1.3219. The largest is the INTERIOR
        // 400→8000 gap (never exercised before this test — prior coverage only had
        // 0/1-band inputs), so the suggestion is its geometric midpoint:
        // sqrt(400*8000) ≈ 1788.8544 Hz.
        let bands = [
            EQBand(frequency: 200, gain: 0),
            EQBand(frequency: 400, gain: 0),
            EQBand(frequency: 8000, gain: 0),
        ]
        let freq = EQPresetData.suggestFrequency(for: bands)
        #expect(abs(freq - 1788.8544) <= 0.01)
    }

    @Test func resultClampedToAudibleRange() {
        // Genuinely exercise the clamp (the pre-existing version of this test used a
        // single band at 20000 Hz, whose unclamped result — 10000 Hz — was already well
        // inside range, so `.clamped(to:)` was a no-op and the test passed regardless
        // of whether clamping worked at all).
        //
        // 11 bands at 39 * 1.8^i (i=0...10) Hz. The below-lowest gap is
        // log2(39/20)=log2(1.95)≈0.9658 octaves; every interior gap is exactly
        // log2(1.8)≈0.8480 octaves (< the below-lowest gap, so it never overrides); the
        // final above-highest gap is log2(20000/13924.82)≈0.5205 octaves (also smaller).
        // So the below-lowest branch wins throughout and is never overridden, leaving
        // bestFreq = 39/2 = 19.5 Hz — BELOW EQBand.frequencyRange's 20 Hz floor — which
        // `.clamped(to:)` must pull up to exactly 20.
        let bands = (0...10).map { EQBand(frequency: Float(39.0 * pow(1.8, Double($0))), gain: 0) }
        let freq = EQPresetData.suggestFrequency(for: bands)
        #expect(freq == 20)
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

    /// load()'s decode-failure guard (`try? JSONDecoder().decode(...)` → early return):
    /// deliberately corrupt/malformed data under the same key PresetStore reads must
    /// fall back gracefully (customPresets stays empty), not crash the app.
    @Test func corruptPersistedDataFallsBackGracefullyInsteadOfCrashing() {
        let defaults = UserDefaults(suiteName: suiteName)!
        // Not valid JSON at all.
        defaults.set(Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]), forKey: "eqym.customPresets")

        let corrupted = PresetStore(defaults: defaults)
        #expect(corrupted.customPresets.isEmpty)
        #expect(corrupted.all.count == EQPresetData.builtInPresets.count)
    }

    /// load()'s decode-failure guard also covers well-formed JSON that doesn't match
    /// EQPresetData's schema (e.g. missing required keys) — same graceful-empty outcome.
    @Test func wellFormedButSchemaMismatchedJSONFallsBackGracefully() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let notAPresetArray = try! JSONEncoder().encode(["totally": "unrelated"])
        defaults.set(notAPresetArray, forKey: "eqym.customPresets")

        let corrupted = PresetStore(defaults: defaults)
        #expect(corrupted.customPresets.isEmpty)
    }

    /// The defensive filter in load() (`decoded.filter { !$0.isBuiltIn }`) strips any
    /// persisted preset whose OWN `isBuiltIn` flag is true — it doesn't cross-reference
    /// against the actual built-in identity list, it trusts the persisted flag itself.
    /// Simulates a preset that "somehow ended up persisted" with isBuiltIn=true (e.g. a
    /// future bug elsewhere writing one into the custom-presets store) and confirms
    /// load() strips it out rather than surfacing a duplicate/fake built-in.
    @Test func decodedPresetFlaggedAsBuiltInIsStrippedByTheDefensiveFilter() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let smuggledBuiltIn = EQPresetData(
            id: UUID(), name: "Smuggled Built-In",
            bands: [EQBand(frequency: 1000, gain: 0)], isBuiltIn: true)
        let legitCustom = EQPresetData(
            id: UUID(), name: "Legit Custom",
            bands: [EQBand(frequency: 2000, gain: 1)], isBuiltIn: false)
        let data = try! JSONEncoder().encode([smuggledBuiltIn, legitCustom])
        defaults.set(data, forKey: "eqym.customPresets")

        let loaded = PresetStore(defaults: defaults)
        #expect(loaded.customPresets.count == 1)
        #expect(loaded.customPresets.first?.name == "Legit Custom")
        #expect(!loaded.customPresets.contains { $0.name == "Smuggled Built-In" })
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
