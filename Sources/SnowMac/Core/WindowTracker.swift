import AppKit
import CoreGraphics

/// Polls CGWindowListCopyWindowInfo at 10 Hz, converts window bounds into scene-space
/// [Surface] (top edges of normal windows, the Dock, and each screen's bottom edge),
/// and diffs against the previous poll to detect removed surfaces (feature 04).
final class WindowTracker {
    var onSurfacesUpdated: (([Surface]) -> Void)?
    var onSurfaceRemoved: ((Surface) -> Void)?
    /// Per-screen true-fullscreen state (keyed by screen identity), reported
    /// every poll from the same CGWindowList snapshot already fetched for
    /// surfaces — no extra polling/permissions needed (feature QW4).
    var onFullscreenStatesUpdated: (([ObjectIdentifier: Bool]) -> Void)?

    private let settings: SettingsStore
    private var timer: Timer?
    private var previousSurfaces: [Surface] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private let minWindowWidth: CGFloat = 40
    private let minWindowHeight: CGFloat = 20

    /// kCGWindowBounds includes the window's shadow/frame region, which is
    /// visibly wider than the window's rounded-corner content area. Inset
    /// both edges by this margin so accumulated snow doesn't overhang past
    /// the visible window edges.
    private let windowEdgeInset: CGFloat = 9

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var surfaces: [Surface] = []

        for screen in NSScreen.screens {
            if let bottom = screenBottomSurface(for: screen) {
                surfaces.append(bottom)
            }
        }

        if settings.snowOnWindows {
            surfaces.append(contentsOf: windowSurfaces(from: infoList))
        }

        if settings.snowOnDock {
            if let dockSurface = dockSurface(from: infoList) {
                surfaces.append(dockSurface)
            }
        }

        // Identity for removal must be by `kind` alone (window id / dock /
        // screenBottom), NOT full Equatable (which also compares minX/maxX/y).
        // A dragged or resized window keeps its kCGWindowNumber but changes
        // coordinates every poll, so comparing full Surface equality here
        // made every move/resize look like "this surface vanished" — firing
        // a spill (snow turned into falling clumps) even though the window
        // never closed. Those clumps then almost always land right back on
        // the same window's freshly-reconciled (now-empty) surface below
        // them, which reads as "the snow that fell comes back onto the
        // window I just moved."
        let removed = previousSurfaces.filter { old in !surfaces.contains { $0.kind == old.kind } }

        previousSurfaces = surfaces

        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            let windowCount = surfaces.filter { if case .window = $0.kind { return true }; return false }.count
            let hasDock = surfaces.contains { $0.kind == .dock }
            let ys = surfaces.map { $0.y }
            FileHandle.standardError.write("SNOWMAC_DEBUG poll: total=\(surfaces.count) windows=\(windowCount) dock=\(hasDock) ys=\(ys)\n".data(using: .utf8)!)
            if !removed.isEmpty {
                let suppressed = removed.filter { if case .window(let id) = $0.kind { return windowStillExists(id) }; return false }
                FileHandle.standardError.write("SNOWMAC_DEBUG removed: kinds=\(removed.map { $0.kind }) suppressedSpaceSwitch=\(suppressed.map { $0.kind })\n".data(using: .utf8)!)
            }
        }

        onSurfacesUpdated?(surfaces)
        for surface in removed {
            // A window that disappeared from .optionOnScreenOnly but still
            // exists (queryable by id) is on another Space, or minimized —
            // not closed. Only fire the spill for windows that are truly
            // gone. This is an exact per-window check rather than a
            // count/ratio heuristic, so it is correct for both a single
            // window close (must spill) and a mass app-quit (must spill
            // every one), and silent for a genuine Space switch.
            if case .window(let id) = surface.kind, windowStillExists(id) { continue }
            onSurfaceRemoved?(surface)
        }

        onFullscreenStatesUpdated?(fullscreenStates(from: infoList))
    }

    /// True fullscreen (a Space-filling app, e.g. full-screen video) covers
    /// the entire physical screen INCLUDING the menu bar region, unlike a
    /// merely maximized window which still starts below the menu bar. We
    /// must NOT treat maximized windows as fullscreen — snow piling on their
    /// top edge is the point of this app.
    private func fullscreenStates(from infoList: [[String: Any]]) -> [ObjectIdentifier: Bool] {
        let epsilon: CGFloat = 2
        var result: [ObjectIdentifier: Bool] = [:]
        for screen in NSScreen.screens {
            result[ObjectIdentifier(screen)] = false
        }

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != ownPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0

            guard let screen = screenContaining(cgTopLeftPoint: CGPoint(x: x, y: y)) else { continue }

            let screenRelativeY = y - topLeftOffsetY(for: screen)
            let startsAtTop = abs(screenRelativeY) <= epsilon
            let coversFullHeight = abs(height - screen.frame.height) <= epsilon
            let coversFullWidth = width >= screen.frame.width - epsilon

            if startsAtTop, coversFullHeight, coversFullWidth {
                result[ObjectIdentifier(screen)] = true
            }
        }

        return result
    }

    /// A window that still exists (anywhere — any Space, minimized, etc.)
    /// but is no longer `.optionOnScreenOnly` is a Space switch / minimize,
    /// not a close. Exact existence check, no count/ratio guessing.
    private func windowStillExists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else {
            return false
        }
        return !list.isEmpty
    }

    private func screenBottomSurface(for screen: NSScreen) -> Surface? {
        guard let displayID = displayID(for: screen) else { return nil }
        return Surface(kind: .screenBottom(displayID: displayID), displayID: displayID, minX: 0, maxX: screen.frame.width, y: 0)
    }

    private func windowSurfaces(from infoList: [[String: Any]]) -> [Surface] {
        var result: [Surface] = []

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != ownPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0

            guard width >= minWindowWidth, height >= minWindowHeight else { continue }

            guard let screen = screenContaining(cgTopLeftPoint: CGPoint(x: x, y: y)) else { continue }
            guard let displayID = displayID(for: screen) else { continue }

            // CG coords: origin top-left of the primary display, y grows downward.
            // Scene coords: origin bottom-left of the owning screen, y grows upward.
            let rawMinX = x - screen.frame.origin.x
            let rawMaxX = rawMinX + width
            let sceneMinX = rawMinX + windowEdgeInset
            let sceneMaxX = rawMaxX - windowEdgeInset
            let topInScreenSpace = screen.frame.height - (y - topLeftOffsetY(for: screen))
            let sceneY = topInScreenSpace

            guard sceneMaxX > sceneMinX else { continue }

            if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
                FileHandle.standardError.write("SNOWMAC_DEBUG window: id=\(windowID) rawBounds=[x=\(x), w=\(width)] rawSpan=[\(rawMinX), \(rawMaxX)] insetSpan=[\(sceneMinX), \(sceneMaxX)]\n".data(using: .utf8)!)
            }

            result.append(Surface(kind: .window(id: windowID), displayID: displayID, minX: sceneMinX, maxX: sceneMaxX, y: sceneY))
        }

        return result
    }

    private func dockSurface(from infoList: [[String: Any]]) -> Surface? {
        var best: (area: CGFloat, surface: Surface)?

        for info in infoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String, ownerName == "Dock" else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0
            guard width > 0, height > 0 else { continue }

            guard let screen = screenContaining(cgTopLeftPoint: CGPoint(x: x, y: y)) else { continue }
            guard let displayID = displayID(for: screen) else { continue }

            let sceneMinX = x - screen.frame.origin.x
            let sceneMaxX = sceneMinX + width
            let topInScreenSpace = screen.frame.height - (y - topLeftOffsetY(for: screen))

            let area = width * height
            let candidate = Surface(kind: .dock, displayID: displayID, minX: sceneMinX, maxX: sceneMaxX, y: topInScreenSpace)
            if best == nil || area > best!.area {
                best = (area, candidate)
            }
        }

        return best?.surface
    }

    /// The physical display id backing an NSScreen, used to tag every
    /// Surface so OverlayManager can route it to only its own screen's scene.
    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// CGWindowListCopyWindowInfo reports bounds in a global top-left coordinate
    /// space anchored to the primary display. This returns that display's origin
    /// offset so we can translate into each screen's own top-left space.
    private func topLeftOffsetY(for screen: NSScreen) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        // Primary screen's top edge sits at global CG y = 0.
        // Other screens' top-left-space offset = primary.maxY - screen.maxY (in AppKit bottom-left coords).
        return primary.frame.maxY - screen.frame.maxY
    }

    private func screenContaining(cgTopLeftPoint point: CGPoint) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Convert CG top-left point to AppKit bottom-left point relative to primary screen.
        let appKitY = primary.frame.maxY - point.y
        let appKitPoint = CGPoint(x: point.x, y: appKitY)
        return NSScreen.screens.first { $0.frame.contains(appKitPoint) } ?? NSScreen.screens.first
    }
}
