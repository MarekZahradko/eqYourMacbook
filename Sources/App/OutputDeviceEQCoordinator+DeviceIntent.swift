// UI-intent forwarding: EQController calls these directly (via
// OutputDeviceEQCoordinating), and they either update persisted/policy state and
// re-reconcile, or fan a live update out to every currently-running engine.

import CoreAudio
import Foundation

extension OutputDeviceEQCoordinator {

    // MARK: - UI intent

    // Only one device can ever be EQ-enabled at a time (see reconcile()'s doc
    // comment) — enabling a device replaces the enabled set rather than adding to it.
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID) {
        guard let device = catalog.devices.first(where: { $0.id == deviceID }) else { return }
        if enabled {
            setEnabledDeviceUIDs([device.uid])
        } else {
            var updated = enabledDeviceUIDs
            updated.remove(device.uid)
            setEnabledDeviceUIDs(updated)
        }
        persistEnabledUIDs()
        reconcile()
    }

    func setGloballyEnabled(_ enabled: Bool) {
        globallyEnabled = enabled
        reconcile()
    }

    func updateBands(_ bands: [EQBand]) {
        currentBands = bands
        for engine in engines.values { engine.update(bands: bands) }
    }

    func updateBypass(_ bypassed: Bool) {
        currentBypass = bypassed
        for engine in engines.values { engine.isBypassed = bypassed }
    }

    func setGainStagingEnabled(_ enabled: Bool) {
        currentGainStagingEnabled = enabled
        for engine in engines.values { engine.gainStagingEnabled = enabled }
    }
}
