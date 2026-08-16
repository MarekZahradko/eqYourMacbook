import CoreAudio
import Testing
@testable import eqYourMacbook

/// Tests for OutputDeviceEQCoordinator's pure decision logic — planReconciliation
/// (stop/start policy, default-output-route gating, soft cap) and aggregateStatus
/// (per-engine-state collapse) — with zero CoreAudio involvement.
///
/// Route-gating rationale: the process tap mutes a process's audio system-wide, not
/// per-device (CoreAudio has no device-scoped tap/mute mode), so an engine may only
/// run for the device that is CURRENTLY the OS's default output route — running it
/// for any other device would silence audio everywhere while nothing plays through
/// the actually-active device. `setDeviceEnabled` additionally enforces that only one
/// device is ever enabled at a time, but `planReconciliation` itself is pure and takes
/// `enabledUIDs` as given, so several of these tests exercise multi-candidate inputs
/// to pin down the gating logic in isolation.
@Suite struct OutputDeviceEQCoordinatorTests {

    // MARK: - planReconciliation: default-route gating

    @Test func enabledDeviceNotStartedWhenItIsNotTheDefaultRoute() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a")],
            runningDeviceIDs: [],
            runningDeviceUIDs: [:],
            enabledUIDs: ["a"],
            globallyEnabled: true,
            defaultOutputDeviceUID: "some-other-device",   // "a" is enabled but not routed to
            maxSimultaneous: 4)

        #expect(plan.toStart.isEmpty)
        #expect(plan.toStop.isEmpty)
    }

    @Test func enabledDeviceStartsOnlyWhenItIsTheDefaultRoute() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (2, "b")],
            runningDeviceIDs: [],
            runningDeviceUIDs: [:],
            enabledUIDs: ["a", "b"],   // both enabled (hypothetically), only "a" is routed to
            globallyEnabled: true,
            defaultOutputDeviceUID: "a",
            maxSimultaneous: 4)

        #expect(plan.toStart == [1])
    }

    /// A running, still-enabled device is stopped the moment the OS's default output
    /// route moves to a different device — the app must never keep muting audio
    /// system-wide on behalf of a device that isn't actually receiving it anymore.
    @Test func runningDeviceIsStoppedWhenDefaultRouteMovesAwayEvenThoughStillEnabled() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (2, "b")],
            runningDeviceIDs: [1],
            runningDeviceUIDs: [1: "a"],
            enabledUIDs: ["a"],              // user never touched the checkbox
            globallyEnabled: true,
            defaultOutputDeviceUID: "b",     // but macOS is now routing to "b" instead
            maxSimultaneous: 4)

        #expect(plan.toStop == [1])
        #expect(plan.toStart.isEmpty)
    }

    @Test func runningDeviceKeepsRunningWhileItRemainsTheDefaultRoute() {
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a")],
            runningDeviceIDs: [1],
            runningDeviceUIDs: [1: "a"],
            enabledUIDs: ["a"],
            globallyEnabled: true,
            defaultOutputDeviceUID: "a",
            maxSimultaneous: 4)

        #expect(plan.toStop.isEmpty)
    }

    // MARK: - planReconciliation: presence/enablement/master-switch

    @Test func runningDeviceNoLongerInCatalogIsStopped() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [],   // device 1 has disappeared
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a"],
            globallyEnabled: true,
            defaultOutputDeviceUID: "a",
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
            defaultOutputDeviceUID: "a",
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
            defaultOutputDeviceUID: "a",
            maxSimultaneous: 4)

        #expect(Set(plan.toStop) == [1, 2])
        #expect(plan.toStart.isEmpty)
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
            defaultOutputDeviceUID: "a",
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
            defaultOutputDeviceUID: "a",
            maxSimultaneous: 4)

        #expect(plan.toStop.isEmpty)
        #expect(plan.toStart.isEmpty)
    }

    /// The device that was running (uid "a") stops because the default route moved to
    /// "e" in the same pass that "e" becomes eligible to start — demonstrating the stop
    /// and the corresponding start are decided together in one reconciliation pass,
    /// not staggered across two calls.
    @Test func routeChangeStopsTheOldDeviceAndStartsTheNewOneInTheSamePass() {
        let running: Set<AudioObjectID> = [1]
        let runningUIDs: [AudioObjectID: String] = [1: "a"]
        let catalog: [(id: AudioObjectID, uid: String)] = [(1, "a"), (5, "e")]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: catalog,
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["e"],              // user had switched their selection to "e"
            globallyEnabled: true,
            defaultOutputDeviceUID: "e",     // and macOS is now routing to "e"
            maxSimultaneous: 4)

        #expect(plan.toStop == [1])
        #expect(plan.toStart == [5])
    }

    // MARK: - "Device disappears mid-operation" (mixed present/absent, reused IDs)

    /// Catalog is non-empty but exactly ONE of several previously-running devices is
    /// missing from it. The one still matching the default route stays up; the other
    /// present-but-not-routed-to device is ALSO stopped (route gating), on top of the
    /// missing one.
    @Test func missingDeviceAndNonRouteDeviceAreBothStoppedOnlyRouteDeviceStays() {
        let running: Set<AudioObjectID> = [1, 2, 3]
        let runningUIDs: [AudioObjectID: String] = [1: "a", 2: "b", 3: "c"]
        let plan = OutputDeviceEQCoordinator.planReconciliation(
            catalogDevices: [(1, "a"), (3, "c")],   // device 2 ("b") has disappeared
            runningDeviceIDs: running,
            runningDeviceUIDs: runningUIDs,
            enabledUIDs: ["a", "b", "c"],
            globallyEnabled: true,
            defaultOutputDeviceUID: "a",            // only "a" is the active route
            maxSimultaneous: 4)

        #expect(Set(plan.toStop) == [2, 3])
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
            defaultOutputDeviceUID: "old-device-uid",
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
