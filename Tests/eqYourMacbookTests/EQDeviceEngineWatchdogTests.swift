// Tests for EQDeviceEngine.watchdogDecision — the pure decision logic extracted from
// EQDeviceEngine+Watchdog.swift's watchdogTick() (mirroring the planReconciliation/
// aggregateStatus pattern in OutputDeviceEQCoordinator.swift) so the escalation policy
// (2 consecutive silent-but-should-be-playing ticks → rebuild; persistent silence after
// a rebuild → permission suspicion) is testable deterministically, without a live
// DispatchSourceTimer.
//
// NOTE on scope: this suite deliberately does NOT attempt an end-to-end timer-driven
// integration test — a real DispatchSourceTimer firing every 5 s would need 10+ real
// seconds of wall-clock wait to observe 2 ticks, for little additional coverage: the
// escalation POLICY is fully covered here by fast pure-function tests, and the remaining
// timer-wiring in startWatchdog()/stopWatchdog() is thin, low-risk plumbing not worth a
// slow/flaky integration test. See EQDeviceEngineWatchdogIntegrationTests.swift for
// coverage of what this policy actually DOES on a real engine/CoreAudio-double stack
// (rebuild()'s reentrancy guard, the real watchdogTick() driving a real rebuild(), and the
// unconditional post-rebuild .running re-notification) — driven directly via watchdogTick()
// rather than the raw timer, so it stays fast and deterministic too.
import Testing
@testable import eqYourMacbook

@Suite struct EQDeviceEngineWatchdogTests {

    // MARK: - Escalation: 2 consecutive silent-while-others-play ticks → rebuild

    @Test func firstSilentTickIncrementsButDoesNotEscalate() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: 0, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.newConsecutiveSilentChecks == 1)
        #expect(d.action == .none)
    }

    @Test func secondConsecutiveSilentTickTriggersRebuild() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: 1, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.action == .rebuild)
        #expect(d.newConsecutiveSilentChecks == 0, "counter resets once an action fires")
    }

    // MARK: - Escalation: silence persisting AFTER a rebuild → permission suspicion

    @Test func silenceAfterPriorRebuildEscalatesToPermissionSuspicion() {
        let d1 = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: 0, didRebuildForSilence: true, permissionSuspected: false)
        #expect(d1.action == .none)
        let d2 = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: d1.newConsecutiveSilentChecks, didRebuildForSilence: true,
            permissionSuspected: false)
        #expect(d2.action == .suspectPermissionDenied)
    }

    // MARK: - No false trip on a benign idle system (CLAUDE.md § Invariants: zeros are legitimate
    // when nothing is playing — must not trip the watchdog).

    @Test func idleSystemWithNoOtherAudioNeverEscalates() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: false,
            consecutiveSilentChecks: 5, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.newConsecutiveSilentChecks == 0)
        #expect(d.action == .none)
    }

    // MARK: - A frozen callback counter (not advancing) never counts as a silent tick.

    @Test func nonAdvancingCounterNeverCountsAsSilent() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: false, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: 3, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.newConsecutiveSilentChecks == 0)
        #expect(d.action == .none)
    }

    // MARK: - Audio returning: clears the rebuild latch, and (only if a suspicion was
    // active) fires the idempotent .running re-notification (CLAUDE.md § Invariants).

    @Test func audioReturningAfterSuspicionClearsBothLatches() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0.5, othersOutputting: true,
            consecutiveSilentChecks: 1, didRebuildForSilence: true, permissionSuspected: true)
        #expect(d.resetDidRebuildForSilence)
        #expect(d.clearPermissionSuspicion)
        #expect(d.newConsecutiveSilentChecks == 0, "maxAbs > 0 is never a silent tick")
        #expect(d.action == .none)
    }

    @Test func audioPresentWithoutPriorSuspicionDoesNotFireClear() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0.5, othersOutputting: true,
            consecutiveSilentChecks: 0, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.resetDidRebuildForSilence, "still resets the (already-false) rebuild latch")
        #expect(!d.clearPermissionSuspicion, "nothing to clear if no suspicion was active")
        #expect(d.action == .none)
    }

    // MARK: - A non-silent tick (something else changed) resets an in-progress silent streak.

    @Test func nonSilentTickResetsAnInProgressSilentStreak() {
        // maxAbs > 0 this tick, after 1 prior silent check — streak must reset to 0, not
        // continue accumulating toward the 2-tick threshold.
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 1.0, othersOutputting: true,
            consecutiveSilentChecks: 1, didRebuildForSilence: false, permissionSuspected: false)
        #expect(d.newConsecutiveSilentChecks == 0)
        #expect(d.action == .none)
    }

    // MARK: - Idle latch (CLAUDE.md § Invariants): silent, nobody we tap is playing, yet the
    // HAL still reports our own process as duplex → coreaudiod is stuck treating us as an
    // active call. Two consecutive such ticks → ONE rebuild per silence period.

    private func idleLatched(consecutive: Int, didRebuild: Bool, othersOutputting: Bool = false,
                             maxAbs: Float = 0, advancing: Bool = true, duplex: Bool = true) -> EQDeviceEngine.WatchdogDecision {
        EQDeviceEngine.watchdogDecision(
            advancing: advancing, maxAbs: maxAbs, othersOutputting: othersOutputting,
            consecutiveSilentChecks: 0, didRebuildForSilence: false, permissionSuspected: false,
            ownReportedDuplex: duplex, consecutiveIdleLatchChecks: consecutive, didRebuildForIdleLatch: didRebuild)
    }

    @Test func idleLatchNeedsTwoConsecutiveTicks() {
        let d1 = idleLatched(consecutive: 0, didRebuild: false)
        #expect(d1.action == .none)
        #expect(d1.newConsecutiveIdleLatchChecks == 1)
        #expect(d1.newConsecutiveSilentChecks == 0, "not a TCC-silent tick: nobody else is playing")
        let d2 = idleLatched(consecutive: d1.newConsecutiveIdleLatchChecks, didRebuild: false)
        #expect(d2.action == .rebuildToReleaseIdleLatch)
        #expect(d2.newConsecutiveIdleLatchChecks == 0, "counter resets once the action fires")
    }

    @Test func idleLatchRebuildsOnlyOncePerSilencePeriod() {
        let d = idleLatched(consecutive: 1, didRebuild: true)
        #expect(d.action == .none, "the one rebuild was spent; wait for audio before trying again")
        #expect(d.newConsecutiveIdleLatchChecks == 0)
    }

    @Test func audioReturningReopensTheIdleLatchRebuild() {
        let d = idleLatched(consecutive: 1, didRebuild: true, othersOutputting: true, maxAbs: 0.2)
        #expect(d.resetDidRebuildForIdleLatch)
        #expect(d.resetDidRebuildForSilence)
        #expect(d.newConsecutiveIdleLatchChecks == 0)
        #expect(d.action == .none)
    }

    @Test func idleLatchIgnoresAnIdleSystemThatIsNotReportedDuplex() {
        // The fresh-stack state: silent, nobody playing, NOT duplex → costs nothing, leave it.
        let d = idleLatched(consecutive: 5, didRebuild: false, duplex: false)
        #expect(d.newConsecutiveIdleLatchChecks == 0)
        #expect(d.action == .none)
    }

    @Test func duplexWhileOthersPlayIsTheTCCPathNotTheIdleLatch() {
        let d = EQDeviceEngine.watchdogDecision(
            advancing: true, maxAbs: 0, othersOutputting: true,
            consecutiveSilentChecks: 1, didRebuildForSilence: false, permissionSuspected: false,
            ownReportedDuplex: true, consecutiveIdleLatchChecks: 1, didRebuildForIdleLatch: false)
        #expect(d.action == .rebuild)
        #expect(d.newConsecutiveIdleLatchChecks == 0, "the two paths are disjoint on any one tick")
    }

    @Test func nonAdvancingCounterNeverCountsAsIdleLatched() {
        let d = idleLatched(consecutive: 3, didRebuild: false, advancing: false)
        #expect(d.newConsecutiveIdleLatchChecks == 0)
        #expect(d.action == .none)
    }
}
