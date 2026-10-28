import SwiftUI
import AppKit

// MARK: - Metrics

enum FD {
    static let cardRadius: CGFloat = 24
    static let rowRadius: CGFloat = 14
    static let panelWidth: CGFloat = 400
}

// MARK: - Glass

@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass on macOS 26+, a frosted material with a hairline edge on earlier releases.
    @ViewBuilder
    func fdGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.25)) }
                }
                .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6) }
        }
    }
}

/// Lets neighbouring glass shapes blend and sample the same backdrop.
struct FDGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Card

struct FDCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fdGlass(RoundedRectangle(cornerRadius: FD.cardRadius, style: .continuous))
    }
}

// MARK: - Section Header

struct FDSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.9)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Icon Tile

/// Soft tinted glass tile behind an SF Symbol.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .background { tile }
    }

    @ViewBuilder
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(color.opacity(0.55)), in: shape)
        } else {
            shape
                .fill(LinearGradient(colors: [color.opacity(0.78), color.opacity(0.52)], startPoint: .top, endPoint: .bottom))
                .overlay { shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.6) }
        }
    }
}

// MARK: - Tag

struct FDTag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.16), in: Capsule())
    }
}

// MARK: - Icon Button

struct FDIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fdGlass(Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Glass Slider

struct SliderValueMapping {
    let fraction: (Double) -> Double
    let level: (Double) -> Double
    let adjusted: (Double, Double) -> Double
}

/// Continuous capsule slider with a glass knob.
struct GlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double? = nil
    var tint: Color = .accentColor
    var referenceValue: Double? = nil
    var referenceValues: [Double] = []
    var valueMapping: SliderValueMapping? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let travel = max(1, proxy.size.width - height)
            let fraction = valueMapping?.fraction(value) ?? ((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knobX = height / 2 + travel * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }

                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, knobX + height / 2))

                ForEach(referenceValues + (referenceValue.map { [$0] } ?? []), id: \.self) { reference in
                    let referenceFraction = valueMapping?.fraction(reference) ?? ((reference - range.lowerBound) / (range.upperBound - range.lowerBound))
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: 2, height: reference == 100 ? height - 8 : height - 16)
                        .offset(x: height / 2 + travel * referenceFraction - 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                Circle()
                    .fill(.white.opacity(0.001))
                    .frame(width: height - 2, height: height - 2)
                    .fdGlass(Circle(), tint: .white.opacity(0.35), interactive: true)
                    .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.8) }
                    .shadow(color: .black.opacity(0.22), radius: isDragging ? 7 : 4, y: 2)
                    .scaleEffect(isDragging ? 1.08 : 1)
                    .offset(x: knobX - height / 2 + 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let ratio = min(max((gesture.location.x - height / 2) / travel, 0), 1)
                        var newValue = valueMapping?.level(ratio) ?? (range.lowerBound + ratio * (range.upperBound - range.lowerBound))
                        if let step { newValue = (newValue / step).rounded() * step }
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            let delta = (step ?? (range.upperBound - range.lowerBound) / 20)
            switch direction {
            case .increment: value = valueMapping?.adjusted(value, 1) ?? min(value + delta, range.upperBound)
            case .decrement: value = valueMapping?.adjusted(value, -1) ?? max(value - delta, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

// MARK: - Expandable Row

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            MenuItemIcon(systemName: icon, color: iconColor, size: 30)
            Text(label)
                .font(.system(.body, design: .rounded, weight: .medium))
            Spacer(minLength: 8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { isExpanded.toggle() }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
    }
}
