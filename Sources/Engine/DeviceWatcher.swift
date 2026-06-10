// Listens for default-output-device changes and classifies the route as
// built-in speakers vs. anything else. The controller uses this to engage the EQ
// only on built-in speakers (PLAN.md §1 "engage / disengage"). The watcher itself
// never starts/stops the engine — it only reports the route.

import CoreAudio
import Foundation

@MainActor final class DeviceWatcher {

    private(set) var currentRoute: OutputRoute
    var onRouteChange: ((OutputRoute) -> Void)?   // fired on the main actor

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        currentRoute = DeviceWatcher.computeRoute()
    }

    /// Idempotent. Installs the default-output-device listener on the system object.
    func start() {
        guard listenerBlock == nil else { return }
        // Re-evaluate now in case the route changed between init and start.
        currentRoute = DeviceWatcher.computeRoute()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // FIX 11: the listener is already registered on DispatchQueue.main (the
            // dispatch-queue argument below), so the block runs on main — no redundant
            // inner async hop. Re-isolate to the main actor and handle directly.
            MainActor.assumeIsolated { self?.handleChange() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    /// Idempotent. Removes the listener.
    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listenerBlock = nil
    }

    private func handleChange() {
        let newRoute = DeviceWatcher.computeRoute()
        guard newRoute != currentRoute else { return }   // fire only on actual changes
        currentRoute = newRoute
        onRouteChange?(newRoute)
    }

    /// Classify the current default output device. `.builtInSpeakers(id)` when its
    /// transport type is built-in AND it has output streams; otherwise `.other(name)`.
    static func computeRoute() -> OutputRoute {
        guard let deviceID = try? getDefaultOutputDeviceID() else {
            return .other("Unknown")
        }
        if getDeviceTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn,
           deviceHasOutputStreams(deviceID) {
            return .builtInSpeakers(deviceID)
        }
        let name = (try? getDeviceName(deviceID)) ?? "Unknown"
        return .other(name)
    }
}
