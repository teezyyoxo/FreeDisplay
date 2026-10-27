import SwiftUI

/// Per-display brightness control, always visible on the display card.
struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localBrightness: Double = 50
    @State private var isDragging = false
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            GlassSlider(value: $localBrightness, range: 5...100, step: 1, tint: .orange) { editing in
                isDragging = editing
                guard !editing else { return }
                Task { @MainActor in
                    BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display)
                    updateDDCStatus()
                }
                lastDDCWrite = Date()
            }
            .accessibilityLabel("Display brightness")
            .help("Drag to adjust brightness")
            .onChange(of: localBrightness) { _, newValue in
                guard isDragging else { return }
                // Throttle DDC to ~100ms to avoid flooding the I2C bus; drag-end flushes the final value.
                let now = Date()
                if ddcStatus == true && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                    display.brightness = newValue
                    return
                }
                lastDDCWrite = now
                display.brightness = newValue
                Task { @MainActor in
                    await BrightnessService.shared.setBrightness(newValue, for: display)
                }
            }

            Image(systemName: "sun.max.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("\(Int(localBrightness))%")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 44, alignment: .trailing)
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            updateDDCStatus()
        }
        .onChange(of: display.brightness) { _, newValue in
            if !isDragging && abs(newValue - localBrightness) >= 1 {
                localBrightness = newValue
            }
        }
    }

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
    }
}

/// How brightness is applied to a display, shown as a small tag on its card.
struct BrightnessModeTag: View {
    @ObservedObject var display: DisplayInfo
    @State private var ddcStatus: Bool? = nil

    var body: some View {
        Group {
            if display.isBuiltin {
                FDTag(text: "System", color: .blue)
            } else if let ddcStatus {
                FDTag(text: ddcStatus ? "DDC" : "Software", color: ddcStatus ? .green : .orange)
                    .help(ddcStatus ? "Brightness is set directly on the display" : "Brightness is simulated in software")
            }
        }
        .task(id: display.brightness) {
            ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
        }
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging = false
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        return displays.map(\.brightness).reduce(0, +) / Double(displays.count)
    }

    private var anyDDC: Bool {
        displays.contains { BrightnessService.shared.isDDCAvailable(for: $0.displayID) == true }
    }

    var body: some View {
        HStack(spacing: 10) {
            MenuItemIcon(systemName: "sun.max.fill", color: .orange, size: 30)

            GlassSlider(value: $combinedBrightness, range: 5...100, step: 1, tint: .orange) { editing in
                isDragging = editing
                guard !editing else { return }
                Task { @MainActor in
                    for display in displays {
                        BrightnessService.shared.setBrightnessSmooth(combinedBrightness, for: display)
                    }
                }
                lastDDCWrite = Date()
            }
            .accessibilityLabel("Combined brightness")
            .onChange(of: combinedBrightness) { _, newValue in
                guard isDragging else { return }
                let now = Date()
                if anyDDC && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                    for display in displays { display.brightness = newValue }
                    return
                }
                lastDDCWrite = now
                Task { @MainActor in
                    for display in displays {
                        display.brightness = newValue
                        await BrightnessService.shared.setBrightness(newValue, for: display)
                    }
                }
            }

            Text("\(Int(combinedBrightness))%")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .onAppear { combinedBrightness = averageBrightness }
    }
}
