import SwiftUI

// MARK: - BandListView

struct BandListView: View {
    @EnvironmentObject private var controller: EQController
    @ObservedObject var presetStore: PresetStore

    @State private var savePresetName: String = ""
    @State private var showingSaveField: Bool = false

    private static let rowHeight: CGFloat = 54
    private static let maxVisibleRows = 5

    /// MenuBarExtra(.window) sizes to content's ideal size, and ScrollView's ideal
    /// height is zero, so an explicit height is required. Grows with band count
    /// (one row for the empty-state text), caps at 5 rows, scrolls beyond.
    private var listHeight: CGFloat {
        CGFloat(min(max(controller.bands.count, 1), Self.maxVisibleRows)) * Self.rowHeight
    }

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: listHeight)
            .scrollIndicators(controller.bands.count > Self.maxVisibleRows ? .automatic : .never)

            HStack(spacing: 8) {
                Button(action: addBand) {
                    Label("Add Band", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(controller.bands.count >= EQPresetData.maxBandCount)

                Spacer()

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
        // Zero bands is valid: flat midline in the curve, identity passthrough in the engine.
    }

    private func applyPreset(_ preset: EQPresetData) {
        // Flat preset has an empty bands array by design — allow it through unchanged.
        controller.bands = preset.bands
    }
}
