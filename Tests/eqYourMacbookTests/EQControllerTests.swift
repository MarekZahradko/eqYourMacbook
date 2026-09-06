import Testing
import CoreAudio
import Foundation
@testable import eqYourMacbook

// MARK: - Fake coordinator

/// Records calls instead of touching live CoreAudio, so EQController's wiring can be
/// tested without a real OutputDeviceEQCoordinator (which would register a HAL device
/// listener and start process taps).
@MainActor
private final class FakeOutputDeviceEQCoordinator: OutputDeviceEQCoordinating {
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)?
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)?

    private(set) var startCalled = false
    private(set) var globallyEnabledCalls: [Bool] = []
    private(set) var updateBandsCalls: [[EQBand]] = []
    private(set) var updateBypassCalls: [Bool] = []
    private(set) var gainStagingCalls: [Bool] = []
    private(set) var setDeviceEnabledCalls: [(enabled: Bool, deviceID: AudioObjectID)] = []

    func start() { startCalled = true }
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID) {
        setDeviceEnabledCalls.append((enabled, deviceID))
    }
    func setGloballyEnabled(_ enabled: Bool) { globallyEnabledCalls.append(enabled) }
    func updateBands(_ bands: [EQBand]) { updateBandsCalls.append(bands) }
    func updateBypass(_ bypassed: Bool) { updateBypassCalls.append(bypassed) }
    func setGainStagingEnabled(_ enabled: Bool) { gainStagingCalls.append(enabled) }
}

// MARK: - EQController wiring

@Suite @MainActor final class EQControllerTests {

    private let suiteName = "com.zdenekkops.eqyourmacbook.test.\(UUID().uuidString)"

    private func makeController() -> (EQController, FakeOutputDeviceEQCoordinator, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        let fake = FakeOutputDeviceEQCoordinator()
        let controller = EQController(coordinator: fake, defaults: defaults)
        return (controller, fake, defaults)
    }

    private func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func initStartsTheCoordinatorAndForwardsInitialState() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        #expect(fake.startCalled)
        // isEnabled defaults true on first launch (no stored value yet).
        #expect(fake.globallyEnabledCalls == [true])
        #expect(fake.updateBandsCalls.last == controller.bands)
    }

    @Test func togglingIsEnabledForwardsToCoordinatorAndPersists() {
        let (controller, fake, defaults) = makeController()
        defer { cleanUp() }

        controller.isEnabled = false
        #expect(fake.globallyEnabledCalls.last == false)
        #expect(defaults.object(forKey: "eqym.isEnabled") as? Bool == false)
    }

    @Test func togglingGainStagingForwardsAndPersists() {
        let (controller, fake, defaults) = makeController()
        defer { cleanUp() }

        controller.gainStagingEnabled = false
        #expect(fake.gainStagingCalls.last == false)
        #expect(defaults.object(forKey: "eqym.gainStagingEnabled") as? Bool == false)
    }

    @Test func togglingBypassForwardsToCoordinator() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        controller.isABBypassed = true
        #expect(fake.updateBypassCalls.last == true)
    }

    @Test func settingBandsForwardsToCoordinator() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        let newBands = [EQBand(frequency: 250, gain: 3, filterType: .lowShelf)]
        controller.bands = newBands
        #expect(fake.updateBandsCalls.last == newBands)
    }

    @Test func setDeviceEnabledForwardsToCoordinator() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        controller.setDeviceEnabled(true, deviceID: 42)
        #expect(fake.setDeviceEnabledCalls.last?.enabled == true)
        #expect(fake.setDeviceEnabledCalls.last?.deviceID == 42)
    }

    @Test func deviceRowsCallbackUpdatesPublishedRowsAndStatus() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        let rows = [DeviceRowViewModel(id: 1, name: "Built-in", isBuiltIn: true, isChecked: true, isRunning: true, isInteractable: true)]
        fake.onDeviceRowsChanged?(rows)
        #expect(controller.deviceRows == rows)
    }

    @Test func aggregateStatusCallbackUpdatesStatus() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }

        controller.isEnabled = true
        fake.onAggregateStatusChanged?(AggregateEngineStatus(anyRunning: false, permissionNeeded: false, errorMessage: "tap failed"))
        #expect(controller.status == .error("tap failed"))
    }

    @Test func bandsLoadFromPersistedDataOnInit() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let saved = [EQBand(frequency: 500, gain: -2, filterType: .parametric)]
        defaults.set(try! JSONEncoder().encode(saved), forKey: "eqym.bands")
        let fake = FakeOutputDeviceEQCoordinator()
        let controller = EQController(coordinator: fake, defaults: defaults)
        defer { cleanUp() }

        #expect(controller.bands == saved)
    }

    // MARK: - Control channel (EQControlProtocol.swift): commands map onto the same
    // properties the menu drives, and the snapshot survives its plist wire form.

    @Test func controlCommandsDriveTheSamePropertiesAsTheMenu() {
        let (controller, fake, _) = makeController()
        defer { cleanUp() }
        let enabledCallsBefore = fake.globallyEnabledCalls.count

        controller.applyControlCommand(.disable)
        #expect(controller.isEnabled == false)
        #expect(fake.globallyEnabledCalls.last == false)
        controller.applyControlCommand(.disable)          // idempotent: no second forward
        #expect(fake.globallyEnabledCalls.count == enabledCallsBefore + 1)
        controller.applyControlCommand(.enable)
        #expect(controller.isEnabled == true)

        controller.applyControlCommand(.bypassOn)
        #expect(controller.isABBypassed == true)
        #expect(fake.updateBypassCalls.last == true)
        controller.applyControlCommand(.bypassOff)
        #expect(controller.isABBypassed == false)

        controller.applyControlCommand(.status)          // read-only
        #expect(controller.isEnabled == true && controller.isABBypassed == false)
    }

    @Test func controlSnapshotReflectsStateAndRoundTripsThroughUserInfo() {
        let (controller, _, _) = makeController()
        defer { cleanUp() }

        controller.applyControlCommand(.bypassOn)
        let snapshot = controller.controlSnapshot()
        #expect(snapshot.enabled == true)
        #expect(snapshot.bypassed == true)
        #expect(snapshot.status == "active")
        #expect(snapshot.engineRunning == false, "the fake coordinator never runs an engine")
        #expect(snapshot.deviceUID == nil && snapshot.ioBufferFrames == nil)

        let info = snapshot.userInfo(event: .reply, requestID: "req-1")
        #expect(EQControlProtocol.event(of: info) == .reply)
        #expect(EQControlProtocol.requestID(of: info) == "req-1")
        #expect(EQControlSnapshot(userInfo: info) == snapshot)

        // A running engine's fields survive too, including the [Int] list.
        let running = EQControlSnapshot(
            enabled: true, bypassed: false, gainStaging: true, status: "active", statusDetail: "EQ active on 1 device",
            engineRunning: true, deviceUID: "uid", deviceName: "MacBook Air Speakers",
            sampleRate: 48_000, ioBufferFrames: 512, excludedProcessObjects: [77, 4242], ownProcessObject: 77)
        #expect(EQControlSnapshot(userInfo: running.userInfo(event: .changed, requestID: nil)) == running)
        #expect(EQControlSnapshot(userInfo: ["garbage": 1]) == nil)
    }

    @Test func controlStatusTokensAreStable() {
        // The tools match on these literals; changing one is a protocol change.
        #expect(EQController.controlStatusToken(.active) == "active")
        #expect(EQController.controlStatusToken(.disabled) == "disabled")
        #expect(EQController.controlStatusToken(.permissionNeeded) == "permissionNeeded")
        #expect(EQController.controlStatusToken(.error("x")) == "error")
    }
}

// MARK: - statusDetail (pure)

@Suite struct EQControllerStatusDetailTests {
    @Test func activeWithZeroRunningDevicesReadsAsNoneSelected() {
        #expect(EQController.statusDetail(for: .active, runningDeviceCount: 0) == "EQ enabled — no output devices selected")
    }

    @Test func activeWithOneRunningDeviceUsesSingularWording() {
        #expect(EQController.statusDetail(for: .active, runningDeviceCount: 1) == "EQ active on 1 device")
    }

    @Test func activeWithMultipleRunningDevicesUsesPluralWording() {
        #expect(EQController.statusDetail(for: .active, runningDeviceCount: 3) == "EQ active on 3 devices")
    }

    @Test func disabledIgnoresRunningDeviceCount() {
        #expect(EQController.statusDetail(for: .disabled, runningDeviceCount: 2) == "EQ is off")
    }

    @Test func permissionNeededMessage() {
        #expect(EQController.statusDetail(for: .permissionNeeded, runningDeviceCount: 0) == "System Audio Recording permission needed")
    }

    @Test func errorMessageIncludesTheUnderlyingMessage() {
        #expect(EQController.statusDetail(for: .error("tap creation failed"), runningDeviceCount: 0) == "Error: tap creation failed")
    }

}
