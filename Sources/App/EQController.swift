import CoreAudio
import Foundation
import SwiftUI
import Combine
import ServiceManagement
import os.log

// MARK: - DisplayStatus

/// At most one engine ever runs — the enabled device that's ALSO the OS's current
/// default-output route (docs/CONTRACT.md's Reconciliation/Engage-policy) — so this
/// is only the aggregate master-switch/health line the footer shows; per-device
/// running state lives in DeviceRowView instead.
enum DisplayStatus: Equatable {
    case active                        // master enabled (per-device rows show detail)
    case disabled
    case permissionNeeded              // any engine's watchdog detected all-zero input
    case error(String)
}

// MARK: - EQController

@MainActor
final class EQController: ObservableObject {

    // MARK: Published state

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.isEnabled)
            coordinator.setGloballyEnabled(isEnabled)
            updateStatus()
        }
    }

    @Published var bands: [EQBand] {
        didSet {
            coordinator.updateBands(bands)
            schedulePersistBands()
        }
    }

    @Published var isABBypassed: Bool = false {
        didSet { coordinator.updateBypass(isABBypassed) }
    }

    @Published var gainStagingEnabled: Bool {
        didSet {
            defaults.set(gainStagingEnabled, forKey: Keys.gainStagingEnabled)
            coordinator.setGainStagingEnabled(gainStagingEnabled)
        }
    }

    // No storage needed; SMAppService is the source of truth. Sends objectWillChange
    // manually so the Toggle re-renders after register/unregister.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                os_log("Launch-at-login toggle failed: %{public}@", log: .default, type: .error,
                       error.localizedDescription)
            }
            objectWillChange.send()
        }
    }

    @Published private(set) var status: DisplayStatus = .disabled
    @Published private(set) var deviceRows: [DeviceRowViewModel] = []

    // MARK: Private state

    private let coordinator: OutputDeviceEQCoordinating
    private let defaults: UserDefaults
    private var lastAggregateStatus = AggregateEngineStatus(anyRunning: false, permissionNeeded: false, errorMessage: nil)

    var statusDetail: String {
        Self.statusDetail(for: status, runningDeviceCount: deviceRows.filter(\.isRunning).count)
    }

    nonisolated static func statusDetail(for status: DisplayStatus, runningDeviceCount: Int) -> String {
        switch status {
        case .active:
            if runningDeviceCount == 0 { return "EQ enabled — no output devices selected" }
            if runningDeviceCount == 1 { return "EQ active on 1 device" }
            return "EQ active on \(runningDeviceCount) devices"
        case .disabled:         return "EQ is off"
        case .permissionNeeded: return "System Audio Recording permission needed"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    // MARK: Init

    init(coordinator: OutputDeviceEQCoordinating = OutputDeviceEQCoordinator(), defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults

        let storedEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        isEnabled = storedEnabled
        gainStagingEnabled = defaults.object(forKey: Keys.gainStagingEnabled) as? Bool ?? true

        if let data = defaults.data(forKey: Keys.bands),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: data) {
            bands = decoded
        } else {
            bands = EQPresetData.mbaTameTheHighs.bands
        }

        // Fans updates out to every per-device EQDeviceEngine and forwards their
        // delegate callbacks back up as one aggregate status.
        coordinator.onDeviceRowsChanged = { [weak self] rows in
            self?.deviceRows = rows
            self?.updateStatus()
        }
        coordinator.onAggregateStatusChanged = { [weak self] aggregate in
            guard let self else { return }
            self.lastAggregateStatus = aggregate
            self.updateStatus()
        }
        coordinator.setGainStagingEnabled(gainStagingEnabled)
        coordinator.updateBands(bands)
        coordinator.start()
        coordinator.setGloballyEnabled(isEnabled)

        updateStatus()
    }

    // MARK: DisplayStatus derivation

    /// permissionSuspected beats errorMessage: a TCC denial causes start() to fail,
    /// and permissionNeeded gives an actionable recovery path over a raw CoreAudio error.
    nonisolated static func deriveStatus(
        isEnabled: Bool,
        permissionSuspected: Bool,
        errorMessage: String?
    ) -> DisplayStatus {
        guard isEnabled else { return .disabled }
        if permissionSuspected { return .permissionNeeded }
        if let errorMessage { return .error(errorMessage) }
        return .active
    }

    private func updateStatus() {
        status = Self.deriveStatus(
            isEnabled: isEnabled,
            permissionSuspected: lastAggregateStatus.permissionNeeded,
            errorMessage: lastAggregateStatus.errorMessage)
    }

    // MARK: Device checkboxes

    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID) {
        coordinator.setDeviceEnabled(enabled, deviceID: deviceID)
    }

    // MARK: Privacy Settings

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Persistence helpers

    // Debounces the UserDefaults write: `bands`'s didSet fires at slider-drag rate
    // (30-60+/sec), so cancel-and-reschedule collapses a whole drag into one write.
    // Accepted risk: a kill within this window loses the last change (no
    // applicationWillTerminate hook to flush on quit).
    private static let persistBandsDebounceInterval: TimeInterval = 0.4
    private var persistBandsWorkItem: DispatchWorkItem?

    private func schedulePersistBands() {
        persistBandsWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistBands()
        }
        persistBandsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistBandsDebounceInterval, execute: workItem)
    }

    private func persistBands() {
        if let data = try? JSONEncoder().encode(bands) {
            defaults.set(data, forKey: Keys.bands)
        }
    }

    // MARK: Keys

    private enum Keys {
        static let isEnabled = "eqym.isEnabled"
        static let bands     = "eqym.bands"
        static let gainStagingEnabled = "eqym.gainStagingEnabled"
    }
}
