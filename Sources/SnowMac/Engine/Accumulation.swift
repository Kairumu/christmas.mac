import Foundation
import SpriteKit

/// Per-surface snow heightmap: a fixed-width column model. Each surface's
/// accumulated snow is rendered as a single smooth, bumpy SKShapeNode whose
/// top edge follows the column heights.
final class SnowAccumulator {
    /// Width of each height column, in points.
    static let columnWidth: CGFloat = 8
    /// Maximum snow height any single column may reach.
    static let maxHeight: CGFloat = 40
    /// Minimum height a column must have before it's considered "deep enough"
    /// to scoop or to be hit-testable as interactive snow.
    static let interactiveDepthThreshold: CGFloat = 6

    final class SurfaceState {
        var surface: Surface
        var heights: [CGFloat] {
            didSet { isDirty = true }
        }
        /// Rendered path (see `render(_:)`) is built in LOCAL coordinates;
        /// `node.position` is kept at (surface.minX, surface.y) — either
        /// snapped directly or animated there, see `updateSurfaces` — so a
        /// pure position change never needs the path itself rebuilt.
        let node: SKShapeNode
        /// Set whenever `heights` or the surface's WIDTH (column count)
        /// change; a surface that only moved doesn't need its path
        /// rebuilt — see `updateSurfaces`'s position-only branch.
        var isDirty = true

        init(surface: Surface, node: SKShapeNode) {
            self.surface = surface
            let columns = SurfaceState.columnCount(for: surface)
            self.heights = Array(repeating: 0, count: max(columns, 1))
            self.node = node
        }

        static func columnCount(for surface: Surface) -> Int {
            let width = max(surface.maxX - surface.minX, 0)
            return max(Int((width / SnowAccumulator.columnWidth).rounded(.up)), 1)
        }
    }

    private(set) var states: [SurfaceState] = []
    private let parent: SKNode
    private var timeSinceRender: TimeInterval = 0
    private let renderInterval: TimeInterval = 1.0 / 10.0

    init(parent: SKNode) {
        self.parent = parent
    }

    // MARK: - Surface reconciliation

    /// Reconcile tracked surfaces with the latest set. Persisting surfaces
    /// (matched by `Surface.kind`) keep their accumulated heights and shift
    /// their rendered shape if the surface moved. New surfaces are added.
    /// Removed surfaces are returned so the caller can drop their snow.
    func updateSurfaces(_ surfaces: [Surface]) -> [SurfaceState] {
        var next: [SurfaceState] = []
        var removed: [SurfaceState] = []

        for incoming in surfaces {
            if let existing = states.first(where: { $0.surface.kind == incoming.kind }) {
                let oldWidth = existing.surface.maxX - existing.surface.minX
                let widthChanged = oldWidth != (incoming.maxX - incoming.minX)
                // This runs every poll (10-30 Hz) whether or not anything
                // moved; only touch the node when the surface's geometry
                // actually changed, so an unchanged surface doesn't get its
                // path rebuilt (or re-animated) just because it was
                // reconciled again.
                if existing.surface != incoming {
                    if widthChanged {
                        // Column count changes with width, so the path must
                        // be rebuilt (render(), below, now works in local
                        // coordinates). Snap the node straight to its new
                        // origin instead of animating — the rendered shape
                        // is changing this same frame anyway, so blending
                        // the position too would just read as a mismatched
                        // wobble.
                        existing.node.removeAction(forKey: Self.moveActionKey)
                        existing.node.position = CGPoint(x: incoming.minX, y: incoming.y)
                        existing.isDirty = true
                    } else {
                        // Position-only change (a window drag/move — same
                        // width means the same column count, and `heights`
                        // itself is untouched here): the already-rendered
                        // local path is still valid, so don't rebuild it.
                        // Animate the node to its new origin over a short
                        // beat instead of snapping, so the jump between this
                        // poll's position and the last one blends smoothly —
                        // this is what fixes the visible lag/stepping while
                        // dragging a window.
                        animateMove(existing, to: CGPoint(x: incoming.minX, y: incoming.y))
                    }
                }
                existing.surface = incoming
                let newColumns = SurfaceState.columnCount(for: incoming)
                if newColumns != existing.heights.count {
                    existing.heights = resample(existing.heights, to: newColumns, widthChanged: widthChanged)
                }
                next.append(existing)
            } else {
                let node = SKShapeNode()
                node.fillColor = SKColor(white: 1.0, alpha: 0.95)
                // No stroke: a stroked closed path draws a visible hairline
                // along the BASELINE even where display height is 0, which
                // reads as a white line running across the whole window top.
                node.strokeColor = .clear
                node.lineWidth = 0
                node.lineJoin = .round
                node.lineCap = .round
                node.zPosition = 5
                // render() builds the path in LOCAL coordinates relative to
                // this origin — positioning the node here is what places it
                // in scene space.
                node.position = CGPoint(x: incoming.minX, y: incoming.y)
                parent.addChild(node)
                let state = SurfaceState(surface: incoming, node: node)
                next.append(state)
            }
        }

        for existing in states where !next.contains(where: { $0 === existing }) {
            removed.append(existing)
            existing.node.removeFromParent()
        }

        states = next
        // Not `force: true` — a surface that was merely reconciled again
        // without any geometry/height change shouldn't get its path
        // rebuilt; dirty-flagging above already covers moved/new surfaces,
        // and the next `tick()` picks up anything else within 100ms.
        renderAll(force: false)
        return removed
    }

    /// SKAction key the position-blend animation (see `updateSurfaces`'s
    /// position-only branch) runs under — running a new move action with
    /// the SAME key replaces any still-in-flight one instead of stacking,
    /// so a fast-moving drag (many position-only updates in a row) always
    /// animates toward the latest known position.
    private static let moveActionKey = "surfaceMove"
    /// Duration of that position-blend animation between two polls' surface
    /// origins. Short enough to stay responsive during a drag, long enough
    /// to visibly smooth over the poll-interval stepping it's replacing.
    private static let moveDuration: TimeInterval = 0.07

    private func animateMove(_ state: SurfaceState, to position: CGPoint) {
        let move = SKAction.move(to: position, duration: Self.moveDuration)
        move.timingMode = .linear
        state.node.run(move, withKey: Self.moveActionKey)
    }

    private func resample(_ heights: [CGFloat], to count: Int, widthChanged: Bool) -> [CGFloat] {
        guard widthChanged, !heights.isEmpty, count > 0 else {
            if heights.count == count { return heights }
            if heights.count > count { return Array(heights.prefix(count)) }
            return heights + Array(repeating: 0, count: count - heights.count)
        }
        var result: [CGFloat] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let srcIndex = Int((CGFloat(i) / CGFloat(count)) * CGFloat(heights.count))
            result.append(heights[min(srcIndex, heights.count - 1)])
        }
        return result
    }

    // MARK: - Deposit / removal

    /// Deposit snow at an x position (scene coords) onto the surface whose
    /// top edge is nearest below/at that position. Returns true if deposited.
    @discardableResult
    func deposit(atX x: CGFloat, amount: CGFloat, preferSurface: SurfaceState? = nil) -> Bool {
        guard let state = preferSurface ?? bestSurface(forX: x) else { return false }
        let idx = columnIndex(for: x, in: state)
        guard idx >= 0, idx < state.heights.count else { return false }
        state.heights[idx] = min(state.heights[idx] + amount, Self.maxHeight)
        return true
    }

    /// Find the topmost surface whose x-range contains `x`, i.e. the first
    /// surface a falling flake at this x would land on top of, scanning from
    /// the highest y downward isn't tracked here — caller (SnowScene) decides
    /// landing by comparing flake.y against each surface's current top.
    func bestSurface(forX x: CGFloat) -> SurfaceState? {
        states.first { $0.surface.minX <= x && x <= $0.surface.maxX }
    }

    func topY(of state: SurfaceState, atX x: CGFloat) -> CGFloat {
        let idx = columnIndex(for: x, in: state)
        guard idx >= 0, idx < state.heights.count else { return state.surface.y }
        return state.surface.y + state.heights[idx]
    }

    // Not `private`: SweeperCharacter also needs to reason about specific
    // columns directly (push mechanic), beyond deposit/clearRange's x-ranges.
    func columnIndex(for x: CGFloat, in state: SurfaceState) -> Int {
        let rel = x - state.surface.minX
        return Int(rel / Self.columnWidth)
    }

    /// Clears columns spanning [minX, maxX] and redistributes their combined
    /// mass into the columns immediately ahead of travel (`direction`: +1 for
    /// left-to-right, -1 for right-to-left), capping each at `maxHeight` and
    /// touching at most `pushColumns` of them. Used by the sweeper character:
    /// snow she passes isn't deleted, it's pushed into a mound ahead of her
    /// shovel. Returns whatever mass didn't fit under the cap so the caller
    /// can carry it forward instead of losing it.
    @discardableResult
    func pushSnow(_ state: SurfaceState, minX: CGFloat, maxX: CGFloat, direction: Int, pushColumns: Int) -> CGFloat {
        let startIdx = max(Int((minX - state.surface.minX) / Self.columnWidth), 0)
        let endIdx = min(Int((maxX - state.surface.minX) / Self.columnWidth), state.heights.count - 1)
        guard startIdx <= endIdx else { return 0 }

        var collected: CGFloat = 0
        for i in startIdx...endIdx {
            collected += state.heights[i]
            state.heights[i] = 0
        }
        guard collected > 0 else { return 0 }

        let aheadStart = direction > 0 ? endIdx + 1 : startIdx - 1
        return depositCapped(state, amount: collected, startIdx: aheadStart, direction: direction, maxColumns: pushColumns)
    }

    /// Deposits `amount` starting at column `startIdx`, stepping by
    /// `direction` (+1/-1), capping each touched column at `maxHeight` and
    /// touching at most `maxColumns` columns. Returns whatever amount still
    /// didn't fit — callers (e.g. the sweeper's end-of-surface dump) turn
    /// that into falling clumps instead of discarding it.
    @discardableResult
    func depositCapped(_ state: SurfaceState, amount: CGFloat, startIdx: Int, direction: Int, maxColumns: Int) -> CGFloat {
        guard amount > 0 else { return 0 }
        var remaining = amount
        var idx = startIdx
        var touched = 0
        while touched < maxColumns, idx >= 0, idx < state.heights.count, remaining > 0 {
            let room = Self.maxHeight - state.heights[idx]
            if room > 0 {
                let add = min(room, remaining)
                state.heights[idx] += add
                remaining -= add
            }
            idx += direction
            touched += 1
        }
        return remaining
    }

    /// Scoop snow near scene point p. Returns amount removed (grams; here
    /// just a height-derived unit), 0 if nothing deep enough.
    func scoop(atScenePoint p: CGPoint) -> CGFloat {
        for state in states {
            guard state.surface.minX <= p.x, p.x <= state.surface.maxX else { continue }
            let idx = columnIndex(for: p.x, in: state)
            guard idx >= 0, idx < state.heights.count else { continue }
            let topY = state.surface.y + state.heights[idx]
            guard abs(p.y - topY) < 14, state.heights[idx] >= Self.interactiveDepthThreshold else { continue }
            let removedHeight = min(state.heights[idx], CGFloat.random(in: 10...16))
            // Spread the scoop slightly across neighboring columns for a natural dip.
            let radius = 1
            var totalRemoved: CGFloat = 0
            for d in -radius...radius {
                let i = idx + d
                guard i >= 0, i < state.heights.count else { continue }
                let falloff: CGFloat = d == 0 ? 1.0 : 0.4
                let amt = min(state.heights[i], removedHeight * falloff)
                state.heights[i] -= amt
                totalRemoved += amt
            }
            return totalRemoved
        }
        return 0
    }

    /// Returns true if there's deep-enough accumulated snow under p.
    func isInteractive(atScenePoint p: CGPoint) -> Bool {
        for state in states {
            guard state.surface.minX <= p.x, p.x <= state.surface.maxX else { continue }
            let idx = columnIndex(for: p.x, in: state)
            guard idx >= 0, idx < state.heights.count else { continue }
            let topY = state.surface.y + state.heights[idx]
            if abs(p.y - topY) < 14, state.heights[idx] >= Self.interactiveDepthThreshold {
                return true
            }
        }
        return false
    }

    /// Returns the surface currently carrying the most total snow, or nil.
    func mostLadenSurface() -> SurfaceState? {
        states.max { $0.heights.reduce(0, +) < $1.heights.reduce(0, +) }
    }

    /// Zero out columns in `state` whose x range overlaps [minX, maxX].
    func clearRange(_ state: SurfaceState, minX: CGFloat, maxX: CGFloat) {
        let startIdx = max(Int((minX - state.surface.minX) / Self.columnWidth), 0)
        let endIdx = min(Int((maxX - state.surface.minX) / Self.columnWidth), state.heights.count - 1)
        guard startIdx <= endIdx else { return }
        for i in startIdx...endIdx {
            state.heights[i] = 0
        }
    }

    func clearAll() {
        for state in states {
            for i in 0..<state.heights.count { state.heights[i] = 0 }
        }
        renderAll(force: true)
    }

    /// Remove a surface's state entirely and return it (for converting its
    /// snow into falling clumps). Does not remove the node from parent here;
    /// caller already does on updateSurfaces, but this handles ad-hoc removal.
    func remove(_ state: SurfaceState) {
        // Zero heights at the same moment the node/state is dropped, so a
        // caller that already read them into falling clumps (spillSnow)
        // can never cause this surface to render both a leftover pile AND
        // spilled clumps of the same snow.
        for i in 0..<state.heights.count { state.heights[i] = 0 }
        state.node.removeFromParent()
        states.removeAll { $0 === state }
    }

    // MARK: - Render

    func tick(deltaTime: TimeInterval) {
        timeSinceRender += deltaTime
        guard timeSinceRender >= renderInterval else { return }
        timeSinceRender = 0
        renderAll(force: false)
    }

    private func renderAll(force: Bool) {
        for state in states where force || state.isDirty {
            render(state)
        }
    }

    /// Width of the moving-average window used to smooth the display-only
    /// profile (a 5-tap box blur: the column itself plus 2 neighbors each side).
    private static let smoothingRadius = 2
    /// Display heights below this render as flat baseline (0), even though
    /// the underlying raw column height (used for collision/topY) may be
    /// nonzero. Kills the "scattered speck" look of near-zero columns.
    private static let speckMinHeight: CGFloat = 2
    /// A run of consecutive above-threshold columns shorter than this many
    /// columns is itself treated as a speck and flattened to baseline, so a
    /// single stray tall column surrounded by zeros doesn't render as an
    /// isolated block.
    private static let speckMinRunLength = 2

    /// Box-blur the raw heights for display purposes only; the raw
    /// `heights` array (read by topY/scoop/deposit) is never touched.
    private func smoothedHeights(_ heights: [CGFloat]) -> [CGFloat] {
        guard heights.count > 1 else { return heights }
        let radius = Self.smoothingRadius
        var result = [CGFloat](repeating: 0, count: heights.count)
        for i in 0..<heights.count {
            var sum: CGFloat = 0
            var count = 0
            for d in -radius...radius {
                let j = i + d
                guard j >= 0, j < heights.count else { continue }
                sum += heights[j]
                count += 1
            }
            result[i] = sum / CGFloat(count)
        }
        return result
    }

    /// Flatten any column below `speckMinHeight`, then flatten any surviving
    /// run of nonzero columns shorter than `speckMinRunLength`. Operates on
    /// the already-smoothed display heights, not the raw heights.
    private func withoutSpecks(_ heights: [CGFloat]) -> [CGFloat] {
        var result = heights
        for i in 0..<result.count where result[i] < Self.speckMinHeight {
            result[i] = 0
        }
        var i = 0
        while i < result.count {
            guard result[i] > 0 else { i += 1; continue }
            var j = i
            while j < result.count, result[j] > 0 { j += 1 }
            if j - i < Self.speckMinRunLength {
                for k in i..<j { result[k] = 0 }
            }
            i = j
        }
        return result
    }

    /// Trace a smooth path through `points` by connecting the midpoint of
    /// each adjacent pair with a quadratic Bézier whose control point is the
    /// point between them — the standard "smooth curve through N points"
    /// construction. Every point pulls the curve toward it without being a
    /// hard vertex, so column-to-column transitions (including down to a
    /// zero-height baseline point) read as soft rolling bumps instead of
    /// straight polyline segments.
    private func addSmoothCurve(to path: CGMutablePath, through points: [CGPoint]) {
        guard let first = points.first else { return }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
    }

    private func render(_ state: SurfaceState) {
        defer { state.isDirty = false }
        let heights = state.heights
        guard !heights.isEmpty else {
            state.node.path = nil
            return
        }
        // Built in LOCAL coordinates — (0, 0) is this surface's own origin,
        // i.e. `state.node.position` (kept at (surface.minX, surface.y) by
        // updateSurfaces) — rather than absolute scene coordinates. That's
        // what lets a pure position change (a window drag) move just the
        // node and skip rebuilding this path entirely.
        let width = max(state.surface.maxX - state.surface.minX, 0)
        let w = Self.columnWidth

        // Column x positions are derived from `columnWidth * index`, but the
        // column count is `ceil(width / columnWidth)` (SurfaceState.columnCount),
        // so the last column's center (and every x built from it) can land
        // past `width` whenever the surface's width isn't an exact multiple
        // of columnWidth — which is the common case. Clamp every x
        // coordinate into the local span [0, width] so the path can never
        // render snow past the surface's actual edges.
        func clampedX(_ x: CGFloat) -> CGFloat {
            min(max(x, 0), width)
        }

        // Display-only profile: smooth first (so a single-column spike
        // bleeds into near-zero neighbors), then flatten whatever's still
        // too small/narrow to read as a real drift. Raw `heights` — read by
        // topY(of:atX:), scoop, deposit, clearRange — is never modified.
        let displayHeights = withoutSpecks(smoothedHeights(heights))

        // Nothing visible to draw — clear the path entirely instead of
        // building a degenerate flat path along the baseline (whose
        // antialiased fill edge can still show as a faint line).
        guard displayHeights.contains(where: { $0 > 0 }) else {
            state.node.path = nil
            return
        }

        // One point per column at its center, plus a baseline anchor at each
        // span edge. Zero-height columns are themselves baseline-height
        // points, so run starts/ends ease into the baseline through the same
        // smooth-curve construction as the span edges — no separate
        // case-by-case tapering needed.
        var points: [CGPoint] = [CGPoint(x: 0, y: 0)]
        points.reserveCapacity(displayHeights.count + 2)
        for (i, h) in displayHeights.enumerated() {
            let x = clampedX((CGFloat(i) + 0.5) * w)
            points.append(CGPoint(x: x, y: h))
        }
        points.append(CGPoint(x: width, y: 0))

        let path = CGMutablePath()
        addSmoothCurve(to: path, through: points)
        path.closeSubpath()

        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            let pathMinX = path.boundingBox.minX
            let pathMaxX = path.boundingBox.maxX
            FileHandle.standardError.write("SNOWMAC_DEBUG render: kind=\(state.surface.kind) surfaceSpan=[\(state.surface.minX), \(state.surface.maxX)] cols=\(heights.count) pathSpan(local)=[\(pathMinX), \(pathMaxX)] nodePos=\(state.node.position)\n".data(using: .utf8)!)
        }

        state.node.path = path
    }
}
