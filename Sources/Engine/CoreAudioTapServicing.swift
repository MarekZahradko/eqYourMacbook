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
}
