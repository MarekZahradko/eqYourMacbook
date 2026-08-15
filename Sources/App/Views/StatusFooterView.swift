import SwiftUI

// MARK: - StatusFooterView

struct StatusFooterView: View {
    @EnvironmentObject private var controller: EQController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
            Text(controller.statusDetail)
                .font(.caption)
                .foregroundColor(textColor)
                .lineLimit(1)

            Spacer()

            if case .permissionNeeded = controller.status {
                Button("Open Settings") {
                    controller.openPrivacySettings()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var icon: String {
        switch controller.status {
        case .active:           return "speaker.wave.2.fill"
        case .disabled:         return "power"
        case .permissionNeeded: return "lock.shield"
        case .error:            return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch controller.status {
        case .active:           return .green
        case .disabled:         return .orange
        case .permissionNeeded: return .orange
        case .error:            return .red
        }
    }

    private var textColor: Color {
        switch controller.status {
        case .error:            return .red
        case .permissionNeeded: return .orange
        default:                return .secondary
        }
    }
}
