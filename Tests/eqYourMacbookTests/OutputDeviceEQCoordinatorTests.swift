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

    /// 2 already running + 3 enabled-but-not-running candidates, cap of 4: exactly 2
    /// more should start. planReconciliation's toStart loop walks `catalogDevices` in
    /// array order (not the unordered running-IDs Set), so which 2 win is deterministic:
    /// the first 2 candidates in catalog order, i.e. devices 3 and 4, NOT device 5.
    @Test func partialFillStartsExactlyEnoughToReachCapInCatalogOrder() {
        let running: Set<AudioObjectID> = [1, 2]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b"]
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
        #expect(plan.toStart == [3, 4])
    }

    /// maxSimultaneous == 0: the cap guard (`remainingRunningCount + toStart.count <
    /// maxSimultaneous`) fails on the very first candidate, so nothing new starts. The
    /// cap only ever gates NEW starts — it never forces an already-running device to
    /// stop, so toStop stays empty too (no running devices in this scenario at all).
    @Test func zeroCapStartsNothingButDoesNotStopAnything() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (2, "b")],
            runningDeviceIDs: [],
            runningDeviceUIDs: [:],
            enabledUIDs: ["a", "b"],
            globallyEnabled: true,
            maxSimultaneous: 0)

        #expect(plan.toStop.isEmpty)
        #expect(plan.toStart.isEmpty)
    }

    /// Empty catalog with a nonzero cap: the toStart loop over `catalogDevices` is
    /// vacuous, and there are no running devices to evaluate for toStop either. Confirms
    /// no crash / no spurious entries when the catalog just hasn't populated yet.
    @Test func emptyCatalogWithNonzeroCapProducesEmptyPlan() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [],
            runningDeviceIDs: [],
            runningDeviceUIDs: [:],
            enabledUIDs: ["a"],
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop.isEmpty)
        #expect(plan.toStart.isEmpty)
    }

    /// A device stopped this cycle (uid "a" unchecked) frees a cap slot that a
    /// newly-enabled candidate (uid "e") immediately fills in the SAME reconciliation
    /// pass. This works because `remainingRunningCount` is computed as
    /// `runningDeviceIDs.subtracting(toStop).count` — i.e. toStop is subtracted BEFORE
    /// the toStart loop evaluates the cap, so freed slots are visible immediately
    /// rather than only on the next reconcile() call.
    @Test func stoppingADeviceFreesItsCapSlotForANewStartInTheSamePass() {
        let running: Set<AudioObjectID> = [1, 2, 3, 4]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b", 3: "c", 4: "d"]
        let catalog: [(id: AudioObjectID, uid: String)] = [
            (1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "e"),
        ]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: catalog,
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["b", "c", "d", "e"],   // "a" unchecked, "e" newly checked
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop == [1])
        #expect(plan.toStart == [5])
    }

    // MARK: - "Device disappears mid-operation" (mixed present/absent, reused IDs)

    /// Catalog is non-empty but exactly ONE of several previously-running devices is
    /// missing from it (the others are still present). Only the missing device should
    /// be in toStop.
    @Test func onlyTheOneMissingRunningDeviceAmongSeveralIsStopped() {
        let running: Set<AudioObjectID> = [1, 2, 3]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b", 3: "c"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (3, "c")],   // device 2 ("b") has disappeared
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a", "b", "c"],
            globallyEnabled: true,
            maxSimultaneous: 4)

        #expect(plan.toStop == [2])
        #expect(plan.toStart.isEmpty)
    }

    /// GAP (documents a real correctness issue, not just a test): planReconciliation's
    /// `stillPresent` check is purely ID-membership (`catalogIDs.contains(id)`) — it
    /// never compares the running engine's OWN uid (`runningDeviceUIDs[id]`) against
    /// the uid the catalog currently reports AT THAT SAME ID. If CoreAudio reuses an
    /// AudioObjectID for a completely different physical device (old device unplugged,
    /// new device enumerated, HAL happens to hand out the same ID) while the OLD
    /// device's uid is still in `enabledUIDs` (the user never got a chance to react),
    /// the plan considers the stale engine both "still present" (id matches) and
    /// "still wanted" (old uid still enabled) — so it is NOT stopped, and the new
    /// device's uid is never started either (its uid isn't enabled, and its id is
    /// already "running" as far as the plan can see). The stale engine silently keeps
    /// running against whatever CoreAudio now considers that AudioObjectID to be.
    /// This test pins down the CURRENT (buggy) behavior; see report for the flag.
    @Test func reusedAudioObjectIDStopsStaleEngineForTheOldDevice() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(5, "new-device-uid")],   // id 5 now belongs to a new device
            runningDeviceIDs: [5],
            runningDeviceUIDs: [5: "old-device-uid"],  // engine was started for the old one
            enabledUIDs: ["old-device-uid"],           // user's checkbox state didn't change
            globallyEnabled: true,
            maxSimultaneous: 4)

        // UID mismatch at the reused id means the old device is gone, so its stale
        // engine is stopped. The new device isn't enabled, so nothing starts.
        #expect(plan.toStop == [5])
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

    /// One engine .running + a DIFFERENT engine .failed at the same time: both facets
    /// must compose — anyRunning is true (from the running engine) AND errorMessage is
    /// set (from the failed one). Neither the `.contains { .running }` check nor the
    /// `.compactMap { .failed }.first` check is short-circuited by the other engine's
    /// state, since they scan the same `engineStates.values` independently.
    @Test func aggregateStatusRunningAndFailedComposeSimultaneously() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .running, 2: .failed("tap creation failed")],
            permissionSuspectedDevices: [])
        #expect(status.anyRunning)
        #expect(status.errorMessage == "tap creation failed")
        #expect(!status.permissionNeeded)
    }

    /// One engine .failed, and a DIFFERENT device separately flagged as
    /// permission-suspected: both facets surface together (errorMessage from the
    /// failed engine's state, permissionNeeded from the independent suspected-set),
    /// neither masking the other.
    @Test func aggregateStatusFailedMessageAndSeparatePermissionSuspicionCompose() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [1: .failed("aggregate device error"), 2: .stopped],
            permissionSuspectedDevices: [2])
        #expect(!status.anyRunning)
        #expect(status.errorMessage == "aggregate device error")
        #expect(status.permissionNeeded)
    }

    /// Multiple simultaneously-.failed engines: aggregateStatus picks
    /// `engineStates.values.compactMap{...}.first`, i.e. whichever failed message the
    /// Dictionary happens to yield first during iteration. Swift's Dictionary iteration
    /// order is NOT contractually stable/deterministic across engine-state sets (it
    /// depends on hashing, not insertion order), so which of several simultaneous
    /// failure messages surfaces in the UI is effectively arbitrary/unspecified by this
    /// implementation. This test intentionally does NOT pin down which one wins (that
    /// would be flaky) — it only asserts the composed result is one of the actual
    /// failure messages, never nil and never a fabricated third value. See report: this
    /// "arbitrary pick among multiple failures" is flagged as a real (minor) gap —
    /// nothing here loosens tolerances or skips coverage to work around it.
    @Test func aggregateStatusWithMultipleFailedEnginesSurfacesTheLowestDeviceID() {
        let status = OutputDeviceEQCoordinator.aggregateStatus(
            engineStates: [2: .failed("second device failed"), 1: .failed("first device failed")],
            permissionSuspectedDevices: [])
        #expect(!status.anyRunning)
        #expect(status.errorMessage == "first device failed")
    }
}
