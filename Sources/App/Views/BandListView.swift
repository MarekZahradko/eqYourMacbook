import SwiftUI

// MARK: - BandListView

struct BandListView: View {
    @EnvironmentObject private var controller: EQController
    @ObservedObject var presetStore: PresetStore

    // Tracks the name being typed when saving a new preset.
    @State private var savePresetName: String = ""
    @State private var showingSaveField: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Band list: max ~5 rows visible
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($controller.bands) { $band in
                        BandRowView(band: $band) {
                            deleteBand(id: band.id)
                        }
                        .padding(.horizontal, 10)
                        Divider()
                    }
                    if controller.bands.isEmpty {
                        Text("No bands — tap + to add")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                    }
                }
            }
            .frame(maxHeight: 5 * 54)  // ~5 rows at ~54 pt each

            // Footer toolbar
            HStack(spacing: 8) {
                // Add band
                Button(action: addBand) {
                    Label("Add Band", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(controller.bands.count >= EQPresetData.maxBandCount)

                Spacer()

                // Preset menu
                Menu {
                    ForEach(presetStore.all) { preset in
                        Button(preset.name) { applyPreset(preset) }
                    }
                    Divider()
                    Button("Save as preset…") { showingSaveField.toggle() }
                    if presetStore.customPresets.count > 0 {
                        Menu("Delete preset") {
                            ForEach(presetStore.customPresets) { preset in
                                Button(preset.name) { presetStore.delete(id: preset.id) }
                            }
                        }
                    }
                } label: {
                    Label("Presets", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
                .menuStyle(.automatic)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Inline save-preset field
            if showingSaveField {
                HStack {
                    TextField("Preset name", text: $savePresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Save") {
                        let trimmed = savePresetName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            presetStore.save(name: trimmed, bands: controller.bands)
                        }
                        savePresetName = ""
                        showingSaveField = false
                    }
                    .font(.caption)
                    .disabled(savePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        savePresetName = ""
                        showingSaveField = false
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Actions

    private func addBand() {
        let freq = EQPresetData.suggestFrequency(for: controller.bands)
        controller.bands.append(EQBand(frequency: freq, gain: 0))
    }

    private func deleteBand(id: UUID) {
        controller.bands.removeAll { $0.id == id }
        // Zero bands is valid; EQCurveView renders a flat midline, engine runs identity passthrough.
    }

    private func applyPreset(_ preset: EQPresetData) {
        // Flat preset has an empty bands array by design — allow it through unchanged.
        controller.bands = preset.bands
    }
}
