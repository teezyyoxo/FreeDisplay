import SwiftUI
import AppKit

/// Captures the next key press (including brightness keys) as a shortcut binding.
private struct UncheckedEvent: @unchecked Sendable {
    let value: NSEvent?
}

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var message: String?

    private var monitor: Any?

    func begin(onCapture: @escaping (ShortcutBinding?) -> Void) {
        end()
        message = nil
        isRecording = true
        // The global tap would otherwise swallow brightness keys before this window sees them.
        BrightnessKeyService.shared.setRecordingShortcut(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                UncheckedEvent(value: self.handle(event, onCapture: onCapture))
            }.value
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        BrightnessKeyService.shared.setRecordingShortcut(false)
    }

    private func handle(_ event: NSEvent, onCapture: (ShortcutBinding?) -> Void) -> NSEvent? {
        if event.type == .keyDown {
            let bareKey = UInt64(event.modifierFlags.rawValue) & ShortcutKey.modifierMask == 0
            if bareKey, event.keyCode == 53 {
                end()
                return nil
            }
            if bareKey, event.keyCode == 51 || event.keyCode == 117 {
                end()
                onCapture(nil)
                return nil
            }
        }

        guard let binding = ShortcutBinding(event: event) else {
            // Non-brightness media keys (volume, playback) keep working while recording.
            return event.type == .systemDefined ? event : nil
        }

        guard binding.isSafeToCapture else {
            message = "Add a modifier (⌃ ⌥ ⇧ ⌘) so normal typing isn't affected."
            return nil
        }

        end()
        onCapture(binding)
        return nil
    }
}

// MARK: - Row

struct ShortcutRecorderRow: View {
    let action: BrightnessShortcutAction
    @ObservedObject private var settings = SettingsService.shared
    @StateObject private var recorder = ShortcutRecorder()

    private var binding: ShortcutBinding? { settings.binding(for: action) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(action: toggleRecording) { field }
                    .buttonStyle(.plain)
                    .help(recorder.isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to record a shortcut")

                if binding != nil, !recorder.isRecording {
                    Button { settings.setBinding(nil, for: action) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                    .accessibilityLabel("Clear \(action.group.title) \(action.title) shortcut")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let message = recorder.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onDisappear { recorder.end() }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.end()
        } else {
            recorder.begin { settings.setBinding($0, for: action) }
        }
    }

    @ViewBuilder
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if recorder.isRecording {
                Text("Press shortcut…")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else if let binding {
                ShortcutChips(parts: binding.parts)
            } else {
                Text("Record")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 28)
        .background(.primary.opacity(recorder.isRecording ? 0.0 : 0.07), in: shape)
        .overlay {
            shape.strokeBorder(recorder.isRecording ? Color.accentColor : .primary.opacity(0.1), lineWidth: recorder.isRecording ? 1.5 : 0.5)
        }
        .contentShape(shape)
    }
}

struct ShortcutChips: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .padding(.horizontal, part.count > 1 ? 7 : 5)
                    .padding(.vertical, 1.5)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: " "))
    }
}
