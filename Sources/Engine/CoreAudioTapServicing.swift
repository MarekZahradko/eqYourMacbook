// CoreAudio-service protocol seam (+ live implementation) used by EQDeviceEngine's
// start/finishStart/teardown path so tests can substitute a double.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - CoreAudioTapServicing — narrow testability seam
//
// Wraps only the CoreAudio calls EQDeviceEngine's start/finishStart/teardown path
// makes, so a test double can assert call order without touching real hardware.
// Deliberately narrow — not a general CoreAudio abstraction layer.
protocol CoreAudioTapServicing {
    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
    func createAggregateDevice(_ description: CFDictionary, _ deviceID: inout AudioObjectID) -> OSStatus
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus
    func createIOProcIDWithBlock(_ procID: inout AudioDeviceIOProcID?, _ deviceID: AudioObjectID,
                                  _ queue: DispatchQueue?, _ block: @escaping AudioDeviceIOBlock) -> OSStatus
    func destroyIOProcID(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID) -> OSStatus
    func startDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus
    func stopDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus

    // Added alongside the test-fake build-out (see FakeCoreAudioTapService.swift):
    // performStart()'s step 3.5 format-verification and step 4 sample-rate read used to
    // call CoreAudioHelpers.swift's free functions directly, bypassing this seam — so no
    // test double could simulate a format mismatch/read failure, and a synthetic
    // AudioObjectID always fails the real AudioObjectGetPropertyData (not HAL-registered),
    // blocking performStart from reaching .running and everything downstream (RT
    // allocation, IOProc creation, bypass-publish ordering, gain-staging). Widening the
    // seam to cover these two reads closes that gap;
    // LiveCoreAudioTapService forwards to the exact same free functions, so production
    // behavior is unchanged.
    func getStreamFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription?
    func getDeviceNominalSampleRate(_ deviceID: AudioObjectID) -> Double

    // performStart()'s step 2 needs the set of processes holding exclusive (hog-mode)
    // access so it can exclude them from the global tap; rebuild() re-reads it once as a
    // staleness backstop when its reentrancy guard clears. Behind the seam for the same reason as the two reads above:
    // otherwise no test could drive the exclusion logic without a real hogged device.
    func hoggingProcessObjectIDs() -> [AudioObjectID]

    // The tap's second dynamic exclusion source, read at the same two points: processes
    // in a live duplex voice session (a call). See CoreAudioHelpers.swift's
    // voiceSessionProcessObjectIDs() for why they must not be tapped. Behind the seam so
    // a test can simulate a call starting/ending without one actually happening.
    func voiceSessionProcessObjectIDs() -> [AudioObjectID]

    // performStart()'s step 4.5 pins OUR client's IO buffer size on the aggregate instead
    // of inheriting coreaudiod's per-device default (CLAUDE.md § Invariants, "IO buffer
    // size"). The range read clamps the request, the read-back verifies what the HAL
    // actually granted, and the latency read is diagnostics for the start-up log line
    // that `scripts/eqym-ctl.sh latency` correlates with the measured figure.
    func getBufferFrameSizeRange(_ deviceID: AudioObjectID) -> ClosedRange<UInt32>?
    func setBufferFrameSize(_ deviceID: AudioObjectID, _ frames: UInt32) -> OSStatus
    func getBufferFrameSize(_ deviceID: AudioObjectID) -> UInt32?
    func getOutputLatencyFrames(_ deviceID: AudioObjectID) -> (latency: UInt32, safetyOffset: UInt32)?

    // The watchdog's idle-latch detector (CLAUDE.md § Invariants, "Idle latch") reads
    // whether the HAL currently reports OUR OWN process as duplex. Two property reads on
    // one object; behind the seam so a test can put the engine into the latched state.
    func isProcessRunningDuplex(_ processObject: AudioObjectID) -> Bool
}

/// Default live implementation: calls the real CoreAudio/AudioToolbox APIs directly.
struct LiveCoreAudioTapService: CoreAudioTapServicing {
    func createProcessTap(_ description: CATapDescription, _ tapID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateProcessTap(description, &tapID)
    }
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }
    func createAggregateDevice(_ description: CFDictionary, _ deviceID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description, &deviceID)
    }
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
    func createIOProcIDWithBlock(_ procID: inout AudioDeviceIOProcID?, _ deviceID: AudioObjectID,
                                  _ queue: DispatchQueue?, _ block: @escaping AudioDeviceIOBlock) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue, block)
    }
    func destroyIOProcID(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }
    func startDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStart(deviceID, procID)
    }
    func stopDevice(_ deviceID: AudioObjectID, _ procID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStop(deviceID, procID)
    }
    // Module-qualified: an unqualified call would resolve to `self` (infinite recursion)
    // since member lookup shadows top-level functions of the same name — same reasoning
    // as OutputDeviceEQCoordinator.anyOtherProcessOutputtingAudio's forwarding call.
    func getStreamFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        eqYourMacbook.getStreamFormat(deviceID)
    }
    func getDeviceNominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        eqYourMacbook.getDeviceNominalSampleRate(deviceID)
    }
    func hoggingProcessObjectIDs() -> [AudioObjectID] {
        eqYourMacbook.hoggingProcessObjectIDs()
    }
    func voiceSessionProcessObjectIDs() -> [AudioObjectID] {
        eqYourMacbook.voiceSessionProcessObjectIDs()
    }
    func getBufferFrameSizeRange(_ deviceID: AudioObjectID) -> ClosedRange<UInt32>? {
        eqYourMacbook.getBufferFrameSizeRange(deviceID)
    }
    func setBufferFrameSize(_ deviceID: AudioObjectID, _ frames: UInt32) -> OSStatus {
        eqYourMacbook.setBufferFrameSize(deviceID, frames)
    }
    func getBufferFrameSize(_ deviceID: AudioObjectID) -> UInt32? {
        eqYourMacbook.getBufferFrameSize(deviceID)
    }
    func getOutputLatencyFrames(_ deviceID: AudioObjectID) -> (latency: UInt32, safetyOffset: UInt32)? {
        eqYourMacbook.getOutputLatencyFrames(deviceID)
    }
    func isProcessRunningDuplex(_ processObject: AudioObjectID) -> Bool {
        eqYourMacbook.processIsRunningDuplex(processObject)
    }
}
