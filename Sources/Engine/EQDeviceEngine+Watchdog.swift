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
        let counter = context.callbackCounter
        let maxAbs = context.maxAbsInput
        context.maxAbsInput = 0   // read-then-reset so each tick sees the max since the last
        let advancing = counter != lastWatchdogCounter
        lastWatchdogCounter = counter

        // Audio is flowing again. If we'd previously raised a permission-suspected
        // condition, clear it and re-notify the controller with .running (idempotent).
        if maxAbs > 0 {
            didRebuildForSilence = false
            if permissionSuspected {
                permissionSuspected = false
                os_log(.default, log: engineLog, "watchdog: audio recovered, clearing permission suspicion")
                delegate?.engine(self, didChangeState: .running)
            }
        }

        // Zeros are legitimate when nothing is playing. Only treat a silent check as
        // suspicious when some OTHER process is actually outputting audio — otherwise
        // we'd false-trip on an idle but healthy chain.
        let othersOutputting = anyOtherProcessOutputtingAudio(excluding: ownProcessObjectID)
        if advancing && maxAbs == 0 && othersOutputting {
            consecutiveSilentChecks += 1
        } else {
            consecutiveSilentChecks = 0
        }

        guard consecutiveSilentChecks >= 2 else { return }

        if !didRebuildForSilence {
            // One silent rebuild (stop + start), no delegate noise.
            didRebuildForSilence = true
            consecutiveSilentChecks = 0
            os_log(.default, log: engineLog, "watchdog: silent input, rebuilding once")
            rebuild()
        } else {
            // Still silent after a rebuild → likely TCC denial.
            os_log(.error, log: engineLog, "watchdog: still silent after rebuild → permission denial suspected")
            consecutiveSilentChecks = 0
            permissionSuspected = true
            delegate?.engineSuspectsPermissionDenied(self)
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
