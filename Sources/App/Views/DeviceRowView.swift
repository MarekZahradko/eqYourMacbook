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
            if row.isChecked && row.isRunning {
                // This device is both user-enabled and the OS's current default
                // output route, with its engine confirmed running — EQ is live here.
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
                    .help("EQ is active on this device")
            }
        }
        .opacity(row.isInteractable ? 1 : 0.4)
    }
}
