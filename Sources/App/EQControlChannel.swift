// Local control surface over DistributedNotificationCenter, so bench tools
// (scripts/eqym-ctl.sh) can drive and observe the app without a human clicking the
// menu — a measurement that depends on "toggle around t = 10 s" is neither reproducible
// nor comparable across runs. Protocol (names, commands, snapshot keys) is
// EQControlProtocol.swift, shared verbatim with the tools.
//
// Thin by design: it only decodes commands and posts snapshots. What a command DOES,
// and what a snapshot CONTAINS, is EQController's (applyControlCommand /
// controlSnapshot), which is where the unit tests bite.

import Foundation

@MainActor final class EQControlChannel {

    private let center: DistributedNotificationCenter
    private var observer: NSObjectProtocol?
    private var onCommand: ((EQControlCommand, _ requestID: String?) -> Void)?

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    /// Idempotent. `onCommand` runs on the main actor for every well-formed command.
    func start(onCommand: @escaping (EQControlCommand, _ requestID: String?) -> Void) {
        self.onCommand = onCommand
        guard observer == nil else { return }
        observer = center.addObserver(forName: EQControlProtocol.commandNotification, object: nil,
                                      queue: .main) { [weak self] note in
            // Payload is untrusted input from another local process: decode defensively,
            // ignore anything that is not exactly a known command.
            guard let info = note.userInfo,
                  let raw = info[EQControlProtocol.Keys.command] as? String,
                  let command = EQControlCommand(rawValue: raw) else { return }
            let requestID = EQControlProtocol.requestID(of: info)
            MainActor.assumeIsolated {
                self?.onCommand?(command, requestID)
            }
        }
    }

    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        onCommand = nil
    }

    /// Posts one snapshot. `deliverImmediately` bypasses the receiver's suspension
    /// coalescing so timestamps stay meaningful for the tools' window measurements.
    func broadcast(_ snapshot: EQControlSnapshot, event: EQControlProtocol.Event, requestID: String? = nil) {
        center.postNotificationName(EQControlProtocol.stateNotification, object: nil,
                                    userInfo: snapshot.userInfo(event: event, requestID: requestID),
                                    deliverImmediately: true)
    }
}
