// Owns the lifecycle of per-device EQDeviceEngine instances: which devices exist
// (OutputDeviceCatalog), which the user has enabled (enabledDeviceUIDs, persisted),
// and which are actually running (engines). EQController only renders/forwards UI intent.

import CoreAudio
import Foundation

struct DeviceRowViewModel: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let isBuiltIn: Bool
    var isChecked: Bool
    var isRunning: Bool
}

/// Aggregate view of every running engine's health, for EQController's DisplayStatus.
/// Collapses per-engine delegate callbacks into: anything running, any engine
/// suspecting a permission problem, and the most recent error message.
struct AggregateEngineStatus: Equatable {
    var anyRunning: Bool
    var permissionNeeded: Bool
    var errorMessage: String?
}

@MainActor final class OutputDeviceEQCoordinator {

    // The coordinator conforms to EQDeviceEngineDelegate and is the delegate for every
    // EQDeviceEngine it creates, keyed by each engine's own deviceID. It collapses all
    // per-device states into one AggregateEngineStatus for EQController's status line.
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)?
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)?

    private(set) var deviceRows: [DeviceRowViewModel] = []
    private(set) var enabledDeviceUIDs: Set<String> = []

    private let catalog = OutputDeviceCatalog()
    private let enabledUIDStore = EnabledDeviceUIDStore()
    private var engines: [AudioObjectID: EQDeviceEngine] = [:]

    private var engineStates: [AudioObjectID: EngineState] = [:]
    private var permissionSuspectedDevices: Set<AudioObjectID> = []

    private var globallyEnabled = true
    private var currentBands: [EQBand] = []
    private var currentBypass = false
    private var currentGainStagingEnabled = true

    // Soft cap on simultaneously enabled devices: N concurrent aggregate+tap+IOProc
    // sets is unverified on real hardware. Keeps a mistaken "enable everything" click
    // from spawning unbounded taps. Raise once multi-device stability is confirmed.
    private static let maxSimultaneousDevices = 4

    init() {}

    // MARK: - Lifecycle

    func start() {
        catalog.onDevicesChanged = { [weak self] _ in
            self?.reconcile()
        }
        catalog.start()
        loadPersistedEnabledUIDs()
        reconcile()
    }

    func stop() {
        catalog.stop()
        for engine in engines.values { engine.stop() }
        engines.removeAll()
        engineStates.removeAll()
        permissionSuspectedDevices.removeAll()
        rebuildDeviceRows()
    }

    // MARK: - UI intent

    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID) {
        guard let device = catalog.devices.first(where: { $0.id == deviceID }) else { return }
        if enabled {
            enabledDeviceUIDs.insert(device.uid)
        } else {
            enabledDeviceUIDs.remove(device.uid)
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

    // MARK: - First-launch default

    private func loadPersistedEnabledUIDs() {
        if let loaded = enabledUIDStore.load() {
            enabledDeviceUIDs = loaded
            return
        }
        // First launch: seed with just the built-in speakers' UID once discovered.
        if let builtIn = catalog.devices.first(where: \.isBuiltIn) {
            enabledDeviceUIDs = [builtIn.uid]
            persistEnabledUIDs()
        }
    }

    private func persistEnabledUIDs() {
        enabledUIDStore.save(enabledDeviceUIDs)
    }

    // MARK: - Reconciliation
    //
    // Open risk: whether N concurrent aggregate-device + tap + IOProc sets are stable
    // on real hardware is unverified — needs manual multi-device testing on first build.
    private func reconcile() {
        // First-launch seeding needs the catalog populated; retry if still empty.
        if enabledDeviceUIDs.isEmpty {
            loadPersistedEnabledUIDs()
        }

        let plan = Self.planReconciliation(
            catalogDevices: catalog.devices.map { (id: $0.id, uid: $0.uid) },
            runningDeviceIDs: Set(engines.keys),
            runningDeviceUIDs: engines.mapValues(\.deviceUID),
            enabledUIDs: enabledDeviceUIDs,
            globallyEnabled: globallyEnabled,
            maxSimultaneous: Self.maxSimultaneousDevices)

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
            let engine = EQDeviceEngine(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
            engine.delegate = self
            engine.gainStagingEnabled = currentGainStagingEnabled
            engine.isBypassed = currentBypass
            engines[device.id] = engine
            engineStates[device.id] = .stopped
            engine.start(bands: currentBands)
        }

        rebuildDeviceRows()
        publishAggregateStatus()
    }

    private func rebuildDeviceRows() {
        deviceRows = catalog.devices.map { device in
            let running: Bool = {
                if case .running = engineStates[device.id] { return true }
                return false
            }()
            return DeviceRowViewModel(
                id: device.id,
                name: device.name,
                isBuiltIn: device.isBuiltIn,
                isChecked: enabledDeviceUIDs.contains(device.uid),
                isRunning: running)
        }
        onDeviceRowsChanged?(deviceRows)
    }

    private func publishAggregateStatus() {
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
    nonisolated static func planReconciliation(
        catalogDevices: [(id: AudioObjectID, uid: String)],
        runningDeviceIDs: Set<AudioObjectID>,
        runningDeviceUIDs: [AudioObjectID: String],
        enabledUIDs: Set<String>,
        globallyEnabled: Bool,
        maxSimultaneous: Int
    ) -> (toStop: [AudioObjectID], toStart: [AudioObjectID]) {
        let catalogIDs = Set(catalogDevices.map(\.id))

        var toStop: [AudioObjectID] = []
        for id in runningDeviceIDs {
            let uid = runningDeviceUIDs[id]
            let stillWanted = globallyEnabled && (uid.map(enabledUIDs.contains) ?? false)
            let stillPresent = catalogIDs.contains(id)
            if !stillPresent || !stillWanted {
                toStop.append(id)
            }
        }

        var toStart: [AudioObjectID] = []
        if globallyEnabled {
            let remainingRunningCount = runningDeviceIDs.subtracting(toStop).count
            for device in catalogDevices {
                guard enabledUIDs.contains(device.uid) else { continue }
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
        let errorMessage = engineStates.values.compactMap { state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }.first
        return AggregateEngineStatus(
            anyRunning: anyRunning,
            permissionNeeded: !permissionSuspectedDevices.isEmpty,
            errorMessage: errorMessage)
    }
}

// MARK: - EQDeviceEngineDelegate

extension OutputDeviceEQCoordinator: EQDeviceEngineDelegate {
    func engine(_ engine: EQDeviceEngine, didChangeState state: EngineState) {
        engineStates[engine.deviceID] = state
        if case .running = state { permissionSuspectedDevices.remove(engine.deviceID) }
        rebuildDeviceRows()
        publishAggregateStatus()
    }

    func engineSuspectsPermissionDenied(_ engine: EQDeviceEngine) {
        permissionSuspectedDevices.insert(engine.deviceID)
        publishAggregateStatus()
    }
}
