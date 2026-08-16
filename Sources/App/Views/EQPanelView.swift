import SwiftUI

// MARK: - EQPanelView

struct EQPanelView: View {
    @EnvironmentObject private var controller: EQController
    @StateObject private var presetStore = PresetStore()

    var body: some View {
        VStack(spacing: 0) {

            HStack(alignment: .top) {
                Text("eqYourMacbook")
                    .font(.headline)
                Spacer()
                // Compare toggle hidden — users found it redundant with EQ (same
                // perceived effect), even though it's functionally distinct under
                // the hood (bypass vs. disable). Kept wired to isABBypassed/engine
                // so it can be reintroduced with a clearer design later.
                // Toggle("Compare", isOn: $controller.isABBypassed)
                //     .toggleStyle(.button)
                //     .controlSize(.small)
                //     .help("Hold to A/B compare — bypasses EQ without restarting the engine")

                Toggle("EQ", isOn: $controller.isEnabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .tint(.accentColor)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 6) {
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

            // Redundant with the "EQ" toggle above while active — the toggle's tint
            // already says "enabled", and per-device status now shows on DeviceRowView.
            // Shown only for states that need the user's attention/action.
            if controller.status != .active {
                StatusFooterView()

                Divider()
            }

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
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(width: UIConstants.panelWidth)
    }
}
