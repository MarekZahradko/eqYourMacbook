// UserDefaults persistence for the set of user-enabled output device UIDs.

import Foundation

final class EnabledDeviceUIDStore {

    private enum Keys {
        static let enabledDeviceUIDs = "eqym.enabledDeviceUIDs"
    }

    // Injectable for test isolation (mirrors PresetStore's `defaults` seam); every
    // production call site still gets `.standard`, matching CONTRACT.md's documented
    // persistence store.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the persisted set, or nil if nothing has been saved yet (first launch).
    func load() -> Set<String>? {
        guard let data = defaults.data(forKey: Keys.enabledDeviceUIDs),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(decoded)
    }

    func save(_ uids: Set<String>) {
        if let data = try? JSONEncoder().encode(Array(uids)) {
            defaults.set(data, forKey: Keys.enabledDeviceUIDs)
        }
    }
}
