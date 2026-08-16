// First-launch default + persisted enabledDeviceUIDs load/save, via EnabledDeviceUIDStore.

import CoreAudio
import Foundation

extension OutputDeviceEQCoordinator {

    // MARK: - First-launch default

    func loadPersistedEnabledUIDs() {
        if let loaded = enabledUIDStore.load() {
            setEnabledDeviceUIDs(loaded)
            return
        }
        // First launch: seed with just the built-in speakers' UID once discovered.
        if let builtIn = catalog.devices.first(where: \.isBuiltIn) {
            setEnabledDeviceUIDs([builtIn.uid])
            persistEnabledUIDs()
        }
    }

    func persistEnabledUIDs() {
        enabledUIDStore.save(enabledDeviceUIDs)
    }
}
