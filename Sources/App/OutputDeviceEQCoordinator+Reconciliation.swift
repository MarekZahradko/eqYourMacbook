// The policy core: reconcile() (which engines should be running right now, and starts/
// stops them to match), the default-output-route listener that feeds it, the two
// published-state rebuilders it drives, and the pure decision logic
// (planReconciliation/aggregateStatus) those rebuilders are backed by.

import CoreAudio
import Foundation

extension OutputDeviceEQCoordinator {

    // MARK: - Default-output-route listener

    /// Installs the system-object listener for `kAudioHardwarePropertyDefaultOutputDevice`.
    /// Called once from OutputDeviceEQCoordinator+Lifecycle.swift's start(), balanced by
    /// removeDefaultOutputRouteListener() from stop().
    func installDefaultOutputRouteListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Registered on DispatchQueue.main below, so this already runs on main.
            MainActor.assumeIsolated { self?.handleDefaultOutputDeviceChanged() }
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, DispatchQueue.main, block)
    }

    /// Removes the listener installed above. Called from
    /// OutputDeviceEQCoordinator+Lifecycle.swift's stop().
    func removeDefaultOutputRouteListener() {
        guard let block = defaultOutputListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, DispatchQueue.main, block)
        defaultOutputListenerBlock = nil
    }

    /// Change-detection guard, mirroring OutputDeviceCatalog's
    /// shouldPublishDeviceListChange: CoreAudio fires this listener on any default-
    /// output-route notification, not only ones where the routed-to UID actually moved,
    /// and reconcile() isn't free — so only reconcile when the UID differs from the
    /// last notification acted on.
    private func handleDefaultOutputDeviceChanged() {
        let newUID = liveDefaultOutputUID()
        guard newUID != lastNotifiedDefaultOutputDeviceUID else { return }
        lastNotifiedDefaultOutputDeviceUID = newUID
        reconcile()
    }

    /// Live-queries CoreAudio directly for the current default-output UID rather than
    /// resolving via `catalog.devices.first(where: { $0.id == defaultID })`: the catalog
    /// is refreshed by a SEPARATE, independently-fired listener
    /// (`kAudioHardwarePropertyDevices`) with no ordering guarantee relative to this
    /// device-route listener. A hot-plug that changes both at once (e.g. a USB DAC that
    /// also becomes the new default route) can fire this listener before the catalog
    /// catches up, so a catalog lookup would wrongly resolve to nil. `getDeviceUID(_:)`
    /// (CoreAudioHelpers.swift) has no such dependency, so it resolves correctly on the
    /// very first notification.
    ///
    /// Doesn't by itself let reconcile() start an engine for a genuinely-new device
    /// instantly — that still needs the device's `catalog.devices` entry to construct an
    /// `EQDeviceEngine`, closed by `catalog.onDevicesChanged` re-calling reconcile() once
    /// the catalog catches up (+Lifecycle.swift's start()). This query just keeps
    /// `currentDefaultOutputDeviceUID`/the dedup guard above from being wrongly nilled
    /// in the meantime.
    private func liveDefaultOutputUID() -> String? {
        (try? getDefaultOutputDeviceID()).flatMap { defaultID in try? getDeviceUID(defaultID) }
    }

    // MARK: - Reconciliation
    //
    // The process tap (`stereoGlobalTapButExcludeProcesses`) mutes audio system-wide, not
    // per-device — CoreAudio has no per-device-scoped tap/mute mode. So an engine may
    // ONLY run for the device the OS is currently routing default output to; running it
    // for any other device would silence audio everywhere while nothing plays through
    // the actually-active route. "Enabled" therefore means "start only if also the
    // current default output" — the app must never choose or override output routing,
    // only ride along with it.
    func reconcile() {
        // First-launch seeding needs the catalog populated; retry if still empty.
        if enabledDeviceUIDs.isEmpty {
            loadPersistedEnabledUIDs()
        }

        currentDefaultOutputDeviceUID = liveDefaultOutputUID()

        let plan = Self.planReconciliation(
            catalogDevices: catalog.devices.map { (id: $0.id, uid: $0.uid) },
            runningDeviceIDs: Set(engines.keys),
            runningDeviceUIDs: engines.mapValues(\.deviceUID),
            enabledUIDs: enabledDeviceUIDs,
            globallyEnabled: globallyEnabled,
            defaultOutputDeviceUID: currentDefaultOutputDeviceUID,
            maxSimultaneous: Self.maxSimultaneousDevices)

        // engine.stop()/start() below can synchronously re-enter the
        // EQDeviceEngineDelegate conformance; suppress its rebuild/publish calls since
        // this function does both itself, once, right after.
        isReconcilingEngines = true

        // Stop engines no longer wanted or present (replug auto-resumes: UID stays enabled).
        for id in plan.toStop {
            engines[id]?.stop()
            engines.removeValue(forKey: id)
            engineStates.removeValue(forKey: id)
            permissionSuspectedDevices.remove(id)
        }

        // Start engines the plan selected (enabled, present, not-yet-running, within cap).
        for id in plan.toStart {
            guard let device = catalog.devices.first(where: { $0.id == id }) else { continue }
            let engine = makeEngine(device.id, device.uid, device.name)
            engine.delegate = self
            engine.gainStagingEnabled = currentGainStagingEnabled
            engine.isBypassed = currentBypass
            engines[device.id] = engine
            engineStates[device.id] = .stopped
            engine.start(bands: currentBands)
        }

        isReconcilingEngines = false

        rebuildDeviceRows()
        publishAggregateStatus()
    }

    func rebuildDeviceRows() {
        let rows = catalog.devices.map { device -> DeviceRowViewModel in
            let running: Bool = {
                if case .running = engineStates[device.id] { return true }
                return false
            }()
            let isChecked = enabledDeviceUIDs.contains(device.uid)
            return DeviceRowViewModel(
                id: device.id,
                name: device.name,
                isBuiltIn: device.isBuiltIn,
                isChecked: isChecked,
                isRunning: running,
                isInteractable: enabledDeviceUIDs.isEmpty || isChecked)
        }
        setDeviceRows(rows)
        onDeviceRowsChanged?(rows)
    }

    func publishAggregateStatus() {
        let status = Self.aggregateStatus(
            engineStates: engineStates,
            permissionSuspectedDevices: permissionSuspectedDevices)
        onAggregateStatusChanged?(status)
    }
}

// MARK: - Pure decision logic (testable without CoreAudio)

extension OutputDeviceEQCoordinator {
    /// Pure: decide which device IDs to stop and which (present, enabled,
    /// not-yet-running) device IDs to start, capped at maxSimultaneous.
    ///
    /// `defaultOutputDeviceUID` gates both directions — an engine only stays running
    /// (or starts) for the device the OS is CURRENTLY routing default output to. Not an
    /// optimization: running the engine's system-wide mute for a non-active-route device
    /// would silence audio everywhere while nothing plays through the device in use.
    nonisolated static func planReconciliation(
        catalogDevices: [(id: AudioObjectID, uid: String)],
        runningDeviceIDs: Set<AudioObjectID>,
        runningDeviceUIDs: [AudioObjectID: String],
        enabledUIDs: Set<String>,
        globallyEnabled: Bool,
        defaultOutputDeviceUID: String?,
        maxSimultaneous: Int
    ) -> (toStop: [AudioObjectID], toStart: [AudioObjectID]) {
        // Keyed by id so a reused AudioObjectID with a different UID counts as "gone", not "still present".
        let catalogUIDByID = Dictionary(uniqueKeysWithValues: catalogDevices.map { ($0.id, $0.uid) })

        var toStop: [AudioObjectID] = []
        for id in runningDeviceIDs {
            let uid = runningDeviceUIDs[id]
            let isActiveRoute = uid != nil && uid == defaultOutputDeviceUID
            let stillWanted = globallyEnabled && (uid.map(enabledUIDs.contains) ?? false) && isActiveRoute
            let stillPresent = catalogUIDByID[id] != nil && catalogUIDByID[id] == uid
            if !stillPresent || !stillWanted {
                toStop.append(id)
            }
        }

        var toStart: [AudioObjectID] = []
        if globallyEnabled {
            let remainingRunningCount = runningDeviceIDs.subtracting(toStop).count
            for device in catalogDevices {
                guard enabledUIDs.contains(device.uid) else { continue }
                guard device.uid == defaultOutputDeviceUID else { continue }
                guard !runningDeviceIDs.contains(device.id) else { continue }
                guard remainingRunningCount + toStart.count < maxSimultaneous else { break }
                toStart.append(device.id)
            }
        }

        return (toStop, toStart)
    }

    /// Pure: collapse per-device engine states + permission-suspicion set into
    /// AggregateEngineStatus.
    nonisolated static func aggregateStatus(
        engineStates: [AudioObjectID: EngineState],
        permissionSuspectedDevices: Set<AudioObjectID>
    ) -> AggregateEngineStatus {
        let anyRunning = engineStates.values.contains { if case .running = $0 { return true }; return false }
        // Sorted by deviceID for a deterministic pick when multiple devices fail at once.
        let errorMessage = engineStates.sorted { $0.key < $1.key }.compactMap { _, state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }.first
        return AggregateEngineStatus(
            anyRunning: anyRunning,
            permissionNeeded: !permissionSuspectedDevices.isEmpty,
            errorMessage: errorMessage)
    }
}
