import SwiftUI

/// The expanded controls inside a display card (brightness lives in the card header).
struct DisplayDetailView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var showModeList = false
    @State private var showColorProfile = false
    @State private var showImageAdjustment = false
    @State private var activeProfileName = ""

    private func sectionKey(_ name: String) -> String {
        "fd.expanded.\(display.displayUUID).\(name)"
    }

    private func loadExpanded(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: sectionKey(name))
    }

    private func saveExpanded(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: sectionKey(name))
    }

    private var modeSubtitle: String {
        var parts: [String] = []
        if let mode = display.currentDisplayMode {
            parts.append(mode.resolutionString)
            if mode.isHiDPI { parts.append("HiDPI") }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HiDPIRowView(display: display)

            ExpandableRow(
                icon: "rectangle.on.rectangle",
                iconColor: .indigo,
                label: "Display Modes",
                subtitle: modeSubtitle,
                isExpanded: $showModeList
            )
            if showModeList {
                DisplayModeListView(display: display)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ExpandableRow(
                icon: "paintpalette.fill",
                iconColor: .purple,
                label: "Color Profiles",
                subtitle: activeProfileName,
                isExpanded: $showColorProfile
            )
            if showColorProfile {
                ColorProfileView(display: display, activeProfileName: $activeProfileName)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ExpandableRow(
                icon: "slider.horizontal.3",
                iconColor: .teal,
                label: "Image Adjustments",
                isExpanded: $showImageAdjustment
            )
            if showImageAdjustment {
                ImageAdjustmentView(display: display)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            MainDisplayView(display: display)
            NotchView(display: display)
        }
        .onAppear {
            showModeList = loadExpanded("modeList")
            showColorProfile = loadExpanded("colorProfile")
            showImageAdjustment = loadExpanded("imageAdjust")
        }
        .onChange(of: showModeList) { _, v in saveExpanded("modeList", v) }
        .onChange(of: showColorProfile) { _, v in saveExpanded("colorProfile", v) }
        .onChange(of: showImageAdjustment) { _, v in saveExpanded("imageAdjust", v) }
        .task(id: display.displayID) {
            activeProfileName = ColorProfileService.shared.currentProfileName(for: display.displayID)
        }
    }
}
