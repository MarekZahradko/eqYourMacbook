// OutputDeviceEQCoordinator's start()/stop(): wires up OutputDeviceCatalog and the
// default-output-route listener, loads persisted enabled-device state, and (on stop)
// tears down every running engine.

import CoreAudio
import Foundation

extension OutputDeviceEQCoordinator {

    // MARK: - Lifecycle

    func start() {
        catalog.onDevicesChanged = { [weak self] _ in
            self?.reconcile()
        }
        catalog.start()
        loadPersistedEnabledUIDs()

        installDefaultOutputRouteListener()

        reconcile()
        // Prime the route listener's dedup baseline (handleDefaultOutputDeviceChanged(),
        // +Reconciliation.swift) so the first live notification only re-reconciles on an
        // actual route change.
        lastNotifiedDefaultOutputDeviceUID = currentDefaultOutputDeviceUID
    }

    func stop() {
        catalog.stop()
        removeDefaultOutputRouteListener()
        for engine in engines.values { engine.stop() }
        engines.removeAll()
        engineStates.removeAll()
        permissionSuspectedDevices.removeAll()
        rebuildDeviceRows()
    }
}
