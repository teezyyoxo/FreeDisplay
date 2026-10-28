import SwiftUI
import Combine

/// Per-display brightness control, always visible on the display card.
struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            brightnessSlider
            if display.supportsHDRBrightness || display.hdrBrightnessEnabled {
                hdrControls
            } else if !display.isBuiltin {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Extra brightness requires an HDR display with HDR enabled.")
                        .foregroundStyle(.secondary)
                    Button("Display settings") { HDRBrightnessService.shared.openDisplaySettings() }
                        .buttonStyle(.link)
                }
                .font(.caption2)
            }
        }
    }

    private var brightnessSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            GlassSlider(
                value: Binding(get: { display.brightness }, set: {
                    BrightnessService.shared.setBrightnessFromSlider($0, for: display)
                }),
                range: 5...display.maximumBrightness, step: 1,
                tint: display.brightness > 100 ? .blue : .orange,
                referenceValues: display.maximumBrightness > 100 ? [100, 110, 120] : [],
                valueMapping: SliderValueMapping(
                    fraction: { BrightnessScale.fraction($0, minimum: 5, maximum: display.maximumBrightness) },
                    level: { BrightnessScale.level(at: $0, minimum: 5, maximum: display.maximumBrightness) },
                    adjusted: { max(5, BrightnessScale.next($0, direction: $1, nativeStep: 1, maximum: display.maximumBrightness)) }
                )
            ) { editing in
                if editing {
                    BrightnessService.shared.cancelAnimation(for: display.displayID)
                } else {
                    BrightnessService.shared.setBrightnessFromSlider(display.brightness, for: display, isFinal: true)
                }
            }
            .accessibilityLabel("Display brightness")
            .help(display.maximumBrightness > 100 ? "Normal brightness through 100%, then HDR steps at 110%, 120%, and 130%" : "Drag to adjust brightness")

            Image(systemName: "sun.max.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("\(Int(display.brightness.rounded()))%")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(display.brightness > 100 ? Color.blue : Color.primary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var hdrControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { display.hdrBrightnessEnabled },
                set: { HDRBrightnessService.shared.setEnabled($0, for: display) }
            )) {
                Text("HDR / XDR brightness")
                    .font(.system(.caption, design: .rounded, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!display.supportsHDRBrightness && !display.hdrBrightnessEnabled)
            .help("Unlock extra brightness above 100% on this display")

            if let error = display.hdrBrightnessError {
                Text(error).foregroundStyle(.orange)
            } else if display.hdrBrightnessEnabled {
                Text(hdrDescription).foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var hdrDescription: String {
        if !display.supportsHDRBrightness {
            return "HDR brightness is unavailable in the current display mode."
        }
        if display.brightness > 100 && display.hdrBrightnessMultiplier <= 1.01 {
            return "Waiting for HDR headroom. macOS controls the available brightness."
        }
        if display.brightness > 100 {
            let step = BrightnessScale.hdrStep(display.brightness)
            return "HDR \(step) of 3"
        }
        return "3 extra brightness steps: 110%, 120%, 130%."
    }

}

/// How brightness is applied to a display, shown as a small tag on its card.
struct BrightnessModeTag: View {
    @ObservedObject var display: DisplayInfo
    @State private var ddcStatus: Bool? = nil

    var body: some View {
        Group {
            if display.brightness > 100 {
                FDTag(text: "HDR", color: .blue)
            } else if display.isBuiltin {
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
    @ObservedObject private var hdrBrightnessService = HDRBrightnessService.shared
    @State private var combinedBrightness: Double = 50
    @State private var isDragging = false

    private var maximumBrightness: Double {
        hdrBrightnessService.maximumBrightness(for: displays)
    }

    private func apply(_ value: Double, isFinal: Bool = false) {
        combinedBrightness = BrightnessScale.normalized(value, maximum: maximumBrightness)
        for display in displays {
            BrightnessService.shared.setBrightnessFromSlider(combinedBrightness, for: display, isFinal: isFinal)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            MenuItemIcon(systemName: "sun.max.fill", color: .orange, size: 30)
            GlassSlider(
                value: Binding(get: { combinedBrightness }, set: { apply($0) }),
                range: 5...maximumBrightness, step: 1,
                tint: combinedBrightness > 100 ? .blue : .orange,
                referenceValues: maximumBrightness > 100 ? [100, 110, 120] : [],
                valueMapping: SliderValueMapping(
                    fraction: { BrightnessScale.fraction($0, minimum: 5, maximum: maximumBrightness) },
                    level: { BrightnessScale.level(at: $0, minimum: 5, maximum: maximumBrightness) },
                    adjusted: { max(5, BrightnessScale.next($0, direction: $1, nativeStep: 1, maximum: maximumBrightness)) }
                )
            ) { editing in
                isDragging = editing
                if !editing { apply(combinedBrightness, isFinal: true) }
            }
            .accessibilityLabel("Combined brightness")
            Text("\(Int(combinedBrightness.rounded()))%")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(combinedBrightness > 100 ? Color.blue : Color.primary)
                .frame(width: 56, alignment: .trailing)
        }
        .onReceive(Publishers.MergeMany(displays.map { display in
            display.$brightness.map { (display.displayID, $0) }.eraseToAnyPublisher()
        })) { id, brightness in
            guard !isDragging, !displays.isEmpty else { return }
            // @Published emits before assignment; use the received value for that display.
            combinedBrightness = displays.map { $0.displayID == id ? brightness : $0.brightness }.reduce(0, +) / Double(displays.count)
        }
        .onChange(of: maximumBrightness) { _, maximum in
            combinedBrightness = min(combinedBrightness, maximum)
        }
    }
}
