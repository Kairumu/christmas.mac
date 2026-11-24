import SpriteKit

/// Single entry point for the interaction layer. Owns all snowballs/snowmen,
/// implements `SnowInteractionDelegate` (scoop → roll → stack/throw state
/// machine), and wires itself as the scene's `interactionDelegate`.
final class InteractionController: SnowInteractionDelegate {
    private enum Draggable {
        case ball(Snowball)
        case snowman(Snowman)

        var node: SKNode {
            switch self {
            case .ball(let b): return b
            case .snowman(let s): return s
            }
        }

        var mass: CGFloat {
            switch self {
            case .ball(let b): return b.mass
            case .snowman: return 2500
            }
        }
    }

    private enum Phase {
        case idle
        case holding(Draggable)
    }

    /// Two balls stacked, waiting for a third to complete a snowman.
    private struct PartialStack {
        var point: CGPoint
        var balls: [Snowball]
        let container: SKNode
    }

    private weak var scene: (SKScene & SnowSceneAPI)?
    private let physics: ThrowPhysics

    private var phase: Phase = .idle
    private var lastDragPoint: CGPoint?

    private var snowballs: [Snowball] = []
    private var partialStacks: [PartialStack] = []
    private var snowmen: [Snowman] = []

    private let stackDistance: CGFloat = 70
    private let throwSpeedThreshold: CGFloat = 320
    private let dragGrowthFactor: CGFloat = 0.12
    private let scoopGrowthFactor: CGFloat = 0.35

    /// Default ball-size proportions for a snowman assembled whole (not
    /// from 3 separately player-grown balls) — 영서에게 눈사람 부탁. Decreasing
    /// base->torso->head, matching an ordinary stacked snowman's look.
    private static let builtSnowmanBaseRadius: CGFloat = 30
    private static let builtSnowmanTorsoRadius: CGFloat = 22
    private static let builtSnowmanHeadRadius: CGFloat = 15

    /// Key for the per-node action that polls a thrown object's physics body
    /// until it settles, so thrown objects can be re-tracked (see
    /// `throwDraggable`/`watchForSettle`).
    private let settleActionKey = "snowmac-settle-watch"
    private let settleSpeedEpsilon: CGFloat = 4

    init(scene: SKScene & SnowSceneAPI) {
        self.scene = scene
        self.physics = ThrowPhysics(scene: scene)
        scene.interactionDelegate = self
        physics.onShatter = { [weak self] node, point in
            self?.handleShatter(node: node, at: point)
        }
    }

    // MARK: - SnowInteractionDelegate

    func mouseDown(atScenePoint p: CGPoint) {
        guard let scene else { return }

        if let snowman = snowmanNear(p) {
            snowmen.removeAll { $0 === snowman }
            phase = .holding(.snowman(snowman))
            lastDragPoint = p
            GloveCursor.push()
            return
        }

        if let ball = ballNear(p) {
            snowballs.removeAll { $0 === ball }
            phase = .holding(.ball(ball))
            lastDragPoint = p
            GloveCursor.push()
            return
        }

        // A partial stack (2 balls, waiting for a 3rd to become a snowman)
        // claims a 70pt interactive radius via `isInteractive`, but had no
        // pickup branch here — clicks fell through to scoopSnow (0 in
        // mid-air) and did nothing, so the overlay captured clicks in that
        // whole radius with no way to act on them. Picking up the topmost
        // ball disassembles the stack; the remainder goes back to being a
        // loose, re-stackable ball.
        if let idx = partialStackNear(p) {
            let entry = partialStacks[idx]
            let sorted = entry.balls.sorted { $0.radius > $1.radius }
            guard let top = sorted.last else { return }
            let remaining = sorted.dropLast()

            entry.container.removeFromParent()
            partialStacks.remove(at: idx)

            for ball in remaining {
                ball.removeAllActions()
                ball.removeFromParent()
                ball.setScale(1.0)
                ball.alpha = 1
                ball.position = entry.point
                scene.addChild(ball)
                snowballs.append(ball)
            }

            top.removeAllActions()
            top.removeFromParent()
            top.setScale(1.0)
            top.alpha = 1
            top.position = p
            scene.addChild(top)
            phase = .holding(.ball(top))
            lastDragPoint = p
            GloveCursor.push()
            return
        }

        let scooped = scene.scoopSnow(atScenePoint: p)
        guard scooped > 0 else { return }

        let ball = Snowball(radius: Snowball.minRadius)
        ball.position = p
        ball.grow(by: scooped * scoopGrowthFactor)
        scene.addChild(ball)
        phase = .holding(.ball(ball))
        lastDragPoint = p
        GloveCursor.push()
    }

    func mouseDragged(toScenePoint p: CGPoint, velocity: CGVector) {
        guard case .holding(let draggable) = phase, let scene else { return }

        if case .ball(let ball) = draggable, let last = lastDragPoint {
            let distance = hypot(p.x - last.x, p.y - last.y)
            ball.grow(by: distance * dragGrowthFactor)
            let scooped = scene.scoopSnow(atScenePoint: p)
            if scooped > 0 {
                ball.grow(by: scooped * scoopGrowthFactor)
            }
        }

        draggable.node.position = p
        lastDragPoint = p
    }

    func mouseUp(atScenePoint p: CGPoint, velocity: CGVector) {
        guard case .holding(let draggable) = phase else { return }
        phase = .idle
        lastDragPoint = nil
        GloveCursor.pop()

        draggable.node.position = p
        let speed = hypot(velocity.dx, velocity.dy)

        if speed >= throwSpeedThreshold {
            throwDraggable(draggable, velocity: velocity)
            return
        }

        switch draggable {
        case .snowman(let snowman):
            snowmen.append(snowman)
        case .ball(let ball):
            if let target = stackTarget(near: p, excluding: ball) {
                stack(ball, onto: target)
            } else {
                snowballs.append(ball)
            }
        }
    }

    /// Right-click on deep-enough accumulated snow (SnowScene already
    /// checked the depth rule): spawn a standalone ball at rest at p — same
    /// ball-creation path as the scoop branch of mouseDown(atScenePoint:)
    /// (minRadius + scoopGrowthFactor), but added straight into `snowballs`
    /// with a pop-in instead of going through `.holding` (no drag in
    /// progress to hold it for), so it's immediately draggable/stackable/
    /// throwable like any other loose ball.
    func spawnSnowball(atScenePoint p: CGPoint) {
        guard let scene else { return }
        let scooped = scene.scoopSnow(atScenePoint: p)
        guard scooped > 0 else { return }

        let ball = Snowball(radius: Snowball.minRadius)
        ball.position = p
        ball.grow(by: scooped * scoopGrowthFactor)
        ball.setScale(0.01)
        ball.alpha = 0
        scene.addChild(ball)
        ball.run(.group([.fadeIn(withDuration: 0.12), .scale(to: 1.0, duration: 0.12)]))
        snowballs.append(ball)
    }

    /// 영서가 눈사람을 만들어주는 메뉴: assemble a complete snowman directly at p,
    /// via the same shared helper the 3rd-ball stack completion uses.
    func buildSnowman(atScenePoint p: CGPoint) {
        spawnSnowman(at: p, baseRadius: Self.builtSnowmanBaseRadius, torsoRadius: Self.builtSnowmanTorsoRadius, headRadius: Self.builtSnowmanHeadRadius)
    }

    func isInteractive(atScenePoint p: CGPoint) -> Bool {
        ballNear(p) != nil || snowmanNear(p) != nil || partialStackNear(p) != nil
    }

    func resetAll() {
        // The held object (mid-drag) is deliberately absent from all three
        // arrays, so it must be cleaned up explicitly here — otherwise it's
        // orphaned as a scene child that's not draggable, clickable, or
        // resettable, while GloveCursor has already been pushed for it.
        // Must happen before resetting `phase`/popping the cursor so a
        // reset mid-drag is atomic: object gone, cursor restored, phase
        // idle, all in the same call.
        if case .holding(let draggable) = phase {
            draggable.node.removeFromParent()
        }
        snowballs.forEach { $0.removeFromParent() }
        snowmen.forEach { $0.removeFromParent() }
        partialStacks.forEach { $0.container.removeFromParent() }
        snowballs.removeAll()
        snowmen.removeAll()
        partialStacks.removeAll()
        phase = .idle
        lastDragPoint = nil
        GloveCursor.pop()
    }

    // MARK: - Hit testing

    private func ballNear(_ p: CGPoint) -> Snowball? {
        snowballs.first { $0.contains(scenePoint: p) }
    }

    private func snowmanNear(_ p: CGPoint) -> Snowman? {
        snowmen.first { $0.contains(scenePoint: p) }
    }

    private func partialStackNear(_ p: CGPoint) -> Int? {
        partialStacks.firstIndex { hypot($0.point.x - p.x, $0.point.y - p.y) <= stackDistance }
    }

    // MARK: - Stacking

    private enum StackTarget {
        case lone(Snowball)
        case partial(Int)
    }

    private func stackTarget(near p: CGPoint, excluding ball: Snowball) -> StackTarget? {
        if let idx = partialStacks.firstIndex(where: { hypot($0.point.x - p.x, $0.point.y - p.y) < stackDistance }) {
            return .partial(idx)
        }
        if let lone = snowballs.first(where: { $0 !== ball && hypot($0.position.x - p.x, $0.position.y - p.y) < stackDistance }) {
            return .lone(lone)
        }
        return nil
    }

    private func stack(_ ball: Snowball, onto target: StackTarget) {
        switch target {
        case .lone(let other):
            snowballs.removeAll { $0 === other }
            let point = other.position
            other.removeFromParent()
            ball.removeFromParent()

            let container = makePartialStackVisual(balls: [other, ball], at: point)
            scene?.addChild(container)
            partialStacks.append(PartialStack(point: point, balls: [other, ball], container: container))

        case .partial(let idx):
            var entry = partialStacks[idx]
            entry.balls.append(ball)
            ball.removeFromParent()
            entry.container.removeFromParent()
            partialStacks.remove(at: idx)

            let sorted = entry.balls.sorted { $0.radius > $1.radius }
            spawnSnowman(at: entry.point, baseRadius: sorted[0].radius, torsoRadius: sorted[1].radius, headRadius: sorted[2].radius)
        }
    }

    /// Shared snowman-assembly entry point: constructs a Snowman (which
    /// itself runs the staged parts-appear-one-by-one pop-in) and registers
    /// it in `snowmen` so it's clickable/throwable/resettable like any
    /// other. Used both by the 3rd-ball stack completion above and by
    /// buildSnowman(atScenePoint:) (영서에게 눈사람 부탁), so the two paths never
    /// duplicate the assembly/registration logic.
    private func spawnSnowman(at point: CGPoint, baseRadius: CGFloat, torsoRadius: CGFloat, headRadius: CGFloat) {
        let snowman = Snowman(
            basePoint: point,
            variant: SnowmanVariant.next(),
            baseRadius: baseRadius,
            torsoRadius: torsoRadius,
            headRadius: headRadius
        )
        scene?.addChild(snowman)
        snowmen.append(snowman)
    }

    private func makePartialStackVisual(balls: [Snowball], at point: CGPoint) -> SKNode {
        let container = SKNode()
        container.position = point
        container.name = "snowman-partial"

        let sorted = balls.sorted { $0.radius > $1.radius }
        var y: CGFloat = 0
        for ball in sorted {
            ball.position = CGPoint(x: 0, y: y + ball.radius * 0.85)
            ball.setScale(0.01)
            ball.alpha = 0
            container.addChild(ball)
            ball.run(.group([.fadeIn(withDuration: 0.12), .scale(to: 1.0, duration: 0.12)]))
            y += ball.radius * 1.5
        }
        return container
    }

    // MARK: - Throwing / shattering

    private func throwDraggable(_ draggable: Draggable, velocity: CGVector) {
        let node = draggable.node
        node.removeAllActions()
        physics.throwNode(node, velocity: velocity, mass: draggable.mass)
        watchForSettle(draggable)
    }

    /// A thrown node is tracked by nobody while in flight — `mouseDown`
    /// removed it from its array and `throwDraggable` never puts it back.
    /// Poll its physics body until it comes to rest (bounced, landed,
    /// settled below the shatter threshold), then re-file it into its
    /// owning array so it's clickable/resettable again, and drop its
    /// physics body so settled debris stops costing physics time. If the
    /// node shattered instead, `handleShatter` already removed it from the
    /// scene, so the `node.parent != nil` guard below makes this a no-op.
    private func watchForSettle(_ draggable: Draggable) {
        let node = draggable.node
        let watch = SKAction.repeatForever(.sequence([
            .wait(forDuration: 0.2),
            .run { [weak self, weak node] in
                guard let self, let node, node.parent != nil else { return }
                guard let body = node.physicsBody else { return }
                let speed = hypot(body.velocity.dx, body.velocity.dy)
                guard speed < self.settleSpeedEpsilon, abs(body.angularVelocity) < 0.2 else { return }
                node.removeAction(forKey: self.settleActionKey)
                node.physicsBody = nil
                self.retrack(draggable)
            }
        ]))
        node.run(watch, withKey: settleActionKey)
    }

    private func retrack(_ draggable: Draggable) {
        switch draggable {
        case .ball(let ball):
            guard !snowballs.contains(where: { $0 === ball }) else { return }
            snowballs.append(ball)
        case .snowman(let snowman):
            guard !snowmen.contains(where: { $0 === snowman }) else { return }
            snowmen.append(snowman)
        }
    }

    private func handleShatter(node: SKNode, at point: CGPoint) {
        node.removeAction(forKey: settleActionKey)
        node.removeFromParent()
        guard let scene else { return }
        ThrowPhysics.spawnShatter(at: point, in: scene)
    }
}
