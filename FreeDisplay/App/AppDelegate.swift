import AppKit
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit if another instance is already running.
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            print("[FreeDisplay] Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        BrightnessKeyService.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrightnessKeyService.shared.stop()
        BrightnessHUDService.shared.stop()
        HDRBrightnessService.shared.stop()
        // GammaService restores each display's transfer table on termination.
        VirtualDisplayService.shared.destroyAll()
    }
}
