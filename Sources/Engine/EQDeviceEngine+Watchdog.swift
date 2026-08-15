// EQDeviceEngine's silence-detection watchdog and the in-place rebuild it triggers.

import AudioToolbox
import Foundation
import os.log

extension EQDeviceEngine {

    // MARK: - Watchdog (CONTRACT.md)

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

    private func watchdogTick() {
        guard case .running = state, let context = rtContext else { return }
        // rtAcquireFence() pairs with the RT thread's rtReleaseFence() after writing
        // callbackCounter/maxAbsInput (EQIOProcFactory.swift) — guarantees this read
        // observes the RT thread's latest writes rather than a stale cached value.
        rtAcquireFence()
        let counter = context.callbackCounter
        let maxAbs = context.maxAbsInput
        context.maxAbsInput = 0   // read-then-reset so each tick sees the max since the last
        // Publish the reset in order before the RT thread's next telemetry write.
        rtReleaseFence()
        let advancing = counter != lastWatchdogCounter
        lastWatchdogCounter = counter

        // Zeros are legitimate when nothing is playing. Only treat a silent check as
        // suspicious when some OTHER process is actually outputting audio — otherwise
        // we'd false-trip on an idle but healthy chain. Prefer the delegate's shared,
        // TTL-cached answer (OutputDeviceEQCoordinator memoizes this across every
        // engine's watchdog tick, avoiding N redundant CoreAudio process-list
        // enumerations per tick cycle); fall back to the uncached free function
        // directly if no delegate is attached (e.g. an engine driven without a
        // coordinator in isolation).
        let othersOutputting = delegate?.anyOtherProcessOutputtingAudio(excluding: ownProcessObjectID)
            ?? anyOtherProcessOutputtingAudio(excluding: ownProcessObjectID)

        let decision = Self.watchdogDecision(
            advancing: advancing, maxAbs: maxAbs, othersOutputting: othersOutputting,
            consecutiveSilentChecks: consecutiveSilentChecks, didRebuildForSilence: didRebuildForSilence,
            permissionSuspected: permissionSuspected)

        // Audio is flowing again. If we'd previously raised a permission-suspected
        // condition, clear it and re-notify the controller with .running (idempotent).
        if decision.resetDidRebuildForSilence { didRebuildForSilence = false }
        if decision.clearPermissionSuspicion {
            permissionSuspected = false
            os_log(.default, log: engineLog, "watchdog: audio recovered, clearing permission suspicion")
            delegate?.engine(self, didChangeState: .running)
        }
        consecutiveSilentChecks = decision.newConsecutiveSilentChecks

        switch decision.action {
        case .none:
            break
        case .rebuild:
            // One silent rebuild (stop + start), no delegate noise.
            didRebuildForSilence = true
            os_log(.default, log: engineLog, "watchdog: silent input, rebuilding once")
            rebuild()
        case .suspectPermissionDenied:
            // Still silent after a rebuild → likely TCC denial.
            os_log(.error, log: engineLog, "watchdog: still silent after rebuild → permission denial suspected")
            permissionSuspected = true
            delegate?.engineSuspectsPermissionDenied(self)
        }
    }

    // MARK: - Pure decision logic (testable without CoreAudio/timers)
    //
    // Extracted so the escalation policy (when 2 consecutive silent-but-should-be-playing
    // ticks trigger a rebuild, and when persistent silence after a rebuild escalates to
    // permission suspicion) can be tested deterministically, without a live
    // DispatchSourceTimer — same pattern as OutputDeviceEQCoordinator's
    // planReconciliation/aggregateStatus (OutputDeviceEQCoordinator.swift).

    struct WatchdogDecision: Equatable {
        /// maxAbs > 0 this tick — always clears the "already rebuilt once" latch,
        /// independent of whether a permission suspicion was active.
        var resetDidRebuildForSilence: Bool
        /// maxAbs > 0 AND a permission suspicion was previously raised — fires the
        /// idempotent `.running` re-notification (CONTRACT.md's watchdog↔delegate
        /// idempotency rule).
        var clearPermissionSuspicion: Bool
        var newConsecutiveSilentChecks: Int
        var action: Action

        enum Action: Equatable {
            case none
            case rebuild
            case suspectPermissionDenied
        }
    }

    /// Pure: given this tick's raw observations plus the engine's persistent watchdog
    /// state, decide what should happen. Mirrors watchdogTick()'s prior inline logic
    /// exactly (see git history) — no CoreAudio, no timers, no side effects.
    nonisolated static func watchdogDecision(
        advancing: Bool, maxAbs: Float, othersOutputting: Bool,
        consecutiveSilentChecks: Int, didRebuildForSilence: Bool, permissionSuspected: Bool
    ) -> WatchdogDecision {
        let resetDidRebuild = maxAbs > 0
        let clearSuspicion = maxAbs > 0 && permissionSuspected

        let silentThisTick = advancing && maxAbs == 0 && othersOutputting
        let provisionalCount = silentThisTick ? consecutiveSilentChecks + 1 : 0

        guard provisionalCount >= 2 else {
            return WatchdogDecision(resetDidRebuildForSilence: resetDidRebuild,
                                     clearPermissionSuspicion: clearSuspicion,
                                     newConsecutiveSilentChecks: provisionalCount,
                                     action: .none)
        }
        if !didRebuildForSilence {
            return WatchdogDecision(resetDidRebuildForSilence: resetDidRebuild,
                                     clearPermissionSuspicion: clearSuspicion,
                                     newConsecutiveSilentChecks: 0,
                                     action: .rebuild)
        } else {
            return WatchdogDecision(resetDidRebuildForSilence: resetDidRebuild,
                                     clearPermissionSuspicion: clearSuspicion,
                                     newConsecutiveSilentChecks: 0,
                                     action: .suspectPermissionDenied)
        }
    }

    /// Full stack rebuild preserving the current bands, WITHOUT flickering through
    /// .stopped (which would make the UI blink "disabled"). Tears down Core Audio
    /// and RT state in place, then re-runs the start sequence.
    ///
    /// Guarded against reentrancy (a second wake notification racing the first, or a
    /// watchdog tick during the deferred phase-B gap). After a successful rebuild we
    /// fire .running UNCONDITIONALLY (bypassing the state didSet equality guard, since
    /// state was already .running throughout), so the controller learns the chain is
    /// healthy again.
    ///
    /// Not private: called from EQDeviceEngine+SleepWake.swift's wake handler.
    func rebuild() {
        guard !rebuildInProgress else { return }
        rebuildInProgress = true
        let bands = currentBands
        // Same strict order as stop(), minus the state transition and timers/observer
        // (performStart reinstalls those). Bump the generation so any in-flight phase B
        // from a prior start no-ops.
        startGeneration &+= 1
        stopWatchdog()
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
                if case .running = self.state, self.startGeneration == generation {
                    self.delegate?.engine(self, didChangeState: .running)
                }
            }
        }
    }
}
