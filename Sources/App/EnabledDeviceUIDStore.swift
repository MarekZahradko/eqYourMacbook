// UserDefaults persistence for the set of user-enabled output device UIDs.

import Foundation

final class EnabledDeviceUIDStore {

    private enum Keys {
        static let enabledDeviceUIDs = "eqym.enabledDeviceUIDs"
    }

    /// Returns the persisted set, or nil if nothing has been saved yet (first launch).
    func load() -> Set<String>? {
        guard let data = UserDefaults.standard.data(forKey: Keys.enabledDeviceUIDs),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(decoded)
    }

    func save(_ uids: Set<String>) {
        if let data = try? JSONEncoder().encode(Array(uids)) {
            UserDefaults.standard.set(data, forKey: Keys.enabledDeviceUIDs)
        }
    }
}
