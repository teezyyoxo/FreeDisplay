import AppKit

enum BrightnessShortcutAction: String, CaseIterable, Codable, Identifiable {
    case primaryUp, primaryDown
    case secondaryUp, secondaryDown
    case bothUp, bothDown
    case syncToPrimary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primaryUp:      return "Increase brightness"
        case .primaryDown:    return "Decrease brightness"
        case .secondaryUp:    return "Increase brightness"
        case .secondaryDown:  return "Decrease brightness"
        case .bothUp:         return "Increase brightness"
        case .bothDown:       return "Decrease brightness"
        case .syncToPrimary:  return "Match secondary to primary"
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .primaryUp, .primaryDown:     return .primary
        case .secondaryUp, .secondaryDown: return .secondary
        case .bothUp, .bothDown:           return .both
        case .syncToPrimary:               return .sync
        }
    }
}

enum ShortcutGroup: String, CaseIterable, Identifiable {
    case primary, secondary, both, sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:   return "Primary display"
        case .secondary: return "Secondary display"
        case .both:      return "Both displays"
        case .sync:      return "Sync"
        }
    }

    var actions: [BrightnessShortcutAction] {
        BrightnessShortcutAction.allCases.filter { $0.group == self }
    }
}

/// Logical key identities. Brightness keys get fixed negative codes so a binding works for
/// keyboards that send F14/F15 key presses as well as ones that send media-key events.
enum ShortcutKey {
    static let brightnessUp = -1
    static let brightnessDown = -2

    static let modifierMask: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000

    static func normalize(keycode: Int) -> Int {
        switch keycode {
        case 113: return brightnessUp
        case 107: return brightnessDown
        default:  return keycode
        }
    }

    static func isBrightness(_ code: Int) -> Bool {
        code == brightnessUp || code == brightnessDown
    }

    private static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    ]

    static func isFunctionKey(_ code: Int) -> Bool {
        functionKeys[code] != nil
    }

    static func name(forCode code: Int, characters: String?) -> String {
        if code == brightnessUp { return "Brightness Up" }
        if code == brightnessDown { return "Brightness Down" }
        if let name = functionKeys[code] ?? namedKeys[code] { return name }
        if let characters, !characters.isEmpty { return characters.uppercased() }
        return "Key \(code)"
    }
}

struct ShortcutBinding: Codable, Equatable, Hashable {
    var code: Int
    var modifiers: UInt64
    var keyName: String

    /// Display parts in macOS order: ⌃ ⌥ ⇧ ⌘ then the key.
    var parts: [String] {
        var result: [String] = []
        if modifiers & 0x40000 != 0 { result.append("⌃") }
        if modifiers & 0x80000 != 0 { result.append("⌥") }
        if modifiers & 0x20000 != 0 { result.append("⇧") }
        if modifiers & 0x100000 != 0 { result.append("⌘") }
        result.append(keyName)
        return result
    }

    /// A bare letter or digit would swallow normal typing system-wide.
    var isSafeToCapture: Bool {
        modifiers != 0 || ShortcutKey.isBrightness(code) || ShortcutKey.isFunctionKey(code)
    }

    static func control(_ key: Int) -> ShortcutBinding { make(key, 0x40000) }
    static func option(_ key: Int) -> ShortcutBinding { make(key, 0x80000) }
    static func controlOption(_ key: Int) -> ShortcutBinding { make(key, 0x40000 | 0x80000) }

    private static func make(_ key: Int, _ modifiers: UInt64) -> ShortcutBinding {
        ShortcutBinding(code: key, modifiers: modifiers, keyName: ShortcutKey.name(forCode: key, characters: nil))
    }

    static let defaults: [BrightnessShortcutAction: ShortcutBinding] = [
        .primaryUp:     .control(ShortcutKey.brightnessUp),
        .primaryDown:   .control(ShortcutKey.brightnessDown),
        .secondaryUp:   .option(ShortcutKey.brightnessUp),
        .secondaryDown: .option(ShortcutKey.brightnessDown),
        .bothUp:        .controlOption(ShortcutKey.brightnessUp),
        .bothDown:      .controlOption(ShortcutKey.brightnessDown),
    ]

    /// Parses a recorded key event, or nil if it isn't a usable shortcut key.
    init?(event: NSEvent) {
        let mods = UInt64(event.modifierFlags.rawValue) & ShortcutKey.modifierMask

        switch event.type {
        case .keyDown:
            let code = ShortcutKey.normalize(keycode: Int(event.keyCode))
            self.code = code
            self.modifiers = mods
            self.keyName = ShortcutKey.name(forCode: code, characters: event.charactersIgnoringModifiers)
        case .systemDefined where event.subtype.rawValue == 8:
            let keyType = (event.data1 >> 16) & 0xFF
            let isDown = (event.data1 & 0x0100) == 0
            guard isDown, keyType == 2 || keyType == 3 else { return nil }
            let code = keyType == 2 ? ShortcutKey.brightnessUp : ShortcutKey.brightnessDown
            self.code = code
            self.modifiers = mods
            self.keyName = ShortcutKey.name(forCode: code, characters: nil)
        default:
            return nil
        }
    }

    init(code: Int, modifiers: UInt64, keyName: String) {
        self.code = code
        self.modifiers = modifiers
        self.keyName = keyName
    }
}
