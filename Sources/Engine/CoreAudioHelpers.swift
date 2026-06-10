// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
import CoreAudio

func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw NSError(domain: "eqYourMacbook", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(message): OSStatus \(status)"])
    }
}

func getDefaultOutputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try caCheck(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &deviceID),
        "Failed to get default output device"
    )
    return deviceID
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
        "Failed to get device UID"
    )
    return uid as String
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name),
        "Failed to get device name"
    )
    return name as String
}

// MARK: - Transport type & output-stream introspection

/// Read a device's transport type (e.g. `kAudioDeviceTransportTypeBuiltIn`).
/// Returns `kAudioDeviceTransportTypeUnknown` on failure rather than throwing —
/// callers iterate over many devices and a single bad device must not abort the scan.
func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = kAudioDeviceTransportTypeUnknown
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    return status == noErr ? transport : kAudioDeviceTransportTypeUnknown
}

/// Whether a device exposes at least one output stream.
/// Uses the byte size of the output-scope stream configuration: an output device
/// has one or more `AudioBuffer`s in its `kAudioDevicePropertyStreamConfiguration`.
func deviceHasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
        return false
    }
    // Allocate a raw buffer of exactly the reported size and read the AudioBufferList into it.
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
        return false
    }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    for buffer in list where buffer.mNumberChannels > 0 {
        return true
    }
    return false
}

/// All audio device IDs known to the HAL.
func getAllDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
        "Failed to get device list size"
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    try caCheck(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices),
        "Failed to get device list"
    )
    return devices
}

/// Find the built-in speakers: a device whose transport type is built-in AND that
/// has output streams. Prefers the default output device when it already qualifies
/// (the common case), otherwise scans the full device list. Throws if none found.
func findBuiltInSpeakers() throws -> AudioDeviceID {
    // Fast path: the current default output is usually the built-in speakers.
    if let defaultID = try? getDefaultOutputDeviceID(),
       getDeviceTransportType(defaultID) == kAudioDeviceTransportTypeBuiltIn,
       deviceHasOutputStreams(defaultID) {
        return defaultID
    }
    for deviceID in try getAllDeviceIDs() {
        if getDeviceTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn,
           deviceHasOutputStreams(deviceID) {
            return deviceID
        }
    }
    throw NSError(domain: "eqYourMacbook", code: -1,
                  userInfo: [NSLocalizedDescriptionKey: "No built-in speakers found"])
}

/// Read a device's nominal sample rate (output scope). Returns 0 on failure.
func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    return status == noErr ? rate : 0
}

// MARK: - Process-output introspection (watchdog discriminator, FIX 5)

/// Whether any process OTHER than `excluding` is currently outputting audio.
///
/// Used by the watchdog to discriminate a genuine silent-input fault (our chain is
/// broken while audio plays) from a benign idle system (nothing is playing → zeros
/// are correct, do NOT trip). Enumerates the system object's process list and reads
/// each process's "is running output" flag, skipping our own process object (we
/// already translate our PID for tap self-exclusion).
///
/// macOS 14.2+ constants: `kAudioHardwarePropertyProcessObjectList`,
/// `kAudioProcessPropertyIsRunningOutput`. VERIFY THESE NAMES ON THE FIRST MAC BUILD.
/// Fallback policy if they don't exist in the SDK: delete this helper and have the
/// watchdog NEVER auto-escalate to permissionSuspected — keep only the single silent
/// rebuild path (the rebuild is harmless; a false permission prompt is not).
func anyOtherProcessOutputtingAudio(excluding ownProcessObjectID: AudioObjectID) -> Bool {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
          size > 0 else {
        return false
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return false }
    var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else {
        return false
    }

    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    for processObject in processes where processObject != ownProcessObjectID {
        var isRunningOutput: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            processObject, &runningAddress, 0, nil, &valueSize, &isRunningOutput)
        if status == noErr && isRunningOutput != 0 {
            return true
        }
    }
    return false
}
