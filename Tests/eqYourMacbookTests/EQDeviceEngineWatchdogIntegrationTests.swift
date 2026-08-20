// Integration tests for EQDeviceEngine+Watchdog.swift's watchdogTick() and rebuild(), going
// beyond the pure escalation-policy tests in EQDeviceEngineWatchdogTests.swift (which only
// exercise watchdogDecision(), a pure function, and explicitly do not attempt an end-to-end
// timer-driven test — see that file's header). These drive the REAL watchdogTick() directly
// (now `internal` rather than `private` — a deliberate, documented test seam, same
// "Not private: called from ..." convention already used for rebuild() in the same file)
// instead of waiting on the real 5 s DispatchSourceTimer, so the escalation policy's actual
// effect on a real engine/CoreAudio-double stack (rebuild() firing stop+start, the
// reentrancy guard, the unconditional post-rebuild .running re-notification) is covered
// deterministically and fast.
//
// Silence is simulated by advancing context.callbackCounter directly (so watchdogTick()
// observes `advancing == true`) while leaving maxAbsInput at its post-start value of 0
// (reset by performStart() and never otherwise touched here), and by pointing the
// delegate's anyOtherProcessOutputtingAudio(excluding:) answer at `true` — the two
// conditions CLAUDE.md § Invariants requires together for a tick to count as suspicious silence
// ("A check counts as silent only when callbacks are advancing AND max == 0 AND some OTHER
// process is actually outputting audio").
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

@MainActor
@Suite(.serialized) struct EQDeviceEngineWatchdogIntegrationTests {

    private let testBand = EQBand(frequency: 1000, gain: 3, bandwidth: 1.0, filterType: .parametric)

    // MARK: - watchdogTick() x2 (consecutive, silent) -> a REAL rebuild() -> CLAUDE.md § Invariants'
    // unconditional post-rebuild .running re-notification.

    @Test func twoConsecutiveSilentTicksDriveARealRebuildAndUnconditionalRunningNotification() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)
        let delegate = RecordingEngineDelegate()
        delegate.othersOutputtingAnswer = true
        engine.delegate = delegate

        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        #expect(delegate.states == [.running])

        let context = try #require(engine.rtContext)

        // Tick 1: advancing (counter moved), maxAbs == 0 (untouched since start()),
        // othersOutputting == true -> counts as the FIRST silent tick; must not escalate yet.
        context.callbackCounter = 1
        engine.watchdogTick()
        #expect(engine.consecutiveSilentChecks == 1)
        #expect(!engine.didRebuildForSilence)
        #expect(engine.state == .running, "must not rebuild on a single silent tick")
        #expect(delegate.states == [.running], "no delegate noise on a non-escalating tick")

        // Tick 2: second CONSECUTIVE silent tick -> CLAUDE.md § Invariants' 2-tick escalation ->
        // rebuild() (stop + start), "no delegate noise" for the silent rebuild itself.
        let callsBeforeRebuild = fake.callLog.count
        context.callbackCounter = 2
        engine.watchdogTick()

        #expect(engine.consecutiveSilentChecks == 0, "escalating resets the streak counter")
        // rebuild()'s teardown and the synchronous phase-A half of its own performStart()
        // run inline within watchdogTick(), so by the time watchdogTick() returns, exactly
        // this much of the CoreAudio call sequence must already have happened — phase B
        // (createIOProcIDWithBlock, startDevice) is still deferred ~0.3 s at this point.
        #expect(Array(fake.callLog[callsBeforeRebuild...]) == [
            .hoggingProcessObjectIDs,
            .stopDevice, .destroyIOProcID, .destroyAggregateDevice, .destroyProcessTap,
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .getDeviceNominalSampleRate,
        ], "watchdogTick() must have driven a real rebuild() through to phase A synchronously")
        #expect(delegate.states == [.running],
                "CLAUDE.md § Invariants: a silent rebuild fires no delegate noise by itself — only the later unconditional re-notify, once phase B has actually completed")

        // Wait past rebuild()'s own phase-B deferral (~0.3 s, performStart()'s) AND its
        // separate ~0.35 s unconditional-re-notify deferral (scheduled independently right
        // after performStart() returns inside rebuild()).
        try await Task.sleep(for: .milliseconds(700))

        #expect(Array(fake.callLog[callsBeforeRebuild...]) == [
            .hoggingProcessObjectIDs,
            .stopDevice, .destroyIOProcID, .destroyAggregateDevice, .destroyProcessTap,
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .getDeviceNominalSampleRate,
            .createIOProcIDWithBlock, .startDevice,
        ])
        #expect(engine.state == .running)
        // CLAUDE.md § Invariants: "After a successful silent rebuild the engine fires
        // didChangeState(.running) UNCONDITIONALLY (bypassing the internal state-equality
        // guard, since state stayed .running throughout the rebuild) so the coordinator
        // knows the chain is healthy again." -> a SECOND .running entry despite state never
        // actually leaving .running from the engine's own perspective.
        #expect(delegate.states == [.running, .running])

        engine.stop()
    }

    // MARK: - rebuild()'s reentrancy guard (rebuildInProgress): a second rebuild() call
    // while one is already in flight (its own phase-B / unconditional-re-notify deferrals
    // not yet resolved) must be a complete no-op — zero additional CoreAudio calls, no
    // double teardown of the freshly (partially) rebuilt stack.

    @Test func rebuildReentrancyGuardBlocksASecondConcurrentRebuild() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        #expect(!engine.rebuildInProgress)

        let callsAfterStart = fake.callLog.count
        engine.rebuild()
        #expect(engine.rebuildInProgress, "the guard must be set for the duration of the in-flight rebuild")
        let callsAfterFirstRebuildCall = fake.callLog.count
        #expect(callsAfterFirstRebuildCall > callsAfterStart,
                "the first rebuild() call must have actually run its synchronous phase")

        // Second call lands WHILE the first rebuild's phase B / re-notify deferrals are
        // still pending (well within their ~0.3 s / ~0.35 s window) — must be swallowed
        // entirely by rebuildInProgress, not run a second concurrent teardown+rebuild.
        engine.rebuild()
        #expect(fake.callLog.count == callsAfterFirstRebuildCall,
                "a rebuild() call while one is already in flight must issue ZERO additional CoreAudio calls")

        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.state == .running)
        #expect(!engine.rebuildInProgress,
                "the guard must clear once the (single) in-flight rebuild's phase B actually completed")

        engine.stop()
    }
}
