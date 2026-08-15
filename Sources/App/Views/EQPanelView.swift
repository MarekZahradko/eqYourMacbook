import SwiftUI

// MARK: - EQPanelView

struct EQPanelView: View {
    @EnvironmentObject private var controller: EQController
    @StateObject private var presetStore = PresetStore()

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text("eqYourMacbook")
                    .font(.headline)
                Spacer()
                // Toggle(.button) gives the hold-to-compare feel without custom gestures.
                Toggle("Compare", isOn: $controller.isABBypassed)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Hold to A/B compare — bypasses EQ without restarting the engine")

                Toggle("EQ", isOn: $controller.isEnabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(controller.deviceRows) { row in
                    DeviceRowView(row: row) { checked in
                        controller.setDeviceEnabled(checked, deviceID: row.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            EQCurveView(
                bands: controller.bands,
                dimmed: !controller.isEnabled || controller.isABBypassed
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            BandListView(presetStore: presetStore)

            Divider()

            StatusFooterView()

            Divider()

            HStack {
                Toggle("Gain-Staging", isOn: $controller.gainStagingEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Automatically lowers the overall level to avoid clipping when any band boosts above 0 dB. Has no effect if every band is at 0 dB or cut.")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.launchAtLogin = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: UIConstants.panelWidth)
    }
}
