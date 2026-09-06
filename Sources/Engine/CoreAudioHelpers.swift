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

// MARK: - Process-object introspection
//
// Shared by the watchdog's "is anyone else playing?" discriminator and by the tap's
// voice-session exclusion. Both walk `kAudioHardwarePropertyProcessObjectList` and read
// per-process boolean IO flags, so the enumeration and the flag read live here once.
// macOS 14.2+ constants — VERIFIED ON FIRST MAC BUILD (they resolve against the CLT SDK).

/// Every process object the HAL currently knows about. Empty on any read failure —
/// callers treat "no processes" as "nothing to act on", which is the safe default for
/// both of them (no silence escalation; no extra tap exclusions).
func allProcessObjectIDs() -> [AudioObjectID] {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
          size > 0 else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else {
        return []
    }
    return processes
}

/// Read one of a process object's `UInt32` IO flags (`kAudioProcessPropertyIsRunningInput`
/// / `…IsRunningOutput`). False on a failed read — a process we can't interrogate is
/// treated as idle rather than aborting the whole scan (same convention as
/// getDeviceTransportType).
func processIsRunning(_ processObject: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var valueSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &valueSize, &value) == noErr else {
        return false
    }
    return value != 0
}

// MARK: - Voice sessions (tap exclusion)
//
// WHY (observed 2026-08-26, WhatsApp): a process running INPUT and OUTPUT at once is in a
// duplex voice session — a call. macOS drives those through VoiceProcessingIO, which
// ducks "other (i.e. non-voice) audio" by default (AudioUnitProperties.h,
// kAUVoiceIOProperty_OtherAudioDuckingConfiguration). Our tap is `.mutedWhenTapped`, so
// it silences the caller at the source and re-renders its audio from OUR process — which
// the OS then classifies as that very "other audio" and ducks. The call ducks itself:
// WhatsApp calls were near-inaudible until the EQ was toggled off. (Teams is unaffected:
// it is a native macOS app doing its own AEC over the plain HAL, with no
// VoiceProcessingIO session.) Bypass does NOT help — it keeps the tap alive and we are
// still the process rendering the audio. The only fix is to keep such a process OUT of
// the tap, so its audio never leaves its own voice session. Consequence, accepted
// deliberately: calls are not equalized. Everything else still is.

/// Process objects currently running INPUT and OUTPUT simultaneously — i.e. in a live
/// duplex voice session. Our own process can match this too (the aggregate's tap side is
/// an input stream), which is harmless: EQDeviceEngine.tapExcludedProcessObjects unions
/// our own process object in unconditionally and deduplicates, so the resulting exclusion
/// set is identical either way and stays stable across rebuilds.
/// Running input AND output at once — the HAL's view of "in a voice session". Also what
/// the watchdog reads about OUR OWN process object to detect the idle latch (CLAUDE.md
/// § Invariants): once the tap has carried audio, coreaudiod keeps reporting our aggregate
/// client as duplex and treats it as an always-active call — full device cost and a held
/// sleep assertion — until the stack is rebuilt.
func processIsRunningDuplex(_ processObject: AudioObjectID) -> Bool {
    processIsRunning(processObject, kAudioProcessPropertyIsRunningInput)
        && processIsRunning(processObject, kAudioProcessPropertyIsRunningOutput)
}

func voiceSessionProcessObjectIDs() -> [AudioObjectID] {
    allProcessObjectIDs().filter(processIsRunningDuplex)
}

// MARK: - Process-output introspection (watchdog discriminator)

/// Whether any process whose audio SHOULD be reaching our tap is currently outputting
/// audio. Lets the watchdog distinguish a genuine silent-input fault (chain broken while
/// audio plays) from a benign idle system (nothing playing, zeros are correct).
///
/// `excluding` is the tap's full exclusion set, not just our own process: a hog holder or
/// a process in a call is deliberately NOT tapped, so its output legitimately never
/// reaches us. Counting it here would make every call — or any exclusive-mode playback —
/// look like a broken chain and escalate to a false "TCC denied" suspicion.
func anyOtherProcessOutputtingAudio(excluding excludedProcessObjectIDs: [AudioObjectID]) -> Bool {
    let excluded = Set(excludedProcessObjectIDs)
    return allProcessObjectIDs().contains { process in
        !excluded.contains(process)
            && processIsRunning(process, kAudioProcessPropertyIsRunningOutput)
    }
}

// MARK: - IO buffer size / latency (aggregate device, our client)

/// Frames per IO cycle for OUR client of `deviceID` (`kAudioDevicePropertyBufferFrameSize`
/// is a per-client setting, so this never affects other processes using the device).
func getBufferFrameSize(_ deviceID: AudioObjectID) -> UInt32? {
    getProperty(deviceID, selector: kAudioDevicePropertyBufferFrameSize)
}

func setBufferFrameSize(_ deviceID: AudioObjectID, _ frames: UInt32) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = frames
    return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &value)
}

func getBufferFrameSizeRange(_ deviceID: AudioObjectID) -> ClosedRange<UInt32>? {
    guard let range: AudioValueRange = getProperty(deviceID, selector: kAudioDevicePropertyBufferFrameSizeRange),
          range.mMinimum >= 0, range.mMaximum >= range.mMinimum else { return nil }
    return UInt32(range.mMinimum)...UInt32(range.mMaximum)
}

/// Frames the device reports it adds on the output side beyond the IO buffer itself:
/// `kAudioDevicePropertyLatency` (device/driver latency) and
/// `kAudioDevicePropertySafetyOffset` (how far ahead of the hardware head the HAL must
/// write). Read for diagnostics only (logged at start-up; `scripts/eqym-ctl.sh latency`
/// correlates the log line with the measured end-to-end figure).
func getOutputLatencyFrames(_ deviceID: AudioObjectID) -> (latency: UInt32, safetyOffset: UInt32)? {
    guard let latency: UInt32 = getProperty(deviceID, selector: kAudioDevicePropertyLatency,
                                            scope: kAudioObjectPropertyScopeOutput),
          let safety: UInt32 = getProperty(deviceID, selector: kAudioDevicePropertySafetyOffset,
                                           scope: kAudioObjectPropertyScopeOutput) else { return nil }
    return (latency, safety)
}
