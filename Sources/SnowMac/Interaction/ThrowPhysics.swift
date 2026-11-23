import SpriteKit

private enum ThrowCategory {
    static let edge: UInt32 = 1 << 0
    static let throwable: UInt32 = 1 << 1
}

/// Applies SpriteKit physics to thrown snowballs/snowmen: bounces off screen edges
/// (feature 09, restitution) and reports hard impacts so the caller can shatter the
/// node. Installs its own edge-loop physics body on the scene so it does not need
/// to touch Engine/* for collision surfaces.
final class ThrowPhysics: NSObject, SKPhysicsContactDelegate {
    private weak var scene: SKScene?
    private var edgeInstalled = false
    private let shatterSpeedThreshold: CGFloat = 480

    /// Called with the node that hit a wall hard enough to shatter, and the impact point.
    var onShatter: ((SKNode, CGPoint) -> Void)?

    init(scene: SKScene) {
        self.scene = scene
        super.init()
        scene.physicsWorld.contactDelegate = self
        installEdgeLoopIfNeeded()
    }

    private func installEdgeLoopIfNeeded() {
        guard let scene, !edgeInstalled, scene.frame.width > 0, scene.frame.height > 0 else { return }
        let edge = SKPhysicsBody(edgeLoopFrom: scene.frame)
        edge.restitution = 0.75
        edge.friction = 0.1
        edge.categoryBitMask = ThrowCategory.edge
        scene.physicsBody = edge
        edgeInstalled = true
    }

    /// Gives `node` a dynamic physics body with `velocity` so it flies, bounces off
    /// the screen edges, and reports back via `onShatter` on a hard impact.
    func throwNode(_ node: SKNode, velocity: CGVector, mass: CGFloat) {
        installEdgeLoopIfNeeded()
        let bounds = node.calculateAccumulatedFrame()
        let radius = max(bounds.width, bounds.height, 12) / 2

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.velocity = velocity
        body.restitution = 0.6
        body.friction = 0.2
        body.linearDamping = 0.1
        body.angularDamping = 0.4
        body.allowsRotation = true
        body.mass = max(mass, 1) / 40
        body.categoryBitMask = ThrowCategory.throwable
        body.collisionBitMask = ThrowCategory.edge
        body.contactTestBitMask = ThrowCategory.edge
        node.physicsBody = body
    }

    func didBegin(_ contact: SKPhysicsContact) {
        let bodies = [contact.bodyA, contact.bodyB]
        guard bodies.contains(where: { $0.categoryBitMask == ThrowCategory.edge }),
              let thrownBody = bodies.first(where: { $0.categoryBitMask == ThrowCategory.throwable }),
              let node = thrownBody.node else { return }

        let v = thrownBody.velocity
        let speed = hypot(v.dx, v.dy)
        if speed >= shatterSpeedThreshold {
            onShatter?(node, contact.contactPoint)
        }
    }

    /// Spawns white fragment particles that fly outward and fade, plus a soft snow
    /// puff (feature 09, "와장창" shatter-on-hard-impact).
    static func spawnShatter(at point: CGPoint, in scene: SKScene) {
        let puff = SKShapeNode(circleOfRadius: 6)
        puff.fillColor = .white
        puff.strokeColor = .clear
        puff.alpha = 0.6
        puff.position = point
        puff.zPosition = 500
        scene.addChild(puff)
        puff.run(.sequence([
            .group([.scale(to: 3.4, duration: 0.35), .fadeOut(withDuration: 0.35)]),
            .removeFromParent()
        ]))

        for _ in 0..<12 {
            let fragment = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.5...3.5))
            fragment.fillColor = .white
            fragment.strokeColor = .clear
            fragment.alpha = 0.9
            fragment.position = point
            fragment.zPosition = 501
            scene.addChild(fragment)

            let angle = CGFloat.random(in: 0...(2 * .pi))
            let distance = CGFloat.random(in: 18...60)
            let destination = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            let move = SKAction.move(to: destination, duration: 0.4)
            move.timingMode = .easeOut
            fragment.run(.sequence([
                .group([move, .fadeOut(withDuration: 0.4)]),
                .removeFromParent()
            ]))
        }
    }
}
