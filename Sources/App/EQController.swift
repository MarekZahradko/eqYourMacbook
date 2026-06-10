import SwiftUI
import ServiceManagement
import os.log

// MARK: - DisplayStatus

enum DisplayStatus: Equatable {
    case active                        // EQ engaged on built-in speakers
    case standby(otherOutput: String)  // enabled but output is not built-in
    case disabled                      // user switched off
    case permissionNeeded              // watchdog detected all-zero input
    case error(String)
}

// MARK: - EQController

@MainActor
final class EQController: ObservableObject, EQEngineDelegate {

    // MARK: Published state

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
            reevaluate()
        }
    }

    @Published var bands: [EQBand] {
        didSet {
            if case .running = engine.state {
                engine.update(bands: bands)
            }
            persistBands()
        }
    }

    @Published var isABBypassed: Bool = false {
        didSet { engine.isBypassed = isABBypassed }
    }

    // Computed — no storage needed; SMAppService is the SSOT.
    // Manually sends objectWillChange so the Toggle re-renders after register/unregister.
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

    // MARK: Private state

    private let engine = EQEngine()
    private let watcher = DeviceWatcher()
    private var permissionSuspected = false

    // Keeps the launchAtLogin computed property stable across reads in a single
    // rendering pass (SMAppService.mainApp.status is not free to call repeatedly).
    var statusDetail: String {
        switch status {
        case .active:                    return "EQ active on built-in speakers"
        case .standby(let name):         return "Standby — output: \(name)"
        case .disabled:                  return "EQ is off"
        case .permissionNeeded:          return "System Audio Recording permission needed"
        case .error(let msg):            return "Error: \(msg)"
        }
    }

    // MARK: Init

    init() {
        // Load persisted enabled flag; default true on first launch.
        let storedEnabled = UserDefaults.standard.object(forKey: Keys.isEnabled) as? Bool ?? true
        isEnabled = storedEnabled

        // Load persisted bands; default to MBA preset on first launch.
        if let data = UserDefaults.standard.data(forKey: Keys.bands),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: data) {
            bands = decoded
        } else {
            bands = EQPresetData.mbaTameTheHighs.bands
        }

        // Wire engine and watcher.
        engine.delegate = self
        watcher.onRouteChange = { [weak self] route in
            self?.handleRouteChange(route)
        }
        watcher.start()

        // Initial policy evaluation against the current route.
        reevaluate()
    }

    // MARK: Engage policy

    /// Pure function — testable without CoreAudio or any instance state.
    nonisolated static func shouldRun(isEnabled: Bool, route: OutputRoute) -> Bool {
        guard isEnabled else { return false }
        if case .builtInSpeakers = route { return true }
        return false
    }

    func reevaluate() {
        let route = watcher.currentRoute
        if Self.shouldRun(isEnabled: isEnabled, route: route) {
            engine.start(bands: bands)
        } else {
            engine.stop()
        }
        updateStatus()
    }

    // MARK: Route change

    private func handleRouteChange(_ route: OutputRoute) {
        reevaluate()
    }

    // MARK: DisplayStatus derivation

    /// Pure function — testable without any instance.
    nonisolated static func deriveStatus(
        isEnabled: Bool,
        route: OutputRoute,
        engineState: EngineState,
        permissionSuspected: Bool
    ) -> DisplayStatus {
        guard isEnabled else { return .disabled }
        if case .other(let name) = route { return .standby(otherOutput: name) }
        // permissionSuspected beats .failed: TCC denial causes start() to fail;
        // showing permissionNeeded gives the user an actionable recovery path.
        if permissionSuspected { return .permissionNeeded }
        switch engineState {
        case .running:       return .active
        case .failed(let m): return .error(m)
        case .stopped:       return .standby(otherOutput: "—")
        }
    }

    private func updateStatus() {
        status = Self.deriveStatus(
            isEnabled: isEnabled,
            route: watcher.currentRoute,
            engineState: engine.state,
            permissionSuspected: permissionSuspected
        )
    }

    // MARK: EQEngineDelegate

    func engine(_ engine: EQEngine, didChangeState state: EngineState) {
        if case .running = state { permissionSuspected = false }
        updateStatus()
    }

    func engineSuspectsPermissionDenied(_ engine: EQEngine) {
        permissionSuspected = true
        updateStatus()
    }

    // MARK: Privacy Settings

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Persistence helpers

    private func persistBands() {
        if let data = try? JSONEncoder().encode(bands) {
            UserDefaults.standard.set(data, forKey: Keys.bands)
        }
    }

    // MARK: Keys

    private enum Keys {
        static let isEnabled = "eqym.isEnabled"
        static let bands     = "eqym.bands"
    }
}
