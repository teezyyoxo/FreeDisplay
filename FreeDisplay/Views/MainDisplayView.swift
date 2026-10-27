import SwiftUI

/// Displays the "Set as Main Display" control inside DisplayDetailView.
/// Shows a status row when this display is already main, or a tappable button otherwise.
struct MainDisplayView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var errorMessage: String?
    @State private var isHovered = false
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if display.isMain {
                HStack(spacing: 12) {
                    MenuItemIcon(systemName: "star.fill", color: .blue)
                    Text("Main Display")
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Spacer()
                    FDTag(text: "Current", color: .blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            } else {
                HStack(spacing: 12) {
                    MenuItemIcon(systemName: "star", color: .blue)
                    Text("Set as Main Display")
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous)
                        .fill(.primary.opacity(isHovered ? 0.08 : 0))
                )
                .onHover { isHovered = $0 }
                .contentShape(Rectangle())
                .onTapGesture { isConfirming = true }
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .alert("Make \(display.name) the main display?", isPresented: $isConfirming) {
            Button("Set as Main Display") { setAsMain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The menu bar and Dock will move to this display.")
        }
    }

    private func setAsMain() {
        Task { @MainActor in
            let success = await ArrangementService.shared.setAsMainDisplay(
                display.displayID,
                among: displayManager.displays
            )
            if !success {
                errorMessage = "Failed to set main display"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                errorMessage = nil
            }
        }
    }
}
