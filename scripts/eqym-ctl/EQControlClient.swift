// Client side of the app's control channel (Sources/App/EQControlChannel.swift). The
// protocol file Sources/App/EQControlProtocol.swift is compiled into this tool verbatim
// (see scripts/eqym-ctl.sh), so there is exactly one definition of every name and key.
//
// Single-threaded by design: notifications arrive on the main queue and are consumed by
// pumping the main run loop (`pump`). Bench tool, not app code.

import Foundation

final class EQControlClient {

    struct Received {
        let snapshot: EQControlSnapshot
        let event: EQControlProtocol.Event
        /// When the app posted it (its own clock) — use this for window measurements,
        /// not `receivedAt`, so notification delivery latency cancels out.
        let postedAt: Date
        let receivedAt: Date
        let requestID: String?
    }

    private let center = DistributedNotificationCenter.default()
    private var observer: NSObjectProtocol?
    private(set) var inbox: [Received] = []
    /// Called for every state notification, in arrival order, while the run loop is pumped.
    var onState: ((Received) -> Void)?

    init() {
        observer = center.addObserver(forName: EQControlProtocol.stateNotification, object: nil,
                                      queue: .main) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let snapshot = EQControlSnapshot(userInfo: info) else { return }
            let received = Received(snapshot: snapshot,
                                    event: EQControlProtocol.event(of: info) ?? .changed,
                                    postedAt: EQControlProtocol.timestamp(of: info) ?? Date(),
                                    receivedAt: Date(),
                                    requestID: EQControlProtocol.requestID(of: info))
            self.inbox.append(received)
            self.onState?(received)
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Runs the main run loop for up to `seconds`, returning early once `stop()` is true.
    func pump(_ seconds: TimeInterval, until stop: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if let stop, stop() { return }
        } while Date() < deadline
    }

    /// Sends one command and waits for the app's reply to it (matched by request ID).
    /// nil = no reply within `timeout`: the app is not running, or it predates the channel.
    func request(_ command: EQControlCommand, timeout: TimeInterval = 2.0) -> EQControlSnapshot? {
        let id = UUID().uuidString
        center.postNotificationName(EQControlProtocol.commandNotification, object: nil,
                                    userInfo: [EQControlProtocol.Keys.command: command.rawValue,
                                               EQControlProtocol.Keys.requestID: id],
                                    deliverImmediately: true)
        var reply: EQControlSnapshot?
        pump(timeout) { [self] in
            if let hit = inbox.first(where: { $0.requestID == id }) { reply = hit.snapshot; return true }
            return false
        }
        return reply
    }

    /// Waits for the next state notification (posted after this call) matching `predicate`.
    func waitForState(timeout: TimeInterval, where predicate: @escaping (EQControlSnapshot) -> Bool) -> Received? {
        let startIndex = inbox.count
        var found: Received?
        pump(timeout) { [self] in
            if let hit = inbox[startIndex...].first(where: { predicate($0.snapshot) }) { found = hit; return true }
            return false
        }
        return found
    }
}

// MARK: - Presentation

extension EQControlSnapshot {
    var summaryLines: [String] {
        var lines = [
            "enabled:        \(enabled)",
            "bypassed:       \(bypassed)",
            "gainStaging:    \(gainStaging)",
            "status:         \(status)  (\(statusDetail))",
            "engineRunning:  \(engineRunning)",
        ]
        if engineRunning {
            lines.append("device:         \(deviceName ?? "?")  [\(deviceUID ?? "?")]")
            if let sampleRate { lines.append("sampleRate:     \(Int(sampleRate)) Hz") }
            if let ioBufferFrames, let sampleRate {
                lines.append(String(format: "ioBuffer:       %d frames = %.1f ms", ioBufferFrames,
                                    Double(ioBufferFrames) / sampleRate * 1000))
            } else {
                lines.append("ioBuffer:       (not reported — un-pinned?)")
            }
            lines.append("ownProcessObject: \(ownProcessObject.map(String.init) ?? "?")")
            lines.append("excludedProcessObjects: \(excludedProcessObjects.map(String.init).joined(separator: ", "))")
        }
        return lines
    }
}

let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func stamp(_ date: Date = Date()) -> String { timestampFormatter.string(from: date) }

/// When set, everything `emit` prints is also appended here, so a run's output survives
/// the terminal (the Mac and the analysis session share `.build/measure`).
var emitMirror: FileHandle?

func mirrorOutput(toFileIn directory: String, prefix: String) {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let path = (directory as NSString).appendingPathComponent("\(prefix)-\(f.string(from: Date())).log")
    if FileManager.default.createFile(atPath: path, contents: nil) {
        emitMirror = FileHandle(forWritingAtPath: path)
        emit("(output mirrored to \(path))")
    }
}

func emit(_ line: String) {
    print(line)
    fflush(stdout)
    if let emitMirror, let data = (line + "\n").data(using: .utf8) { emitMirror.write(data) }
}

func fail(_ code: Int32, _ message: String) -> Never {
    let data = ("error: " + message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
    emitMirror?.write(data)           // a failed run leaves its reason in the log too
    exit(code)
}
