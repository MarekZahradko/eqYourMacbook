import Testing
import Foundation
@testable import eqYourMacbook

// MARK: - EnabledDeviceUIDStore round-trip
//
// Mirrors PresetStoreTests' isolation pattern (AppLogicTests.swift): a uniquely-named
// UserDefaults suite per test instance, torn down in deinit, so tests never touch the
// real `UserDefaults.standard` domain or interfere with each other.

@Suite final class EnabledDeviceUIDStoreTests {

    private var store: EnabledDeviceUIDStore!
    private let suiteName = "com.zdenekkops.eqyourmacbook.test.\(UUID().uuidString)"

    init() {
        store = EnabledDeviceUIDStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func nothingPersistedYetReturnsNil() {
        #expect(store.load() == nil)
    }

    @Test func saveThenLoadRoundTripsTheSetViaJSONCoding() {
        let uids: Set<String> = ["builtin-uid", "usb-uid", "bluetooth-uid"]
        store.save(uids)
        #expect(store.load() == uids)
    }

    @Test func savingAnEmptySetPersistsAndLoadsAsEmpty_notNil() {
        // Distinguishes "explicitly saved as empty" (user unchecked everything) from
        // "never saved" (first launch) — load() must return `Set()`, not nil, once
        // save() has been called at least once, even with an empty set.
        store.save([])
        #expect(store.load() == Set<String>())
    }

    @Test func laterSaveOverwritesEarlierSave() {
        store.save(["a", "b"])
        store.save(["c"])
        #expect(store.load() == ["c"])
    }

    @Test func persistenceAcrossInstancesOnTheSameSuite() {
        let defaults = UserDefaults(suiteName: suiteName)!
        store.save(["persisted-uid"])

        let store2 = EnabledDeviceUIDStore(defaults: defaults)
        #expect(store2.load() == ["persisted-uid"])
    }
}
