// Controllable double for CoreAudioTapServicing (see Sources/Engine/CoreAudioTapServicing.swift).
// Lets a test: simulate any single call in EQDeviceEngine's start/stop path succeeding or
// failing independently with a chosen OSStatus; simulate the aggregate device's reported
// stream format / nominal sample rate (needed for performStart()'s format-verification
// step — see CoreAudioTapServicing's own doc comments); inspect the exact call
// sequence (teardown-order assertions per CLAUDE.md § Invariants); hook any individual call to peek
// at engine/context state at that precise moment (used by the bypass-ordering regression
// test); and, most importantly, capture the real IOProc block (`AudioDeviceIOBlock`) that
// EQDeviceEngine hands to `createIOProcIDWithBlock`, built by the REAL production
// `makeIOBlock` factory (EQIOProcFactory.swift) — so a test can invoke it directly with
// synthetic AudioBufferLists and exercise the actual RT callback code.

import AudioToolbox
import CoreAudio
import Foundation
@testable import eqYourMacbook

final class FakeCoreAudioTapService: CoreAudioTapServicing, @unchecked Sendable {

    enum Call: Equatable {
        case createProcessTap
        case destroyProcessTap
        case createAggregateDevice
        case destroyAggregateDevice
        case createIOProcIDWithBlock
        case destroyIOProcID
        case startDevice
        case stopDevice
        case getStreamFormat
        case getDeviceNominalSampleRate
        case hoggingProcessObjectIDs
        case voiceSessionProcessObjectIDs
        case getBufferFrameSizeRange
        case setBufferFrameSize
        case getBufferFrameSize
        case getOutputLatencyFrames
        case isProcessRunningDuplex
    }

    // MARK: - Call log (order + count) — read this to assert CLAUDE.md § Invariants' teardown order.
    private(set) var callLog: [Call] = []

    /// Fires at the START of every protocol method, before its simulated effect/return —
    /// lets a test peek at engine/RT-context state at the exact moment a given CoreAudio
    /// call would have happened (e.g. "is context.bypass already 1 by the time
    /// startDevice() is called?").
    var onCall: ((Call) -> Void)?

    // MARK: - Controllable failure knobs (default: everything succeeds)
    var failCreateProcessTap = false
    var failCreateAggregateDevice = false
    var failCreateIOProcIDWithBlock = false
    var failStartDevice = false
    var failDestroyProcessTap = false
    var failDestroyAggregateDevice = false
    var failDestroyIOProcID = false
    var failStopDevice = false
    /// Generic OSStatus surfaced by any of the failure knobs above (real CoreAudio
    /// failures are never `noErr`, and the exact value doesn't matter to
    /// EQDeviceEngine — it only ever surfaces it in an error string).
    var failureStatus: OSStatus = -1

    // MARK: - Format-verification knobs (performStart's step 3.5 / step 4).
    // Defaults describe a valid Float32 stereo format at 48 kHz — the happy-path
    // default, so a test only needs to override what it's specifically probing.
    var streamFormatToReturn: AudioStreamBasicDescription? = FakeCoreAudioTapService.validFloat32StereoFormat
    var nominalSampleRateToReturn: Double = 48_000

    /// Hog-mode holders reported to performStart()'s tap-exclusion step. Default: none
    /// hogged, matching an idle system. A test flips this mid-run to simulate another
    /// app taking (or releasing) exclusive access to a device.
    var hoggingProcessObjectsToReturn: [AudioObjectID] = []

    /// Processes in a live duplex voice session (a call), the tap's second exclusion
    /// source. Default: nobody is on a call. A test flips this mid-run to simulate a call
    /// starting or ending without one actually happening.
    var voiceSessionProcessObjectsToReturn: [AudioObjectID] = []

    // IO buffer pin (performStart step 4.5). The fake models a HAL that grants exactly
    // what is asked within `bufferFrameSizeRangeToReturn`; `failSetBufferFrameSize`
    // models a refusal, which must be non-fatal (the pin is a tuning, not a dependency).
    var bufferFrameSizeRangeToReturn: ClosedRange<UInt32>? = 32...4096
    var failSetBufferFrameSize = false
    private(set) var lastRequestedBufferFrameSize: UInt32?
    private var grantedBufferFrameSize: UInt32 = 512
    var outputLatencyFramesToReturn: (latency: UInt32, safetyOffset: UInt32)? = (0, 0)

    /// Process objects the fake HAL reports as running input AND output. Put the engine's
    /// own `ownProcessObjectID` here to simulate the idle latch (CLAUDE.md § Invariants).
    var duplexProcessObjectsToReturn: Set<AudioObjectID> = []

    /// The exclusion list of the most recently created tap — lets a test assert exactly
    /// which processes were excluded (CATapDescription exposes no readable accessor
    /// contract we want to depend on, so it is captured here at creation time).
    private(set) var lastTapExcludedProcesses: [AudioObjectID]?

    static var validFloat32StereoFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    // MARK: - Synthetic handles returned on success
    private var nextObjectID: AudioObjectID = 1000
    private(set) var lastCreatedTapID: AudioObjectID?
    private(set) var lastCreatedAggregateID: AudioObjectID?
    private(set) var lastCreatedIOProcID: AudioDeviceIOProcID?

    /// THE key capability: the real production IOProc block, captured at
    /// createIOProcIDWithBlock time, so a test can drive it directly.
    private(set) var capturedIOBlock: AudioDeviceIOBlock?

    init() {}

    // MARK: - CoreAudioTapServicing

    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus {
        callLog.append(.createProcessTap)
        onCall?(.createProcessTap)
        guard !failCreateProcessTap else {
            tapID = AudioObjectID(kAudioObjectUnknown)
            return failureStatus
        }
        let id = nextObjectID; nextObjectID += 1
        tapID = id
        lastCreatedTapID = id
        lastTapExcludedProcesses = description.processes
        return noErr
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        callLog.append(.destroyProcessTap)
        onCall?(.destroyProcessTap)
        return failDestroyProcessTap ? failureStatus : noErr
    }

    func createAggregateDevice(_ description: CFDictionary, _ deviceID: inout AudioObjectID) -> OSStatus {
        callLog.append(.createAggregateDevice)
        onCall?(.createAggregateDevice)
        guard !failCreateAggregateDevice else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            return failureStatus
        }
        let id = nextObjectID; nextObjectID += 1
        deviceID = id
        lastCreatedAggregateID = id
        return noErr
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        callLog.append(.destroyAggregateDevice)
        onCall?(.destroyAggregateDevice)
        return failDestroyAggregateDevice ? failureStatus : noErr
    }

    func createIOProcIDWithBlock(_ procID: inout AudioDeviceIOProcID?, _ deviceID: AudioObjectID,
                                  _ queue: DispatchQueue?, _ block: @escaping AudioDeviceIOBlock) -> OSStatus {
        callLog.append(.createIOProcIDWithBlock)
        onCall?(.createIOProcIDWithBlock)
        capturedIOBlock = block
        guard !failCreateIOProcIDWithBlock else {
            procID = nil
            return failureStatus
        }
        // VERIFIED ON FIRST MAC BUILD: AudioDeviceIOProcID is a C function pointer, not an
        // opaque pointer — bitcast a synthetic pointer-sized token instead (never invoked).
        let rawToken = UnsafeMutableRawPointer(bitPattern: Int(nextObjectID))
        nextObjectID += 1
        let token = unsafeBitCast(rawToken, to: AudioDeviceIOProcID?.self)
        procID = token
        lastCreatedIOProcID = token
        return noErr
    }

    func destroyIOProcID(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID) -> OSStatus {
        callLog.append(.destroyIOProcID)
        onCall?(.destroyIOProcID)
        return failDestroyIOProcID ? failureStatus : noErr
    }

    func startDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus {
        callLog.append(.startDevice)
        onCall?(.startDevice)
        return failStartDevice ? failureStatus : noErr
    }

    func stopDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus {
        callLog.append(.stopDevice)
        onCall?(.stopDevice)
        return failStopDevice ? failureStatus : noErr
    }

    func getStreamFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        callLog.append(.getStreamFormat)
        onCall?(.getStreamFormat)
        return streamFormatToReturn
    }

    func getDeviceNominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        callLog.append(.getDeviceNominalSampleRate)
        onCall?(.getDeviceNominalSampleRate)
        return nominalSampleRateToReturn
    }

    func hoggingProcessObjectIDs() -> [AudioObjectID] {
        callLog.append(.hoggingProcessObjectIDs)
        onCall?(.hoggingProcessObjectIDs)
        return hoggingProcessObjectsToReturn
    }

    func voiceSessionProcessObjectIDs() -> [AudioObjectID] {
        callLog.append(.voiceSessionProcessObjectIDs)
        onCall?(.voiceSessionProcessObjectIDs)
        return voiceSessionProcessObjectsToReturn
    }
    func getBufferFrameSizeRange(_ deviceID: AudioObjectID) -> ClosedRange<UInt32>? {
        callLog.append(.getBufferFrameSizeRange)
        onCall?(.getBufferFrameSizeRange)
        return bufferFrameSizeRangeToReturn
    }
    func setBufferFrameSize(_ deviceID: AudioObjectID, _ frames: UInt32) -> OSStatus {
        callLog.append(.setBufferFrameSize)
        onCall?(.setBufferFrameSize)
        lastRequestedBufferFrameSize = frames
        guard !failSetBufferFrameSize else { return failureStatus }
        grantedBufferFrameSize = frames
        return noErr
    }
    func getBufferFrameSize(_ deviceID: AudioObjectID) -> UInt32? {
        callLog.append(.getBufferFrameSize)
        onCall?(.getBufferFrameSize)
        return grantedBufferFrameSize
    }
    func getOutputLatencyFrames(_ deviceID: AudioObjectID) -> (latency: UInt32, safetyOffset: UInt32)? {
        callLog.append(.getOutputLatencyFrames)
        onCall?(.getOutputLatencyFrames)
        return outputLatencyFramesToReturn
    }
    func isProcessRunningDuplex(_ processObject: AudioObjectID) -> Bool {
        callLog.append(.isProcessRunningDuplex)
        onCall?(.isProcessRunningDuplex)
        return duplexProcessObjectsToReturn.contains(processObject)
    }
}
