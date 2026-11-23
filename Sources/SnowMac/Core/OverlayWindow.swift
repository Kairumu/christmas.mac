import AppKit
import SpriteKit

/// Borderless, transparent, click-through-by-default window hosting the snow scene
/// for a single NSScreen.
final class OverlayWindow: NSWindow {
    let skView: SKView
    private(set) var scene: (SKScene & SnowSceneAPI)
    /// The physical display this window is presenting on. Used by
    /// OverlayManager to route each Surface to only its own screen's scene.
    private(set) var displayID: CGDirectDisplayID?
    /// Must be retained here — the scene only holds it weakly (see
    /// SnowSceneAPI.interactionDelegate). Owning this per-window (rather
    /// than in a flat array on OverlayManager) lets rebuildWindows()
    /// reconcile windows to screens 1:1 without losing track of which
    /// controller belongs to which surviving/departing window.
    var interactionController: InteractionController?

    init(screen: NSScreen, scene: SKScene & SnowSceneAPI) {
        self.scene = scene
        self.skView = SKView(frame: screen.frame)
        self.displayID = OverlayWindow.displayID(for: screen)

        // IMPORTANT: call the 4-arg designated initializer directly, NOT the
        // `screen:`-taking variant. AppKit's `init(contentRect:styleMask:
        // backing:defer:screen:)` is implemented by internally re-invoking
        // `self.init(contentRect:styleMask:backing:defer:)` via dynamic
        // dispatch — which lands on THIS CLASS's own override below (the
        // "stand-in" initializer), not NSWindow's base implementation. That
        // override unconditionally reassigns `self.scene`/`self.skView` to a
        // brand-new throwaway scene/view, silently clobbering the real
        // `scene`/`skView` set just above — immediately after construction,
        // `self.scene` ends up pointing at a scene that is never presented
        // (its `didMove(to:)` never fires, so its `accumulator` stays nil
        // forever), while the real, visibly-rendering scene becomes
        // unreachable from `OverlayManager.windows[i].scene`. This is why
        // EVERY menu action (intensity, snowplow, clear-all, window/Dock
        // surface updates) silently no-oped: they were all being forwarded
        // to the dead, unpresented scene, never to the live one. Calling the
        // 4-arg initializer here goes straight to NSWindow's real designated
        // initializer and skips that re-entrant clobbering; `setFrame`
        // below still places the window on the correct screen.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar - 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        skView.frame = CGRect(origin: .zero, size: screen.frame.size)
        skView.allowsTransparency = true
        skView.autoresizingMask = [.width, .height]
        // Flakes/clumps now share one texture (see SnowScene.flakeTexture) —
        // this lets SpriteKit batch them into one draw call instead of
        // sorting/drawing each sprite individually by z-order.
        skView.ignoresSiblingOrder = true
        contentView = skView

        scene.scaleMode = .resizeFill
        scene.size = screen.frame.size
        skView.presentScene(scene)

        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    func reposition(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        scene.size = screen.frame.size
        displayID = OverlayWindow.displayID(for: screen)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// AppKit's window server can instantiate stand-in windows of this class
    /// via the screen-less designated initializer — observed in practice
    /// with `.fullScreenAuxiliary`/`.canJoinAllSpaces` collection behavior
    /// during Spaces/full-screen transitions. Because this subclass adds
    /// non-optional stored properties, Swift does not synthesize this
    /// initializer automatically; without an explicit override it crashes
    /// with "Fatal error: Use of unimplemented initializer". Provide a
    /// harmless fallback scene so any such stand-in window is still valid.
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.scene = SnowSceneFactory.make(size: contentRect.size)
        self.skView = SKView(frame: contentRect)
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }
}
