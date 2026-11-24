import AppKit
import SpriteKit

/// Owns one OverlayWindow per NSScreen, wires settings, and routes global mouse
/// movement to the active scene's isInteractive hit-test to toggle click-through.
final class OverlayManager {
    private let settings: SettingsStore
    private var windows: [OverlayWindow] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var lowPowerObserver: NSObjectProtocol?

    // MARK: - Run-state aggregation (P9)
    //
    // scene.isPaused used to also be driven by per-screen fullscreen state
    // (feature QW4: fullscreen -> freeze snowfall). SKScene.isPaused
    // freezes every in-flight flake exactly where it happened to be —
    // that read as snow stuck scattered mid-air/mid-screen, not as a pile
    // forming anywhere. The actual desired behavior (explicit user
    // expectation) is the opposite: snow keeps falling during fullscreen
    // and piles on screenBottom like normal. The fullscreen-pause path has
    // been removed entirely — isPaused now has no cause at all and is left
    // at SKScene's default (false). manualOff (intensity == .off) was
    // never a pause cause either — it already stops spawning on its own
    // (graceful stop, not a freeze). Low power is also not a pause cause —
    // it only throttles spawn rate/wind, handled via `lowPowerMode` below.
    private var lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// The set of enabled display IDs as of the last rebuildWindows() call.
    /// Settings changes fire frequently (intensity, snowOnWindows, etc.) but
    /// only a change to THIS set requires tearing down/creating windows —
    /// rebuildWindows() destroys accumulated snow on screens it recreates,
    /// so we must not call it on every settings change.
    private var lastEnabledDisplayIDs: Set<CGDirectDisplayID> = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Single seam worker-2 swaps to wire in the real engine:
    /// `SnowSceneFactory.make(size:)` once Engine/SnowScene lands.
    private func makeScene(size: CGSize) -> (scene: SKScene & SnowSceneAPI, controller: InteractionController) {
        let scene = SnowSceneFactory.make(size: size)
        scene.intensity = settings.intensity
        scene.lowPowerMode = lowPowerActive
        // Wire the interaction layer: InteractionController sets itself as
        // scene.interactionDelegate in its init. Caller must retain the
        // returned controller — the scene only holds it weakly.
        let interaction = InteractionController(scene: scene)
        return (scene, interaction)
    }

    func start() {
        rebuildWindows()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applySettingsToScenes()
            self?.rebuildWindowsIfEnabledDisplaysChanged()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        installMouseMonitors()

        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.applyLowPowerState()
        }
    }

    func stop() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
        NotificationCenter.default.removeObserver(self)
        windows.forEach { teardownWindow($0) }
        windows.removeAll()
    }

    @objc private func screenParametersChanged() {
        rebuildWindows()
    }

    /// `NSApplication.didChangeScreenParametersNotification` fires for far
    /// more than display hotplug — resolution changes, arrangement changes,
    /// display sleep/wake, Dock auto-hide/reveal `visibleFrame` changes.
    /// Reconcile instead of rebuilding from scratch: surviving screens keep
    /// their window/scene (so accumulated snow, snowmen, and in-progress
    /// drags survive), moved/resized screens are repositioned in place, and
    /// only genuinely departed/added screens get torn down or created.
    private func rebuildWindows() {
        let screens = NSScreen.screens
        var screensByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in screens {
            if let id = displayID(for: screen) {
                screensByDisplayID[id] = screen
            }
        }

        var survivors: [OverlayWindow] = []
        var matchedDisplayIDs = Set<CGDirectDisplayID>()

        for window in windows {
            guard let id = window.displayID,
                  let screen = screensByDisplayID[id],
                  settings.isDisplayEnabled(id),
                  matchedDisplayIDs.insert(id).inserted else {
                teardownWindow(window)
                continue
            }
            if !NSEqualRects(window.frame, screen.frame) {
                window.reposition(to: screen)
            }
            survivors.append(window)
        }

        for screen in screens {
            guard let id = displayID(for: screen), !matchedDisplayIDs.contains(id), settings.isDisplayEnabled(id) else { continue }
            matchedDisplayIDs.insert(id)
            let (scene, controller) = makeScene(size: screen.frame.size)
            let window = OverlayWindow(screen: screen, scene: scene)
            window.interactionController = controller
            survivors.append(window)
        }

        windows = survivors
        lastEnabledDisplayIDs = enabledDisplayIDs(in: screensByDisplayID.keys)
    }

    /// Shared by rebuildWindows() (to cache what was just applied) and
    /// rebuildWindowsIfEnabledDisplaysChanged() (to detect what changed).
    private func enabledDisplayIDs<S: Sequence>(in displayIDs: S) -> Set<CGDirectDisplayID> where S.Element == CGDirectDisplayID {
        Set(displayIDs.filter { settings.isDisplayEnabled($0) })
    }

    /// Per-display enable/disable is the only settings change that requires
    /// a structural rebuild (create/teardown windows) — every other
    /// settings change (intensity, snowOnWindows, etc.) is handled by
    /// applySettingsToScenes() alone. Compares against lastEnabledDisplayIDs
    /// so a rebuild only happens when the enabled set actually changed.
    private func rebuildWindowsIfEnabledDisplaysChanged() {
        var connectedDisplayIDs: [CGDirectDisplayID] = []
        for screen in NSScreen.screens {
            if let id = displayID(for: screen) {
                connectedDisplayIDs.append(id)
            }
        }
        guard enabledDisplayIDs(in: connectedDisplayIDs) != lastEnabledDisplayIDs else { return }
        rebuildWindows()
    }

    /// Real teardown for a window whose screen is gone — `orderOut` alone
    /// leaves the NSWindow in AppKit's window list (isReleasedWhenClosed is
    /// false), retaining its SKView/SKScene/flake nodes indefinitely.
    /// Also resets the interaction layer first so a drag interrupted by a
    /// display change doesn't leave GloveCursor stuck pushed with no
    /// controller left to pop it.
    private func teardownWindow(_ window: OverlayWindow) {
        window.interactionController?.resetAll()
        window.skView.presentScene(nil)
        window.contentView = nil
        window.close()
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func applySettingsToScenes() {
        for window in windows {
            window.scene.intensity = settings.intensity
        }
    }

    /// Route each surface to ONLY the scene for its own display — a surface
    /// carrying another screen's displayID would otherwise render a
    /// floating, inaccurate accumulation ledge on every other screen.
    func updateSurfaces(_ surfaces: [Surface]) {
        for window in windows {
            guard let displayID = window.displayID else { continue }
            window.scene.updateSurfaces(surfaces.filter { $0.displayID == displayID })
        }
    }

    func surfaceRemoved(_ surface: Surface) {
        for window in windows where window.displayID == surface.displayID {
            window.scene.surfaceRemoved(surface)
        }
    }

    func summonSnowplow() {
        windows.forEach { $0.scene.summonSnowplow() }
    }

    func summonSweeper() {
        windows.forEach { $0.scene.summonSweeper() }
    }

    /// 블리자드: one-shot storm burst on every screen's scene.
    func triggerBlizzard() {
        windows.forEach { $0.scene.triggerBlizzard() }
    }

    /// 영서에게 눈사람 부탁.
    func requestSnowmanBuild() {
        windows.forEach { $0.scene.summonSweeperForSnowman() }
    }

    func resetAllSnow() {
        windows.forEach { $0.scene.resetAllSnow() }
    }

    /// "눈 모두 치우기": accumulated snow only.
    func clearAccumulatedSnow() {
        windows.forEach { $0.scene.clearAccumulatedSnow() }
    }

    /// "눈사람 리셋": interaction objects (snowballs/snowmen) only.
    func resetSnowmen() {
        windows.forEach { $0.scene.interactionDelegate?.resetAll() }
    }

    private func applyLowPowerState() {
        for window in windows {
            window.scene.lowPowerMode = lowPowerActive
        }
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
            return event
        }
    }

    private func handleMouseMoved(screenPoint: CGPoint) {
        for window in windows {
            guard let screen = window.screen ?? NSScreen.screens.first(where: { NSEqualRects($0.frame, window.frame) }) else { continue }
            guard screen.frame.contains(screenPoint) else {
                window.ignoresMouseEvents = true
                continue
            }
            let scenePoint = CGPoint(
                x: screenPoint.x - screen.frame.origin.x,
                y: screenPoint.y - screen.frame.origin.y
            )
            let interactive = window.scene.isInteractive(atScenePoint: scenePoint)
            window.ignoresMouseEvents = !interactive
        }
    }
}
