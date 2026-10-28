import SwiftUI

/// Read-only presentation of the same target and scale used by the display card.
struct BrightnessHUDView: View {
    @ObservedObject var display: DisplayInfo

    private var isHDR: Bool { display.brightness > 100 }
    private var hdrEnabled: Bool { display.maximumBrightness > 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isHDR ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isHDR ? Color.blue : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(isHDR ? "HDR \(BrightnessScale.hdrStep(display.brightness)) of 3" : "Native brightness")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(Int(display.brightness.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHDR ? Color.blue : Color.primary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 3) {
                ForEach(0..<BrightnessScale.nativeSegments, id: \.self) { index in
                    segment(fill: min(1, max(0, display.brightness / 100 * 16 - Double(index))), color: .orange)
                }
                if hdrEnabled {
                    ForEach(0..<BrightnessScale.hdrLevels.count, id: \.self) { index in
                        segment(fill: BrightnessScale.hdrStep(display.brightness) > index ? 1 : 0, color: .blue)
                            .overlay(alignment: .leading) {
                                if index == 0 {
                                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 1, height: 14).offset(x: -2)
                                }
                            }
                    }
                }
            }
            .frame(height: 7)
            HStack {
                Text("FreeDisplay")
                Spacer()
                if isHDR {
                    Text(display.hdrBrightnessMultiplier <= 1.01 ? "HDR temporarily unavailable" : "HDR brightness")
                } else {
                    Text(hdrEnabled ? "100% native · 3 HDR steps" : "100% maximum")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(display.name), brightness \(Int(display.brightness.rounded())) percent\(isHDR ? ", HDR step \(BrightnessScale.hdrStep(display.brightness)) of 3" : "")")
    }

    private func segment(fill: Double, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * fill)
                }
        }
    }
}
