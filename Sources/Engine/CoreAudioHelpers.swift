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

/// Generic scalar/struct property read, collapsing the repeated
/// AudioObjectPropertyAddress/AudioObjectGetPropertyData boilerplate below.
/// Returns nil on failure — callers pick their own sentinel/default.
func getProperty<T>(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
    guard status == noErr else { return nil }
    return ptr.pointee
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
        "Failed to get device UID"
    )
    guard let result = uid?.takeRetainedValue() else {
        throw NSError(domain: "eqYourMacbook", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Device UID is nil"])
    }
    return result as String
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name),
        "Failed to get device name"
    )
    guard let result = name?.takeRetainedValue() else {
        throw NSError(domain: "eqYourMacbook", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Device name is nil"])
    }
    return result as String
}

// MARK: - Transport type & output-stream introspection

/// Read a device's transport type (e.g. `kAudioDeviceTransportTypeBuiltIn`).
/// Returns `kAudioDeviceTransportTypeUnknown` on failure rather than throwing —
/// callers iterate over many devices and a single bad device must not abort the scan.
func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
    getProperty(deviceID, selector: kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
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

/// Read a device's nominal sample rate (output scope). Returns 0 on failure.
func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
    getProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeOutput) ?? 0
}

/// Read a device's current output stream format. Returns nil on failure. Used to verify
/// the tap/aggregate actually delivers what the IOProc assumes (Float32, N channels)
/// instead of assuming it silently — see EQDeviceEngine.performStart's format check.
func getStreamFormat(_ deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
    getProperty(deviceID, selector: kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput)
}

// MARK: - Hog mode (exclusive access) introspection
//
// A process that takes hog mode on a device (foobar2000's "exclusive" playback, and
// any other bit-perfect player) plays to THAT device while macOS moves the default
// output route elsewhere. Our tap is a GLOBAL process tap: it would capture such a
// process anyway and — with .mutedWhenTapped — silence it on the device it hogged,
// re-rendering its audio through our aggregate on a completely different device.
// So every hog holder is excluded from the tap; see EQDeviceEngine+Lifecycle.swift.

/// PID holding exclusive (hog-mode) access to `deviceID`'s output, or -1 if the device
/// is not hogged. Never throws — callers scan every device and one bad read must not
/// abort the scan (same convention as getDeviceTransportType).
func getDeviceHogModePID(_ deviceID: AudioDeviceID) -> pid_t {
    getProperty(deviceID, selector: kAudioDevicePropertyHogMode,
                scope: kAudioObjectPropertyScopeOutput) ?? -1
}

/// Translate a PID to its CoreAudio process object (the identifier
/// `CATapDescription`'s exclusion list is keyed by).
func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
    var translateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid = pid
    var processObjectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try caCheck(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &translateAddress,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &size, &processObjectID),
        "Failed to translate PID to process object")
    return processObjectID
}

/// Process objects of every process currently holding hog mode on ANY output device.
/// Unresolvable PIDs are dropped rather than failing the scan — an exclusion we can't
/// express is strictly better than no tap at all.
func hoggingProcessObjectIDs() -> [AudioObjectID] {
    guard let devices = try? getAllDeviceIDs() else { return [] }
    var result: [AudioObjectID] = []
    for device in devices where deviceHasOutputStreams(device) {
        let pid = getDeviceHogModePID(device)
        guard pid != -1, pid != getpid() else { continue }
        guard let object = try? translatePIDToProcessObject(pid),
              object != kAudioObjectUnknown else { continue }
        result.append(object)
    }
    return result
}

// MARK: - Process-output introspection (watchdog discriminator)

/// Whether any process OTHER than `excluding` is currently outputting audio. Lets the
/// watchdog distinguish a genuine silent-input fault (chain broken while audio plays)
/// from a benign idle system (nothing playing, zeros are correct). Uses macOS 14.2+
/// constants `kAudioHardwarePropertyProcessObjectList`/`kAudioProcessPropertyIsRunningOutput`
/// — VERIFY THESE NAMES ON THE FIRST MAC BUILD; if missing from the SDK, delete this
/// helper and never auto-escalate to permissionSuspected (keep only the silent rebuild path).
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
