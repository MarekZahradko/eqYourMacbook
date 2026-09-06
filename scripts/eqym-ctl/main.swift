// eqym-ctl — drives and observes a running eqYourMacbook over its local control channel
// (Sources/App/EQControlChannel.swift) and runs the two on-Mac measurements that decide
// tuning values recorded in CLAUDE.md § Invariants. Built and run by scripts/eqym-ctl.sh.
//
// Exit codes: 0 ok · 2 usage · 3 app unreachable · 4 engine not running / unlabeled
// · 5 microphone · 6 environment (afplay, files) · 7 clicks not detected · 8 no shift measured
// · 9 not quiet (another process has output running — measurement refused or discarded).

import CoreAudio
import Foundation

let usage = """
usage: eqym-ctl <command>

  status                 print the app's state (enabled, bypass, running device, IO buffer, exclusions)
  enable | disable       master switch (tears the tap down / rebuilds it)
  bypass on | off        A/B bypass (the tap stays up; IOProc copies instead of filtering)
  processes              list HAL audio processes with input/output running right now
  quiet                  exit 0 if no process other than the app has output running, else 9 and
                         list them — gate every silence measurement on this, before AND after
  watch [outDir]         stream state changes and process IO transitions with timestamps;
                         prints the EXCLUSION WINDOW (process became duplex → tap rebuilt
                         without it) for every call that starts — start a call, read it off;
                         output is also written to <outDir>/watch-<stamp>.log
  latency [outDir]       measure the latency the EQ path adds (mic + click train, ~35 s,
                         fully automated); appends to <outDir>/latency-results.tsv and
                         writes the full report to <outDir>/latency-<stamp>.log
                         (default outDir: .build/measure next to the repo, via eqym-ctl.sh)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage); exit(2)
}
let client = EQControlClient()

func requireReachable(_ snapshot: EQControlSnapshot?) -> EQControlSnapshot {
    guard let snapshot else {
        fail(3, "eqYourMacbook is not reachable over the control channel — is the installed build running, and does it include EQControlChannel.swift?")
    }
    return snapshot
}

switch command {
case "status":
    let state = requireReachable(client.request(.status))
    state.summaryLines.forEach(emit)

case "enable", "disable":
    let state = requireReachable(client.request(command == "enable" ? .enable : .disable))
    state.summaryLines.forEach(emit)
    if command == "enable", !state.engineRunning {
        // Phase B lands ~0.3 s later; wait for it so the caller sees the final state.
        if let running = client.waitForState(timeout: 3) { $0.engineRunning } {
            emit("— engine came up (\(stamp(running.postedAt))):")
            running.snapshot.summaryLines.forEach(emit)
        } else {
            emit("— no engine came up within 3 s (no device checked, or it is not the default output?)")
        }
    }

case "bypass":
    guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else { print(usage); exit(2) }
    let state = requireReachable(client.request(arguments[1] == "on" ? .bypassOn : .bypassOff))
    state.summaryLines.forEach(emit)

case "processes":
    printProcesses(own: client.request(.status, timeout: 1.0)?.ownProcessObject.map { AudioObjectID($0) })

case "quiet":
    let own = client.request(.status, timeout: 1.0)?.ownProcessObject.map { AudioObjectID($0) }
    let offenders = otherProcessesWithOutputRunning(excluding: own.map { [$0] } ?? [])
    if offenders.isEmpty {
        emit("\(stamp())  quiet: no process other than eqYourMacbook has output running")
        exit(0)
    }
    emit("\(stamp())  NOT quiet — output running in:")
    for (object, io) in offenders { emit("  \(describe(object, io))") }
    exit(9)

case "watch":
    mirrorOutput(toFileIn: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath, prefix: "watch")
    let initial = requireReachable(client.request(.status))
    emit("\(stamp())  app reachable; engine running: \(initial.engineRunning)" +
         (initial.engineRunning ? ", excludes \(initial.excludedProcessObjects)" : ""))
    emit("\(stamp())  watching HAL process IO and app state (Ctrl-C to stop). Start a call now.")
    emit("")
    var excluded = Set(initial.excludedProcessObjects)
    // Duplex transitions awaiting the exclusion rebuild, and exclusions awaiting re-inclusion.
    var awaitingExclusion: [Int: Date] = [:]
    var awaitingInclusion: [Int: Date] = [:]
    client.onState = { received in
        let now = Set(received.snapshot.excludedProcessObjects)
        var note = ""
        if now != excluded {
            note = "  exclusions: \(excluded.sorted()) → \(now.sorted())"
        }
        emit("\(stamp(received.postedAt))  [app]  \(received.event.rawValue)  enabled=\(received.snapshot.enabled) engine=\(received.snapshot.engineRunning)\(note)")
        for (object, since) in awaitingExclusion where now.contains(object) {
            let ms = received.postedAt.timeIntervalSince(since) * 1000
            emit(String(format: "%@  EXCLUSION WINDOW  object %d: duplex → tap rebuilt without it in %.0f ms", stamp(received.postedAt), object, ms))
            awaitingExclusion.removeValue(forKey: object)
        }
        for (object, since) in awaitingInclusion where !now.contains(object) {
            let ms = received.postedAt.timeIntervalSince(since) * 1000
            emit(String(format: "%@  RE-INCLUSION WINDOW  object %d: call ended → tapped again in %.0f ms", stamp(received.postedAt), object, ms))
            awaitingInclusion.removeValue(forKey: object)
        }
        excluded = now
    }
    let watcher = ProcessIOWatcher()
    watcher.poll { _, _, _ in }          // prime
    while true {
        client.pump(0.1)
        watcher.poll { object, from, to in
            let now = Date()
            if let to {
                emit("\(stamp(now))  [hal]  \(describe(object, to))  →  \(to.label)")
                let wasDuplex = from?.isDuplex ?? false
                if to.isDuplex, !wasDuplex, !excluded.contains(Int(object)) {
                    awaitingExclusion[Int(object)] = now
                }
                if !to.isDuplex, wasDuplex, excluded.contains(Int(object)) {
                    awaitingInclusion[Int(object)] = now
                }
            } else if let from {
                emit("\(stamp(now))  [hal]  \(describe(object, from))  →  gone")
            }
        }
    }

case "latency":
    let outDir = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
    mirrorOutput(toFileIn: outDir, prefix: "latency")
    exit(LatencyMeasurement.run(client: client, outDir: outDir))

default:
    print(usage); exit(2)
}
