import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private init() {}

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsWindowView()))
            window.title = "FreeDisplay Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Permissions

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var inputMonitoring = CGPreflightListenEventAccess()
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        if accessibility && inputMonitoring && !BrightnessKeyService.shared.isActive {
            BrightnessKeyService.shared.start()
        }
    }
}

// MARK: - Root

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, brightness, shortcuts, appearance, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .brightness: return "Brightness Keys"
        case .shortcuts:  return "Shortcuts"
        case .appearance: return "Appearance"
        case .about:      return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .brightness: return "sun.max.fill"
        case .shortcuts:  return "command"
        case .appearance: return "paintbrush.fill"
        case .about:      return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general:    return .gray
        case .brightness: return .orange
        case .shortcuts:  return .indigo
        case .appearance: return .teal
        case .about:      return .blue
        }
    }
}

struct SettingsWindowView: View {
    @State private var selection: SettingsPage = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label {
                    Text(page.title)
                } icon: {
                    MenuItemIcon(systemName: page.icon, color: page.color, size: 24)
                }
                .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch selection {
                case .general:    GeneralSettingsPage()
                case .brightness: BrightnessKeysSettingsPage()
                case .shortcuts:  ShortcutsSettingsPage()
                case .appearance: AppearanceSettingsPage()
                case .about:      AboutSettingsPage()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selection.title)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPage: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch FreeDisplay at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { enabled in
                        if enabled { LaunchService.shared.enable() } else { LaunchService.shared.disable() }
                        settings.launchAtLogin = enabled
                    }
                ))
                Toggle("Check for updates when FreeDisplay starts", isOn: $settings.checkUpdatesOnLaunch)
            }

            Section {
                Toggle("Show a combined brightness slider", isOn: $settings.showCombinedBrightness)
            } header: {
                Text("Menu Panel")
            } footer: {
                Text("Adds one slider to the panel that adjusts every display together.")
            }
        }
    }
}

// MARK: - Brightness Keys

private struct BrightnessKeysSettingsPage: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var keyService = BrightnessKeyService.shared
    @StateObject private var permissions = PermissionMonitor()

    var body: some View {
        Form {
            Section {
                Toggle("Adjust the display under the pointer", isOn: $settings.brightnessKeyRouting)
                LabeledContent("Change per key press") {
                    HStack {
                        Slider(value: $settings.brightnessKeyStep, in: 1...20)
                            .frame(width: 180)
                        Text(String(format: "%.1f%%", settings.brightnessKeyStep))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("Brightness Keys")
            } footer: {
                Text("The brightness keys change whichever display the mouse pointer is on. Use Shortcuts to target a specific display instead.")
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    detail: "Lets FreeDisplay intercept brightness keys.",
                    granted: permissions.accessibility,
                    openURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                    request: nil
                )
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Lets FreeDisplay see key presses system-wide.",
                    granted: permissions.inputMonitoring,
                    openURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                    request: { _ = keyService.requestInputMonitoringPermission() }
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Grant these to FreeDisplay itself, not to the app that launched it.")
            }

            Section("Status") {
                LabeledContent("Keyboard monitor") {
                    Label(keyService.isActive ? "Running" : "Not running",
                          systemImage: keyService.isActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(keyService.isActive ? .green : .orange)
                }
                if let detected = keyService.lastKeyEventDisplayName {
                    LabeledContent("Last key press on", value: detected)
                }
                if let action = keyService.lastActionDescription {
                    LabeledContent("Last action", value: action)
                }
            }
        }
        .onAppear { permissions.start() }
        .onDisappear { permissions.stop() }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, openURL: String, request: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                if let request {
                    Button("Request", action: request)
                }
                Button("Open Settings") {
                    if let url = URL(string: openURL) { NSWorkspace.shared.open(url) }
                }
            } else {
                Text("Granted").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPage: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        Form {
            ForEach(ShortcutGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.actions) { action in
                        ShortcutRecorderRow(action: action)
                    }
                }
            }

            Section {
                Button("Restore Default Shortcuts") { settings.resetShortcuts() }
            } footer: {
                Text("Shortcuts take priority over pointer-based control. Click a field and press the keys you want, including the brightness keys. Esc cancels and Delete clears.")
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPage: View {
    @ObservedObject private var settings = SettingsService.shared

    private var usesLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                sliderRow("Transparency", value: $settings.menuBackgroundTransparency)
                if !usesLiquidGlass {
                    sliderRow("Blur", value: $settings.menuBackgroundBlur)
                }
            } header: {
                Text("Menu Panel")
            } footer: {
                Text(usesLiquidGlass
                     ? "Higher transparency lets more of the Liquid Glass show through."
                     : "Higher transparency shows more of what is behind the panel.")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1)
                    .frame(width: 200)
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsPage: View {
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    MenuItemIcon(systemName: "display", color: .blue, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FreeDisplay").font(.title2.weight(.semibold))
                        Text("Version \(updateService.currentVersion) (\(updateService.buildHash))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Text("A free, open-source display manager for macOS.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
