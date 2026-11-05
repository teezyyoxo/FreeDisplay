import SwiftUI

@main
struct FreeDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var displayManager = DisplayManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(displayManager)
                .task {
                    // Enable "external above built-in" arrangement by default on first launch.
                    let defaults = UserDefaults.standard
                    if defaults.object(forKey: "fd.arrangement.externalAbove") == nil {
                        defaults.set(true, forKey: "fd.arrangement.externalAbove")
                    }

                    // After a 2-second delay (allows displays to fully initialize),
                    // position any external display above the built-in display.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        displayManager.arrangeExternalAboveBuiltin()
                    }

                }
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
