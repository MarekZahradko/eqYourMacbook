// Tap process-exclusion tests. The tap is global, so anything it captures it also MUTES
// at the source and re-renders from our process — two real-world situations where that
// is wrong, and both are encoded here:
//
// 1. HOG MODE (foobar2000, 2026-08-19): fb2k takes hog mode on a USB S/PDIF DAC; macOS
//    therefore moves the DEFAULT OUTPUT route to the built-in speakers; the coordinator
//    legitimately starts an engine for the built-in speakers (it is both user-enabled and
//    the live route); the global `stereoGlobalTapButExcludeProcesses` tap then captures
//    fb2k anyway — `.mutedWhenTapped` silences it on the DAC it locked and our aggregate
//    re-renders it through the speakers. Excluding every hog holder from the tap is what
//    keeps the hogging app's audio on the device it hogged.
//
// 2. VOICE SESSIONS (WhatsApp, 2026-08-26): WhatsApp for Mac is a Catalyst app running
//    WebRTC's RTCAudioSession in playAndRecord/voiceChat, i.e. macOS VoiceProcessingIO,
//    which ducks all "other audio" while the call is up. Tapping it moved the call audio
//    into OUR process, where the OS dutifully ducked it as "other audio" — the call
//    ducked itself and was near-inaudible until the EQ was toggled off. (Teams was
//    unaffected: native macOS app, own AEC over the plain HAL, no VoiceProcessingIO.)
//    Excluding a process that is running input AND output keeps its call audio inside its
//    own voice session. Accepted consequence: calls are not equalized.
//
// Driven entirely through FakeCoreAudioTapService — no real hog mode and no real call
// needed. Engines are built with `tapExclusionMonitor: nil` so no live HAL listeners are
// registered; the monitor is a pure notification source and the rebuild decision it
// triggers (rebuildIfTapExclusionsStale) is exercised directly, as is rebuild()'s
// completion re-check that backstops a callback swallowed mid-rebuild.
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

@MainActor
@Suite(.serialized) struct EQDeviceEngineTapExclusionTests {

    private let testBand = EQBand(frequency: 1000, gain: 3, bandwidth: 1.0, filterType: .parametric)

    private func makeRunningEngine(
        _ fake: FakeCoreAudioTapService
    ) async throws -> EQDeviceEngine {
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, tapExclusionMonitor: nil)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        return engine
    }

    // MARK: - Pure exclusion-list logic

    @Test func exclusionListAlwaysContainsOurOwnProcess() {
        #expect(EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [], voiceSessions: []) == [7])
    }

    @Test func exclusionListMergesHoldersDeduplicatedAndOrderIndependent() {
        // Two HAL enumerations reporting the same holders in a different order (and one
        // process hogging two devices at once) must compare EQUAL — the staleness checks
        // compare these lists directly, so any instability would rebuild forever.
        let a = EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [42, 13, 42], voiceSessions: [])
        let b = EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [13, 42], voiceSessions: [])
        #expect(a == [7, 13, 42])
        #expect(a == b)
    }

    @Test func exclusionListMergesBothSourcesAndTheirOverlap() {
        // The two sources are independent and may overlap (a call app that also took hog
        // mode). The union must still be stable and deduplicated.
        let merged = EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [42], voiceSessions: [99, 42])
        #expect(merged == [7, 42, 99])
    }

    @Test func exclusionListToleratesOurOwnProcessAppearingAsAVoiceSession() {
        // Our aggregate's tap side is an input stream, so the HAL can legitimately report
        // US as duplex. Since `own` is unioned in unconditionally, that must change
        // nothing — otherwise the set would flap and rebuild forever.
        let withUs = EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [], voiceSessions: [7, 99])
        let withoutUs = EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [], voiceSessions: [99])
        #expect(withUs == [7, 99])
        #expect(withUs == withoutUs)
    }

    @Test func exclusionListDropsUnknownProcessObjects() {
        // A PID that could not be translated must not be passed to CATapDescription as
        // kAudioObjectUnknown — that is not a process, and it would also make the list
        // unstable against a later successful translation.
        let unknown = AudioObjectID(kAudioObjectUnknown)
        #expect(EQDeviceEngine.tapExcludedProcessObjects(
            own: 7, hoggers: [unknown, 42], voiceSessions: [unknown]) == [7, 42])
        // Degenerate case: our own translation failed too -> exclude nobody rather than
        // excluding "process unknown".
        #expect(EQDeviceEngine.tapExcludedProcessObjects(
            own: unknown, hoggers: [], voiceSessions: []).isEmpty)
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

    @Test func tapExcludesVoiceSessionsPresentAtStart() async throws {
        let fake = FakeCoreAudioTapService()
        fake.voiceSessionProcessObjectsToReturn = [777]    // e.g. a WhatsApp call already up
        let engine = try await makeRunningEngine(fake)

        let excluded = try #require(fake.lastTapExcludedProcesses)
        #expect(excluded.contains(777),
                "a process already in a call must be excluded from the tap, or it ducks itself")
        #expect(excluded.contains(engine.ownProcessObjectID))
        #expect(engine.excludedProcessObjectIDs == excluded)

        engine.stop()
    }

    @Test func tapExcludesOnlyOurselfWhenNothingIsHoggedAndNobodyIsOnACall() async throws {
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

    @Test func callStartedWhileRunningRebuildsTapWithTheNewExclusion() async throws {
        // THE WhatsApp regression: EQ already running, then a call comes in.
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        fake.voiceSessionProcessObjectsToReturn = [777]
        #expect(engine.rebuildIfTapExclusionsStale())
        try await Task.sleep(for: .milliseconds(700))

        #expect(engine.state == .running)
        let excluded = try #require(fake.lastTapExcludedProcesses)
        #expect(excluded == [engine.ownProcessObjectID, 777].sorted())

        engine.stop()
    }

    @Test func callEndedWhileRunningRebuildsTapBackToTappingThatProcessAgain() async throws {
        let fake = FakeCoreAudioTapService()
        fake.voiceSessionProcessObjectsToReturn = [777]
        let engine = try await makeRunningEngine(fake)

        // Call ends: that app is an ordinary audio source again and must be EQ'd.
        fake.voiceSessionProcessObjectsToReturn = []
        #expect(engine.rebuildIfTapExclusionsStale())
        try await Task.sleep(for: .milliseconds(700))

        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        engine.stop()
    }

    @Test func aStillRunningCallDoesNotRebuildOnEverySubsequentCheck() async throws {
        // Stability guard for the new source: the excluded call app keeps reporting itself
        // as duplex for the whole call (excluding it from the tap does not stop its IO),
        // so every later check must be a no-op. Anything else would rebuild — and glitch
        // the call — on every monitor notification for as long as the call lasts.
        let fake = FakeCoreAudioTapService()
        fake.voiceSessionProcessObjectsToReturn = [777]
        let engine = try await makeRunningEngine(fake)
        let callsBefore = fake.callLog.count

        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(!fake.callLog[callsBefore...].contains(.destroyProcessTap))

        engine.stop()
    }

    @Test func unchangedExclusionSetDoesNotRebuild() async throws {
        let fake = FakeCoreAudioTapService()
        fake.hoggingProcessObjectsToReturn = [4242]
        let engine = try await makeRunningEngine(fake)
        let callsBefore = fake.callLog.count

        // The monitor fires on ANY notification it watches, including ones that don't move
        // the exclusion set (a device re-reporting the same owner, a hot-plug of an
        // unrelated device, an app starting playback without input). Rebuilding on those
        // would glitch audio for nothing.
        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(fake.callLog[callsBefore...] == [.hoggingProcessObjectIDs, .voiceSessionProcessObjectIDs],
                "only the two staleness reads themselves; no teardown/recreate")

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
        fake.voiceSessionProcessObjectsToReturn = [777]
        #expect(engine.rebuildIfTapExclusionsStale() == false)
        #expect(fake.callLog.count == callsBefore, "no CoreAudio calls at all while stopped")
        #expect(engine.state == .stopped)
    }

    // MARK: - Rebuild-completion backstop
    //
    // TapExclusionMonitor's callback is swallowed by rebuild()'s reentrancy guard while a
    // rebuild is in flight (~0.65 s: phase B deferral + re-notify deferral). The 5 s
    // watchdog tick used to re-scan every device and process as a backstop for that; it
    // no longer does (that scan cost ~100+ IPC round trips per tick for the engine's whole
    // lifetime). Instead rebuild() re-checks the live exclusion set exactly once when its
    // guard clears, and rebuilds again if the set moved in the meantime.

    @Test func exclusionChangeDuringAnInFlightRebuildIsPickedUpWhenTheRebuildCompletes() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)

        engine.rebuild()                                  // e.g. the wake handler
        #expect(engine.rebuildInProgress)
        // A hog appears while the rebuild is in flight; the monitor's callback fires and
        // is absorbed by the reentrancy guard.
        fake.hoggingProcessObjectsToReturn = [4242]
        engine.rebuildIfTapExclusionsStale()
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID],
                "the in-flight rebuild already created its tap without the hog; a second rebuild must not start yet")

        // In-flight rebuild completes (~0.35 s) → one-shot re-check → second rebuild (~0.65 s).
        try await Task.sleep(for: .milliseconds(1300))
        #expect(engine.state == .running)
        #expect(!engine.rebuildInProgress)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID, 4242].sorted())

        engine.stop()
    }

    @Test func voiceSessionChangeDuringAnInFlightRebuildIsAlsoPickedUp() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)

        engine.rebuild()
        fake.voiceSessionProcessObjectsToReturn = [777]
        engine.rebuildIfTapExclusionsStale()

        try await Task.sleep(for: .milliseconds(1300))
        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID, 777].sorted())

        engine.stop()
    }

    @Test func watchdogTickDoesNotRescanExclusions() async throws {
        // Exclusion staleness has its own paths (monitor listeners, the 2 s polling
        // backstop below, rebuild()'s completion re-check); the watchdog tick stays out of
        // it, so a change is NOT noticed by a tick as such.
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        let callsBefore = fake.callLog.count

        fake.hoggingProcessObjectsToReturn = [4242]
        engine.watchdogTick()

        #expect(fake.callLog.count == callsBefore, "a quiet tick makes no CoreAudio calls at all")
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        engine.stop()
    }

    // MARK: - Polling backstop (CLAUDE.md § Invariants, "Tap exclusions")
    //
    // Measured 2026-09-04: a Teams call was tapped for 291 s because no HAL notification
    // arrived for that process object's IsRunningInput flip; the rebuild that finally
    // excluded it was triggered by an unrelated process's flag change. The listeners stay
    // the fast path; the engine additionally re-reads the set every
    // `exclusionBackstopInterval` (2 s in production, shortened here).

    @Test func backstopNoticesAnExclusionChangeNoListenerReported() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, tapExclusionMonitor: nil,
                                    exclusionBackstopInterval: 0.2)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID])

        // A call starts and nobody tells us (no rebuildIfTapExclusionsStale() call here).
        fake.voiceSessionProcessObjectsToReturn = [777]
        try await Task.sleep(for: .milliseconds(900))    // ≥ 1 backstop period + rebuild (0.3 s phase B + 0.35 s)

        #expect(engine.state == .running)
        #expect(fake.lastTapExcludedProcesses == [engine.ownProcessObjectID, 777].sorted(),
                "the backstop must have rebuilt the tap with the call excluded, without any notification")

        // stop() cancels the backstop: no further CoreAudio calls afterwards.
        engine.stop()
        let callsAfterStop = fake.callLog.count
        fake.hoggingProcessObjectsToReturn = [4242]
        try await Task.sleep(for: .milliseconds(500))
        #expect(fake.callLog.count == callsAfterStop, "no polling while stopped")
    }

    @Test func backstopIsQuietWhileTheSetIsUnchanged() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, tapExclusionMonitor: nil,
                                    exclusionBackstopInterval: 0.2)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        let callsBefore = fake.callLog.count

        try await Task.sleep(for: .milliseconds(700))

        let added = fake.callLog[callsBefore...]
        #expect(!added.contains(.destroyProcessTap), "an unchanged set must never rebuild")
        #expect(added.allSatisfy { $0 == .hoggingProcessObjectIDs || $0 == .voiceSessionProcessObjectIDs },
                "only the two staleness reads per period")
        #expect(added.count >= 4, "at least two periods must have polled")

        engine.stop()
    }

    // MARK: - Watchdog discriminator

    @Test func watchdogSkipsTheOtherOutputQuestionWhileAudioIsFlowing() async throws {
        // The "is anyone else outputting audio" enumeration is the tick's only remaining
        // CoreAudio cost. It is needed only to tell legitimate silence from a broken
        // chain, so a tick that sees non-zero input must not ask it at all.
        let fake = FakeCoreAudioTapService()
        let engine = try await makeRunningEngine(fake)
        let delegate = RecordingEngineDelegate()
        engine.delegate = delegate
        let context = try #require(engine.rtContext)

        context.callbackCounter = 1
        context.rtUpdateMaxAbsInput(0.25)
        engine.watchdogTick()
        #expect(delegate.lastOthersOutputtingExclusions == nil, "audio flowing: not asked")

        // Not advancing (device stalled): also not a silence candidate, not asked.
        engine.watchdogTick()
        #expect(delegate.lastOthersOutputtingExclusions == nil)

        // Advancing with zero input: the only case that needs the answer.
        context.callbackCounter = 2
        engine.watchdogTick()
        #expect(delegate.lastOthersOutputtingExclusions != nil)

        engine.stop()
    }

    @Test func watchdogAsksAboutOtherOutputUsingTheFullExclusionSet() async throws {
        // An excluded process is deliberately NOT tapped, so its audio never reaches our
        // IOProc. If the watchdog still counted it as "someone else is playing", every
        // call would look like a broken chain: maxAbs == 0 while audio is audibly playing
        // → two silent ticks → rebuild → still zero → a false "TCC denied" suspicion, for
        // as long as the call lasts. The tick must therefore ask about the whole exclusion
        // set, not just our own process object.
        let fake = FakeCoreAudioTapService()
        fake.voiceSessionProcessObjectsToReturn = [777]
        fake.hoggingProcessObjectsToReturn = [4242]
        let engine = try await makeRunningEngine(fake)
        let delegate = RecordingEngineDelegate()
        engine.delegate = delegate
        // The question is only asked on a silence-candidate tick (advancing, max-abs 0).
        let context = try #require(engine.rtContext)
        context.callbackCounter = 1

        engine.watchdogTick()

        let asked = try #require(delegate.lastOthersOutputtingExclusions)
        #expect(asked == [engine.ownProcessObjectID, 777, 4242].sorted())
        #expect(asked == engine.excludedProcessObjectIDs)

        engine.stop()
    }

}
