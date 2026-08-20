// Tap process-exclusion tests: the fix for "another app takes exclusive (hog-mode)
// access to some output device, and our global tap hijacks its audio onto ours".
//
// Real-world repro this encodes (foobar2000, 2026-08-19): fb2k takes hog mode on a USB
// S/PDIF DAC; macOS therefore moves the DEFAULT OUTPUT route to the built-in speakers;
// the coordinator legitimately starts an engine for the built-in speakers (it is both
// user-enabled and the live route); the global `stereoGlobalTapButExcludeProcesses` tap
// then captures fb2k anyway — `.mutedWhenTapped` silences it on the DAC it locked and
// our aggregate re-renders it through the speakers. Excluding every hog holder from the
// tap is what keeps the hogging app's audio on the device it hogged.
//
// Driven entirely through FakeCoreAudioTapService — no real CoreAudio hog mode needed.
// Engines are built with `hogModeMonitor: nil` so no live HAL listeners are registered;
// the monitor is a pure notification source and the rebuild decision it triggers
// (rebuildIfTapExclusionsStale) is exercised directly, as is the watchdog backstop.
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

@MainActor
@Suite(.serialized) struct EQDeviceEngineHogModeTests {

    private let testBand = EQBand(frequency: 1000, gain: 3, bandwidth: 1.0, filterType: .parametric)

    private func makeRunningEngine(
        _ fake: FakeCoreAudioTapService
    ) async throws -> EQDeviceEngine {
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, hogModeMonitor: nil)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        return engine
    }

    // MARK: - Pure exclusion-list logic

    @Test func exclusionListAlwaysContainsOurOwnProcess() {
        #expect(EQDeviceEngine.tapExcludedProcessObjects(own: 7, hoggers: []) == [7])
    }

    @Test func exclusionListMergesHoldersDeduplicatedAndOrderIndependent() {
        // Two HAL enumerations reporting the same holders in a different order (and one
        // process hogging two devices at once) must compare EQUAL — the staleness checks
        // compare these lists directly, so any instability would rebuild forever.
        let a = EQDeviceEngine.tapExcludedProcessObjects(own: 7, hoggers: [42, 13, 42])
        let b = EQDeviceEngine.tapExcludedProcessObjects(own: 7, hoggers: [13, 42])
        #expect(a == [7, 13, 42])
        #expect(a == b)
    }

    @Test func exclusionListDropsUnknownProcessObjects() {
        // A PID that could not be translated must not be passed to CATapDescription as
        // kAudioObjectUnknown — that is not a process, and it would also make the list
        // unstable against a later successful translation.
        let unknown = AudioObjectID(kAudioObjectUnknown)
        #expect(EQDeviceEngine.tapExcludedProcessObjects(own: 7, hoggers: [unknown, 42]) == [7, 42])
        // Degenerate case: our own translation failed too -> exclude nobody rather than
        // excluding "process unknown".
        #expect(EQDeviceEngine.tapExcludedProcessObjects(own: unknown, hoggers: []).isEmpty)
    }

    // MARK: - Exclusions at start()

    @Test func tapExcludesHogHoldersPresentAtStart() async throws {
        let fake = FakeCoreAudioTapService()
        fake.hoggingProcessObjectsToReturn = [4242]        // e.g. foobar2000 in exclusive mode
        let engine = try await makeRunningEngine(fake)

        let excluded = try #require(fake.lastTapExcludedProcesses)
        #expect(excluded.contains(4242), "a process already holding hog mode must be excluded from the tap")
        #expect(excluded.contains(engine.ownProcessObjectID))
        #expect(engine.excludedProcessObjectIDs == excluded)

        engine.stop()
    }

    @Test func tapExcludesOnlyOurselfWhenNoDeviceIsHogged() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)

        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        engine.stop()
    }

    // MARK: - Exclusions changing while running

    @Test func hogTakenWhileRunningRebuildsTapWithTheNewExclusion() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        // Another app switches to exclusive playback mid-run.
        fake.hoggingProcessObjectsToReturn = [4242]
        #expect(engine.rebuildIfTapExclusionsStale())
        try await Task.sleep(for: .milliseconds(700))   // phase B + rebuild's re-notify deferral

        #expect(engine.state == .running, "the rebuild must land back in .running, not .failed")
        let excluded = try #require(fake.lastTapExcludedProcesses)
        #expect(excluded == [engine.ownProcessObjectID, 4242].sorted())

        engine.stop()
    }

    @Test func hogReleasedWhileRunningRebuildsTapBackToTappingThatProcessAgain() async throws {
        let fake = FakeCoreAudioTapService()
        fake.hoggingProcessObjectsToReturn = [4242]
        let engine = try await makeRunningEngine(fake)

        // Exclusive playback ends: that app must be EQ'd again, so the exclusion goes away.
        fake.hoggingProcessObjectsToReturn = []
        #expect(engine.rebuildIfTapExclusionsStale())
        try await Task.sleep(for: .milliseconds(700))

        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        engine.stop()
    }

    @Test func unchangedHogSetDoesNotRebuild() async throws {
        let fake = FakeCoreAudioTapService()
        fake.hoggingProcessObjectsToReturn = [4242]
        let engine = try await makeRunningEngine(fake)
        let callsBefore = fake.callLog.count

        // The monitor fires on ANY hog-mode notification, including ones that don't move
        // the holder set (e.g. a device re-reporting the same owner, or a hot-plug of an
        // unrelated device). Rebuilding on those would glitch audio for nothing.
        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(fake.callLog[callsBefore...] == [.hoggingProcessObjectIDs],
                "only the staleness read itself; no teardown/recreate")

        engine.stop()
    }

    @Test func exclusionsAreNotReevaluatedWhileStopped() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        engine.stop()
        let callsBefore = fake.callLog.count

        // A late monitor callback (or a watchdog tick) racing stop() must not resurrect
        // a torn-down engine.
        fake.hoggingProcessObjectsToReturn = [4242]
        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(fake.callLog.count == callsBefore, "no CoreAudio calls at all while stopped")
        #expect(engine.state == .stopped)
    }

    // MARK: - Watchdog backstop

    @Test func watchdogTickRebuildsWhenAMonitorCallbackWasMissed() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        let callsBefore = fake.callLog.count

        // Simulates the case the HogModeMonitor cannot cover: its callback arrived while
        // rebuild() was already in progress (swallowed by the reentrancy guard), or no
        // monitor is installed at all. The 5 s watchdog tick must still notice.
        fake.hoggingProcessObjectsToReturn = [4242]
        engine.watchdogTick()

        #expect(fake.callLog[callsBefore...].contains(.destroyProcessTap),
                "the tick must have driven a real rebuild, not just re-read the hog set")
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID, 4242].sorted())

        engine.stop()
    }

    @Test func watchdogSilenceEscalationIsSkippedOnATickThatRebuiltForHogChange() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        let delegate = RecordingEngineDelegate()
        delegate.othersOutputtingAnswer = true          // would otherwise count as "silent"
        engine.delegate = delegate
        engine.consecutiveSilentChecks = 1              // one more silent tick would escalate

        fake.hoggingProcessObjectsToReturn = [4242]
        engine.watchdogTick()

        // The tick bailed out after starting the rebuild: its silence bookkeeping must not
        // have run against RT state that no longer exists. The streak reads 0 rather than
        // the 1 it was seeded with because performStart() resets the watchdog counters for
        // the freshly built stack — the rebuilt chain is judged from scratch, which is the
        // intended behavior; what matters is that this tick neither incremented the streak
        // nor escalated.
        #expect(engine.consecutiveSilentChecks == 0)
        #expect(engine.didRebuildForSilence == false)
        #expect(delegate.permissionSuspectedCount == 0)

        try await Task.sleep(for: .milliseconds(700))
        engine.stop()
    }
}
