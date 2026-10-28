import AppKit
import MetalKit

/// Extends desktop brightness using public EDR rendering and multiply compositing.
/// GammaService remains the sole owner of display transfer tables.
@MainActor
final class HDRBrightnessService: ObservableObject {
    static let shared = HDRBrightnessService()

    private var displays: [CGDirectDisplayID: DisplayInfo] = [:]
    private var overlays: [CGDirectDisplayID: HDRBrightnessOverlay] = [:]
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeTask: Task<Void, Never>?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(displays: Array(self.displays.values))
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wakeTask?.cancel()
                self.wakeTask = Task { @MainActor in
                    // Let WindowServer recreate its display surfaces before rendering.
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self.refresh(displays: Array(self.displays.values))
                    for display in self.displays.values { self.reapply(for: display) }
                }
            }
        }
    }

    private func key(_ suffix: String, for display: DisplayInfo) -> String {
        "fd.hdrBrightness.\(display.displayUUID).\(suffix)"
    }

    func refresh(displays newDisplays: [DisplayInfo]) {
        objectWillChange.send()
        let previousIDs = Set(displays.keys)
        displays = Dictionary(uniqueKeysWithValues: newDisplays.map { ($0.displayID, $0) })
        for id in Array(overlays.keys) where displays[id] == nil {
            removeOverlay(for: id)
        }
        for display in newDisplays {
            let screen = NSScreen.screen(for: display.displayID)
            // Mirrored/virtual outputs cannot be independently boosted.
            let eligible = !VirtualDisplayService.shared.isVirtualDisplay(display.displayID)
                && CGDisplayMirrorsDisplay(display.displayID) == kCGNullDirectDisplay
                && CGDisplayIsInMirrorSet(display.displayID) == 0
            display.hdrBrightnessHeadroom = eligible
                ? Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) : 1

            let enabledKey = key("enabled", for: display)
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                // A saved false is an explicit opt-out; an absent preference follows capability.
                display.hdrBrightnessEnabled = display.supportsHDRBrightness
            } else if !previousIDs.contains(display.displayID) {
                display.hdrBrightnessEnabled = UserDefaults.standard.bool(forKey: enabledKey)
            }
            if !previousIDs.contains(display.displayID), display.hdrBrightnessEnabled, display.supportsHDRBrightness {
                let levelKey = key("stepLevel", for: display)
                let saved: Double
                if UserDefaults.standard.object(forKey: levelKey) != nil {
                    saved = UserDefaults.standard.double(forKey: levelKey)
                } else {
                    let legacy = UserDefaults.standard.double(forKey: key("level", for: display))
                    saved = BrightnessScale.migratedLegacyLevel(legacy, potentialHeadroom: display.hdrBrightnessHeadroom)
                }
                if saved > 100 { display.brightness = BrightnessScale.normalized(saved, maximum: display.maximumBrightness) }
            }

            if display.brightness > display.maximumBrightness {
                BrightnessService.shared.setBrightnessSmooth(display.maximumBrightness, for: display)
            } else if display.brightness > 100 {
                _ = apply(display.brightness, for: display)
            } else {
                removeOverlay(for: display.displayID)
            }
        }
    }

    func setEnabled(_ enabled: Bool, for display: DisplayInfo) {
        objectWillChange.send()
        BrightnessService.shared.cancelAnimation(for: display.displayID)
        display.hdrBrightnessEnabled = enabled && display.supportsHDRBrightness
        UserDefaults.standard.set(display.hdrBrightnessEnabled, forKey: key("enabled", for: display))
        display.hdrBrightnessError = nil
        if !display.hdrBrightnessEnabled {
            removeOverlay(for: display.displayID)
            UserDefaults.standard.set(100, forKey: key("stepLevel", for: display))
            BrightnessService.shared.setBrightnessSmooth(min(100, display.brightness), for: display)
        }
    }

    func maximumBrightness(for displays: [DisplayInfo]) -> Double {
        displays.map(\.maximumBrightness).max() ?? 100
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// All input methods share these levels. Each HDR step uses a third of the
    /// currently available extra brightness, with 130% reaching its full extent.
    func apply(_ brightness: Double, for display: DisplayInfo) -> Double {
        let requested = BrightnessScale.normalized(brightness, maximum: display.maximumBrightness)
        if display.hdrBrightnessEnabled {
            UserDefaults.standard.set(requested, forKey: key("stepLevel", for: display))
        }
        guard requested > 100, let screen = NSScreen.screen(for: display.displayID) else {
            removeOverlay(for: display.displayID)
            return min(100, requested)
        }
        if overlays[display.displayID] == nil {
            guard let overlay = HDRBrightnessOverlay(screen: screen) else {
                display.hdrBrightnessError = "HDR brightness could not start on this display."
                return 100
            }
            overlays[display.displayID] = overlay
        }
        display.hdrBrightnessError = nil
        updateOverlay(for: display, requested: requested)
        startTimerIfNeeded()
        return requested
    }

    func reapply(for display: DisplayInfo) {
        removeOverlay(for: display.displayID)
        if display.brightness > 100 {
            BrightnessService.shared.invalidateHardwareBrightness(for: display.displayID)
            BrightnessService.shared.setBrightnessSmooth(display.brightness, for: display)
        }
    }

    func stop() {
        wakeTask?.cancel()
        for id in Array(overlays.keys) { removeOverlay(for: id) }
    }

    private func removeOverlay(for id: CGDirectDisplayID) {
        overlays.removeValue(forKey: id)?.close()
        displays[id]?.hdrBrightnessMultiplier = 1
        if overlays.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateOverlay(for display: DisplayInfo, requested: Double) {
        guard let screen = NSScreen.screen(for: display.displayID) else {
            removeOverlay(for: display.displayID)
            return
        }
        let headroom = max(1, Double(screen.maximumExtendedDynamicRangeColorComponentValue))
        let multiplier = BrightnessScale.multiplier(level: requested, headroom: headroom)
        if abs(display.hdrBrightnessMultiplier - multiplier) > 0.001 {
            display.hdrBrightnessMultiplier = multiplier
        }
        overlays[display.displayID]?.update(screen: screen, multiplier: multiplier)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in Array(self.overlays.keys) {
                    guard let display = self.displays[id] else { continue }
                    self.updateOverlay(for: display, requested: display.brightness)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Click-through windows on all Spaces, including full-screen apps. A tiny HDR
/// patch activates EDR; a neutral multiply layer scales the desktop without capture.
@MainActor
private final class HDRBrightnessOverlay {
    private let boostWindow: NSWindow
    private let activationWindow: NSWindow
    private let boostView: HDRBrightnessMetalView
    private let activationView: HDRBrightnessMetalView

    init?(screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        boostView = HDRBrightnessMetalView(device: device, queue: queue)
        activationView = HDRBrightnessMetalView(device: device, queue: queue)
        // Keep blending in WindowServer's compositor. A CIFilter object is an
        // in-process Core Image operation; it does not provide an HDR desktop backdrop.
        boostView.layer?.compositingFilter = "multiply"
        activationView.multiplier = 2

        boostWindow = Self.makeWindow(frame: screen.frame, view: boostView)
        activationWindow = Self.makeWindow(frame: Self.activationFrame(screen), view: activationView)
        // Present a neutral multiplied frame before making the full-screen layer visible.
        boostView.draw()
        activationWindow.orderFrontRegardless()
        boostWindow.orderFrontRegardless()
        activationView.draw()
        boostView.draw()
    }

    private static func activationFrame(_ screen: NSScreen) -> NSRect {
        let pixel = 1 / screen.backingScaleFactor
        return NSRect(x: screen.frame.maxX - pixel, y: screen.frame.maxY - pixel, width: pixel, height: pixel)
    }

    private static func makeWindow(frame: NSRect, view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = view
        return window
    }

    func update(screen: NSScreen, multiplier: Double) {
        if boostWindow.frame != screen.frame { boostWindow.setFrame(screen.frame, display: true) }
        activationWindow.setFrame(Self.activationFrame(screen), display: true)
        boostView.multiplier = multiplier
        // The service drives both surfaces in common run-loop modes, including menu tracking.
        activationView.draw()
        boostView.draw()
    }

    func close() {
        boostView.isPaused = true
        activationView.isPaused = true
        boostWindow.close()
        activationWindow.close()
    }
}

@MainActor
private final class HDRBrightnessMetalView: MTKView, MTKViewDelegate {
    var multiplier: Double = 1
    private let commandQueue: MTLCommandQueue

    init(device: MTLDevice, queue: MTLCommandQueue) {
        commandQueue = queue
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        autoResizeDrawable = false
        // A solid-color surface needs only one texel, even when scaled to the full screen.
        drawableSize = CGSize(width: 1, height: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.isOpaque = false
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: multiplier, green: multiplier, blue: multiplier, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
