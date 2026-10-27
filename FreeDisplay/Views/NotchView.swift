import SwiftUI
import AppKit

/// Displays notch information and provides a toggle to cover the notch with a black overlay.
/// Only visible for built-in displays that actually have a notch (safeAreaInsets.top > 0).
struct NotchView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHidingNotch: Bool = false
    @State private var isHovered = false

    private func syncState() {
        isHidingNotch = NotchOverlayManager.shared.isShowingOverlay(for: display.displayID)
    }

    private var notchHeight: CGFloat {
        guard display.isBuiltin,
              let screen = NSScreen.screen(for: display.displayID)
        else { return 0 }
        return screen.safeAreaInsets.top
    }

    var body: some View {
        if notchHeight > 0 {
            VStack(alignment: .leading, spacing: 0) {
                // Info row
                HStack(spacing: 12) {
                    MenuItemIcon(systemName: "camera.aperture", color: .blue)
                    Text("Notch")
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Text(String(format: "%.0f pt", notchHeight))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)

                // Hide/show toggle
                HStack(spacing: 12) {
                    MenuItemIcon(systemName: isHidingNotch ? "eye.slash" : "eye", color: .gray)
                    Text("Hide Notch Area")
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Spacer()
                    Toggle("", isOn: $isHidingNotch)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: isHidingNotch) { _, newValue in
                            if newValue {
                                NotchOverlayManager.shared.showOverlay(for: display.displayID)
                            } else {
                                NotchOverlayManager.shared.hideOverlay(for: display.displayID)
                            }
                        }
                        .help("Show a black overlay over the menu bar area to hide the notch")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous)
                        .fill(.primary.opacity(isHovered ? 0.08 : 0))
                )
                .onHover { isHovered = $0 }
            }
            .onAppear {
                syncState()
            }
        }
    }
}
