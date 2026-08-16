// Integration tests for EQDeviceEngine+SleepWake.swift's installWakeObserver()/
// removeWakeObserver() — the NSWorkspace.didWakeNotification handler that schedules a
// preventive rebuild ~1 s after wake (CONTRACT.md: "Sleep/wake: engine observes
// NSWorkspace.didWakeNotification while running and schedules a rebuild ~1 s after wake").
// Driven end-to-end through FakeCoreAudioTapService (see EQDeviceEngineLifecycleTests.swift's
// header for the phase-A/phase-B start() timing background this also relies on).
//
// Each test injects its own private NotificationCenter() via EQDeviceEngine's
// wakeNotificationCenter: parameter, instead of the real process-global
// NSWorkspace.shared.notificationCenter production uses — posting to a private instance
// can't fan out to another concurrently-running suite's `.running` engine, which a shared
// center would (every engine that reaches `.running` registers an observer on it).
//
// Both tests use REAL wall-clock waits (Task.sleep past the ~1 s deferral) rather than a
// mocked clock, matching the actual DispatchQueue.main.asyncAfter timing in production —
// same convention as EQDeviceEngineLifecycleTests.swift's phase-B awaits.
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

@MainActor
@Suite(.serialized) struct EQDeviceEngineSleepWakeTests {

    private let testBand = EQBand(frequency: 1000, gain: 3, bandwidth: 1.0, filterType: .parametric)

    // MARK: - Wake -> ~1 s later -> preventive rebuild

    @Test func wakeNotificationTriggersPreventiveRebuildAfterDeferral() async throws {
        let fake = FakeCoreAudioTapService()
        let notificationCenter = NotificationCenter()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, wakeNotificationCenter: notificationCenter)
        let delegate = RecordingEngineDelegate()
        engine.delegate = delegate

        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        #expect(delegate.states == [.running])
        let callsBeforeWake = fake.callLog.count

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        // Wait past the ~1 s wake deferral AND rebuild()'s own follow-up deferrals: its
        // performStart()'s ~0.3 s phase-B gap, plus rebuild()'s own separate ~0.35 s
        // unconditional-re-notify deferral scheduled right after performStart() returns
        // (EQDeviceEngine+Watchdog.swift's rebuild()). Generous margin over both.
        try await Task.sleep(for: .milliseconds(1800))

        let addedCalls = Array(fake.callLog[callsBeforeWake...])
        #expect(addedCalls == [
            .stopDevice, .destroyIOProcID, .destroyAggregateDevice, .destroyProcessTap,
            .createProcessTap, .createAggregateDevice, .getStreamFormat, .getDeviceNominalSampleRate,
            .createIOProcIDWithBlock, .startDevice,
        ], "wake must have driven a full stop+start rebuild (CONTRACT.md teardown order), not merely re-touched the existing stack")
        #expect(engine.state == .running)
        // CONTRACT.md: after a successful silent/preventive rebuild the engine fires
        // didChangeState(.running) UNCONDITIONALLY — a SECOND .running entry, even though
        // state never actually left .running from the engine's own perspective (the
        // transition(to:) call inside finishStart() is suppressed by state's didSet
        // equality guard; this second entry comes from rebuild()'s own explicit,
        // unconditional delegate call).
        #expect(delegate.states == [.running, .running])

        engine.stop()
    }

    // MARK: - A stop() landing WITHIN the ~1 s wake deferral window must make the already-
    // scheduled, now-stale wake rebuild a complete no-op when it fires — not run rebuild()
    // against a torn-down engine. installWakeObserver()'s captured `generation` +
    // `startGeneration` comparison exists to prevent exactly this race (same mechanism as
    // performStart()'s phase-B guard and rebuild()'s own generation bump — see
    // EQDeviceEngine+SleepWake.swift).

    @Test func staleWakeRebuildIsSuppressedIfEngineRestartsDuringDeferralWindow() async throws {
        let fake = FakeCoreAudioTapService()
        let notificationCenter = NotificationCenter()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device",
                                    tapService: fake, wakeNotificationCenter: notificationCenter)
        let delegate = RecordingEngineDelegate()
        engine.delegate = delegate

        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        // Stop AND restart well within the ~1 s deferral window — this is the actual race
        // the generation guard exists for: state reads `.running` again by fire time (from
        // the NEW run), so a bare `if case .running = state` check (the pre-fix code) would
        // NOT have caught this — only the generation mismatch does. A test that only stops
        // (and never restarts) can't discriminate pre-fix from post-fix behavior, since
        // `.stopped` alone already suppresses the pre-fix check too.
        try await Task.sleep(for: .milliseconds(300))
        engine.stop()
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)
        let callsAfterRestart = fake.callLog.count
        let statesAfterRestart = delegate.states

        // Wait well past the original ~1 s deferral (relative to the wake post above) plus
        // rebuild()'s own follow-up deferral, so a regression of the generation guard
        // (i.e. it silently missing and firing rebuild() anyway against the NEW run) would
        // have had every chance to show up by now.
        try await Task.sleep(for: .milliseconds(1800))

        #expect(fake.callLog.count == callsAfterRestart,
                "a stale wake rebuild must not issue ANY further CoreAudio calls against the new run once superseded by stop()+start() — rebuild() would tear down and rebuild a run it was never scheduled against otherwise")
        #expect(delegate.states == statesAfterRestart,
                "no further delegate notifications from a suppressed stale rebuild")
        #expect(engine.state == .running)
    }
}
