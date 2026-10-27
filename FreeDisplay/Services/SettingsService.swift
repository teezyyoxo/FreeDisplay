import AppKit
import Foundation
import CoreGraphics
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/FreeDisplay/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FreeDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        loadAll()
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "fd.launchAtLogin"
        static let launchAtLoginPrompted  = "fd.launchAtLogin.prompted"
        static let menuWidth              = "fd.menuWidth"
        static let appearanceMode         = "fd.appearanceMode"
        static let menuBackgroundBlur     = "fd.menuBlurStrength"
        static let legacyMenuBackgroundBlur = "fd.menuBackgroundBlur"
        static let menuBackgroundTransparency = "fd.menuBackgroundTransparency"
        static let brightnessKeyRouting   = "fd.brightnessKeyRouting"
        static let brightnessKeyStep      = "fd.brightnessKeyStep"
        static let shortcuts              = "fd.shortcuts"
        static let showCombinedBrightness = "fd.showCombinedBrightness"
        static let ddcCacheTTL            = "fd.ddcCacheTTL"
        static let checkUpdatesOnLaunch   = "fd.checkUpdatesOnLaunch"
        static let colorPickerHistory     = "fd.colorPickerHistory"
        // Per-display keys use prefix + displayID
        static let brightnessPrefix       = "fd.brightness_"
        static let contrastPrefix         = "fd.contrast_"
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    @Published var menuWidth: Double = 320 {
        didSet { defaults.set(menuWidth, forKey: Keys.menuWidth) }
    }

    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
            NSApplication.shared.appearance = appearanceMode.nsAppearance
        }
    }

    @Published var menuBackgroundTransparency: Double = 0.85 {
        didSet { defaults.set(menuBackgroundTransparency, forKey: Keys.menuBackgroundTransparency) }
    }

    /// Opacity of the tint laid behind the glass cards; 0 leaves the system material untouched.
    var panelTint: Double { (1 - menuBackgroundTransparency) * 0.9 }

    @Published var menuBackgroundBlur: Double = 0.9 {
        didSet { defaults.set(menuBackgroundBlur, forKey: Keys.menuBackgroundBlur) }
    }

    @Published var brightnessKeyRouting: Bool = true {
        didSet { defaults.set(brightnessKeyRouting, forKey: Keys.brightnessKeyRouting) }
    }

    @Published var brightnessKeyStep: Double = 6.25 {
        didSet { defaults.set(brightnessKeyStep, forKey: Keys.brightnessKeyStep) }
    }

    /// Only bound actions are present; clearing a shortcut removes its entry.
    @Published var shortcuts: [String: ShortcutBinding] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: Keys.shortcuts)
            }
        }
    }

    func binding(for action: BrightnessShortcutAction) -> ShortcutBinding? {
        shortcuts[action.rawValue]
    }

    /// Assigning a binding already used by another action moves it to this one.
    func setBinding(_ binding: ShortcutBinding?, for action: BrightnessShortcutAction) {
        var updated = shortcuts
        if let binding {
            for (key, existing) in updated where existing == binding {
                updated.removeValue(forKey: key)
            }
            updated[action.rawValue] = binding
        } else {
            updated.removeValue(forKey: action.rawValue)
        }
        shortcuts = updated
    }

    func resetShortcuts() {
        shortcuts = Self.defaultShortcuts()
    }

    private static func defaultShortcuts() -> [String: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: ShortcutBinding.defaults.map { ($0.key.rawValue, $0.value) })
    }

    @Published var showCombinedBrightness: Bool = true {
        didSet { defaults.set(showCombinedBrightness, forKey: Keys.showCombinedBrightness) }
    }

    @Published var ddcCacheTTL: Double = 5.0 {
        didSet { defaults.set(ddcCacheTTL, forKey: Keys.ddcCacheTTL) }
    }

    @Published var checkUpdatesOnLaunch: Bool = true {
        didSet { defaults.set(checkUpdatesOnLaunch, forKey: Keys.checkUpdatesOnLaunch) }
    }

    /// Recently sampled colors (hex strings, newest first, max 20).
    @Published var colorPickerHistory: [String] = [] {
        didSet {
            defaults.set(colorPickerHistory, forKey: Keys.colorPickerHistory)
        }
    }

    // MARK: - Per-Display Settings

    func brightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.brightnessPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.brightnessPrefix + "\(displayID)")
    }

    func contrast(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.contrastPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.contrastPrefix + "\(displayID)")
    }

    // MARK: - Color History

    func addColorToHistory(_ hex: String) {
        var history = colorPickerHistory.filter { $0 != hex }
        history.insert(hex, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        colorPickerHistory = history
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[SettingsService] Failed to save \(filename): \(error)")
            #endif
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative SMAppService state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        menuWidth = defaults.object(forKey: Keys.menuWidth) != nil
            ? defaults.double(forKey: Keys.menuWidth) : 320
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        if defaults.object(forKey: Keys.menuBackgroundTransparency) != nil {
            menuBackgroundTransparency = defaults.double(forKey: Keys.menuBackgroundTransparency)
        } else {
            menuBackgroundTransparency = 0.85
        }
        if defaults.object(forKey: Keys.menuBackgroundBlur) != nil {
            menuBackgroundBlur = defaults.double(forKey: Keys.menuBackgroundBlur)
        } else if defaults.object(forKey: Keys.legacyMenuBackgroundBlur) != nil {
            menuBackgroundBlur = sqrt(defaults.double(forKey: Keys.legacyMenuBackgroundBlur))
        } else {
            menuBackgroundBlur = 0.9
        }
        brightnessKeyRouting = defaults.object(forKey: Keys.brightnessKeyRouting) != nil
            ? defaults.bool(forKey: Keys.brightnessKeyRouting) : true
        brightnessKeyStep = defaults.object(forKey: Keys.brightnessKeyStep) != nil
            ? defaults.double(forKey: Keys.brightnessKeyStep) : 6.25
        if let data = defaults.data(forKey: Keys.shortcuts),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            shortcuts = decoded
        } else {
            shortcuts = Self.defaultShortcuts()
        }
        showCombinedBrightness = defaults.object(forKey: Keys.showCombinedBrightness) != nil
            ? defaults.bool(forKey: Keys.showCombinedBrightness) : true
        ddcCacheTTL = defaults.object(forKey: Keys.ddcCacheTTL) != nil
            ? defaults.double(forKey: Keys.ddcCacheTTL) : 5.0
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkUpdatesOnLaunch) : true
        colorPickerHistory = defaults.stringArray(forKey: Keys.colorPickerHistory) ?? []
    }
}
