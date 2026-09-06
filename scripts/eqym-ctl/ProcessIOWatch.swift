// HAL process-object IO state: which audio processes are running INPUT and/or OUTPUT —
// the two properties the app's voice-session exclusion keys on (CLAUDE.md § Invariants,
// "Tap exclusions") and the one its watchdog discriminator asks about. Polled here
// (bench tool); the app itself uses listeners.

import CoreAudio
import Foundation

struct ProcessIO: Equatable {
    let pid: pid_t
    let bundleID: String
    var input: Bool
    var output: Bool

    var isDuplex: Bool { input && output }

    var label: String {
        switch (input, output) {
        case (true, true):   return "DUPLEX  (voice session → excluded from tap)"
        case (false, true):  return "output  (tapped)"
        case (true, false):  return "input"
        default:             return "idle"
        }
    }
}

private func halProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr) == noErr else { return nil }
    return ptr.pointee
}

private func halString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    guard let unmanaged: Unmanaged<CFString> = halProperty(object, selector) else { return "?" }
    return unmanaged.takeRetainedValue() as String
}

func processObjectIDs() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list) == noErr
    else { return [] }
    return list
}

func processIOStates() -> [AudioObjectID: ProcessIO] {
    var result: [AudioObjectID: ProcessIO] = [:]
    for object in processObjectIDs() {
        let input: UInt32 = halProperty(object, kAudioProcessPropertyIsRunningInput) ?? 0
        let output: UInt32 = halProperty(object, kAudioProcessPropertyIsRunningOutput) ?? 0
        result[object] = ProcessIO(pid: halProperty(object, kAudioProcessPropertyPID) ?? -1,
                                   bundleID: halString(object, kAudioProcessPropertyBundleID),
                                   input: input != 0, output: output != 0)
    }
    return result
}

func describe(_ object: AudioObjectID, _ io: ProcessIO) -> String {
    "object \(object)  pid \(io.pid)  \(io.bundleID)"
}

/// Processes other than `excluding` (normally eqYourMacbook itself) that have OUTPUT
/// running right now. Any of them makes a silence measurement meaningless: a browser
/// holding an output stream looks exactly like a latch on CPU alone.
func otherProcessesWithOutputRunning(excluding: Set<AudioObjectID>) -> [(AudioObjectID, ProcessIO)] {
    processIOStates()
        .filter { $0.value.output && !excluding.contains($0.key) }
        .sorted { $0.key < $1.key }
        .map { ($0.key, $0.value) }
}

/// One-shot listing, active processes first; `own` marks the app's own process object.
func printProcesses(own: AudioObjectID?) {
    let states = processIOStates()
    let active = states.filter { $0.value.input || $0.value.output }.sorted { $0.key < $1.key }
    emit("\(stamp())  \(states.count) HAL process objects, \(active.count) with IO running:")
    for (object, io) in active {
        emit("  \(describe(object, io))  →  \(io.label)\(object == own ? "   ← eqYourMacbook" : "")")
    }
    if active.isEmpty { emit("  (none — no process has input or output running)") }
}

/// Diffs successive polls; `onChange` gets every transition, including appearances and
/// disappearances (as `to == nil`).
final class ProcessIOWatcher {
    private var known: [AudioObjectID: ProcessIO] = [:]
    private var primed = false

    func poll(onChange: (AudioObjectID, _ from: ProcessIO?, _ to: ProcessIO?) -> Void) {
        let current = processIOStates()
        if !primed {
            known = current
            primed = true
            return
        }
        for (object, io) in current where known[object] != io {
            onChange(object, known[object], io)
        }
        for (object, io) in known where current[object] == nil {
            onChange(object, io, nil)
        }
        known = current
    }

    var snapshot: [AudioObjectID: ProcessIO] { known }
}
