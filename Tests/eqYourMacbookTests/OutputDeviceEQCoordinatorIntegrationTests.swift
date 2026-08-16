// Integration tests for OutputDeviceEQCoordinator itself: reconcile()'s actual
// start/stop glue, setDeviceEnabled's mutual-exclusion + persistence round-trip, and the
// EQDeviceEngineDelegate conformance's rebuildDeviceRows()/publishAggregateStatus()
// wiring (including the isReconcilingEngines reentrancy guard). Complements
// OutputDeviceEQCoordinatorTests.swift, which only exercises the pure
// planReconciliation/aggregateStatus helpers — this file drives the coordinator CLASS
// itself, constructed for real, through its public API.
//
// MARK: - What makes this possible without live CoreAudio, and what still doesn't
//
// Two constructor-injectable seams (OutputDeviceEQCoordinator.swift) make this possible:
// `enabledUIDStore:` (an isolated UserDefaults suite instead of `.standard`) and
// `engineFactory:` (reconcile()'s only way to construct an EQDeviceEngine, injected here
// to build engines backed by FakeCoreAudioTapService so start()/stop() never touch live
// CoreAudio). `OutputDeviceCatalog.setDevices(_:)` seeds `coordinator.catalog` with a
// synthetic device list without calling `catalog.start()` (which would register a live
// `kAudioHardwarePropertyDevices` listener); tests likewise never call
// `coordinator.start()`, driving `setDeviceEnabled`/`setGloballyEnabled` directly instead.
//
// The one gap these seams do NOT close: `reconcile()` unconditionally re-reads the
// CURRENT default-output-route UID from live, unseamed CoreAudio calls
// (`liveDefaultOutputUID()` in OutputDeviceEQCoordinator+Reconciliation.swift) on every
// call — a test cannot inject a fake route or simulate the OS's route changing mid-test,
// only read whatever the real machine's actual default-output device is (same accepted
// constraint as EQDeviceEngineLifecycleTests' `translateOwnPIDToProcessObject()` reliance).
//
// Tests below discover the real machine's live default-output UID via the same free
// functions reconcile() itself calls, then build a SYNTHETIC OutputDeviceInfo carrying
// that UID so reconcile()'s route-match check passes deterministically — making "an
// engine starts for the enabled+present+route-matching device" fully testable. It does
// NOT make "the route changes away from a running engine" testable as a within-test
// transition (nothing can force the OS's default-output device to change without
// unplugging hardware). That stop trigger is covered instead by: (1) the pure
// `planReconciliation` helper (OutputDeviceEQCoordinatorTests.swift) pinning the DECISION
// logic for a route change with zero CoreAudio involved; (2) this file's
// `setGloballyEnabledStopsARunningEngine` exercising the identical `toStop` GLUE via the
// master switch, since `stillWanted` ANDs `globallyEnabled` with the route match — either
// one going false is handled identically by reconcile().

import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

// MARK: - Test-only engine factory

/// Captures every FakeCoreAudioTapService-backed EQDeviceEngine the coordinator's
/// injected `engineFactory` constructs, keyed by deviceID, so a test can inspect/drive
/// the exact fake behind whichever engine reconcile() actually created.
@MainActor
private final class EngineFactorySpy {
    private(set) var fakesByDeviceID: [AudioObjectID: FakeCoreAudioTapService] = [:]
    private(set) var createdDeviceIDs: [AudioObjectID] = []
    /// Called with each new fake right after creation, before the engine is built --
    /// lets a test pre-configure failure knobs (e.g. failCreateProcessTap) per device.
    var configure: ((AudioObjectID, FakeCoreAudioTapService) -> Void)?

    func makeEngine(_ deviceID: AudioObjectID, _ deviceUID: String, _ deviceName: String) -> EQDeviceEngine {
        let fake = FakeCoreAudioTapService()
        configure?(deviceID, fake)
        fakesByDeviceID[deviceID] = fake
        createdDeviceIDs.append(deviceID)
        return EQDeviceEngine(deviceID: deviceID, deviceUID: deviceUID, deviceName: deviceName, tapService: fake)
    }
}

@MainActor
@Suite(.serialized) struct OutputDeviceEQCoordinatorIntegrationTests {

    // MARK: - Helpers

    /// Discovers the REAL machine's actual current default-output device UID, via the
    /// exact same free functions `reconcile()`'s `liveDefaultOutputUID()` calls. See this
    /// file's header comment for why tests match against this instead of faking it.
    private func liveDefaultOutputRouteUID() throws -> String {
        let id = try getDefaultOutputDeviceID()
        return try getDeviceUID(id)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "com.zdenekkops.eqyourmacbook.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func cleanUp(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(
        defaults: UserDefaults, spy: EngineFactorySpy = EngineFactorySpy()
    ) -> OutputDeviceEQCoordinator {
        OutputDeviceEQCoordinator(
            enabledUIDStore: EnabledDeviceUIDStore(defaults: defaults),
            engineFactory: spy.makeEngine)
    }

    // MARK: - reconcile() starting an engine (via setDeviceEnabled)

    @Test func setDeviceEnabledStartsAnEngineWhenDeviceIsPresentEnabledAndTheLiveRoute() async throws {
        let liveRouteUID = try liveDefaultOutputRouteUID()
        let syntheticID = AudioObjectID(9_001)
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanUp(suiteName) }
        let spy = EngineFactorySpy()
        let coordinator = makeCoordinator(defaults: defaults, spy: spy)
        defer { coordinator.stop() }

        coordinator.catalog.setDevices([
            OutputDeviceInfo(id: syntheticID, uid: liveRouteUID, name: "Test Route Device", isBuiltIn: false),
        ])

        var rowsSnapshots: [[DeviceRowViewModel]] = []
        coordinator.onDeviceRowsChanged = { rowsSnapshots.append($0) }
        var statusSnapshots: [AggregateEngineStatus] = []
        coordinator.onAggregateStatusChanged = { statusSnapshots.append($0) }

        coordinator.setDeviceEnabled(true, deviceID: syntheticID)

        // reconcile() ran synchronously; phase A of engine.start() is synchronous too, but
        // phase B (createIOProcIDWithBlock/startDevice/.running) is deferred ~0.3s
        // (EQDeviceEngine+Lifecycle.swift) -- mirrors EQDeviceEngineLifecycleTests' own
        // awaiting pattern.
        #expect(coordinator.engines[syntheticID] != nil)
        #expect(coordinator.deviceRows.first(where: { $0.id == syntheticID })?.isChecked == true)
        #expect(coordinator.deviceRows.first(where: { $0.id == syntheticID })?.isRunning == false)

        try await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.engines[syntheticID]?.state == .running)
        #expect(coordinator.engineStates[syntheticID] == .running)
        #expect(coordinator.deviceRows.first(where: { $0.id == syntheticID })?.isRunning == true)
        #expect(statusSnapshots.last?.anyRunning == true)
        let fake = try #require(spy.fakesByDeviceID[syntheticID])
        #expect(fake.callLog == [
            .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .getDeviceNominalSampleRate, .createIOProcIDWithBlock, .startDevice,
        ])
        // At least the row rebuild + status publish from setDeviceEnabled's own
        // reconcile() pass, plus the one from finishStart()'s later didChangeState(.running).
        #expect(rowsSnapshots.count >= 2)
    }

    // MARK: - reconcile() stopping an engine when it's no longer wanted
    //
    // Uses the master switch rather than a route change (see file header) — `stillWanted`
    // treats either one going false identically.

    @Test func setGloballyEnabledStopsARunningEngine() async throws {
        let liveRouteUID = try liveDefaultOutputRouteUID()
        let syntheticID = AudioObjectID(9_002)
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanUp(suiteName) }
        let spy = EngineFactorySpy()
        let coordinator = makeCoordinator(defaults: defaults, spy: spy)
        defer { coordinator.stop() }

        coordinator.catalog.setDevices([
            OutputDeviceInfo(id: syntheticID, uid: liveRouteUID, name: "Test Route Device", isBuiltIn: false),
        ])
        coordinator.setDeviceEnabled(true, deviceID: syntheticID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.engines[syntheticID]?.state == .running)

        var statusSnapshots: [AggregateEngineStatus] = []
        coordinator.onAggregateStatusChanged = { statusSnapshots.append($0) }

        coordinator.setGloballyEnabled(false)

        #expect(coordinator.engines[syntheticID] == nil)
        #expect(coordinator.engineStates[syntheticID] == nil)
        #expect(coordinator.deviceRows.first(where: { $0.id == syntheticID })?.isRunning == false)
        #expect(statusSnapshots.last?.anyRunning == false)
        let fake = try #require(spy.fakesByDeviceID[syntheticID])
        // CONTRACT.md's strict teardown order.
        #expect(fake.callLog.suffix(4) == [
            .stopDevice, .destroyIOProcID, .destroyAggregateDevice, .destroyProcessTap,
        ])
    }

    // MARK: - setDeviceEnabled: mutual exclusion / targeted-device switching

    @Test func setDeviceEnabledReplacesTheEnabledSetAndOnlyStartsTheLiveRouteDevice() async throws {
        let liveRouteUID = try liveDefaultOutputRouteUID()
        let routeDeviceID = AudioObjectID(9_101)
        let otherDeviceID = AudioObjectID(9_102)
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanUp(suiteName) }
        let spy = EngineFactorySpy()
        let coordinator = makeCoordinator(defaults: defaults, spy: spy)
        defer { coordinator.stop() }

        coordinator.catalog.setDevices([
            OutputDeviceInfo(id: routeDeviceID, uid: liveRouteUID, name: "Route Device", isBuiltIn: false),
            OutputDeviceInfo(id: otherDeviceID, uid: "eqym-test-non-route-uid", name: "Other Device", isBuiltIn: false),
        ])

        coordinator.setDeviceEnabled(true, deviceID: routeDeviceID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.engines[routeDeviceID]?.state == .running)

        // User re-checks a DIFFERENT device -- single-selection replace, not an insert.
        coordinator.setDeviceEnabled(true, deviceID: otherDeviceID)

        #expect(coordinator.enabledDeviceUIDs == ["eqym-test-non-route-uid"])
        // The previously-running engine is stopped immediately (no longer enabled).
        #expect(coordinator.engines[routeDeviceID] == nil)
        // The newly-checked device does NOT start: it isn't the live default-output route.
        // CONTRACT.md's Engage policy: checking a device is independent of it actually
        // running -- the row shows checked but "not yet running".
        #expect(coordinator.engines[otherDeviceID] == nil)
        let otherRow = coordinator.deviceRows.first(where: { $0.id == otherDeviceID })
        #expect(otherRow?.isChecked == true)
        #expect(otherRow?.isRunning == false)
        let routeRow = coordinator.deviceRows.first(where: { $0.id == routeDeviceID })
        #expect(routeRow?.isChecked == false)
        // Mutual exclusion: a DIFFERENT device (otherDeviceID) is now checked, so every
        // other row -- routeRow included -- is non-interactable (CONTRACT.md's Engage
        // policy / DeviceRowViewModel.isInteractable's doc comment).
        #expect(routeRow?.isInteractable == false)
    }

    // MARK: - EQDeviceEngineDelegate conformance: isReconcilingEngines reentrancy guard
    //
    // A synchronous start FAILURE transitions EQDeviceEngine.state to .failed inside
    // failStart(), firing didChangeState(.failed) SYNCHRONOUSLY while still inside
    // reconcile()'s `for id in plan.toStart` loop — before reconcile()'s own unconditional
    // rebuildDeviceRows()/publishAggregateStatus() calls at its end. Without
    // isReconcilingEngines, that reentrant callback would invoke both too, double-publishing
    // per setDeviceEnabled() call instead of once.

    @Test func reentrantFailureDuringReconcileDoesNotDoublePublish() throws {
        let liveRouteUID = try liveDefaultOutputRouteUID()
        let syntheticID = AudioObjectID(9_201)
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanUp(suiteName) }
        let spy = EngineFactorySpy()
        // Synchronous start failure: performStart() throws at its very first CoreAudio
        // call, so failStart()'s transition(to: .failed) fires while
        // isReconcilingEngines is still true.
        spy.configure = { _, fake in fake.failCreateProcessTap = true }
        let coordinator = makeCoordinator(defaults: defaults, spy: spy)
        defer { coordinator.stop() }

        coordinator.catalog.setDevices([
            OutputDeviceInfo(id: syntheticID, uid: liveRouteUID, name: "Test Route Device", isBuiltIn: false),
        ])

        var rowsPublishCount = 0
        coordinator.onDeviceRowsChanged = { _ in rowsPublishCount += 1 }
        var statusPublishCount = 0
        coordinator.onAggregateStatusChanged = { _ in statusPublishCount += 1 }

        coordinator.setDeviceEnabled(true, deviceID: syntheticID)

        #expect(rowsPublishCount == 1, "the guard must suppress the mid-reconcile reentrant publish, leaving only reconcile()'s own final one")
        #expect(statusPublishCount == 1, "same as above, for publishAggregateStatus()")
        guard case .failed(let message) = coordinator.engineStates[syntheticID] else {
            Issue.record("expected .failed, got \(String(describing: coordinator.engineStates[syntheticID]))")
            return
        }
        #expect(message.hasPrefix("Failed to create process tap"))
    }

    // MARK: - Persistence round-trip through a fresh coordinator instance

    @Test func setDeviceEnabledPersistenceRoundTripsThroughAFreshCoordinatorOnTheSameSuite() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanUp(suiteName) }
        let syntheticID = AudioObjectID(9_301)
        let syntheticUID = "eqym-test-persistence-round-trip-uid"

        let coordinator1 = makeCoordinator(defaults: defaults)
        coordinator1.catalog.setDevices([
            OutputDeviceInfo(id: syntheticID, uid: syntheticUID, name: "Test Device", isBuiltIn: false),
        ])
        coordinator1.setDeviceEnabled(true, deviceID: syntheticID)
        #expect(coordinator1.enabledDeviceUIDs == [syntheticUID])
        defer { coordinator1.stop() }

        // A brand-new coordinator instance, same UserDefaults suite, sharing NO in-memory
        // state with coordinator1 -- only loadPersistedEnabledUIDs()'s read from the store
        // both were constructed with.
        let coordinator2 = makeCoordinator(defaults: defaults)
        defer { coordinator2.stop() }
        coordinator2.loadPersistedEnabledUIDs()
        #expect(coordinator2.enabledDeviceUIDs == [syntheticUID])
    }
}
