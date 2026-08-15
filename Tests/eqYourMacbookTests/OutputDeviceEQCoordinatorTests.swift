import CoreAudio
import XCTest
@testable import eqYourMacbook

/// Tests for OutputDeviceEQCoordinator's pure decision logic — planReconciliation
/// (stop/start policy + soft cap) and aggregateStatus (per-engine-state collapse) —
/// with zero CoreAudio involvement.
final class OutputDeviceEQCoordinatorTests: XCTestCase {

    // MARK: - planReconciliation

    func testFifthEnabledDeviceNotStartedWhenFourAlreadyRunning() {
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

        XCTAssertTrue(plan.toStop.isEmpty)
        XCTAssertFalse(plan.toStart.contains(5))
    }

    func testRunningDeviceNoLongerInCatalogIsStopped() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [],   // device 1 has disappeared
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a"],
            globallyEnabled: true,
            maxSimultaneous: 4)

        XCTAssertEqual(plan.toStop, [1])
        XCTAssertTrue(plan.toStart.isEmpty)
    }

    func testRunningDeviceWithUncheckedUIDIsStopped() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a")],
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: [],   // "a" was unchecked
            globallyEnabled: true,
            maxSimultaneous: 4)

        XCTAssertEqual(plan.toStop, [1])
        XCTAssertTrue(plan.toStart.isEmpty)
    }

    func testGloballyDisabledStopsEverythingAndStartsNothing() {
        let running: Set<AudioObjectID> = [1, 2]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (2, "b")],
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a", "b"],   // still enabled+present, but master switch is off
            globallyEnabled: false,
            maxSimultaneous: 4)

        XCTAssertEqual(Set(plan.toStop), [1, 2])
        XCTAssertTrue(plan.toStart.isEmpty)
    }

    // MARK: - aggregateStatus

    func testAggregateStatusAnyRunningTrueWhenOneEngineRunning() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .running, 2: .stopped],
            permissionSuspectedDevices: [])
        XCTAssertTrue(status.anyRunning)
        XCTAssertNil(status.errorMessage)
        XCTAssertFalse(status.permissionNeeded)
    }

    func testAggregateStatusSurfacesFailedMessage() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .failed("tap creation failed")],
            permissionSuspectedDevices: [])
        XCTAssertEqual(status.errorMessage, "tap creation failed")
        XCTAssertFalse(status.anyRunning)
    }

    func testAggregateStatusPermissionNeededWhenDeviceSuspected() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .stopped],
            permissionSuspectedDevices: [1])
        XCTAssertTrue(status.permissionNeeded)
    }

    func testAggregateStatusEmptyInputsAreAllFalseOrNil() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [:],
            permissionSuspectedDevices: [])
        XCTAssertFalse(status.anyRunning)
        XCTAssertFalse(status.permissionNeeded)
        XCTAssertNil(status.errorMessage)
    }
}
