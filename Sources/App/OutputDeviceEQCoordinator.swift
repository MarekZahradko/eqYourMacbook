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
    // Only one device may be enabled at a time (the process-tap's mute is
    // system-wide, not device-scoped — see reconcile()'s doc comment), so every
    // other row is non-interactive while one is checked.
    var isInteractable: Bool
}

/// Aggregate view of every running engine's health, for EQController's DisplayStatus.
/// Collapses per-engine delegate callbacks into: anything running, any engine
/// suspecting a permission problem, and the most recent error message.
struct AggregateEngineStatus: Equatable {
    var anyRunning: Bool
    var permissionNeeded: Bool
    var errorMessage: String?
}

/// Seam so EQController can be tested with a fake instead of a live coordinator
/// (which would otherwise register a real CoreAudio device listener and start taps).
@MainActor protocol OutputDeviceEQCoordinating: AnyObject {
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)? { get set }
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)? { get set }

    func start()
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID)
    func setGloballyEnabled(_ enabled: Bool)
    func updateBands(_ bands: [EQBand])
    func updateBypass(_ bypassed: Bool)
    func setGainStagingEnabled(_ enabled: Bool)
}

@MainActor final class OutputDeviceEQCoordinator: OutputDeviceEQCoordinating {

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

    // Tracks which device UID macOS is currently actually routing system audio
    // to. Reconciliation only ever starts/keeps an engine running for the
    // enabled device when it IS this route — see reconcile()'s doc comment for why.
    private var currentDefaultOutputDeviceUID: String?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var engineStates: [AudioObjectID: EngineState] = [:]
    private var permissionSuspectedDevices: Set<AudioObjectID> = []

    private var globallyEnabled = true
    private var currentBands: [EQBand] = []
    private var currentBypass = false
    private var currentGainStagingEnabled = true

    // Memoizes anyOtherProcessOutputtingAudio(excluding:) across every engine's watchdog
    // tick (each EQDeviceEngine runs its own independent 5 s DispatchSourceTimer on
    // .main, so ticks aren't synchronized). Every engine would ask this with the same
    // ownProcessObjectID and get the identical CoreAudio answer, so re-enumerating the
    // system process list + re-querying kAudioProcessPropertyIsRunningOutput once per
    // engine per tick is pure waste. TTL is short (1 s) so it doesn't blur the watchdog's
    // own 5 s-period / 2-consecutive-check detection latency — it only dedupes calls
    // that land within the same ~1 s window, which real per-engine timer jitter can do.
    private static let othersOutputtingCacheTTL: TimeInterval = 1.0
    private var cachedOthersOutputting: Bool?
    private var othersOutputtingCachedAt: Date?

    // Defense-in-depth only: setDeviceEnabled() and the default-output-route gating
    // in planReconciliation already guarantee at most one engine ever runs (the
    // process tap's mute is system-wide, not per-device — see reconcile()'s doc
    // comment — so more than one running engine at a time is never safe). This cap
    // exists purely to bound an unforeseen bug in that invariant, not as a tunable.
    private static let maxSimultaneousDevices = 1

    init() {}

    // MARK: - Lifecycle

    func start() {
        catalog.onDevicesChanged = { [weak self] _ in
            self?.reconcile()
        }
        catalog.start()
        loadPersistedEnabledUIDs()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Registered on DispatchQueue.main below, so this already runs on main.
            MainActor.assumeIsolated { self?.reconcile() }
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, DispatchQueue.main, block)

        reconcile()
    }

    func stop() {
        catalog.stop()
        if let block = defaultOutputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, DispatchQueue.main, block)
            defaultOutputListenerBlock = nil
        }
        for engine in engines.values { engine.stop() }
        engines.removeAll()
        engineStates.removeAll()
        permissionSuspectedDevices.removeAll()
        rebuildDeviceRows()
    }

    // MARK: - UI intent

    // Only one device can ever be EQ-enabled at a time (see reconcile()'s doc
    // comment) — enabling a device replaces the enabled set rather than adding to it.
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID) {
        guard let device = catalog.devices.first(where: { $0.id == deviceID }) else { return }
        if enabled {
            enabledDeviceUIDs = [device.uid]
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
    // The process tap (`stereoGlobalTapButExcludeProcesses`, see EQDeviceEngine+Lifecycle)
    // mutes a process's audio system-wide, not just on the tapped device — CoreAudio
    // has no per-device-scoped tap/mute mode. So an engine may ONLY run for the
    // device the OS is actually routing default output to right now: running it for
    // any other device would silence audio everywhere while nothing plays through
    // the actually-active route. This is why only one device can ever be enabled
    // (setDeviceEnabled enforces that) and why "enabled" here further means "start
    // only if this device is also the current default output" — the app must never
    // choose or override the user's/macOS's output routing, only ride along with it.
    private func reconcile() {
        // First-launch seeding needs the catalog populated; retry if still empty.
        if enabledDeviceUIDs.isEmpty {
            loadPersistedEnabledUIDs()
        }

        currentDefaultOutputDeviceUID = (try? getDefaultOutputDeviceID()).flatMap { defaultID in
            catalog.devices.first(where: { $0.id == defaultID })?.uid
        }

        let plan = Self.planReconciliation(
            catalogDevices: catalog.devices.map { (id: $0.id, uid: $0.uid) },
            runningDeviceIDs: Set(engines.keys),
            runningDeviceUIDs: engines.mapValues(\.deviceUID),
            enabledUIDs: enabledDeviceUIDs,
            globallyEnabled: globallyEnabled,
            defaultOutputDeviceUID: currentDefaultOutputDeviceUID,
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
            let isChecked = enabledDeviceUIDs.contains(device.uid)
            return DeviceRowViewModel(
                id: device.id,
                name: device.name,
                isBuiltIn: device.isBuiltIn,
                isChecked: isChecked,
                isRunning: running,
                isInteractable: enabledDeviceUIDs.isEmpty || isChecked)
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
    ///
    /// `defaultOutputDeviceUID` gates both directions: an engine only stays
    /// running (or gets started) for the device the OS is CURRENTLY routing
    /// default output to. This is not an optimization — running the engine
    /// (and its system-wide mute) for a device that isn't the active route
    /// would silence audio everywhere while nothing plays through the device
    /// actually in use. The app must only ride along with routing, never
    /// choose or override it.
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

    // Shared TTL-cached helper (CLAUDE.md audit fix): computes the real answer once per
    // ~1 s window and reuses it for every engine that asks within that window, instead
    // of each of the (up to maxSimultaneousDevices) engines independently re-querying
    // CoreAudio on its own 5 s timer. Recomputes on a cache miss/expiry; never changes
    // the watchdog's detection semantics, only avoids redundant round-trips.
    func anyOtherProcessOutputtingAudio(excluding processObjectID: AudioObjectID) -> Bool {
        let now = Date()
        if let cachedOthersOutputting, let othersOutputtingCachedAt,
           now.timeIntervalSince(othersOutputtingCachedAt) < Self.othersOutputtingCacheTTL {
            return cachedOthersOutputting
        }
        // Module-qualified: the protocol requirement below has the same base name as
        // the free function in CoreAudioHelpers.swift, and an unqualified call here
        // would resolve to `self` (infinite recursion) since member lookup shadows
        // top-level functions of the same name.
        let result = eqYourMacbook.anyOtherProcessOutputtingAudio(excluding: processObjectID)
        cachedOthersOutputting = result
        othersOutputtingCachedAt = now
        return result
    }
}
