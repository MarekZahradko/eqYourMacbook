// EQDeviceEngine's sleep/wake observer: preventively rebuilds the tap/aggregate
// stack shortly after the machine wakes.

import AppKit
import Foundation

extension EQDeviceEngine {

    // MARK: - Sleep / wake

    func installWakeObserver() {
        removeWakeObserver()
        wakeObserver = wakeNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Capture the generation NOW (wake time), not at fire time: a
                // stop()/rebuild() racing the ~1 s deferral below bumps startGeneration
                // (EQDeviceEngine.swift), and the mismatch below then makes this no-op
                // instead of firing a stale rebuild — same guard performStart()'s own
                // phase-B deferral uses (EQDeviceEngine+Lifecycle.swift).
                let generation = self.startGeneration
                // ~1 s after wake (iqualize-proven timing) → preventive rebuild. Its own
                // [weak self] — Swift does NOT propagate the outer closure's weak self
                // into a nested closure, so without this the inner (also escaping)
                // closure would capture self STRONGLY for the full 1 s deferral, keeping
                // a stop()'d/dealloc'ing engine alive longer than intended.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.startGeneration == generation else { return }
                        if case .running = self.state { self.rebuild() }
                    }
                }
            }
        }
    }

    func removeWakeObserver() {
        if let obs = wakeObserver {
            wakeNotificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }
}
