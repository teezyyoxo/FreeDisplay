import AppKit
import SwiftUI

/// Owns FreeDisplay's non-activating brightness HUD. Handled key events are
/// consumed by BrightnessKeyService before macOS can display its native HUD.
@MainActor
final class BrightnessHUDService {
    static let shared = BrightnessHUDService()
    private init() {}

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var dismissalTimers: [CGDirectDisplayID: Timer] = [:]

    func show(for display: DisplayInfo, on screen: NSScreen) {
        let id = display.displayID
        dismissalTimers.removeValue(forKey: id)?.invalidate()
        let panel: NSPanel
        if let existing = panels[id] {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 316, height: 116),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panels[id] = panel
        }
        panel.contentView = NSHostingView(rootView: BrightnessHUDView(display: display))
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                     y: visible.minY + min(80, visible.height * 0.1)))
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels[id]?.orderOut(nil)
                self?.dismissalTimers.removeValue(forKey: id)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissalTimers[id] = timer
    }

    func stop() {
        for timer in dismissalTimers.values { timer.invalidate() }
        dismissalTimers.removeAll()
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }
}
