import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// MARK: - BrightnessAnimator

/// Manages smooth brightness transitions for a single display.
/// Cancels any in-progress animation when a new one starts, so rapid presses stay responsive.
/// All methods must be called on the main thread.
@MainActor
final class BrightnessAnimator {
    private var timer: Timer?
    private var currentStep: Int = 0
    private var totalSteps: Int = 0
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var stepHandler: ((Double, Bool) -> Void)?

    /// Cancel any running animation immediately.
    func cancel() {
        timer?.invalidate()
        timer = nil
        stepHandler = nil
    }

    /// Animate from `from` to `to` over `duration` seconds using `steps` discrete steps.
    /// `handler(value, isLast)` is called once per step on the main thread.
    /// Calling this cancels any previously running animation.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()

        // If from ≈ to, no animation needed — just apply final value.
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        let clampedSteps = max(2, steps)
        currentStep = 0
        totalSteps = clampedSteps
        startValue = from
        targetValue = to
        stepHandler = handler
        let interval = duration / Double(clampedSteps)

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentStep += 1
                let progress = Double(self.currentStep) / Double(self.totalSteps)
                // Ease-out curve: smoother deceleration at the end
                let eased = 1.0 - pow(1.0 - progress, 2.0)
                let value = self.startValue + (self.targetValue - self.startValue) * eased
                let isLast = self.currentStep >= self.totalSteps
                if isLast {
                    self.timer?.invalidate()
                    self.timer = nil
                }
                // Always pass the exact target on the last step to avoid floating-point drift.
                self.stepHandler?(isLast ? self.targetValue : value, isLast)
                if isLast { self.stepHandler = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - BrightnessService

final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private let queue = DispatchQueue(label: "com.freedisplay.brightness", qos: .userInitiated)

    // MARK: - Per-display Animators (main thread only)

    /// One animator per display. Accessed only on the main thread.
    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]
    @MainActor private var hardwareBrightnessTargets: [CGDirectDisplayID: Double] = [:]
    @MainActor private var appliedBrightness: [CGDirectDisplayID: Double] = [:]
    @MainActor private var lastSliderWrite: [CGDirectDisplayID: TimeInterval] = [:]

    @MainActor
    func invalidateHardwareBrightness(for displayID: CGDirectDisplayID) {
        hardwareBrightnessTargets.removeValue(forKey: displayID)
        appliedBrightness.removeValue(forKey: displayID)
        lastSliderWrite.removeValue(forKey: displayID)
    }

    @MainActor
    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let a = BrightnessAnimator()
        animators[displayID] = a
        return a
    }

    /// Cancel any running brightness animation for a display.
    /// Call this before starting an instant (non-animated) change.
    @MainActor
    func cancelAnimation(for displayID: CGDirectDisplayID) {
        animators[displayID]?.cancel()
    }

    // MARK: - Manual Adjust Cooldown

    /// Set when the user manually adjusts brightness; auto-brightness skips updates for 30 s.
    private(set) var lastManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.01–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    private func softBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        "fd.softBrightness_\(displayID)"
    }

    private func saveSoftwareBrightness(factor: Double, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(factor, forKey: softBrightnessKey(for: displayID))
    }

    private func loadSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = softBrightnessKey(for: displayID)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Returns the current software brightness factor for a display, or nil if not set.
    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Tracks whether hardware DDC is available for each external display.
    /// nil  = not yet determined
    /// true = DDC write succeeded at least once
    /// false = DDC write has failed; use software (gamma) fallback
    private var ddcAvailable: [CGDirectDisplayID: Bool] = [:]
    private let ddcAvailableLock = NSLock()

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    // MARK: - Public API

    @MainActor
    func refreshBrightness(for display: DisplayInfo) async {
        let previousBrightness = display.brightness
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        if isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness())
                }
            }
            if let b = brightness, display.brightness == previousBrightness, display.brightness <= 100 {
                display.brightness = b
            }
        } else {
            // First check if DDC is already known to be unavailable; if so skip the
            // async DDC call and just read the current gamma-derived brightness.
            let knownUnavailable: Bool = ddcAvailableLock.withLock {
                ddcAvailable[displayID] == false
            }
            if knownUnavailable {
                // Can't read brightness from gamma tables meaningfully; leave value as-is
                return
            }

            DDCService.shared.readAsync(
                displayID: displayID,
                command: DDCService.brightnessVCP
            ) { [weak self] result in
                guard let self else { return }
                if let result = result, result.max > 0 {
                    let brightness = Double(result.current) / Double(result.max) * 100.0
                    self.ddcAvailableLock.lock()
                    self.ddcAvailable[displayID] = true
                    self.ddcMaxBrightness[displayID] = result.max
                    self.ddcAvailableLock.unlock()
                    Task { @MainActor in
                        if display.brightness == previousBrightness, display.brightness <= 100 { display.brightness = brightness }
                    }
                } else {
                    // DDC read returned nil; mark unavailable
                    self.ddcAvailableLock.lock()
                    if self.ddcAvailable[displayID] == nil {
                        self.ddcAvailable[displayID] = false
                    }
                    self.ddcAvailableLock.unlock()
                }
            }
        }
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        setBrightnessImmediately(brightness, for: display, isAutoAdjust: isAutoAdjust)
    }

    /// Synchronous target updates keep drag bindings and keyboard readback in the same transaction.
    @MainActor
    func setBrightnessImmediately(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) {
        cancelAnimation(for: display.displayID)
        applyBrightness(brightness, for: display, isAutoAdjust: isAutoAdjust)
    }

    @MainActor
    func setBrightnessFromSlider(_ brightness: Double, for display: DisplayInfo, isFinal: Bool = false) {
        cancelAnimation(for: display.displayID)
        let now = Date.timeIntervalSinceReferenceDate
        let needsWrite = isFinal || brightness > 100 || display.brightness > 100
            || isDDCAvailable(for: display.displayID) != true
            || now - (lastSliderWrite[display.displayID] ?? 0) >= 0.1
        if needsWrite { lastSliderWrite[display.displayID] = now }
        applyBrightness(brightness, for: display, isAutoAdjust: false, writesHardware: needsWrite)
    }

    @MainActor
    private func applyBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool, updatesTarget: Bool = true, writesHardware: Bool = true) {
        guard brightness.isFinite else { return }
        let requested = HDRBrightnessService.shared.apply(brightness, for: display)
        let hardwareBrightness = min(100, requested)
        let displayID = display.displayID
        appliedBrightness[displayID] = requested
        if updatesTarget {
            display.brightness = requested
            SettingsService.shared.setBrightness(requested, for: displayID)
        }

        if !isAutoAdjust {
            manualAdjustLock.withLock { lastManualAdjustDate = Date() }
        }

        // Remove any old software dimming before entering the extended range.
        if requested > 100, (currentSoftwareBrightness(for: displayID) ?? 1) < 1 {
            setSoftwareBrightness(100, for: displayID)
        }
        guard writesHardware else { return }

        // Above 100%, only the EDR multiplier changes. Repeated 100% hardware
        // writes waste I2C traffic and can cause macOS to recalculate HDR headroom.
        let needsHardwareWrite = requested <= 100 || hardwareBrightnessTargets[displayID] != 100
        hardwareBrightnessTargets[displayID] = hardwareBrightness
        guard needsHardwareWrite else { return }

        if display.isBuiltin {
            queue.async { [weak self] in
                self?.setInternalBrightness(Float(hardwareBrightness / 100))
            }
        } else {
            let status = ddcAvailableLock.withLock { ddcAvailable[displayID] }
            if status == false {
                // An already-neutral gamma table needs no write when entering HDR.
                // Transfer-function changes can reset the screen's EDR state.
                if requested <= 100 || (currentSoftwareBrightness(for: displayID) ?? 1) < 1 {
                    setSoftwareBrightness(hardwareBrightness, for: displayID)
                }
                return
            }
            let knownMax = ddcAvailableLock.withLock { ddcMaxBrightness[displayID] ?? 100 }
            let value = UInt16(hardwareBrightness / 100 * Double(knownMax))
            DDCService.shared.writeAsync(
                displayID: displayID, command: DDCService.brightnessVCP, value: value
            ) { [weak self, weak display] success in
                guard let self else { return }
                self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = success }
                if !success {
                    DispatchQueue.main.async {
                        // Use the latest target: a failed older write must not undo a newer adjustment.
                        guard let display, display.isOnline else { return }
                        if display.brightness <= 100 || (self.currentSoftwareBrightness(for: displayID) ?? 1) < 1 {
                            self.setSoftwareBrightness(min(100, display.brightness), for: displayID)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Uses the same HDR/hardware/software routing for sliders, shortcuts and presets.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false
    ) {
        guard targetBrightness.isFinite else { return }
        let target = BrightnessScale.normalized(targetBrightness, maximum: display.maximumBrightness)
        let previous = display.brightness
        // HDR is explicitly stepped, so animation must not create intermediate fake HDR percentages.
        if target > 100 || previous > 100 {
            setBrightnessImmediately(target, for: display, isAutoAdjust: isAutoAdjust)
            return
        }
        let from = appliedBrightness[display.displayID] ?? previous
        display.brightness = target
        SettingsService.shared.setBrightness(target, for: display.displayID)
        let usesDDC = !display.isBuiltin && isDDCAvailable(for: display.displayID) != false
        animator(for: display.displayID).animate(
            from: from, to: target, steps: usesDDC ? 5 : 8, duration: 0.20
        ) { [weak self, weak display] value, _ in
            guard let self, let display else { return }
            self.applyBrightness(value, for: display, isAutoAdjust: isAutoAdjust, updatesTarget: false)
        }
    }

    // MARK: - Software Brightness (Gamma Table Fallback)

    /// Applies brightness via gamma table manipulation for displays where DDC is unavailable.
    /// Uses a linear ramp from 0 to `factor` so white level is dimmed while black stays black.
    /// brightness: 0–100 (percentage); never goes fully to 0 to avoid a completely black screen.
    ///
    /// Delegates all transfer-table writes to GammaService, preserving image adjustments.
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, min(1, brightness / 100.0))
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
        saveSoftwareBrightness(factor: factor, for: displayID)

        GammaService.shared.applySoftwareBrightness(for: displayID)
    }

    /// Removes software dimming while retaining the display's image adjustments.
    func resetSoftwareBrightness(for displayID: CGDirectDisplayID) {
        _ = softwareBrightnessLock.withLock { softwareBrightnessFactors.removeValue(forKey: displayID) }
        UserDefaults.standard.removeObject(forKey: softBrightnessKey(for: displayID))
        GammaService.shared.applySoftwareBrightness(for: displayID)
    }

    /// Returns whether DDC is available for the given display.
    /// nil means not yet determined (first use).
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// Clears DDC availability and max brightness cache for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            ddcAvailable.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
        }
    }

    /// Re-applies the software brightness for a display after wake from sleep or hot-plug.
    /// Checks in-memory factor first; falls back to UserDefaults so restart is handled too.
    /// No-op if no saved factor < 1.0 exists.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        let displayID = display.displayID
        let inMemory = softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
        let factor = inMemory ?? loadSoftwareBrightness(for: displayID)
        guard let f = factor, f < 1.0 else { return }
        // Populate in-memory cache if loaded from disk
        if inMemory == nil {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = f }
        }
        setSoftwareBrightness(f * 100.0, for: displayID)
    }

    // MARK: - Internal Display (IODisplayGetFloatParameter)

    private static nonisolated(unsafe) let ioDisplayBrightnessKey = "brightness" as CFString

    /// Returns the io_service_t for the built-in display using CGDisplayIOServicePort.
    /// Falls back to iterating IODisplayConnect services if CGDisplayIOServicePort returns null.
    /// Caller does NOT need to release — CGDisplayIOServicePort returns a non-retained port.
    private func builtinIOService() -> io_service_t? {
        // Find the built-in CGDirectDisplayID
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        guard let builtinID = (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // CGDisplayIOServicePort returns a non-retained service port (do not release)
        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

    private func getInternalBrightness() -> Double? {
        // Primary: use CGDisplayIOServicePort to get the specific builtin display service
        if let servicePort = builtinIOService() {
            var value: Float = 0
            if IODisplayGetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }

        // Fallback: iterate IODisplayConnect but only accept services that
        // correspond to a built-in display (matched via CGDisplayIOServicePort cross-check).
        // Build set of known external service ports to exclude them.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Skip services that are known external display ports
            guard !externalPorts.contains(service) else { continue }
            var value: Float = 0
            if IODisplayGetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }
        return nil
    }

    private func setInternalBrightness(_ value: Float) {
        // Primary: use CGDisplayIOServicePort to target only the builtin display service
        if let servicePort = builtinIOService() {
            if IODisplaySetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }

        // Fallback: iterate IODisplayConnect, skipping known external ports
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            #if DEBUG
            print("[BrightnessService] setInternalBrightness: no builtin service responded")
            #endif
            return
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard !externalPorts.contains(service) else { continue }
            if IODisplaySetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }
        #if DEBUG
        print("[BrightnessService] setInternalBrightness: no builtin service responded")
        #endif
    }
}
