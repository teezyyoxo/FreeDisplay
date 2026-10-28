import AppKit
import Combine
import SwiftUI

// Hardware writes are recorded, not sent to monitors. All brightness routing,
// key decoding, animation, HDR rendering and HUD code comes from the app sources.
@MainActor final class SettingsService {
    static let shared = SettingsService()
    @Published var shortcuts = Dictionary(uniqueKeysWithValues: ShortcutBinding.defaults.map { ($0.key.rawValue, $0.value) })
    @Published var brightnessKeyRouting = true
    var brightnessKeyStep = 6.25
    private var saved: [CGDirectDisplayID: Double] = [:]
    func brightness(for id: CGDirectDisplayID) -> Double? { saved[id] }
    func setBrightness(_ value: Double, for id: CGDirectDisplayID) { saved[id] = value }
}
struct DisplayMode: Sendable {
    let width = 0, height = 0
    let isHiDPI = false
    static func currentMode(for id: CGDirectDisplayID) -> DisplayMode? { nil }
    static func availableModes(for id: CGDirectDisplayID) -> [DisplayMode] { [] }
}
@MainActor final class VirtualDisplayService {
    static let shared = VirtualDisplayService()
    func isVirtualDisplay(_ id: CGDirectDisplayID) -> Bool { false }
}
@MainActor final class DisplayManagerAccessor {
    static let shared = DisplayManagerAccessor()
    var displays: [DisplayInfo] = []
}
final class GammaService: @unchecked Sendable {
    static let shared = GammaService()
    private let lock = NSLock()
    private var count = 0
    var writes: Int { lock.withLock { count } }
    func applySoftwareBrightness(for id: CGDirectDisplayID) { lock.withLock { count += 1 } }
}
final class DDCService: @unchecked Sendable {
    static let shared = DDCService()
    static let brightnessVCP: UInt8 = 0x10
    private let lock = NSLock()
    private var recorded: [UInt16] = []
    private var failsWrites = false
    private var delaysWrites = false
    private var deferred: [@Sendable (Bool) -> Void] = []
    func deferWrites() { lock.withLock { delaysWrites = true } }
    func failDeferredWrites() {
        let callbacks = lock.withLock {
            delaysWrites = false
            let callbacks = deferred
            deferred.removeAll()
            return callbacks
        }
        callbacks.forEach { $0(false) }
    }
    func forceUnavailable() { lock.withLock { failsWrites = true } }
    private var reader: (@Sendable ((current: UInt16, max: UInt16)?) -> Void)?
    var writes: [UInt16] { lock.withLock { recorded } }
    func writeAsync(displayID: CGDirectDisplayID, command: UInt8, value: UInt16, completion: (@Sendable (Bool) -> Void)?) {
        lock.withLock { recorded.append(value) }
        let delayed = lock.withLock {
            if delaysWrites, let completion { deferred.append(completion); return true }
            return false
        }
        if !delayed { completion?(lock.withLock { !failsWrites }) }
    }
    func readAsync(displayID: CGDirectDisplayID, command: UInt8,
                   completion: @escaping @Sendable ((current: UInt16, max: UInt16)?) -> Void) {
        lock.withLock { reader = completion }
    }
    func completeRead() {
        let callback = lock.withLock { let result = reader; reader = nil; return result }
        callback?((10, 100))
    }
}

@MainActor final class RegressionDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await BrightnessRegression.check()
            NSApp.terminate(nil)
        }
    }
}

@main @MainActor struct BrightnessRegression {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = RegressionDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static func check() async {
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let savedDomain = defaults.persistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: domain)
        defer {
            BrightnessHUDService.shared.stop()
            HDRBrightnessService.shared.stop()
            BrightnessKeyService.shared.stop()
            if let savedDomain { defaults.setPersistentDomain(savedDomain, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        for maximum in [100.0, 130.0] {
            for value in stride(from: 5.0, through: maximum, by: 1) {
                let fraction = BrightnessScale.fraction(value, minimum: 5, maximum: maximum)
                let roundTrip = BrightnessScale.level(at: fraction, minimum: 5, maximum: maximum)
                precondition(abs(roundTrip - BrightnessScale.normalized(value, maximum: maximum)) < 0.001)
            }
        }
        precondition(BrightnessScale.fraction(100, maximum: 130) == 16.0 / 19)
        precondition(BrightnessScale.next(98, direction: 1, nativeStep: 6.25, maximum: 130) == 100)
        var sequence = [100.0]
        for _ in 0..<4 { sequence.append(BrightnessScale.next(sequence.last!, direction: 1, nativeStep: 6.25, maximum: 130)) }
        precondition(sequence == [100, 110, 120, 130, 130])
        for expected in [120.0, 110, 100, 93.75] {
            sequence.append(BrightnessScale.next(sequence.last!, direction: -1, nativeStep: 6.25, maximum: 130))
            precondition(sequence.last == expected)
        }
        precondition(BrightnessScale.migratedLegacyLevel(436, potentialHeadroom: 4.362) == 130)
        precondition(BrightnessScale.migratedLegacyLevel(214, potentialHeadroom: 4.362) == 110)
        let oldPreset = Data("{\"id\":\"AC8AC5C1-AC8A-45C1-ABCD-AC8AC5C1AC8A\",\"displayUUID\":\"test\",\"width\":2560,\"height\":1440,\"isHiDPI\":false,\"brightness\":4.36}".utf8)
        precondition((try! JSONDecoder().decode(DisplayPresetEntry.self, from: oldPreset)).brightnessScaleVersion == nil)
        print("PASS: scale round trips, HDR snapping, boundary stepping and legacy migration")

        let displays = NSScreen.screens.map { DisplayInfo(displayID: $0.displayID) }
        guard let primary = displays.first(where: { $0.isMain }) ?? displays.first else {
            print("SKIP: desktop integration needs a connected display")
            return
        }
        for display in displays { display.isBuiltin = false; display.brightness = 100 }
        DisplayManagerAccessor.shared.displays = displays
        HDRBrightnessService.shared.refresh(displays: displays)
        for display in displays {
            precondition(display.hdrBrightnessEnabled == display.supportsHDRBrightness)
            precondition(display.maximumBrightness == (display.supportsHDRBrightness ? 130 : 100))
        }
        print("PASS: HDR default enabled only for compatible displays")

        let service = BrightnessService.shared
        primary.brightness = 50
        service.setBrightnessImmediately(50, for: primary)
        for _ in 0..<4 { BrightnessKeyService.shared.perform(.primaryUp) }
        precondition(primary.brightness == 75, "Key repeats must accumulate from the target, not in-flight animation")
        let before = DDCService.shared.writes.count
        trackMenu(for: 0.28)
        precondition(DDCService.shared.writes.count > before, "Animation stalled during menu tracking")
        precondition(primary.brightness == 75, "Animation frames must not move the published target backwards")

        // Exercise the real event decoder/callback without posting global keyboard input.
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: true)!
        event.flags = .maskControl
        precondition(BrightnessKeyService.shared.handleEventFromCallback(type: .keyDown, event: event) == nil)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(primary.brightness == 81.25)
        await service.refreshBrightness(for: primary)
        service.setBrightnessImmediately(90, for: primary)
        DDCService.shared.completeRead()
        try? await Task.sleep(for: .milliseconds(50))
        precondition(primary.brightness == 90, "A late read overwrote the keyboard/slider target")
        print("PASS: key callback, rapid repeats, common-mode animation and stale-read protection")

        // Cover actual system-defined media-event decoding, including both edges.
        // This still does not prove that WindowServer delivers hardware input to a tap.
        let beforeMedia = BrightnessKeyService.shared.receivedKeyCount
        let beforePrimary = primary.brightness
        for state in [0x0A, 0x0B] {
            let media = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (3 << 16) | (state << 8), data2: -1)!.cgEvent!
            precondition(BrightnessKeyService.shared.handleEventFromCallback(type: CGEventType(rawValue: 14)!, event: media) == nil)
        }
        try? await Task.sleep(for: .milliseconds(50))
        precondition(primary.brightness == beforePrimary - SettingsService.shared.brightnessKeyStep)
        precondition(BrightnessKeyService.shared.receivedKeyCount == beforeMedia + 2)
        let volume = NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: (0 << 16) | (0x0A << 8), data2: -1)!.cgEvent!
        precondition(BrightnessKeyService.shared.handleEventFromCallback(type: CGEventType(rawValue: 14)!, event: volume) != nil)
        precondition(BrightnessKeyService.shared.receivedKeyCount == beforeMedia + 2)
        print("PASS: media brightness decoding consumes both edges; unrelated media keys pass through")

        service.setBrightnessFromSlider(100, for: primary, isFinal: true)
        if primary.supportsHDRBrightness {
            // These assertions verify commands/headroom mapping, not desktop luminance.
            // The compositor must additionally pass a real 100% versus 130% visual check.
            var previousMultiplier = 1.0
            for expected in [110.0, 120, 130] {
                BrightnessKeyService.shared.perform(.primaryUp)
                precondition(primary.brightness == expected)
                try? await Task.sleep(for: .milliseconds(600))
                precondition(primary.hdrBrightnessMultiplier > previousMultiplier,
                             "HDR steps did not increase output: \(primary.hdrBrightnessMultiplier)")
                previousMultiplier = primary.hdrBrightnessMultiplier
                render(BrightnessHUDView(display: primary).frame(width: 316, height: 116), name: "hud-\(Int(expected))")
            }
            BrightnessKeyService.shared.perform(.primaryUp)
            precondition(primary.brightness == 130)
            service.setBrightnessFromSlider(100, for: primary, isFinal: true)
            for expected in [110.0, 120, 130] {
                let fraction = BrightnessScale.fraction(expected, minimum: 5, maximum: primary.maximumBrightness)
                let dragged = BrightnessScale.level(at: fraction, minimum: 5, maximum: primary.maximumBrightness)
                service.setBrightnessFromSlider(dragged, for: primary, isFinal: true)
                precondition(primary.brightness == expected)
                trackMenu(for: 0.4)
                precondition(primary.hdrBrightnessMultiplier > 1, "HDR stalled while dragging in menu tracking mode")
            }
            render(BrightnessSliderView(display: primary).padding(16).frame(width: 380), name: "slider-hdr")
            HDRBrightnessService.shared.setEnabled(false, for: primary)
            precondition(primary.brightness == 100 && primary.maximumBrightness == 100)
            HDRBrightnessService.shared.refresh(displays: displays)
            precondition(!primary.hdrBrightnessEnabled, "Explicit HDR opt-out was lost")
            service.setBrightnessFromSlider(130, for: primary, isFinal: true)
            precondition(primary.brightness == 100)
            render(BrightnessHUDView(display: primary).frame(width: 316, height: 116), name: "hud-native")
            print("PASS: keyboard and drag HDR commands 110/120/130, selected EDR multipliers, opt-out and SDR clamping")
        }
        if primary.supportsHDRBrightness {
            HDRBrightnessService.shared.setEnabled(true, for: primary)
            DDCService.shared.deferWrites()
            service.invalidateDDCState(for: primary.displayID)
            service.setBrightnessImmediately(70, for: primary)
            service.setBrightnessFromSlider(110, for: primary, isFinal: true)
            let beforeLateFailures = GammaService.shared.writes
            DDCService.shared.failDeferredWrites()
            try? await Task.sleep(for: .milliseconds(50))
            precondition(GammaService.shared.writes == beforeLateFailures, "Late DDC failures reset active HDR gamma")
            DDCService.shared.forceUnavailable()
            service.invalidateDDCState(for: primary.displayID)
            service.setBrightnessImmediately(60, for: primary)
            try? await Task.sleep(for: .milliseconds(50))
            precondition(service.currentSoftwareBrightness(for: primary.displayID) == 0.6)
            service.setBrightnessFromSlider(110, for: primary, isFinal: true)
            precondition(service.currentSoftwareBrightness(for: primary.displayID) == 1)
            let gammaWrites = GammaService.shared.writes
            for level in [120.0, 130] { service.setBrightnessFromSlider(level, for: primary, isFinal: true) }
            precondition(GammaService.shared.writes == gammaWrites, "HDR changes rewrote a neutral gamma table")
            try? await Task.sleep(for: .milliseconds(400))
            precondition(primary.hdrBrightnessMultiplier > 1)
            HDRBrightnessService.shared.setEnabled(false, for: primary)
            print("PASS: software-fallback drag restores dimming once, then HDR changes leave gamma alone")
        }
        precondition(DDCService.shared.writes.allSatisfy { $0 <= 100 }, "HDR percentages leaked into hardware VCP values")
        if let secondary = displays.first(where: { $0.displayID != primary.displayID }) {
            secondary.brightness = 50
            BrightnessKeyService.shared.perform(.bothUp)
            precondition(primary.brightness == 100 && secondary.brightness == 56.25)
            render(CombinedBrightnessView(displays: displays).padding().frame(width: 380), name: "combined")
        }
        print("PASS: mixed-display shortcuts clamp each display independently; hardware writes stay in range")
    }

    static func trackMenu(for seconds: Double) {
        CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString), seconds, false)
    }

    static func render<V: View>(_ view: V, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["FD_TEST_RENDER_DIR"] else { return }
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            preconditionFailure("Could not render \(name)")
        }
        try! png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
