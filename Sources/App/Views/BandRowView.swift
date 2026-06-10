import SwiftUI

// MARK: - BandRowView

struct BandRowView: View {
    @Binding var band: EQBand
    let onDelete: () -> Void

    // Computed log-scale slider position (0...1) ↔ frequency 20–20000 Hz
    private var logSliderValue: Double {
        get { (log10(Double(band.frequency)) - log10(20.0)) / (log10(20000.0) - log10(20.0)) }
    }

    /// Gain is not meaningful for pass/notch filter types.
    private var gainDisabled: Bool {
        switch band.filterType {
        case .lowPass, .highPass, .bandPass, .notch: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: type, frequency slider, mute, delete
            HStack(spacing: 6) {
                Picker("", selection: $band.filterType) {
                    ForEach(FilterType.allCases, id: \.self) { ft in
                        Text(ft.shortLabel).tag(ft)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .labelsHidden()
                .onChange(of: band.filterType) { newType in
                    switch newType {
                    case .lowPass, .highPass, .bandPass, .notch:
                        // Reset to Butterworth-ish slope; gain is meaningless for pass/notch.
                        band.bandwidth = EQBand.qToOctaves(0.707)
                        band.gain = 0
                    case .parametric, .lowShelf, .highShelf:
                        break   // keep whatever the user had
                    }
                }

                // Log-frequency slider
                Slider(
                    value: Binding(
                        get: { logSliderValue },
                        set: { v in
                            let freq = pow(10.0, v * (log10(20000.0) - log10(20.0)) + log10(20.0))
                            band.frequency = Float(freq.rounded())
                        }
                    ),
                    in: 0...1
                )

                Text(band.frequencyLabel)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)

                // Mute
                Button(action: { band.muted.toggle() }) {
                    Image(systemName: band.muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundColor(band.muted ? .secondary : .primary)
                }
                .buttonStyle(.borderless)

                // Delete
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            // Row 2: gain slider + bandwidth stepper
            HStack(spacing: 6) {
                Text("Gain")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)

                Slider(value: $band.gain, in: -UIConstants.maxGainDB...UIConstants.maxGainDB)
                    .disabled(gainDisabled)
                    .opacity(gainDisabled ? 0.35 : 1)

                Text(gainDisabled ? "—" : band.gainLabel)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)

                Stepper(
                    value: $band.bandwidth,
                    in: Float(0.1)...Float(4.0),
                    step: Float(0.1)
                ) {
                    Text(band.bandwidthLabel(asQ: false))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - FilterType short labels (view-layer only)

private extension FilterType {
    var shortLabel: String {
        switch self {
        case .parametric: return "Bell"
        case .lowShelf:   return "Lo S"
        case .highShelf:  return "Hi S"
        case .lowPass:    return "LP"
        case .highPass:   return "HP"
        case .bandPass:   return "BP"
        case .notch:      return "Notch"
        }
    }
}
