import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var overlayManager: OverlayManager?
    private var windowTracker: WindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = SettingsStore.shared
        let overlayManager = OverlayManager(settings: settings)
        self.overlayManager = overlayManager
        overlayManager.start()

        let windowTracker = WindowTracker(settings: settings)
        windowTracker.onSurfacesUpdated = { [weak overlayManager] surfaces in
            overlayManager?.updateSurfaces(surfaces)
        }
        windowTracker.onSurfaceRemoved = { [weak overlayManager] surface in
            overlayManager?.surfaceRemoved(surface)
        }
        windowTracker.onFullscreenStatesUpdated = { [weak overlayManager] states in
            overlayManager?.updateFullscreenStates(states)
        }
        self.windowTracker = windowTracker
        windowTracker.start()

        self.statusBarController = StatusBarController(settings: settings, overlayManager: overlayManager)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowTracker?.stop()
        overlayManager?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
