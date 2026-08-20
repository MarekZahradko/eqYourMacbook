// Owns the lifecycle of per-device EQDeviceEngine instances: which devices exist
// (OutputDeviceCatalog), which the user has enabled (enabledDeviceUIDs, persisted),
// and which are actually running (engines). EQController only renders/forwards UI intent.
//
// Split across files (extensions can't hold stored properties, so all state lives
// here): lifecycle (start/stop) in +Lifecycle.swift; UI-intent forwarding in
// +DeviceIntent.swift; enabledDeviceUIDs load/save in +Persistence.swift; reconcile()
// and the route listener in +Reconciliation.swift; model types, the protocol seam,
// stored state, init, and EQDeviceEngineDelegate conformance here. Properties touched
// only from extension files are `internal` rather than `private`, each commented with
// which file(s) need the access (same convention as EQDeviceEngine's file split). The
// two properties documented as `private(set)` (`deviceRows`,
// `enabledDeviceUIDs`) keep that declaration and expose a narrow hook method for
// extension-file writes instead, mirroring EQDeviceEngine's `transition(to:)`.

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

    // Delegate for every EQDeviceEngine it creates (keyed by deviceID); collapses all
    // per-device states into one AggregateEngineStatus for EQController's status line.
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)?
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)?

    private(set) var deviceRows: [DeviceRowViewModel] = []
    private(set) var enabledDeviceUIDs: Set<String> = []

    /// Hook for +Reconciliation.swift's rebuildDeviceRows() to write `deviceRows`
    /// without widening its intentional `private(set)` setter.
    func setDeviceRows(_ rows: [DeviceRowViewModel]) {
        deviceRows = rows
    }

    /// Hook for +DeviceIntent.swift's setDeviceEnabled() and +Persistence.swift's
    /// loadPersistedEnabledUIDs() to write `enabledDeviceUIDs` — same reasoning as
    /// setDeviceRows(_:) above.
    func setEnabledDeviceUIDs(_ uids: Set<String>) {
        enabledDeviceUIDs = uids
    }

    // Read/written from +Lifecycle/+DeviceIntent/+Persistence/+Reconciliation → internal.
    // Not constructor-injected like enabledUIDStore/makeEngine below: tests populate it
    // via its own `setDevices(_:)` hook (OutputDeviceCatalog.swift) instead.
    let catalog = OutputDeviceCatalog()
    // Touched only by +Persistence.swift → internal. Constructor-injectable (mirrors
    // EnabledDeviceUIDStore's own `defaults:` seam) so tests can use an isolated
    // UserDefaults suite instead of `.standard`.
    let enabledUIDStore: EnabledDeviceUIDStore

    /// Builds the `EQDeviceEngine` for a device reconcile() decided to start.
    /// Constructor-injectable testability seam (default: real `EQDeviceEngine` backed
    /// by `LiveCoreAudioTapService`, so every real call site is unaffected). Tests
    /// inject a factory backed by `FakeCoreAudioTapService` to exercise reconcile()'s
    /// start/stop glue and this file's `EQDeviceEngineDelegate` conformance without
    /// touching live CoreAudio.
    typealias EngineFactory = (
        _ deviceID: AudioObjectID, _ deviceUID: String, _ deviceName: String
    ) -> EQDeviceEngine
    // Touched only by +Reconciliation.swift's reconcile() → internal.
    let makeEngine: EngineFactory
    // Touched by +DeviceIntent.swift (fan-out loops), +Lifecycle.swift (stop()), and
    // +Reconciliation.swift (start/stop bookkeeping) → internal.
    var engines: [AudioObjectID: EQDeviceEngine] = [:]

    // The device UID macOS is currently routing system audio to. An engine only ever
    // starts/stays running for the enabled device when it IS this route (reconcile()'s
    // doc comment). Refreshed unconditionally by reconcile() every call; primed by
    // +Lifecycle.swift's start() → internal.
    var currentDefaultOutputDeviceUID: String?
    // Last default-output UID the route listener actually acted on, so
    // handleDefaultOutputDeviceChanged() (+Reconciliation.swift) can skip reconcile()
    // when CoreAudio fires the notification without the route itself changing. Primed
    // by +Lifecycle.swift's start() → internal.
    var lastNotifiedDefaultOutputDeviceUID: String?
    // Touched only by +Reconciliation.swift's install/removeDefaultOutputRouteListener() → internal.
    var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // Touched by this file's EQDeviceEngineDelegate conformance, +Lifecycle.swift
    // (stop() clears both), and +Reconciliation.swift (read/write) → internal.
    var engineStates: [AudioObjectID: EngineState] = [:]
    var permissionSuspectedDevices: Set<AudioObjectID> = []

    /// Suppresses rebuildDeviceRows()/publishAggregateStatus() while reconcile()
    /// (+Reconciliation.swift) is mid-pass: engine.stop()/start() can synchronously
    /// re-enter this file's EQDeviceEngineDelegate conformance (e.g. a start failing
    /// synchronously fires didChangeState before reconcile()'s loop finishes), and any
    /// such mid-pass callback is just a preview of the state reconcile() unconditionally
    /// republishes once at its own end. Set/cleared only by reconcile() → internal.
    var isReconcilingEngines = false

    // Touched by +DeviceIntent.swift (setters) and +Reconciliation.swift (reconcile()
    // reads them when starting/updating engines) → internal.
    var globallyEnabled = true
    var currentBands: [EQBand] = []
    var currentBypass = false
    var currentGainStagingEnabled = true

    // Memoizes anyOtherProcessOutputtingAudio(excluding:) across engines' independent,
    // unsynchronized 5 s watchdog timers, since every engine asks the same CoreAudio
    // question. TTL is short (1 s) so it only dedupes calls in the same jitter window,
    // without blurring the watchdog's own 5 s/2-check detection latency.
    private static let othersOutputtingCacheTTL: TimeInterval = 1.0
    private var cachedOthersOutputting: Bool?
    private var othersOutputtingCachedAt: Date?

    // Defense-in-depth only, not a tunable: setDeviceEnabled() and the default-output-
    // route gating in planReconciliation already guarantee at most one engine ever runs
    // (the process tap's mute is system-wide, not per-device — see reconcile()).
    static let maxSimultaneousDevices = 1

    /// Both parameters default to exact production behavior, so every real call site —
    /// `EQController.init`'s `OutputDeviceEQCoordinator()` included — is unaffected.
    /// Only tests pass non-default values (OutputDeviceEQCoordinatorIntegrationTests.swift).
    init(enabledUIDStore: EnabledDeviceUIDStore = EnabledDeviceUIDStore(),
         engineFactory: @escaping EngineFactory = { deviceID, deviceUID, deviceName in
             EQDeviceEngine(deviceID: deviceID, deviceUID: deviceUID, deviceName: deviceName)
         }) {
        self.enabledUIDStore = enabledUIDStore
        self.makeEngine = engineFactory
    }
}

// MARK: - EQDeviceEngineDelegate

extension OutputDeviceEQCoordinator: EQDeviceEngineDelegate {
    func engine(_ engine: EQDeviceEngine, didChangeState state: EngineState) {
        engineStates[engine.deviceID] = state
        if case .running = state { permissionSuspectedDevices.remove(engine.deviceID) }
        guard !isReconcilingEngines else { return }
        rebuildDeviceRows()
        publishAggregateStatus()
    }

    func engineSuspectsPermissionDenied(_ engine: EQDeviceEngine) {
        permissionSuspectedDevices.insert(engine.deviceID)
        guard !isReconcilingEngines else { return }
        publishAggregateStatus()
    }

    func anyOtherProcessOutputtingAudio(excluding processObjectID: AudioObjectID) -> Bool {
        let now = Date()
        if let cachedOthersOutputting, let othersOutputtingCachedAt,
           now.timeIntervalSince(othersOutputtingCachedAt) < Self.othersOutputtingCacheTTL {
            return cachedOthersOutputting
        }
        // Module-qualified: an unqualified call would resolve to this same-named
        // protocol method (infinite recursion) — member lookup shadows the top-level
        // free function in CoreAudioHelpers.swift.
        let result = eqYourMacbook.anyOtherProcessOutputtingAudio(excluding: processObjectID)
        cachedOthersOutputting = result
        othersOutputtingCachedAt = now
        return result
    }
}
