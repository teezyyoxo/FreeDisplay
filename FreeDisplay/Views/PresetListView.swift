import SwiftUI

/// User-saved display presets plus the control to save a new one.
struct PresetListView: View {
    @ObservedObject private var presetService = PresetService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(presetService.presets) { preset in
                PresetRow(
                    preset: preset,
                    isCurrentMatch: presetService.currentPresetMatch() == preset.id,
                    isApplying: presetService.applyingPresetID == preset.id
                )
            }

            SavePresetView()
        }
    }
}

struct PresetRow: View {
    let preset: DisplayPreset
    let isCurrentMatch: Bool
    let isApplying: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                MenuItemIcon(systemName: preset.icon, color: isCurrentMatch ? .accentColor : .gray, size: 30)
            }

            Text(preset.name)
                .font(.system(.body, design: .rounded, weight: .medium))
                .lineLimit(1)

            Spacer()

            if isCurrentMatch { FDTag(text: "Current", color: .accentColor) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !PresetService.shared.isApplying else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            Button(role: .destructive) {
                PresetService.shared.deletePreset(id: preset.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .disabled(PresetService.shared.isApplying)
        .help("Apply this preset")
    }
}
