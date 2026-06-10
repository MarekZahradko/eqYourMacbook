import SwiftUI

// MARK: - EQPanelView

struct EQPanelView: View {
    @EnvironmentObject private var controller: EQController
    @StateObject private var presetStore = PresetStore()

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            HStack {
                Text("eqYourMacbook")
                    .font(.headline)
                Spacer()
                // A/B Compare: pressing holds bypass; releasing restores.
                // Toggle(.button) gives the hold-to-compare feel without custom gestures.
                Toggle("Compare", isOn: $controller.isABBypassed)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Hold to A/B compare — bypasses EQ without restarting the engine")

                // Master enable toggle
                Toggle("EQ", isOn: $controller.isEnabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // ── Frequency Response Curve ──────────────────────────────────────
            EQCurveView(
                bands: controller.bands,
                dimmed: !controller.isEnabled || controller.isABBypassed
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // ── Band List + Preset toolbar ────────────────────────────────────
            BandListView(presetStore: presetStore)

            Divider()

            // ── Bottom footer ─────────────────────────────────────────────────
            StatusFooterView()

            Divider()

            // ── Settings row ──────────────────────────────────────────────────
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
