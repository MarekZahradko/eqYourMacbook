// Watches every output device's hog-mode (exclusive-access) owner and reports changes.
//
// Why the engine needs this: a process taking hog mode makes macOS re-route the default
// output elsewhere, which is what lets an engine start on (say) the built-in speakers
// while the hogging process is still playing to the device it locked. The global process
// tap would then capture and mute that process, hijacking its audio onto our device.
// EQDeviceEngine excludes hog holders from the tap; this monitor tells it when that set
// changed so it can rebuild. The default-output-route listener is NOT sufficient: hog
// mode can be taken or released without the default route moving at all.

import CoreAudio
import Foundation

@MainActor final class HogModeMonitor {

    private var onChange: (() -> Void)?
    /// One hog-mode listener per output device, keyed by device so re-syncing after a
    /// device-list change can add/remove exactly the difference.
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var hogModeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyHogMode,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {}

    /// Idempotent: a second call while already running just replaces the callback.
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        syncDeviceListeners()
        guard deviceListListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Registered on DispatchQueue.main below, so this already runs on main.
            MainActor.assumeIsolated {
                guard let self else { return }
                // A hot-plugged device may already be hogged, and an unplugged one may
                // have been the only hog holder — both change the exclusion set, so
                // re-register AND report.
                self.syncDeviceListeners()
                self.onChange?()
            }
        }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, DispatchQueue.main, block)
    }

    /// Idempotent. Removes every listener installed by start().
    func stop() {
        for (device, block) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        if let block = deviceListListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, DispatchQueue.main, block)
            deviceListListener = nil
        }
        onChange = nil
    }

    /// Bring the per-device hog listeners in line with the current output-device set.
    private func syncDeviceListeners() {
        let current = Set((try? getAllDeviceIDs())?.filter(deviceHasOutputStreams) ?? [])

        for device in deviceListeners.keys where !current.contains(device) {
            if let block = deviceListeners.removeValue(forKey: device) {
                AudioObjectRemovePropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
            }
        }
        for device in current where deviceListeners[device] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            deviceListeners[device] = block
            AudioObjectAddPropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
        }
    }
}
