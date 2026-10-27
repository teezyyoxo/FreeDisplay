import SwiftUI

struct HiDPIRowView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHovered = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isHiDPIOn: Bool = false

    /// macOS only reads display overrides when the display reconnects.
    private var needsReconnect: Bool {
        isHiDPIOn && !display.availableModes.contains {
            $0.isHiDPI && min($0.width, $0.height) >= 720
        }
    }

    var body: some View {
        if display.isBuiltin {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                MenuItemIcon(systemName: "sparkles", color: .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HiDPI Mode")
                        .font(.system(.body, design: .rounded, weight: .medium))
                    if !isHiDPIOn {
                        Text("Administrator privileges required")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if needsReconnect {
                        Text("Unplug and replug the display to apply")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else if isHiDPIOn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isLoading else { return }
                toggle()
            }
            .onHover { isHovered = $0 }
            .onAppear {
                isHiDPIOn = HiDPIService.shared.isHiDPIEnabled(
                    vendor: display.vendorNumber,
                    product: display.modelNumber
                )
            }
            .alert("HiDPI Operation Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let msg = errorMessage {
                    Text(msg)
                }
            }
        }
    }

    private func toggle() {
        isLoading = true
        if isHiDPIOn {
            let err = HiDPIService.shared.disableHiDPI(
                for: display.displayID,
                vendor: display.vendorNumber,
                product: display.modelNumber
            )
            isLoading = false
            if let err {
                errorMessage = err
            } else {
                isHiDPIOn = false
            }
        } else {
            Task {
                // Use the highest available mode as native resolution,
                // not display.pixelWidth which is the CURRENT resolution
                let (nativeW, nativeH) = display.nativeResolution
                let err = await HiDPIService.shared.enableHiDPI(
                    for: display.displayID,
                    vendor: display.vendorNumber,
                    product: display.modelNumber,
                    nativeWidth: nativeW,
                    nativeHeight: nativeH
                )
                isLoading = false
                if let err {
                    errorMessage = err
                } else {
                    isHiDPIOn = true
                    HiDPIService.shared.refreshModes(for: display)
                }
            }
        }
    }
}
