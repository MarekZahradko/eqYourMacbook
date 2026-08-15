import Foundation
import Combine

// MARK: - PresetStore

final class PresetStore: ObservableObject {

    @Published private(set) var customPresets: [EQPresetData] = []

    /// All presets: built-ins first, then custom.
    var all: [EQPresetData] {
        EQPresetData.builtInPresets + customPresets
    }

    private let defaults: UserDefaults
    private let key = "eqym.customPresets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Mutating API

    func save(name: String, bands: [EQBand]) {
        let preset = EQPresetData(
            id: UUID(),
            name: name,
            bands: bands,
            isBuiltIn: false
        )
        customPresets.append(preset)
        persist()
    }

    /// No-op for built-in presets (isBuiltIn guard).
    func delete(id: UUID) {
        customPresets.removeAll { $0.id == id && !$0.isBuiltIn }
        persist()
    }

    // MARK: Private

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([EQPresetData].self, from: data)
        else { return }
        // Strip any built-ins that somehow ended up persisted (defensive).
        customPresets = decoded.filter { !$0.isBuiltIn }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customPresets) {
            defaults.set(data, forKey: key)
        }
    }
}
