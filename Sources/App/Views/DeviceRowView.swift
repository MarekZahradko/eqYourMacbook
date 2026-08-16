import SwiftUI

// MARK: - DeviceRowView

@MainActor
struct DeviceRowView: View {
    let row: DeviceRowViewModel
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { row.isChecked }, set: { onToggle($0) })) {
                Text(row.name)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            // Only one device can be EQ'd at a time (the process tap mutes audio
            // system-wide, not per-device) — every other row is disabled while one
            // is checked. This never depends on which device is the active output
            // route: the user must always be free to pick any listed device.
            .disabled(!row.isInteractable)
            Spacer()
            if row.isChecked && !row.isRunning {
                // Checked but this device isn't the current default output route
                // yet (or the engine is still starting up/failed) — EQ engages
                // automatically once macOS routes audio to it.
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
                    .font(.caption2)
                    .help("EQ will engage automatically once this becomes the active output")
            }
        }
        .opacity(row.isInteractable ? 1 : 0.4)
    }
}
