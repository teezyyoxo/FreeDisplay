import Foundation

/// User-facing control levels, independent of the display's changing EDR multiplier.
enum BrightnessScale {
    static let hdrLevels: [Double] = [110, 120, 130]
    static let hdrMaximum: Double = 130
    static let nativeSegments = 16

    static func normalized(_ value: Double, maximum: Double) -> Double {
        guard value.isFinite else { return 100 }
        let clamped = max(0, min(maximum, value))
        guard clamped > 100 else { return clamped }
        return min(maximum, 100 + ((clamped - 100) / 10).rounded() * 10)
    }

    static func next(_ value: Double, direction: Double, nativeStep: Double, maximum: Double) -> Double {
        if direction > 0 {
            if value < 100 { return min(100, value + nativeStep) }
            return min(maximum, (hdrLevels.first { $0 > value + 0.001 } ?? maximum))
        }
        if value > 100 {
            return ([100] + hdrLevels).last { $0 < value - 0.001 } ?? 100
        }
        return max(0, value - nativeStep)
    }

    static func hdrStep(_ level: Double) -> Int {
        max(0, min(hdrLevels.count, Int(((level - 100) / 10).rounded())))
    }

    static func multiplier(level: Double, headroom: Double) -> Double {
        1 + max(0, headroom - 1) * Double(hdrStep(level)) / Double(hdrLevels.count)
    }

    /// Reserve one equal-width segment for each normal key step and each HDR step.
    static func fraction(_ level: Double, minimum: Double = 0, maximum: Double) -> Double {
        let nativeFraction = max(0, min(1, (level - minimum) / (100 - minimum)))
        guard maximum > 100 else { return nativeFraction }
        let total = Double(nativeSegments + hdrLevels.count)
        if level <= 100 { return nativeFraction * Double(nativeSegments) / total }
        return (Double(nativeSegments) + (level - 100) / 10) / total
    }

    static func level(at fraction: Double, minimum: Double = 0, maximum: Double) -> Double {
        let fraction = max(0, min(1, fraction))
        guard maximum > 100 else { return minimum + fraction * (100 - minimum) }
        let position = fraction * Double(nativeSegments + hdrLevels.count)
        if position <= Double(nativeSegments) {
            return minimum + position / Double(nativeSegments) * (100 - minimum)
        }
        return normalized(100 + (position - Double(nativeSegments)) * 10, maximum: maximum)
    }

    /// Convert legacy EDR-multiplier percentages to the three-step scale.
    static func migratedLegacyLevel(_ level: Double, potentialHeadroom: Double) -> Double {
        guard level > 100, potentialHeadroom > 1.05 else { return min(100, level) }
        let progress = max(0, min(1, (level / 100 - 1) / (potentialHeadroom - 1)))
        return 100 + max(1, (progress * Double(hdrLevels.count)).rounded()) * 10
    }
}
