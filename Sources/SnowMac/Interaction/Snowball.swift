import SpriteKit

/// A single rollable/throwable snowball. White SKShapeNode core plus a few subtle
/// gray texture dots. `radius` drives both the visual size and `mass`.
final class Snowball: SKNode {
    static let minRadius: CGFloat = 7
    static let maxRadius: CGFloat = 46

    private(set) var radius: CGFloat
    private let body = SKShapeNode()

    private struct DotSpec {
        let angle: CGFloat
        /// Fraction of the ball's current radius, 0...0.75.
        let unitDistance: CGFloat
    }
    private var dotSpecs: [DotSpec] = []
    private var dotNodes: [SKShapeNode] = []

    /// Simple radius-driven mass used for throw physics / stack ordering.
    var mass: CGFloat { radius * radius }

    init(radius: CGFloat = Snowball.minRadius) {
        self.radius = max(radius, Snowball.minRadius)
        super.init()
        name = "snowball"
        zPosition = 100
        addChild(body)
        makeDotPool()
        redraw()
    }

    required init?(coder: NSCoder) {
        fatalError("Snowball does not support coder init")
    }

    /// Grows the ball by `delta` (world units), capped at `maxRadius`. No-op for
    /// non-positive deltas.
    func grow(by delta: CGFloat) {
        guard delta > 0, radius < Snowball.maxRadius else { return }
        radius = min(radius + delta, Snowball.maxRadius)
        redraw()
    }

    func contains(scenePoint p: CGPoint, slack: CGFloat = 6) -> Bool {
        hypot(p.x - position.x, p.y - position.y) <= radius + slack
    }

    /// Texture dots are generated ONCE, at fixed unit angle/distance
    /// fractions, sized for the largest this ball could ever grow
    /// (`maxRadius`). `redraw()` (called on every drag event, 60-120/sec)
    /// then only repositions/toggles visibility on these existing nodes —
    /// it never reallocates a node or a CGPath — instead of tearing down
    /// and rebuilding the whole dot set every event (~900 node churns/sec
    /// while rolling), which also made the texture visibly shimmer from
    /// being re-randomized every frame.
    private func makeDotPool() {
        let maxDotCount = max(3, Int(Snowball.maxRadius / 6))
        for _ in 0..<maxDotCount {
            let dotRadius = CGFloat.random(in: 1...2.2)
            let dot = SKShapeNode(circleOfRadius: dotRadius)
            dot.fillColor = SKColor(white: 0.88, alpha: 0.55)
            dot.strokeColor = .clear
            dot.zPosition = 1
            dot.isHidden = true
            addChild(dot)
            dotNodes.append(dot)
            dotSpecs.append(DotSpec(angle: CGFloat.random(in: 0...(2 * .pi)), unitDistance: CGFloat.random(in: 0...0.75)))
        }
    }

    private func redraw() {
        body.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        body.fillColor = .white
        body.strokeColor = SKColor(white: 0.82, alpha: 1)
        body.lineWidth = 1

        let visibleCount = max(3, Int(radius / 6))
        for (i, dot) in dotNodes.enumerated() {
            guard i < visibleCount else {
                dot.isHidden = true
                continue
            }
            let spec = dotSpecs[i]
            dot.isHidden = false
            dot.position = CGPoint(x: cos(spec.angle) * spec.unitDistance * radius, y: sin(spec.angle) * spec.unitDistance * radius)
        }
    }
}
