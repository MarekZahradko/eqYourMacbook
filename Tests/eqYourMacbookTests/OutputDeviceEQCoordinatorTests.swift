import CoreAudio
import Testing
@testable import eqYourMacbook

/// Tests for OutputDeviceEQCoordinator's pure decision logic — planReconciliation
/// (stop/start policy + soft cap) and aggregateStatus (per-engine-state collapse) —
/// with zero CoreAudio involvement.
@Suite struct OutputDeviceEQCoordinatorTests {

    // MARK: - planReconciliation

    @Test func fifthEnabledDeviceNotStartedWhenFourAlreadyRunning() {
        let running: Set<AudioObjectID> = [1, 2, 3, 4]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b", 3: "c", 4: "d"]
        let catalog: [(id: AudioObjectID, uid: String)] = [
            (1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "e"),
        ]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: catalog,
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a", "b", "c", "d", "e"],
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop.isEmpty)
        #expect(!plan.toStart.contains(5))
    }

    @Test func runningDeviceNoLongerInCatalogIsStopped() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [],   // device 1 has disappeared
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a"],
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop == [1])
        #expect(plan.toStart.isEmpty)
    }

    @Test func runningDeviceWithUncheckedUIDIsStopped() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a")],
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: [],   // "a" was unchecked
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop == [1])
        #expect(plan.toStart.isEmpty)
    }

    @Test func globallyDisabledStopsEverythingAndStartsNothing() {
        let running: Set<AudioObjectID> = [1, 2]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (2, "b")],
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a", "b"],   // still enabled+present, but master switch is off
            globallyEnabled: false,
            maxSimultaneous: 4)

        #expect(Set(plan.toStop) == [1, 2])
        #expect(plan.toStart.isEmpty)
    }

    // MARK: - aggregateStatus

    @Test func aggregateStatusAnyRunningTrueWhenOneEngineRunning() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .running, 2: .stopped],
            permissionSuspectedDevices: [])
        #expect(status.anyRunning)
        #expect(status.errorMessage == nil)
        #expect(!status.permissionNeeded)
    }

    @Test func aggregateStatusSurfacesFailedMessage() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .failed("tap creation failed")],
            permissionSuspectedDevices: [])
        #expect(status.errorMessage == "tap creation failed")
        #expect(!status.anyRunning)
    }

    @Test func aggregateStatusPermissionNeededWhenDeviceSuspected() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .stopped],
            permissionSuspectedDevices: [1])
        #expect(status.permissionNeeded)
    }

    @Test func aggregateStatusEmptyInputsAreAllFalseOrNil() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [:],
            permissionSuspectedDevices: [])
        #expect(!status.anyRunning)
        #expect(!status.permissionNeeded)
        #expect(status.errorMessage == nil)
    }
}
