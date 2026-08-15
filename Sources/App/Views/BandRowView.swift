import SwiftUI

// MARK: - BandRowView

struct BandRowView: View {
    @Binding var band: EQBand
    let onDelete: () -> Void

    /// Log-scale slider bounds, derived from EQBand.frequencyRange (the canonical range).
    private var logFreqMin: Double { log10(Double(EQBand.frequencyRange.lowerBound)) }
    private var logFreqMax: Double { log10(Double(EQBand.frequencyRange.upperBound)) }

    /// Log-scale slider position (0...1) ↔ EQBand.frequencyRange
    private var logSliderValue: Double {
        get { (log10(Double(band.frequency)) - logFreqMin) / (logFreqMax - logFreqMin) }
    }

    /// Gain is not meaningful for pass/notch filter types.
    private var gainDisabled: Bool {
        FilterType.gainless.contains(band.filterType)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Picker("", selection: $band.filterType) {
                    ForEach(FilterType.allCases, id: \.self) { ft in
                        Text(ft.displayName).tag(ft)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 92)
                .labelsHidden()
                .onChange(of: band.filterType) { _, newType in
                    if FilterType.gainless.contains(newType) {
                        // Reset to Butterworth-ish slope; gain is meaningless here.
                        band.bandwidth = EQBand.qToOctaves(0.707)
                        band.gain = 0
                    }
                }

                Slider(
                    value: Binding(
                        get: { logSliderValue },
                        set: { v in
                            let freq = pow(10.0, v * (logFreqMax - logFreqMin) + logFreqMin)
                            band.frequency = Float(freq.rounded())
                        }
                    ),
                    in: 0...1
                )

                Text(band.frequencyLabel)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)

                Button(action: { band.muted.toggle() }) {
                    Image(systemName: band.muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundColor(band.muted ? .secondary : .primary)
                }
                .buttonStyle(.borderless)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

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
                    // Range matches EQBand.bandwidthRange (0.05...4.0) exactly, so the
                    // stepper can't drift from the model's enforced invariant. Step stays
                    // 0.1 despite the 0.05 floor: SwiftUI clamps the final decrement to the
                    // lower bound (0.1 → 0.05) rather than under/overshooting, so the floor
                    // remains reachable even though it isn't a multiple of the step.
                    value: $band.bandwidth,
                    in: EQBand.bandwidthRange,
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
