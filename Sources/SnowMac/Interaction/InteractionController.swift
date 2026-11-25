import AppKit
import SpriteKit

/// Single entry point for the interaction layer. Owns all snowballs/snowmen,
/// implements `SnowInteractionDelegate` (scoop → roll → stack/throw state
/// machine), and wires itself as the scene's `interactionDelegate`.
/// NSObject only because NSMenuItem target/action requires it (snow menu).
final class InteractionController: NSObject, SnowInteractionDelegate {
    private enum Draggable {
        case ball(Snowball)
        case snowman(Snowman)
        /// A 2-ball partial stack, held and moved as one group (its
        /// container node already positions the balls relative to itself).
        case stack(PartialStack)

        var node: SKNode {
            switch self {
            case .ball(let b): return b
            case .snowman(let s): return s
            case .stack(let s): return s.container
            }
        }

        var mass: CGFloat {
            switch self {
            case .ball(let b): return b.mass
            case .snowman: return 2500
            case .stack(let s): return s.balls.reduce(0) { $0 + $1.mass }
            }
        }
    }

    private enum Phase {
        case idle
        case holding(Draggable)
        /// Pressed on bare accumulated snow; whether it's a drag (classic
        /// scoop-and-roll from this point) or a plain click (pops the snow
        /// action menu) is decided by mouseDragged/mouseUp. Right-click
        /// proved unreliable through the click-through overlay, so a plain
        /// left-click is the menu trigger.
        case pendingSnowPress(CGPoint)
        /// Pressed on a partial stack; whether it's a drag (group-move,
        /// see Draggable.stack) or a plain click (pops the "finish as
        /// 2-tier snowman" menu) is decided the same way as
        /// `pendingSnowPress`. The entry is already pulled out of
        /// `partialStacks` so it doesn't double-handle hits while pending.
        case pendingStackPress(PartialStack, CGPoint)
    }

    /// Two balls stacked, waiting for a third to complete a snowman.
    private struct PartialStack {
        var point: CGPoint
        var balls: [Snowball]
        let container: SKNode
        /// Vertical reach of this stack's visual above `point` (`point`'s y
        /// to the top of the upper ball), computed at creation time (see
        /// `makePartialStackVisual`). A flat point-distance check against
        /// `point` alone undershoots a tall stack of two large balls —
        /// dropping a 3rd ball squarely ON TOP of the stack (the natural
        /// place to complete it) can land well over `stackDistance` away
        /// from the base point and silently fail to match. Hit testing
        /// (`partialStackNear`, `stackTarget`'s `.partial` case) instead
        /// treats the stack as a vertical capsule — `stackDistance` of
        /// slack anywhere along this height, via `verticalDistance(from:
        /// base:height:)` — so a drop anywhere over the stack's actual
        /// footprint registers, while a drop clearly off to the side still
        /// doesn't (horizontal slack stays exactly `stackDistance`).
        let height: CGFloat
    }

    private weak var scene: (SKScene & SnowSceneAPI)?
    private let physics: ThrowPhysics

    private var phase: Phase = .idle
    private var lastDragPoint: CGPoint?

    private var snowballs: [Snowball] = []
    private var partialStacks: [PartialStack] = []
    private var snowmen: [Snowman] = []

    /// Per-object fall velocity (points/sec downward), keyed by the managed
    /// node's identity — only ever holds an entry while that object is
    /// actively falling (its support disappeared); gentle settling and
    /// at-rest objects have none. See `tick(dt:)`.
    private var fallVelocities: [ObjectIdentifier: CGFloat] = [:]
    /// Gravity applied while falling — matches SweeperCharacter.advanceFall's
    /// own gravity constant so a dropped prop and a dropped 영서 fall at the
    /// same rate.
    private static let fallGravity: CGFloat = 900
    /// How far (points) an object's base may sit above its surface's
    /// `restingHeight` before it counts as "falling" rather than merely
    /// riding a pile that's a little uneven underneath it.
    private static let fallThreshold: CGFloat = 8
    /// Capped ride speed (points/sec) used to ease an object's base toward
    /// `restingHeight` when it's within `fallThreshold` of it — keeps a
    /// growing/shrinking pile from jittering the object up and down.
    private static let rideSettleSpeed: CGFloat = 30
    /// Tolerance handed to `restingHeight`'s own belowY check — covers one
    /// frame of settling/fall motion, same role as SnowScene's
    /// `landingTolerance`.
    private static let restingTolerance: CGFloat = 4

    /// The stack a plain click (mouseDown→mouseUp with no drag) just
    /// lifted out of `partialStacks`, while `presentStackMenu`'s popUp is
    /// showing its finish-early option. Restored unchanged if the menu is
    /// dismissed without a selection.
    private var pendingStackMenuEntry: PartialStack?

    private let stackDistance: CGFloat = 70
    private let throwSpeedThreshold: CGFloat = 320
    private let dragGrowthFactor: CGFloat = 0.12
    private let scoopGrowthFactor: CGFloat = 0.35

    /// Default ball-size proportions for a snowman assembled whole (not
    /// from separately player-grown balls) — 영서에게 눈사람 부탁. 2-tier
    /// (base + head, no torso): a 3-tier build read as too tall/unsettling
    /// to the user ("너무 징그러워"), matching the same 2-tier look as the
    /// player's own "이대로 눈사람 완성" early-finish. Dropping a ball on the
    /// result still upgrades it to 3-tier afterward, same as any other
    /// 2-tier snowman (see `upgradeToThreeTier`). Keep in sync with
    /// SweeperCharacter.buildBallTargetRadii, which mirrors these so the
    /// real snowman lands at the exact size of the props it replaces.
    private static let builtSnowmanBaseRadius: CGFloat = 30
    private static let builtSnowmanHeadRadius: CGFloat = 18

    /// Upper bounds for ball-stack radii once they become snowman tiers.
    /// Snowball.maxRadius lets a player-grown ball get much bigger than a
    /// classic snowman tier should ever be; without clamping here, a
    /// stack of maxed balls (or a maxed ball dropped as a torso) produces
    /// an oversized, badly-proportioned snowman instead of the intended
    /// cute/compact look — the 3rd-ball stack completion
    /// (`stack(_:onto:)`'s `.partial` case), the 2-ball early finish
    /// (`menuFinishTwoTierSnowman`), and the 2-tier→3-tier torso upgrade
    /// (`upgradeToThreeTier`) all clamp through these.
    private static let maxTierBaseRadius: CGFloat = 34
    private static let maxTierTorsoRadius: CGFloat = 26
    private static let maxTierHeadRadius: CGFloat = 22

    /// Key for the per-node action that polls a thrown object's physics body
    /// until it settles, so thrown objects can be re-tracked (see
    /// `throwDraggable`/`watchForSettle`).
    private let settleActionKey = "snowmac-settle-watch"
    private let settleSpeedEpsilon: CGFloat = 4

    init(scene: SKScene & SnowSceneAPI) {
        self.scene = scene
        self.physics = ThrowPhysics(scene: scene)
        super.init()
        scene.interactionDelegate = self
        physics.onShatter = { [weak self] node, point in
            self?.handleShatter(node: node, at: point)
        }
    }

    // MARK: - Snow action menu (plain left-click on bare snow)

    private func presentSnowMenu(atScenePoint p: CGPoint) {
        guard let scene, let view = scene.view else { return }
        let menu = NSMenu()

        let ballItem = NSMenuItem(title: "여기에 눈덩이 만들기", action: #selector(menuMakeSnowball(_:)), keyEquivalent: "")
        ballItem.target = self
        ballItem.representedObject = NSValue(point: p)
        menu.addItem(ballItem)

        let snowmanItem = NSMenuItem(title: "영서에게 눈사람 부탁", action: #selector(menuAskSnowman(_:)), keyEquivalent: "")
        snowmanItem.target = self
        menu.addItem(snowmanItem)

        menu.popUp(positioning: nil, at: scene.convertPoint(toView: p), in: view)
    }

    @objc private func menuMakeSnowball(_ item: NSMenuItem) {
        guard let value = item.representedObject as? NSValue else { return }
        spawnSnowball(atScenePoint: value.pointValue)
    }

    @objc private func menuAskSnowman(_ item: NSMenuItem) {
        scene?.summonSweeperForSnowman()
    }

    // MARK: - Stack action menu (plain left-click on a partial stack)

    /// Plain click (no drag) on a partial stack: offer to finish it early
    /// as a 2-tier snowman instead of waiting for a 3rd ball. Mirrors
    /// `presentSnowMenu`'s popup mechanics. `popUp` returns whether an
    /// item was actually chosen, so dismissing without choosing (click
    /// elsewhere) puts the stack straight back, unchanged.
    private func presentStackMenu(for entry: PartialStack, atScenePoint p: CGPoint) {
        guard let scene, let view = scene.view else {
            partialStacks.append(entry)
            return
        }
        let menu = NSMenu()

        let finishItem = NSMenuItem(title: "이대로 눈사람 완성", action: #selector(menuFinishTwoTierSnowman(_:)), keyEquivalent: "")
        finishItem.target = self
        menu.addItem(finishItem)

        pendingStackMenuEntry = entry
        let chose = menu.popUp(positioning: nil, at: scene.convertPoint(toView: p), in: view)
        if !chose, let leftover = pendingStackMenuEntry {
            partialStacks.append(leftover)
        }
        pendingStackMenuEntry = nil
    }

    @objc private func menuFinishTwoTierSnowman(_ item: NSMenuItem) {
        guard let entry = pendingStackMenuEntry else { return }
        pendingStackMenuEntry = nil
        entry.container.removeFromParent()
        fallVelocities.removeValue(forKey: ObjectIdentifier(entry.container))
        let sorted = entry.balls.sorted { $0.radius > $1.radius }
        spawnSnowman(
            at: entry.point,
            baseRadius: min(sorted[0].radius, Self.maxTierBaseRadius),
            torsoRadius: nil,
            headRadius: min(sorted[1].radius, Self.maxTierHeadRadius)
        )
    }

    // MARK: - SnowInteractionDelegate

    func mouseDown(atScenePoint p: CGPoint) {
        guard scene != nil else { return }

        if let snowman = snowmanNear(p) {
            snowmen.removeAll { $0 === snowman }
            // Grabbing a mid-fall object (mouseDown already re-files it as
            // held, outside the arrays tick(dt:) scans) must drop its fall
            // state — otherwise a stale velocity would resume as soon as
            // it's set back down.
            fallVelocities.removeValue(forKey: ObjectIdentifier(snowman))
            phase = .holding(.snowman(snowman))
            lastDragPoint = p
            GloveCursor.push()
            return
        }

        if let ball = ballNear(p) {
            snowballs.removeAll { $0 === ball }
            fallVelocities.removeValue(forKey: ObjectIdentifier(ball))
            phase = .holding(.ball(ball))
            lastDragPoint = p
            GloveCursor.push()
            return
        }

        // A partial stack (2 balls, waiting for a 3rd to become a snowman)
        // claims a 70pt interactive radius via `isInteractive`. Whether
        // this press becomes a group-drag (the balls stay stacked, moving
        // as one unit — see Draggable.stack) or a plain click (pops the
        // "finish early" menu) is decided by mouseDragged/mouseUp, same
        // as the pendingSnowPress click-vs-drag split below.
        if let idx = partialStackNear(p) {
            let entry = partialStacks.remove(at: idx)
            fallVelocities.removeValue(forKey: ObjectIdentifier(entry.container))
            phase = .pendingStackPress(entry, p)
            lastDragPoint = p
            return
        }

        // Bare accumulated snow: don't scoop yet — a drag past the small
        // threshold becomes the classic scoop-and-roll (see mouseDragged),
        // while a plain click pops the snow action menu (see mouseUp).
        phase = .pendingSnowPress(p)
        lastDragPoint = p
    }

    func mouseDragged(toScenePoint p: CGPoint, velocity: CGVector) {
        // A pending snow press turns into the classic scoop-and-roll once
        // the cursor has clearly moved (same 5pt threshold 영서's own
        // click-vs-drag decision uses).
        if case .pendingSnowPress(let origin) = phase, let scene {
            guard hypot(p.x - origin.x, p.y - origin.y) > 5 else { return }
            let scooped = scene.scoopSnow(atScenePoint: origin)
            guard scooped > 0 else {
                phase = .idle
                return
            }
            let ball = Snowball(radius: Snowball.minRadius)
            ball.position = origin
            ball.grow(by: scooped * scoopGrowthFactor)
            scene.addChild(ball)
            phase = .holding(.ball(ball))
            lastDragPoint = origin
            GloveCursor.push()
            // fall through — the fresh .holding phase handles THIS drag too
        }

        // Same click-vs-drag split as above, for a pending partial-stack
        // press: past the threshold, it's a group-drag of the whole stack.
        if case .pendingStackPress(let entry, let origin) = phase {
            guard hypot(p.x - origin.x, p.y - origin.y) > 5 else { return }
            phase = .holding(.stack(entry))
            lastDragPoint = origin
            GloveCursor.push()
            // fall through — the fresh .holding phase handles THIS drag too
        }

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
        if case .pendingSnowPress(let origin) = phase {
            phase = .idle
            presentSnowMenu(atScenePoint: origin)
            return
        }
        if case .pendingStackPress(let entry, let origin) = phase {
            phase = .idle
            presentStackMenu(for: entry, atScenePoint: origin)
            return
        }
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
        case .stack(var entry):
            // Set down at its current (possibly moved) position; a loose
            // ball dropped near here still completes the snowman via
            // stackTarget(near:)'s partialStacks lookup against this point.
            entry.point = p
            partialStacks.append(entry)
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

    /// 영서가 눈사람을 만들어주는 메뉴: assemble a complete 2-tier snowman
    /// directly at p, via the same shared helper the 3rd-ball stack
    /// completion uses.
    func buildSnowman(atScenePoint p: CGPoint) {
        spawnSnowman(at: p, baseRadius: Self.builtSnowmanBaseRadius, torsoRadius: nil, headRadius: Self.builtSnowmanHeadRadius)
    }

    func isInteractive(atScenePoint p: CGPoint) -> Bool {
        ballNear(p) != nil || snowmanNear(p) != nil || partialStackNear(p) != nil
    }

    // MARK: - Falling / resting (per-frame tick)

    /// Called every frame from SnowScene.update, after the sweeper block.
    /// Every managed object NOT currently held (mouseDown already pulled a
    /// held object out of these arrays) and not mid-throw (a non-nil
    /// physicsBody means ThrowPhysics still owns its position) gets
    /// checked against the live surface below it: drop with gravity if its
    /// support just disappeared, or gently ride a pile that's grown/shrunk
    /// under it — mirroring 영서's own live pin-to-surface-top behavior
    /// (SweeperCharacter.update) for loose props instead of a character.
    func tick(dt: TimeInterval) {
        guard let scene else { return }

        // Balls that finish a gravity fall THIS tick get a stacking
        // re-check at their landing spot. Stacking used to be evaluated
        // only at the mouseUp instant — once the fall/settle system
        // landed a dropped ball ON another ball/stack afterwards, nothing
        // ever re-evaluated, so balls released from a height just ended
        // up overlapping unmerged ("직접 만들면 안 만들어지는데").
        var landedBalls: [Snowball] = []
        for ball in snowballs {
            let wasFalling = fallVelocities[ObjectIdentifier(ball)] != nil
            settle(node: ball, baseYOffset: ball.radius, dt: dt, scene: scene)
            if wasFalling,
               fallVelocities[ObjectIdentifier(ball)] == nil,
               ball.physicsBody == nil {
                landedBalls.append(ball)
            }
        }
        for ball in landedBalls {
            // stack() mutates the arrays — only merge balls still loose.
            guard snowballs.contains(where: { $0 === ball }) else { continue }
            if let target = stackTarget(near: ball.position, excluding: ball) {
                stack(ball, onto: target)
            }
        }
        for snowman in snowmen {
            // Snowman.position IS its base (bottom-center anchor), so
            // there's no offset to subtract.
            settle(node: snowman, baseYOffset: 0, dt: dt, scene: scene)
        }
        for i in partialStacks.indices {
            // The container's position is itself the stack's base point
            // (see makePartialStackVisual) — keep `point` in sync whenever
            // settle(...) actually moves it, same as mouseUp's set-down.
            if let newBaseY = settle(node: partialStacks[i].container, baseYOffset: 0, dt: dt, scene: scene) {
                partialStacks[i].point.y = newBaseY
            }
        }
    }

    /// Applies gravity-fall or gentle ride-the-pile settling to one managed
    /// node. `baseYOffset` converts the node's own (possibly center-
    /// anchored) position into its bottom-anchored base y. Returns the
    /// object's new base y whenever it moved this tick, so callers that
    /// track a base point separately (PartialStack) can stay in sync.
    @discardableResult
    private func settle(node: SKNode, baseYOffset: CGFloat, dt: TimeInterval, scene: SKScene & SnowSceneAPI) -> CGFloat? {
        // ThrowPhysics owns this node's position until it settles and is
        // re-tracked (see watchForSettle/retrack) — never fight it, and
        // drop any stale fall state so it doesn't resume once it's done.
        guard node.physicsBody == nil else {
            fallVelocities.removeValue(forKey: ObjectIdentifier(node))
            return nil
        }

        let baseX = node.position.x
        let baseY = node.position.y - baseYOffset
        let desired = scene.restingHeight(atX: baseX, belowY: baseY + Self.restingTolerance)
        let key = ObjectIdentifier(node)

        if baseY > desired + Self.fallThreshold {
            var vy = fallVelocities[key] ?? 0
            vy -= Self.fallGravity * CGFloat(dt)
            var newBaseY = baseY + vy * CGFloat(dt)
            if newBaseY <= desired {
                newBaseY = desired
                fallVelocities.removeValue(forKey: key)
                playLandingBounce(node, at: CGPoint(x: baseX, y: newBaseY + baseYOffset))
            } else {
                fallVelocities[key] = vy
            }
            node.position.y = newBaseY + baseYOffset
            return newBaseY
        }

        // Not (or no longer) falling — any leftover velocity from a moment
        // ago is stale.
        fallVelocities.removeValue(forKey: key)

        guard abs(baseY - desired) <= Self.fallThreshold, desired != baseY else { return nil }
        let maxStep = Self.rideSettleSpeed * CGFloat(dt)
        let newBaseY = baseY + max(-maxStep, min(maxStep, desired - baseY))
        node.position.y = newBaseY + baseYOffset
        return newBaseY
    }

    /// Landing juice for a fall that just touched down: a quick squash-
    /// and-recover (scaleY 0.92 -> 1.0) plus a couple of small snow puffs,
    /// reusing ThrowPhysics.spawnShatter's puff-circle look at a smaller,
    /// cheaper scale.
    private func playLandingBounce(_ node: SKNode, at point: CGPoint) {
        node.yScale = 0.92
        let recover = SKAction.scaleY(to: 1.0, duration: 0.15)
        recover.timingMode = .easeOut
        node.run(recover)
        spawnLandingPuff(at: point)
    }

    private func spawnLandingPuff(at point: CGPoint) {
        guard let scene else { return }
        for _ in 0..<2 {
            let circle = SKShapeNode(circleOfRadius: 5)
            circle.fillColor = .white
            circle.strokeColor = .clear
            circle.alpha = 0.7
            circle.position = CGPoint(x: point.x + CGFloat.random(in: -6...6), y: point.y)
            circle.zPosition = 150
            scene.addChild(circle)
            circle.run(.sequence([
                .group([.scale(to: CGFloat.random(in: 1.8...2.4), duration: 0.3), .fadeOut(withDuration: 0.3)]),
                .removeFromParent()
            ]))
        }
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
        } else if case .pendingStackPress(let entry, _) = phase {
            entry.container.removeFromParent()
        }
        if let pending = pendingStackMenuEntry {
            // A stack menu may be open (popUp runs its own nested run
            // loop); clearing this before it returns stops it from
            // resurrecting an already-reset stack.
            pending.container.removeFromParent()
            pendingStackMenuEntry = nil
        }
        snowballs.forEach { $0.removeFromParent() }
        snowmen.forEach { $0.removeFromParent() }
        partialStacks.forEach { $0.container.removeFromParent() }
        snowballs.removeAll()
        snowmen.removeAll()
        partialStacks.removeAll()
        fallVelocities.removeAll()
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

    /// Distance from `p` to the nearest point on the vertical segment
    /// running from `base` up to `base.y + height` at `base.x` — i.e.
    /// treats a tall stack/snowman as a line with `stackDistance` of
    /// slack all along its height, rather than a single anchor point.
    /// Reduces to the plain point-distance `hypot` when `height == 0`.
    private func verticalDistance(from p: CGPoint, base: CGPoint, height: CGFloat) -> CGFloat {
        let clampedY = min(max(p.y, base.y), base.y + height)
        return hypot(p.x - base.x, p.y - clampedY)
    }

    private func partialStackNear(_ p: CGPoint) -> Int? {
        partialStacks.firstIndex { verticalDistance(from: p, base: $0.point, height: $0.height) <= stackDistance }
    }

    // MARK: - Stacking

    private enum StackTarget {
        case lone(Snowball)
        case partial(Int)
        /// An already-completed 2-tier snowman: 3개 붙이면 3단으로 되게 — a
        /// 2-tier snowman is never a dead end, a dropped ball upgrades it.
        case twoTierSnowman(Snowman)
    }

    /// Priority when more than one target is in range at once: a 2-tier
    /// snowman upgrade ranks highest, then completing an existing partial
    /// stack into a full snowman, then (lowest) pairing with another lone
    /// ball — finishing something already in progress always beats
    /// starting a brand-new pair.
    ///
    /// Each branch tests against the target's actual occupied region, not
    /// just its anchor point — `position`/`point` is always the BASE, so a
    /// flat `stackDistance` from there undershoots anything built from
    /// large balls (dropping squarely on top of a tall stack, or on a big
    /// snowman's head, used to miss both targets entirely and silently
    /// fall through to pairing with some other lone ball instead).
    private func stackTarget(near p: CGPoint, excluding ball: Snowball) -> StackTarget? {
        // A snowman's `hitRadius` already approximates how far from its
        // base point its own body/head reaches (it's the same radius
        // `contains(scenePoint:)` uses for ordinary clicks) — using it
        // here instead of the flat `stackDistance` keeps this consistent
        // with how clicking the snowman already behaves.
        if let snowman = snowmen.first(where: { $0.isTwoTier && hypot($0.position.x - p.x, $0.position.y - p.y) < $0.hitRadius }) {
            return .twoTierSnowman(snowman)
        }
        if let idx = partialStacks.firstIndex(where: { verticalDistance(from: p, base: $0.point, height: $0.height) < stackDistance }) {
            return .partial(idx)
        }
        // Lone balls are just circles, so their "occupied region" is the
        // ball itself — widen the flat `stackDistance` slack by both
        // balls' radii so two big balls pair as soon as they're actually
        // touching, not just within the same flat distance tiny balls use.
        if let lone = snowballs.first(where: { $0 !== ball && hypot($0.position.x - p.x, $0.position.y - p.y) < stackDistance + ball.radius + $0.radius }) {
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
            fallVelocities.removeValue(forKey: ObjectIdentifier(other))
            fallVelocities.removeValue(forKey: ObjectIdentifier(ball))

            let (container, reach) = makePartialStackVisual(balls: [other, ball], at: point)
            scene?.addChild(container)
            partialStacks.append(PartialStack(point: point, balls: [other, ball], container: container, height: reach))

        case .partial(let idx):
            var entry = partialStacks[idx]
            entry.balls.append(ball)
            ball.removeFromParent()
            entry.container.removeFromParent()
            partialStacks.remove(at: idx)
            fallVelocities.removeValue(forKey: ObjectIdentifier(entry.container))
            fallVelocities.removeValue(forKey: ObjectIdentifier(ball))

            let sorted = entry.balls.sorted { $0.radius > $1.radius }
            spawnSnowman(
                at: entry.point,
                baseRadius: min(sorted[0].radius, Self.maxTierBaseRadius),
                torsoRadius: min(sorted[1].radius, Self.maxTierTorsoRadius),
                headRadius: min(sorted[2].radius, Self.maxTierHeadRadius)
            )

        case .twoTierSnowman(let snowman):
            upgradeToThreeTier(snowman, addingTorsoFrom: ball)
        }
    }

    /// A loose ball dropped near an already-finished 2-tier snowman
    /// upgrades it to 3-tier: the new ball becomes the torso. Rebuilding
    /// from scratch at the same point/variant is the simplest correct way
    /// to "insert" a torso mid-structure — Snowman's own assemble() already
    /// does the staged pop-in, so the torso (and the rest of the parts)
    /// pop in again as if the snowman were growing.
    private func upgradeToThreeTier(_ snowman: Snowman, addingTorsoFrom ball: Snowball) {
        let point = snowman.position
        // Only a classic 2-tier snowman ever reaches here (`isTwoTier` is
        // always false for a pixel-sculpture kind — see Snowman.isTwoTier),
        // but `kind`/`colorway` are still threaded through explicitly
        // rather than left to spawnSnowman's random defaults, so this stays
        // correct even if that ever changes: the upgrade keeps the exact
        // look it already had instead of re-rolling a fresh one.
        let kind = snowman.kind
        let colorway = snowman.colorway
        let variant = snowman.variant
        let baseRadius = snowman.baseRadius
        let headRadius = snowman.headRadius
        let torsoRadius = min(ball.radius, Self.maxTierTorsoRadius)

        ball.removeFromParent()
        snowmen.removeAll { $0 === snowman }
        snowman.removeFromParent()
        fallVelocities.removeValue(forKey: ObjectIdentifier(snowman))
        fallVelocities.removeValue(forKey: ObjectIdentifier(ball))

        spawnSnowman(at: point, kind: kind, colorway: colorway, variant: variant, baseRadius: baseRadius, torsoRadius: torsoRadius, headRadius: headRadius)
    }

    /// Shared snowman-assembly entry point: constructs a Snowman (which
    /// itself runs the staged parts-appear-one-by-one pop-in) and registers
    /// it in `snowmen` so it's clickable/throwable/resettable like any
    /// other. Used by the 3rd-ball stack completion, buildSnowman(atScenePoint:)
    /// (영서에게 눈사람 부탁), the 2-tier "finish early" menu (`torsoRadius: nil`),
    /// and the 2-tier→3-tier upgrade (explicit `kind`/`colorway`/`variant`,
    /// to keep the look the same instead of rolling a fresh one) — so none
    /// of those paths duplicate the assembly/registration logic.
    ///
    /// `kind`/`variant` default to a fresh roll each call (every completion
    /// path except the upgrade wants that) — `kind` picks one of the 10
    /// looks (feature: pixel-art snowman kinds; see SnowmanKind.random's
    /// weighting), `colorway` picks this spawn's pastel tint for whichever
    /// pixel-sculpture kind came up (a `.classic` roll ignores it and uses
    /// `variant` instead).
    private func spawnSnowman(at point: CGPoint, kind: SnowmanKind = SnowmanKind.random(), colorway: SnowmanColorway = SnowmanColorway.random(), variant: SnowmanVariant = SnowmanVariant.next(), baseRadius: CGFloat, torsoRadius: CGFloat?, headRadius: CGFloat) {
        let snowman = Snowman(
            basePoint: point,
            kind: kind,
            colorway: colorway,
            variant: variant,
            baseRadius: baseRadius,
            torsoRadius: torsoRadius,
            headRadius: headRadius
        )
        scene?.addChild(snowman)
        snowmen.append(snowman)
    }

    /// Arranges two balls as a strict vertical stack inside a fresh
    /// container positioned at `point` — bigger ball always on the bottom
    /// (ties keep their given order, since `sorted` is stable), smaller on
    /// top, both centered on the same x, with the same 0.3 overlap
    /// fraction `Snowman.assemble`'s tiers use. Previously each ball's
    /// offset was computed independently via an incrementing accumulator
    /// sized off that ball's OWN radius only, which (for two near-equal/
    /// maxed balls) under-separated the pair into a visually overlapping
    /// blob instead of a clean stack; this computes both centers from the
    /// pair together so the result is consistent regardless of how close
    /// the two radii are.
    ///
    /// Also returns the vertical reach of the resulting visual (`point`'s
    /// y to the top of the upper ball), so the caller can size the
    /// stack's hit-test radius to actually cover it — a flat
    /// `stackDistance` undershoots a tall stack of two large balls.
    private func makePartialStackVisual(balls: [Snowball], at point: CGPoint) -> (container: SKNode, reach: CGFloat) {
        let container = SKNode()
        container.position = point
        container.name = "snowman-partial"

        let overlap: CGFloat = 0.3
        let sorted = balls.sorted { $0.radius > $1.radius }
        let bottom = sorted[0]
        let top = sorted[1]

        let bottomCenterY = bottom.radius * 0.85
        let topCenterY = bottomCenterY + (bottom.radius + top.radius) * (1 - overlap)

        for (ball, centerY) in [(bottom, bottomCenterY), (top, topCenterY)] {
            ball.position = CGPoint(x: 0, y: centerY)
            ball.setScale(0.01)
            ball.alpha = 0
            container.addChild(ball)
            ball.run(.group([.fadeIn(withDuration: 0.12), .scale(to: 1.0, duration: 0.12)]))
        }

        return (container, topCenterY + top.radius)
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
        case .stack(var entry):
            // A thrown stack that lands (bounces, doesn't shatter) becomes
            // a partial stack again at its rest position — cleaner than
            // unpacking it into two loose balls, since the container
            // already holds them correctly positioned relative to itself.
            guard !partialStacks.contains(where: { $0.container === entry.container }) else { return }
            entry.point = entry.container.position
            partialStacks.append(entry)
        }
    }

    private func handleShatter(node: SKNode, at point: CGPoint) {
        node.removeAction(forKey: settleActionKey)
        node.removeFromParent()
        guard let scene else { return }
        ThrowPhysics.spawnShatter(at: point, in: scene)
    }
}
