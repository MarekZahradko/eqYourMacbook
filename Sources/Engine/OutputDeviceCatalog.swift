// Enumerates output devices and reports hot-plug changes. The user checks exactly one
// device to EQ (mutual exclusion in the App layer); that device's engine only actually
// runs while it's also the OS's current default-output route (CLAUDE.md § Invariants'
// "Reconciliation"). OutputDeviceCatalog never starts/stops anything or decides
// routing — it only reports which devices exist; OutputDeviceEQCoordinator decides
// policy.

import CoreAudio
import Foundation

struct OutputDeviceInfo: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

@MainActor final class OutputDeviceCatalog {

    private(set) var devices: [OutputDeviceInfo] = []
    var onDevicesChanged: (([OutputDeviceInfo]) -> Void)?   // fired on the main actor

    /// Test-only injection hook: lets a test populate `devices` with a synthetic list
    /// WITHOUT ever calling `start()` (which would register a live
    /// `kAudioHardwarePropertyDevices` listener and run `enumerate()` against real
    /// CoreAudio). `devices`'s setter is `private` (deliberately, matching the
    /// `private(set) var devices`), so this narrow hook mirrors
    /// OutputDeviceEQCoordinator's `setDeviceRows(_:)`/`setEnabledDeviceUIDs(_:)` pattern
    /// (same-file-extension-only widening, not a public setter). Production code never
    /// calls this — `start()`/`handleDevicesChanged()` assign `devices` directly since
    /// they're declared in this same file.
    func setDevices(_ devices: [OutputDeviceInfo]) {
        self.devices = devices
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {}

    /// Idempotent. Installs the device-list listener on the system object and does an
    /// initial enumeration.
    func start() {
        devices = Self.enumerate()
        guard listenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Registered on DispatchQueue.main below, so this already runs on main.
            MainActor.assumeIsolated { self?.handleDevicesChanged() }
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

    private func handleDevicesChanged() {
        let new = Self.enumerate()
        guard Self.shouldPublishDeviceListChange(from: devices, to: new) else { return }
        devices = new
        onDevicesChanged?(new)
    }

    /// Enumerate all output-capable devices, built-in first (by transport type),
    /// remainder in HAL-returned order (NOT alphabetized).
    static func enumerate() -> [OutputDeviceInfo] {
        guard let ids = try? getAllDeviceIDs() else { return [] }
        let raw: [RawDeviceInfo] = ids.compactMap { id in
            // VERIFY ON FIRST MAC BUILD: confirm our own private aggregate devices
            // (kAudioAggregateDeviceIsPrivateKey: true) don't surface here. If they do,
            // filterAndSort already excludes them via the aggregate transport type.
            guard let uid = try? getDeviceUID(id), let name = try? getDeviceName(id) else { return nil }
            return RawDeviceInfo(id: id, uid: uid, name: name,
                                 transportType: getDeviceTransportType(id),
                                 hasOutputStreams: deviceHasOutputStreams(id))
        }
        return filterAndSort(raw)
    }
}

// MARK: - Pure ordering/filtering policy (testable without CoreAudio)

/// Plain-data mirror of what enumerate() gathers per device via CoreAudio calls,
/// so the ordering/filtering policy below can run with zero CoreAudio involvement.
struct RawDeviceInfo: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let hasOutputStreams: Bool
}

extension OutputDeviceCatalog {
    /// Pure policy: built-in devices first, aggregate-transport devices excluded,
    /// devices without output streams excluded, remainder in input order.
    nonisolated static func filterAndSort(_ raw: [RawDeviceInfo]) -> [OutputDeviceInfo] {
        var builtIn: [OutputDeviceInfo] = []
        var others: [OutputDeviceInfo] = []
        for device in raw {
            guard device.hasOutputStreams else { continue }
            guard device.transportType != kAudioDeviceTransportTypeAggregate else { continue }
            let info = OutputDeviceInfo(id: device.id, uid: device.uid, name: device.name,
                                        isBuiltIn: device.transportType == kAudioDeviceTransportTypeBuiltIn)
            if info.isBuiltIn {
                builtIn.append(info)
            } else {
                others.append(info)
            }
        }
        return builtIn + others
    }

    /// Pure: dedup decision for `handleDevicesChanged` — fire `onDevicesChanged` only
    /// when the newly enumerated list actually differs from what was last published.
    /// Extracted so the diff/dedup policy (as opposed to the live
    /// AudioObjectPropertyListenerBlock wiring around it) is testable without CoreAudio,
    /// matching how `filterAndSort` was already pulled out of `enumerate()`.
    nonisolated static func shouldPublishDeviceListChange(
        from oldDevices: [OutputDeviceInfo], to newDevices: [OutputDeviceInfo]
    ) -> Bool {
        oldDevices != newDevices
    }
}
