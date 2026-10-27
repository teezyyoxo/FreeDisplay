import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement = false
    @State private var showVirtualDisplays = false
    @State private var showAutoBrightness = false
    @State private var contentHeight: CGFloat = 0

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    /// Leaves room for the menu bar and the header so the panel never outgrows the screen.
    private var maxScrollHeight: CGFloat {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return min(820, max(320, (screen?.visibleFrame.height ?? 900) - 170))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                FDGlassContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(visibleDisplays) { display in
                            DisplayCard(
                                display: display,
                                isExpanded: expandedDisplayIDs.contains(display.displayID)
                            ) {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                    if expandedDisplayIDs.contains(display.displayID) {
                                        expandedDisplayIDs.remove(display.displayID)
                                    } else {
                                        expandedDisplayIDs.insert(display.displayID)
                                    }
                                }
                            }
                        }

                        if settings.showCombinedBrightness, visibleDisplays.count > 1 {
                            FDCard(padding: 12) {
                                CombinedBrightnessView(displays: displayManager.displays)
                            }
                        }

                        presetsSection
                        toolsSection
                        updateBanner
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
            }
            .frame(height: min(max(contentHeight, 140), maxScrollHeight))
        }
        .frame(width: FD.panelWidth)
        .background { PanelBackdrop(tint: settings.panelTint, blur: settings.menuBackgroundBlur) }
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch { await updateService.checkForUpdates() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("FreeDisplay")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text("v\(updateService.currentVersion) (\(updateService.buildHash))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            FDGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    FDIconButton(systemName: "gearshape.fill", help: "Settings") { openSettings() }
                    FDIconButton(systemName: "power", help: "Quit FreeDisplay") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Sections

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FDSectionHeader(title: "Presets", systemImage: "bookmark.fill")
            FDCard(padding: 6) { PresetListView() }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FDSectionHeader(title: "Tools", systemImage: "wrench.and.screwdriver.fill")
            FDCard(padding: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if visibleDisplays.count > 1 {
                        ExpandableRow(icon: "rectangle.3.offgrid", iconColor: .blue, label: "Arrange Displays", isExpanded: $showArrangement)
                        if showArrangement {
                            ArrangementView()
                                .environmentObject(displayManager)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    ExpandableRow(icon: "display.2", iconColor: .indigo, label: "Virtual Displays", isExpanded: $showVirtualDisplays)
                    if showVirtualDisplays {
                        VirtualDisplayView()
                            .padding(.leading, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ExpandableRow(icon: "sun.and.horizon.fill", iconColor: .orange, label: "Auto Brightness", isExpanded: $showAutoBrightness)
                    if showAutoBrightness {
                        AutoBrightnessView()
                            .padding(.leading, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        if updateService.hasUpdate, let version = updateService.latestVersion {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text("Version \(version) is available")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                Spacer()
                Button("View") { updateService.openReleasePage() }
                    .buttonStyle(.borderless)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
            }
            .padding(12)
            .fdGlass(RoundedRectangle(cornerRadius: FD.rowRadius, style: .continuous), tint: .green.opacity(0.35))
        }
    }
}

// MARK: - Display Card

private struct DisplayCard: View {
    @ObservedObject var display: DisplayInfo
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        FDCard(padding: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    header
                    BrightnessSliderView(display: display)
                }
                .padding(16)

                if isExpanded {
                    Divider()
                        .overlay(.primary.opacity(0.08))
                        .padding(.horizontal, 16)
                    DisplayDetailView(display: display)
                        .padding(10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MenuItemIcon(
                systemName: display.isBuiltin ? "laptopcomputer" : "display",
                color: .blue,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(display.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let mode = display.currentDisplayMode {
                    Text("\(mode.resolutionString) · \(mode.refreshRateString)")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                if display.isMain { FDTag(text: "Main", color: .blue) }
                BrightnessModeTag(display: display)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help("Show display controls")
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open Displays Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy Display Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to show display controls")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Backdrop

/// Optional tint behind the glass cards. At 0 the system panel material shows through untouched.
private struct PanelBackdrop: View {
    let tint: Double
    let blur: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            if #unavailable(macOS 26.0) {
                PanelVisualEffect(blurStrength: blur).clipShape(shape)
            }
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(tint))
        }
        .allowsHitTesting(false)
    }
}

private struct PanelVisualEffect: NSViewRepresentable {
    let blurStrength: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = blurStrength
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = blurStrength
    }
}
