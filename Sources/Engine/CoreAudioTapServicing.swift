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
    // seam to cover these two reads (mirrored in docs/CONTRACT.md) closes that gap;
    // LiveCoreAudioTapService forwards to the exact same free functions, so production
    // behavior is unchanged.
    func getStreamFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription?
    func getDeviceNominalSampleRate(_ deviceID: AudioObjectID) -> Double
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
}
