import AppKit
import CoreGraphics
import Combine
import ApplicationServices
import os

// MARK: - C Event Tap Callback

/// The tap is registered on the main run loop, so this callback always fires on the main thread.
private func brightnessKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - BrightnessKeyService

/// Global keyboard brightness control.
///
/// Precedence for each key event:
/// 1. A configured shortcut (primary / secondary / both / sync) always wins.
/// 2. A plain brightness key adjusts the display under the pointer.
/// 3. Everything else passes through untouched.
@MainActor
final class BrightnessKeyService: ObservableObject, @unchecked Sendable {
    static let shared = BrightnessKeyService()
    private init() {}

    // MARK: - Published State

    @Published private(set) var isActive = false
    @Published private(set) var eventTapCreationFailed = false
    @Published private(set) var lastKeyEventDisplayName: String?
    @Published private(set) var lastActionDescription: String?

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selfRetained: Unmanaged<BrightnessKeyService>?
    private var pollTimer: Timer?
    private var pollRetryCount = 0
    private var settingsSubscriptions = Set<AnyCancellable>()
    private static let maxPollRetries = 15

    // Read from the nonisolated tap callback, which only ever runs on the main thread.
    private nonisolated(unsafe) static var shortcutTable: [(code: Int, modifiers: UInt64, action: BrightnessShortcutAction)] = []
    private nonisolated(unsafe) static var pointerRoutingEnabled = true
    private nonisolated(unsafe) static var isRecording = false

    private nonisolated(unsafe) static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    private nonisolated(unsafe) static let nxSubtypeAuxControlButtons: Int16 = 8
    private nonisolated(unsafe) static let nxKeytypeBrightnessUp: Int = 2
    private nonisolated(unsafe) static let nxKeytypeBrightnessDown: Int = 3
    private nonisolated(unsafe) static let log = Logger(subsystem: "com.freedisplay.app", category: "brightness-keys")

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility and Input Monitoring access.
    /// Safe to call repeatedly; an existing tap is kept.
    func start() {
        observeSettings()
        guard eventTap == nil else { return }

        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        let eventMask = CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: brightnessKeyEventCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            selfRetained = nil
            isActive = false
            eventTapCreationFailed = true
            Self.log.error("Event tap creation failed; waiting for permission")
            pollForPermission()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isActive = true
        eventTapCreationFailed = false
        Self.log.info("Event tap installed")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollRetryCount = 0
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        selfRetained?.release()
        selfRetained = nil
        isActive = false
    }

    /// Lets the shortcut recorder see brightness keys that would otherwise be consumed.
    func setRecordingShortcut(_ recording: Bool) {
        Self.isRecording = recording
    }

    @discardableResult
    func requestInputMonitoringPermission() -> Bool {
        let granted = CGRequestListenEventAccess()
        if granted { start() }
        return granted
    }

    // MARK: - Settings Observation

    private func observeSettings() {
        guard settingsSubscriptions.isEmpty else { return }
        let settings = SettingsService.shared

        settings.$shortcuts
            .sink { shortcuts in
                Self.shortcutTable = shortcuts.compactMap { key, binding in
                    BrightnessShortcutAction(rawValue: key).map { (binding.code, binding.modifiers, $0) }
                }
            }
            .store(in: &settingsSubscriptions)

        settings.$brightnessKeyRouting
            .sink { Self.pointerRoutingEnabled = $0 }
            .store(in: &settingsSubscriptions)
    }

    private func pollForPermission() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollRetryCount += 1
            timer.invalidate()
            self.pollTimer = nil
            if self.pollRetryCount > Self.maxPollRetries { return }
            self.start()
        }
    }

    // MARK: - Event Handling

    private struct DecodedKey {
        var code: Int
        var isDown: Bool
        var modifiers: UInt64
    }

    private nonisolated func decode(type: CGEventType, event: CGEvent) -> DecodedKey? {
        let modifiers = event.flags.rawValue & ShortcutKey.modifierMask

        switch type {
        case .keyDown, .keyUp:
            let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return DecodedKey(code: ShortcutKey.normalize(keycode: keycode), isDown: type == .keyDown, modifiers: modifiers)
        default:
            guard type.rawValue == Self.cgEventTypeSystemDefinedRaw,
                  let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons else { return nil }
            let data1 = nsEvent.data1
            let keyType = (data1 >> 16) & 0xFF
            guard keyType == Self.nxKeytypeBrightnessUp || keyType == Self.nxKeytypeBrightnessDown else { return nil }
            let code = keyType == Self.nxKeytypeBrightnessUp ? ShortcutKey.brightnessUp : ShortcutKey.brightnessDown
            return DecodedKey(code: code, isDown: (data1 & 0x0100) == 0, modifiers: modifiers)
        }
    }

    nonisolated func handleEventFromCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            DispatchQueue.main.async {
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return passThrough
        }

        if Self.isRecording { return passThrough }
        guard let key = decode(type: type, event: event) else { return passThrough }

        // 1. Configured shortcuts override pointer-based routing.
        if let match = Self.shortcutTable.first(where: { $0.code == key.code && $0.modifiers == key.modifiers }) {
            if key.isDown {
                let action = match.action
                Task { @MainActor in self.perform(action) }
            }
            return nil
        }

        // 2. Plain brightness keys follow the pointer.
        guard Self.pointerRoutingEnabled,
              ShortcutKey.isBrightness(key.code),
              key.modifiers == 0 else { return passThrough }

        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
              screen.displayID != 0 else { return passThrough }

        let displayID = screen.displayID
        let screenName = screen.localizedName

        if CGDisplayIsBuiltin(displayID) != 0 {
            Task { @MainActor in self.lastKeyEventDisplayName = screenName }
            return passThrough
        }

        // Swallow both edges so macOS never sees half of a key press.
        guard key.isDown else { return nil }
        let direction = key.code == ShortcutKey.brightnessUp ? 1.0 : -1.0
        Task { @MainActor in
            self.lastKeyEventDisplayName = screenName
            self.adjustDisplayUnderPointer(displayID: displayID, direction: direction)
        }
        return nil
    }

    // MARK: - Actions

    private func adjustDisplayUnderPointer(displayID: CGDirectDisplayID, direction: Double) {
        guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID }) else {
            lastActionDescription = "No display matched the pointer"
            return
        }
        lastActionDescription = "\(direction > 0 ? "Increased" : "Decreased") \(display.name)"
        Self.log.info("Pointer routed to \(display.name, privacy: .public)")
        adjust([display], by: SettingsService.shared.brightnessKeyStep * direction)
    }

    func perform(_ action: BrightnessShortcutAction) {
        let displays = DisplayManagerAccessor.shared.displays.filter {
            $0.isOnline && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
        guard let primary = displays.first(where: { $0.isMain }) ?? displays.first else { return }
        let secondary = displays.filter { $0.displayID != primary.displayID }
        let step = SettingsService.shared.brightnessKeyStep
        let targets: [DisplayInfo]

        switch action {
        case .primaryUp:     targets = [primary];  adjust(targets, by: step)
        case .primaryDown:   targets = [primary];  adjust(targets, by: -step)
        case .secondaryUp:   targets = secondary;  adjust(targets, by: step)
        case .secondaryDown: targets = secondary;  adjust(targets, by: -step)
        case .bothUp:        targets = displays;   adjust(targets, by: step)
        case .bothDown:      targets = displays;   adjust(targets, by: -step)
        case .syncToPrimary: targets = secondary;  apply(primary.brightness, to: targets)
        }
        lastActionDescription = action.group.title + ": " + action.title
        Self.log.info("Shortcut \(action.rawValue, privacy: .public) applied to \(targets.count, privacy: .public) display(s)")
    }

    private func adjust(_ displays: [DisplayInfo], by delta: Double) {
        for display in displays {
            apply(display.brightness + delta, to: [display])
        }
    }

    private func apply(_ brightness: Double, to displays: [DisplayInfo]) {
        let clamped = max(0, min(100, brightness))
        for display in displays {
            BrightnessService.shared.setBrightnessSmooth(clamped, for: display)
            if let screen = NSScreen.screen(for: display.displayID) {
                BrightnessHUDService.shared.show(brightness: clamped, on: screen)
            }
        }
    }
}
