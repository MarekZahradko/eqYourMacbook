// EQDeviceEngine's silence-detection watchdog and the in-place rebuild it triggers.

import AudioToolbox
import Foundation
import os.log

extension EQDeviceEngine {

    // MARK: - Watchdog (CLAUDE.md § Invariants)

    func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        watchdogTimer = timer
        timer.resume()
    }

    func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // Not private: driven directly by EQDeviceEngineWatchdogIntegrationTests.swift so the
    // escalation policy's actual effect on a real engine/CoreAudio-double stack (rebuild()
    // firing, the unconditional post-rebuild .running re-notification) can be tested
    // deterministically without waiting on the real 5 s DispatchSourceTimer — same
    // "documented, deliberate test seam" convention as rebuild()'s own "Not private:
    // called from EQDeviceEngine+SleepWake.swift's wake handler" comment below. Production
    // call site is still only startWatchdog()'s timer handler above.
    func watchdogTick() {
        guard case .running = state else { return }
        // NOTE: the tick does not re-read the tap-exclusion set; that has its own path —
        // TapExclusionMonitor's HAL listeners (fast, ~0.8 s), the engine's 2 s polling
        // backstop (startExclusionBackstop, EQDeviceEngine+Lifecycle.swift) for a listener
        // that never fires, and rebuild()'s one-shot re-check for a change swallowed while
        // a rebuild was in flight. Keeping the concerns apart keeps this tick's
        // bookkeeping (silence streaks, latches) independent of exclusion churn.
        guard let context = rtContext else { return }
        // rtAcquireFence() pairs with the RT thread's rtReleaseFence() after writing
        // callbackCounter (EQIOProcFactory.swift) — guarantees this read observes the
        // RT thread's latest write rather than a stale cached value.
        rtAcquireFence()
        let counter = context.callbackCounter
        // maxAbsInput is a separate, CAS-based exchange (not fence-bracketed): it has
        // two genuine concurrent writers (this reset + the RT thread's running-max
        // update), so a plain read-then-store here could silently drop an RT update
        // landing in between, or silently revive a pre-reset sample into this tick's
        // window — see EQDeviceRTContext.swift's maxAbsInputBits doc comment.
        let maxAbs = context.exchangeMaxAbsInputWithZero()
        let advancing = counter != lastWatchdogCounter
        lastWatchdogCounter = counter

        // Zeros are legitimate when nothing is playing, so only treat silence as
        // suspicious when some process we ACTUALLY TAP is outputting audio. Pass the full
        // exclusion set, not just our own process object: a hog holder or a process in a
        // call is deliberately untapped, so its output never reaches us and must not count
        // as evidence of a broken chain (it would otherwise escalate to a false "TCC
        // denied" suspicion for the whole duration of every call). Prefer the delegate's
        // shared, TTL-cached answer (OutputDeviceEQCoordinator memoizes this across every
        // engine's tick, avoiding N redundant CoreAudio enumerations); fall back to the
        // uncached free function if no delegate is attached.
        //
        // Evaluated LAZILY: the answer only matters for a tick that is otherwise a
        // silence candidate (callbacks advancing AND max-abs == 0). While audio is
        // flowing, which is the common case, the process enumeration behind it (one
        // process-list read plus one property read per audio process, all Mach IPC into
        // coreaudiod) is skipped entirely. `watchdogDecision` is unaffected: when
        // `silenceCandidate` is false the flag cannot influence its result.
        let silenceCandidate = Self.watchdogTickIsSilenceCandidate(advancing: advancing, maxAbs: maxAbs)
        let othersOutputting = silenceCandidate
            ? (delegate?.anyOtherProcessOutputtingAudio(excluding: excludedProcessObjectIDs)
               ?? anyOtherProcessOutputtingAudio(excluding: excludedProcessObjectIDs))
            : false

        // Idle latch (CLAUDE.md § Invariants, "Idle latch"): read only when this tick is
        // silent AND nobody we tap is playing — the one situation in which the HAL still
        // reporting our own process as duplex means coreaudiod is stuck treating us as an
        // active call (full device cost, held sleep assertion). Two property reads.
        let ownReportedDuplex = silenceCandidate && !othersOutputting
            ? tapService.isProcessRunningDuplex(ownProcessObjectID)
            : false

        let decision = Self.watchdogDecision(
            advancing: advancing, maxAbs: maxAbs, othersOutputting: othersOutputting,
            consecutiveSilentChecks: consecutiveSilentChecks, didRebuildForSilence: didRebuildForSilence,
            permissionSuspected: permissionSuspected,
            ownReportedDuplex: ownReportedDuplex, consecutiveIdleLatchChecks: consecutiveIdleLatchChecks,
            didRebuildForIdleLatch: didRebuildForIdleLatch)

        // Audio is flowing again: both "already rebuilt once" latches open up for the next
        // silence, and a standing permission suspicion is cleared with the idempotent
        // .running re-notification.
        if decision.resetDidRebuildForSilence { didRebuildForSilence = false }
        if decision.resetDidRebuildForIdleLatch { didRebuildForIdleLatch = false }
        if decision.clearPermissionSuspicion {
            permissionSuspected = false
            os_log(.default, log: engineLog, "watchdog: audio recovered, clearing permission suspicion")
            delegate?.engine(self, didChangeState: .running)
        }
        consecutiveSilentChecks = decision.newConsecutiveSilentChecks
        consecutiveIdleLatchChecks = decision.newConsecutiveIdleLatchChecks

        switch decision.action {
        case .none:
            break
        case .rebuild:
            // One silent rebuild (stop + start), no delegate noise.
            os_log(.default, log: engineLog, "watchdog: silent input while others play, rebuilding once")
            rebuild()
            // AFTER rebuild(): its performStart() resets this flag for the fresh stack, so
            // setting it first lost it — under a real TCC denial the engine then rebuilt
            // every 10 s forever and the escalation below never fired.
            didRebuildForSilence = true
        case .suspectPermissionDenied:
            // Still silent after a rebuild → likely TCC denial.
            os_log(.error, log: engineLog, "watchdog: still silent after rebuild → permission denial suspected")
            permissionSuspected = true
            delegate?.engineSuspectsPermissionDenied(self)
        case .rebuildToReleaseIdleLatch:
            os_log(.default, log: engineLog,
                   "watchdog: idle but still reported duplex, rebuilding once to release coreaudiod's active state")
            rebuild()
            didRebuildForIdleLatch = true   // same ordering rule as .rebuild above
        }
    }

    // MARK: - Pure decision logic (testable without CoreAudio/timers)
    //
    // Extracted so the escalation policy (2 consecutive silent-but-should-be-playing
    // ticks → rebuild; persistent silence after a rebuild → permission suspicion) can be
    // tested deterministically without a live DispatchSourceTimer — same pattern as
    // OutputDeviceEQCoordinator's planReconciliation/aggregateStatus.

    struct WatchdogDecision: Equatable {
        /// maxAbs > 0 this tick — clears the "already rebuilt once" latch of the TCC path,
        /// independent of whether a permission suspicion was active.
        var resetDidRebuildForSilence: Bool
        /// maxAbs > 0 this tick — clears the "already rebuilt once" latch of the idle-latch
        /// path (audio has played, so the next silence gets its one release rebuild again).
        var resetDidRebuildForIdleLatch: Bool
        /// maxAbs > 0 AND a permission suspicion was previously raised — fires the
        /// idempotent `.running` re-notification (CLAUDE.md § Invariants' watchdog↔delegate
        /// idempotency rule).
        var clearPermissionSuspicion: Bool
        var newConsecutiveSilentChecks: Int
        var newConsecutiveIdleLatchChecks: Int
        var action: Action

        enum Action: Equatable {
            case none
            /// TCC path: silent while a tapped process plays → one rebuild.
            case rebuild
            /// TCC path: still silent after that rebuild → suspicion.
            case suspectPermissionDenied
            /// Idle-latch path (CLAUDE.md § Invariants, "Idle latch"): silent, nobody we
            /// tap is playing, yet the HAL still reports us as duplex → one rebuild per
            /// silence period, to drop coreaudiod's always-active treatment of our client.
            case rebuildToReleaseIdleLatch
        }
    }

    /// Pure: whether a tick could count as silent at all, i.e. whether the (costly)
    /// "is anyone else outputting audio" question needs asking. Must stay the exact
    /// `advancing && maxAbs == 0` prefix of `watchdogDecision`'s two silent-tick predicates.
    nonisolated static func watchdogTickIsSilenceCandidate(advancing: Bool, maxAbs: Float) -> Bool {
        advancing && maxAbs == 0
    }

    /// Pure: given this tick's raw observations plus the engine's persistent watchdog
    /// state, decide what should happen. No CoreAudio, no timers, no side effects.
    ///
    /// Two disjoint silent-tick paths (they differ in `othersOutputting`, so at most one
    /// can count on a given tick):
    ///   - TCC path: silent although a NON-EXCLUDED process is outputting → 2 consecutive →
    ///     one rebuild → still silent 2 more → permission suspicion.
    ///   - Idle-latch path: silent, nobody we tap is outputting, yet the HAL reports our own
    ///     process as duplex → 2 consecutive → one rebuild; then nothing more until audio
    ///     has played again (`didRebuildForIdleLatch` is reset by maxAbs > 0).
    nonisolated static func watchdogDecision(
        advancing: Bool, maxAbs: Float, othersOutputting: Bool,
        consecutiveSilentChecks: Int, didRebuildForSilence: Bool, permissionSuspected: Bool,
        ownReportedDuplex: Bool = false, consecutiveIdleLatchChecks: Int = 0, didRebuildForIdleLatch: Bool = false
    ) -> WatchdogDecision {
        let audible = maxAbs > 0
        let silentThisTick = advancing && maxAbs == 0 && othersOutputting
        let idleLatchedThisTick = advancing && maxAbs == 0 && !othersOutputting && ownReportedDuplex
        var decision = WatchdogDecision(
            resetDidRebuildForSilence: audible,
            resetDidRebuildForIdleLatch: audible,
            clearPermissionSuspicion: audible && permissionSuspected,
            newConsecutiveSilentChecks: silentThisTick ? consecutiveSilentChecks + 1 : 0,
            newConsecutiveIdleLatchChecks: idleLatchedThisTick ? consecutiveIdleLatchChecks + 1 : 0,
            action: .none)
        if decision.newConsecutiveSilentChecks >= 2 {
            decision.newConsecutiveSilentChecks = 0
            decision.action = didRebuildForSilence ? .suspectPermissionDenied : .rebuild
        } else if decision.newConsecutiveIdleLatchChecks >= 2 {
            decision.newConsecutiveIdleLatchChecks = 0
            if !didRebuildForIdleLatch { decision.action = .rebuildToReleaseIdleLatch }
        }
        return decision
    }

    /// Full stack rebuild preserving the current bands, WITHOUT flickering through
    /// .stopped (which would make the UI blink "disabled"): tears down Core Audio and RT
    /// state in place, then re-runs the start sequence. Guarded against reentrancy (a
    /// second wake notification racing the first, or a watchdog tick during the deferred
    /// phase-B gap). After a successful rebuild fires .running UNCONDITIONALLY (bypassing
    /// the state didSet equality guard, since state was already .running throughout), so
    /// the controller learns the chain is healthy again. Not private: called from
    /// EQDeviceEngine+SleepWake.swift's wake handler.
    func rebuild() {
        guard !rebuildInProgress else { return }
        rebuildInProgress = true
        let bands = currentBands
        // Same strict order as stop(), minus the state transition and timers/observer
        // (performStart reinstalls those). Bump the generation so any in-flight phase B
        // from a prior start no-ops.
        startGeneration &+= 1
        stopWatchdog()
        stopExclusionBackstop()
        removeWakeObserver()
        teardownCoreAudio()
        releaseRTState()
        performStart(bands: bands)
        // performStart defers phase B ~0.3 s; clear the guard and fire the unconditional
        // .running notification once that phase B has actually run and succeeded.
        // Capture MUST stay after performStart — it bumps startGeneration, and the
        // check below must match the NEW phase B, not the pre-rebuild one.
        let generation = startGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildInProgress = false
                // Only meaningful if the rebuild reached .running.
                guard case .running = self.state, self.startGeneration == generation else { return }
                os_log(.default, log: engineLog, "rebuild complete; tap excludes process objects %{public}@",
                       self.excludedProcessObjectIDs.map { String($0) }.joined(separator: ",") as NSString)
                self.delegate?.engine(self, didChangeState: .running)
                // Backstop for a TapExclusionMonitor callback swallowed by the reentrancy
                // guard above while this rebuild was in flight: re-check the live exclusion
                // set exactly once, now that a further rebuild can actually run. No-ops when
                // nothing changed; this is the only place (besides the monitor callback
                // itself) the set is re-read while running.
                self.rebuildIfTapExclusionsStale()
            }
        }
    }
}
