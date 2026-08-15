// EQDeviceEngine's sleep/wake observer: preventively rebuilds the tap/aggregate
// stack shortly after the machine wakes.

import AppKit
import Foundation

extension EQDeviceEngine {

    // MARK: - Sleep / wake

    func installWakeObserver() {
        removeWakeObserver()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // ~1 s after wake (iqualize-proven timing) → preventive rebuild.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .running = self.state { self.rebuild() }
                }
            }
        }
    }

    func removeWakeObserver() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }
}
