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
        let node: SKShapeNode
        /// Set whenever `heights` or `surface` (span/position) change; a
        /// surface whose shape didn't change doesn't need its path rebuilt.
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
                // This runs every poll (10 Hz) whether or not anything moved;
                // only mark dirty when the surface's geometry actually
                // changed, so an unchanged surface doesn't get its path
                // rebuilt just because it was reconciled again.
                if existing.surface != incoming {
                    existing.isDirty = true
                }
                existing.surface = incoming
                let newColumns = SurfaceState.columnCount(for: incoming)
                if newColumns != existing.heights.count {
                    existing.heights = resample(existing.heights, to: newColumns, widthChanged: oldWidth != (incoming.maxX - incoming.minX))
                }
                next.append(existing)
            } else {
                let node = SKShapeNode()
                node.fillColor = SKColor(white: 1.0, alpha: 0.95)
                node.strokeColor = SKColor(white: 0.85, alpha: 0.6)
                node.lineWidth = 1
                node.zPosition = 5
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

    private func columnIndex(for x: CGFloat, in state: SurfaceState) -> Int {
        let rel = x - state.surface.minX
        return Int(rel / Self.columnWidth)
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

    private func render(_ state: SurfaceState) {
        defer { state.isDirty = false }
        let heights = state.heights
        guard !heights.isEmpty else {
            state.node.path = nil
            return
        }
        let path = CGMutablePath()
        let baseY = state.surface.y
        let minX = state.surface.minX
        let maxX = state.surface.maxX
        let w = Self.columnWidth
        // Taper both ends down to the baseline instead of a sharp vertical
        // wall at the exact span edges, so the rendered pile doesn't read
        // as a hard-edged block hanging past the surface's visible bounds.
        let taper = min(w, 6)

        // Column x positions are derived from `columnWidth * index`, but the
        // column count is `ceil(width / columnWidth)` (SurfaceState.columnCount),
        // so the last column's right edge (and every endX built from it) can
        // land past `maxX` by up to one columnWidth whenever the surface's
        // width isn't an exact multiple of columnWidth — which is the common
        // case. Clamp every x coordinate into the surface span so the path
        // can never render snow past the surface's actual edges.
        func clampedX(_ x: CGFloat) -> CGFloat {
            min(max(x, minX), maxX)
        }

        path.move(to: CGPoint(x: minX, y: baseY))
        path.addLine(to: CGPoint(x: clampedX(minX + taper), y: baseY + heights[0]))
        for (i, h) in heights.enumerated() {
            let x = minX + CGFloat(i) * w
            if i > 0 {
                path.addLine(to: CGPoint(x: clampedX(x), y: baseY + h))
            }
            let endX = x + w
            let isLast = i == heights.count - 1
            path.addLine(to: CGPoint(x: clampedX(isLast ? max(endX - taper, x) : endX), y: baseY + h))
        }
        path.addLine(to: CGPoint(x: maxX, y: baseY))
        path.closeSubpath()

        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            let pathMinX = path.boundingBox.minX
            let pathMaxX = path.boundingBox.maxX
            FileHandle.standardError.write("SNOWMAC_DEBUG render: kind=\(state.surface.kind) surfaceSpan=[\(state.surface.minX), \(state.surface.maxX)] cols=\(heights.count) pathSpan=[\(pathMinX), \(pathMaxX)]\n".data(using: .utf8)!)
        }

        state.node.path = path
    }
}
