import AppKit
import CoreGraphics

/// Polls CGWindowListCopyWindowInfo adaptively — 10 Hz while idle, ramping up
/// to 30 Hz for a bit after any window surface's frame changes (see
/// `tick()`/`fastUntil` below) — converts window bounds into scene-space
/// [Surface] (top edges of normal windows, the Dock, and each screen's bottom edge),
/// and diffs against the previous poll to detect removed surfaces (feature 04).
final class WindowTracker {
    var onSurfacesUpdated: (([Surface]) -> Void)?
    var onSurfaceRemoved: ((Surface) -> Void)?

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
    private let windowEdgeInset: CGFloat = 14

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// The timer itself runs at 30 Hz so a window drag is sampled finely
    /// enough for Accumulation's move-smoothing (Engine/Accumulation.swift)
    /// to animate between poll points smoothly. Running the FULL poll (the
    /// CGWindowListCopyWindowInfo query plus occlusion math) at 30 Hz at all
    /// times would triple idle CPU cost for no visible benefit, though — so
    /// `tick()` below gates most ticks out, and only the full poll's own
    /// cost (not the near-free gate check) ever runs at the higher rate.
    private let pollInterval: TimeInterval = 1.0 / 30.0
    /// While `ProcessInfo.processInfo.systemUptime < fastUntil`, every tick
    /// does a full poll (effectively 30 Hz). Set whenever a poll detects a
    /// window surface's frame actually changed, so a drag — many
    /// consecutive frame changes — keeps extending this window and the
    /// tracker stays at 30 Hz throughout it, decaying back to idle only
    /// `fastPollDuration` after the last detected movement.
    private var fastUntil: TimeInterval = 0
    private let fastPollDuration: TimeInterval = 0.7
    /// Free-running tick counter. At a fixed 30 Hz timer, every 3rd tick
    /// lands at 10 Hz — the previous fixed poll rate — which is what keeps
    /// idle cost unchanged from before this change.
    private var tickCounter = 0

    func start() {
        timer?.invalidate()
        tickCounter = 0
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs on every 30 Hz timer fire; decides whether THIS tick actually
    /// does the (comparatively expensive) full poll, or returns immediately
    /// at near-zero cost. See `fastUntil`/`tickCounter` above for the rule.
    private func tick() {
        tickCounter += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now < fastUntil || tickCounter % 3 == 0 else { return }
        poll(now: now)
    }

    private func poll(now: TimeInterval) {
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

        // A window being dragged/resized reports a changed frame every poll
        // it's moving. Detecting that here (comparing against the previous
        // poll, same as `removed` above) ramps the tracker up to the full
        // 30 Hz rate for a bit so the drag is sampled finely enough for
        // Accumulation's move-smoothing to animate between points smoothly,
        // then lets it decay back to the idle 10 Hz cadence once movement
        // stops. Only `.window` surfaces count — dock/screenBottom don't
        // move independently of their screen.
        let windowFrameChanged = surfaces.contains { incoming in
            guard case .window = incoming.kind else { return false }
            guard let old = previousSurfaces.first(where: { $0.kind == incoming.kind }) else { return false }
            return old.minX != incoming.minX || old.maxX != incoming.maxX || old.y != incoming.y
        }
        if windowFrameChanged {
            fastUntil = now + fastPollDuration
        }

        previousSurfaces = surfaces

        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            let windowCount = surfaces.filter { if case .window = $0.kind { return true }; return false }.count
            let hasDock = surfaces.contains { $0.kind == .dock }
            let ys = surfaces.map { $0.y }
            FileHandle.standardError.write("SNOWMAC_DEBUG poll: total=\(surfaces.count) windows=\(windowCount) dock=\(hasDock) ys=\(ys)\n".data(using: .utf8)!)
            if !removed.isEmpty {
                let suppressed = removed.filter { if case .window(let id, _) = $0.kind { return windowStillExists(id) }; return false }
                FileHandle.standardError.write("SNOWMAC_DEBUG removed: kinds=\(removed.map { $0.kind }) suppressedSpaceSwitch=\(suppressed.map { $0.kind })\n".data(using: .utf8)!)
            }
        }

        // Must fire BEFORE onSurfacesUpdated, not after. onSurfaceRemoved's
        // spill (feature 04) looks up the closed window's SurfaceState in
        // the scene's accumulator to read its piled-up snow. But
        // onSurfacesUpdated's reconciliation (SnowAccumulator.updateSurfaces)
        // already drops the SurfaceState for any surface missing from the
        // new `surfaces` list — which a just-closed window always is. Firing
        // onSurfacesUpdated first meant that by the time onSurfaceRemoved
        // ran, the state was already gone: its lookup silently missed every
        // single time, so the spill never fired regardless of the
        // windowStillExists check below. This is what actually caused
        // "closing a window no longer spills its snow" — not a Space-switch
        // misclassification; windowStillExists itself was verified correct
        // (confirmed false within ~300ms of a real close, across Calculator
        // quit and multiple Finder window closes, with SNOWMAC_DEBUG).
        for surface in removed {
            // A window that disappeared from .optionOnScreenOnly but still
            // exists (queryable by id) is on another Space, or minimized —
            // not closed. Only fire the explicit spill for windows that are
            // truly gone. This is an exact per-window check rather than a
            // count/ratio heuristic, so it is correct for both a single
            // window close (must spill) and a mass app-quit (must spill
            // every one).
            //
            // This check is a heuristic, not a guarantee, in two ways: (1)
            // a window mid close-fade animation can still be queryable here
            // for a poll or two after its shrinking/fading bounds already
            // failed windowSurfaces()'s size/alpha filters, so it reads as
            // "still exists" even though it's actually closing; (2) an
            // occlusion-driven segment reindex on a still-open window can
            // make an old segment's Kind vanish from `surfaces` with no
            // per-window check to run at all. Both cases — and a genuine
            // Space switch/minimize — fall through without firing
            // onSurfaceRemoved here. SnowAccumulator.updateSurfaces's
            // reconciliation still drops that surface's SurfaceState this
            // same poll regardless (it's simply missing from the incoming
            // list), so SnowScene.updateSurfaces spills whatever
            // reconciliation drops as a safety net — see the comment there.
            // That means a genuine Space switch is no longer silent either:
            // its snow spills too, rather than being discarded unspilled.
            if case .window(let id, _) = surface.kind, windowStillExists(id) { continue }
            onSurfaceRemoved?(surface)
        }
        onSurfacesUpdated?(surfaces)
    }

    /// True fullscreen (a Space-filling app, e.g. full-screen video) covers
    /// the entire physical screen INCLUDING the menu bar region, unlike a
    /// merely maximized window which still starts below the menu bar. We
    /// must NOT treat maximized windows as fullscreen — snow piling on
    /// their top edge is the point of this app.
    ///
    /// This used to also drive a per-screen "pause the scene" signal
    /// (feature QW4: fullscreen -> freeze snowfall). That read as "snow
    /// stuck frozen mid-air, scattered across the screen" (SKScene.isPaused
    /// freezes every in-flight flake exactly where it happened to be) —
    /// the opposite of the actual desired behavior: snow should keep
    /// falling and pile on screenBottom while an app is fullscreen. The
    /// pause path has been removed (OverlayManager no longer has an
    /// isPaused/fullscreen path at all); this check now only answers "is
    /// this specific window a fullscreen window," used below to skip
    /// emitting a surface for it — its own top edge sits at the physical
    /// screen top, which isn't a real snow-catching ledge, and letting a
    /// surface through there would catch flakes an instant after they
    /// spawn instead of letting them fall all the way to screenBottom.
    private func isFullscreenWindow(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, screen: NSScreen) -> Bool {
        let epsilon: CGFloat = 2
        let screenRelativeY = y - topLeftOffsetY(for: screen)
        let startsAtTop = abs(screenRelativeY) <= epsilon
        let coversFullHeight = abs(height - screen.frame.height) <= epsilon
        let coversFullWidth = width >= screen.frame.width - epsilon
        return startsAtTop && coversFullHeight && coversFullWidth
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
        guard let displayID = displayID(for: screen), settings.isDisplayEnabled(displayID) else { return nil }
        return Surface(kind: .screenBottom(displayID: displayID), displayID: displayID, minX: 0, maxX: screen.frame.width, y: 0)
    }

    /// A candidate window-surface before occlusion splitting: raw (uninset)
    /// span and vertical extent in CG top-left space, plus its front-to-back
    /// rank (lower = more in front) taken directly from `infoList`'s own
    /// order — CGWindowListCopyWindowInfo documents that order as front to
    /// back for the option set we poll with (no relative-window options).
    private struct RawWindow {
        let windowID: CGWindowID
        let rank: Int
        let rawMinX: CGFloat
        let rawMaxX: CGFloat
        let topY: CGFloat
        let bottomY: CGFloat
        let displayID: CGDirectDisplayID
        let sceneY: CGFloat
    }

    /// How close another window's vertical extent must come to `w`'s own
    /// top-edge row to count as covering it there. Small — this only
    /// absorbs pixel-level bounds noise between visually-touching windows,
    /// not a real gap between two windows that both legitimately show a
    /// sliver of their own top edge.
    private let occlusionMargin: CGFloat = 2
    /// Segments narrower than this (after inset) are dropped as slivers —
    /// an occluder's edge landing a pixel or two inside a window's own span
    /// shouldn't leave a barely-visible, noisy strip of its own.
    private let minSegmentWidth: CGFloat = 8

    /// Builds one Surface per window's top edge — but a window fully or
    /// partially covered by another window IN FRONT of it (anywhere along
    /// that same top-edge row) only gets a Surface for the part that's
    /// actually visible there. Before this, every window's FULL original
    /// span got a Surface regardless of what else was drawn on top of it,
    /// which is wrong whenever two windows overlap: the back window's snow
    /// strip rendered at ITS OWN (often wider, often slightly different y)
    /// span even across the region a front window's body visually covers —
    /// seen as snow floating above/past a window's real edges with a small
    /// gap ("창 위 눈이 아직도 넘침"). Occlusion is checked per-window against
    /// every window ranked in front of it; the open (non-covered) pieces of
    /// its span each become their own segment so reconciliation can track
    /// them independently (see `Surface.Kind.window`'s `segment`).
    private func windowSurfaces(from infoList: [[String: Any]]) -> [Surface] {
        var raws: [RawWindow] = []

        for (rank, info) in infoList.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != ownPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            // Chrome (and other apps) spawn near-invisible helper windows —
            // hover cards, find-bar hosts, PiP placeholders — that are
            // still layer-0 and often pass the size check below. They're
            // not visually present, so they shouldn't catch snow either;
            // kCGWindowAlpha lets us tell them apart from a real window.
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.1 else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0

            guard width >= minWindowWidth, height >= minWindowHeight else { continue }

            guard let screen = screenContaining(cgTopLeftPoint: CGPoint(x: x, y: y)) else { continue }
            guard let displayID = displayID(for: screen) else { continue }
            // Skip building a RawWindow at all for disabled displays — this
            // is what actually saves per-poll cost: the occlusion pass below
            // is O(n^2) over `raws`, so excluding disabled-screen windows
            // here shrinks n instead of filtering the (already computed)
            // result afterward.
            guard settings.isDisplayEnabled(displayID) else { continue }
            // A truly fullscreen window's own "top edge" is the physical
            // screen top — not a real ledge. See isFullscreenWindow's doc
            // for why a surface here is actively wrong, not just useless.
            guard !isFullscreenWindow(x: x, y: y, width: width, height: height, screen: screen) else { continue }

            // CG coords: origin top-left of the primary display, y grows downward.
            // Scene coords: origin bottom-left of the owning screen, y grows upward.
            let rawMinX = x - screen.frame.origin.x
            let rawMaxX = rawMinX + width
            let topInScreenSpace = screen.frame.height - (y - topLeftOffsetY(for: screen))

            raws.append(RawWindow(windowID: windowID, rank: rank, rawMinX: rawMinX, rawMaxX: rawMaxX, topY: y, bottomY: y + height, displayID: displayID, sceneY: topInScreenSpace))
        }

        var result: [Surface] = []
        let debug = ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil

        for w in raws {
            let occluders = raws.filter { front in
                front.rank < w.rank &&
                front.topY - occlusionMargin <= w.topY && w.topY <= front.bottomY + occlusionMargin &&
                front.rawMaxX > w.rawMinX && front.rawMinX < w.rawMaxX
            }

            var openIntervals: [(CGFloat, CGFloat)] = [(w.rawMinX, w.rawMaxX)]
            for occ in occluders {
                openIntervals = openIntervals.flatMap { (lo, hi) -> [(CGFloat, CGFloat)] in
                    let cutLo = max(occ.rawMinX, lo)
                    let cutHi = min(occ.rawMaxX, hi)
                    guard cutLo < cutHi else { return [(lo, hi)] }
                    var pieces: [(CGFloat, CGFloat)] = []
                    if lo < cutLo { pieces.append((lo, cutLo)) }
                    if cutHi < hi { pieces.append((cutHi, hi)) }
                    return pieces
                }
            }

            for (segment, interval) in openIntervals.enumerated() {
                var sceneMinX = interval.0
                var sceneMaxX = interval.1
                // Only inset at the window's OWN true left/right edges — an
                // interior cut made by occlusion is a real, visible boundary
                // already; insetting it too would carve away good snow for
                // no reason.
                if abs(interval.0 - w.rawMinX) < 0.5 { sceneMinX += windowEdgeInset }
                if abs(interval.1 - w.rawMaxX) < 0.5 { sceneMaxX -= windowEdgeInset }
                guard sceneMaxX - sceneMinX >= minSegmentWidth else { continue }

                if debug {
                    FileHandle.standardError.write("SNOWMAC_DEBUG window: id=\(w.windowID) segment=\(segment)/\(openIntervals.count) rawSpan=[\(w.rawMinX), \(w.rawMaxX)] insetSpan=[\(sceneMinX), \(sceneMaxX)] sceneY=\(w.sceneY) occludedBy=\(occluders.map { $0.windowID })\n".data(using: .utf8)!)
                }

                result.append(Surface(kind: .window(id: w.windowID, segment: segment), displayID: w.displayID, minX: sceneMinX, maxX: sceneMaxX, y: w.sceneY))
            }
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
            guard settings.isDisplayEnabled(displayID) else { continue }

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
