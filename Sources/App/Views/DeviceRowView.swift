import SwiftUI

// MARK: - DeviceRowView

struct DeviceRowView: View {
    let row: DeviceRowViewModel
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { row.isChecked }, set: onToggle)) {
                Text(row.name)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            if row.isChecked && !row.isRunning {
                // Checked but not yet running (starting up, or failed).
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
                    .font(.caption2)
            }
        }
    }
}
