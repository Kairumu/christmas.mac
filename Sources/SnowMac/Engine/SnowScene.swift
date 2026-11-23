import SpriteKit

/// Concrete SpriteKit scene: falling snow, per-surface accumulation,
/// snowplow, and the interaction forwarding seam for worker-3's controller.
final class SnowScene: SKScene, SnowSceneAPI {

    // MARK: SnowSceneAPI

    var intensity: SnowIntensity = .normal
    var lowPowerMode: Bool = false

    weak var interactionDelegate: SnowInteractionDelegate?

    // MARK: Internals

    private var accumulator: SnowAccumulator!
    private let flakesLayer = SKNode()
    private let effectsLayer = SKNode()

    /// Live falling flakes we manage ourselves (position/velocity), rather
    /// than SKActions, so we can test landings against accumulation each frame.
    private final class Flake {
        let node: SKSpriteNode
        var velocityY: CGFloat
        var swayPhase: CGFloat
        var swaySpeed: CGFloat
        var swayAmplitude: CGFloat
        /// Amount deposited onto the surface it lands on. Spilled clumps
        /// carry more mass than ordinary flakes.
        var depositAmount: CGFloat
        init(node: SKSpriteNode, velocityY: CGFloat, swayPhase: CGFloat, swaySpeed: CGFloat, swayAmplitude: CGFloat, depositAmount: CGFloat = CGFloat.random(in: 0.4...1.0)) {
            self.node = node
            self.velocityY = velocityY
            self.swayPhase = swayPhase
            self.swaySpeed = swaySpeed
            self.swayAmplitude = swayAmplitude
            self.depositAmount = depositAmount
        }
    }

    private var flakes: [Flake] = []
    private let maxFlakes = 400
    private var spawnAccumulator: Double = 0
    private var lastUpdateTime: TimeInterval?

    /// One shared white-circle texture for every flake/clump sprite, built
    /// once, instead of a fresh SKShapeNode (unbatched, per-node CGPath)
    /// allocated/deallocated per flake. At 펑펑 (220/sec) that was 220
    /// allocations + 220 deallocations/sec/screen.
    private static let flakeTexture: SKTexture = {
        let dimension = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let image = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()

    /// Free-list of hidden, already-parented flake sprites. Landed/spilled
    /// flakes are hidden and pushed here instead of removed from the scene,
    /// so allocation is capped at `maxFlakes` for the process's lifetime
    /// rather than churning per flake.
    private var flakePool: [SKSpriteNode] = []

    private func dequeueFlakeNode() -> SKSpriteNode {
        if let pooled = flakePool.popLast() {
            return pooled
        }
        let node = SKSpriteNode(texture: Self.flakeTexture)
        flakesLayer.addChild(node)
        return node
    }

    private func releaseFlakeNode(_ node: SKSpriteNode) {
        node.isHidden = true
        flakePool.append(node)
    }

    // MARK: - Wind gusts
    //
    // Periodic global lateral force layered on top of each flake's own sway,
    // so snowfall reads as "pushed together" rather than "independent dots."
    // State machine: waiting (20-45s) -> rampUp (2s, 0 -> strength) ->
    // holding (3-6s, strength) -> rampDown (2s, strength -> 0) -> waiting.
    private enum GustPhase { case waiting, rampUp, holding, rampDown }
    private var gustPhase: GustPhase = .waiting
    private var gustPhaseElapsed: TimeInterval = 0
    private var gustPhaseDuration: TimeInterval = Double.random(in: 20...45)
    private var gustStrength: CGFloat = 0
    private var windVelocity: CGFloat = 0

    // displayID 0 is a sentinel: this fallback only exists before the first
    // real updateSurfaces() call (or if WindowTracker couldn't resolve a
    // displayID for this screen). It is never compared against another
    // scene's states, only within this scene's own accumulator, so the
    // sentinel value can't collide with a real screenBottom surface.
    private var fallbackBottomSurface: Surface {
        Surface(kind: .screenBottom(displayID: 0), displayID: 0, minX: 0, maxX: size.width, y: 0)
    }

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        scaleMode = .resizeFill
        addChild(flakesLayer)
        addChild(effectsLayer)
        accumulator = SnowAccumulator(parent: self)
        _ = accumulator.updateSurfaces([fallbackBottomSurface])
    }

    // MARK: - Update loop

    override func update(_ currentTime: TimeInterval) {
        let dt: TimeInterval
        if let last = lastUpdateTime {
            dt = min(currentTime - last, 0.1)
        } else {
            dt = 1.0 / 60.0
        }
        lastUpdateTime = currentTime

        guard size.width > 0, size.height > 0, accumulator != nil else { return }

        if !lowPowerMode {
            updateWind(dt: dt)
        }
        spawnFlakes(dt: dt)
        advanceFlakes(dt: dt)
        accumulator.tick(deltaTime: dt)
    }

    private func updateWind(dt: TimeInterval) {
        gustPhaseElapsed += dt
        switch gustPhase {
        case .waiting:
            guard gustPhaseElapsed >= gustPhaseDuration else { return }
            gustStrength = CGFloat.random(in: 20...60) * (Bool.random() ? 1 : -1)
            gustPhase = .rampUp
            gustPhaseElapsed = 0
            gustPhaseDuration = 2.0
        case .rampUp:
            let t = min(gustPhaseElapsed / gustPhaseDuration, 1.0)
            windVelocity = gustStrength * CGFloat(t)
            guard gustPhaseElapsed >= gustPhaseDuration else { return }
            gustPhase = .holding
            gustPhaseElapsed = 0
            gustPhaseDuration = Double.random(in: 3...6)
        case .holding:
            windVelocity = gustStrength
            guard gustPhaseElapsed >= gustPhaseDuration else { return }
            gustPhase = .rampDown
            gustPhaseElapsed = 0
            gustPhaseDuration = 2.0
        case .rampDown:
            let t = min(gustPhaseElapsed / gustPhaseDuration, 1.0)
            windVelocity = gustStrength * (1 - CGFloat(t))
            guard gustPhaseElapsed >= gustPhaseDuration else { return }
            gustPhase = .waiting
            gustPhaseElapsed = 0
            gustPhaseDuration = Double.random(in: 20...45)
            gustStrength = 0
            windVelocity = 0
        }
    }

    private func spawnFlakes(dt: TimeInterval) {
        let rate = intensity.spawnPerSecond * (lowPowerMode ? 0.3 : 1.0)
        guard rate > 0 else { return }
        spawnAccumulator += rate * dt
        // Bound the backlog to at most one flake's worth instead of letting
        // it grow unboundedly while at the flake cap. Unbounded growth was
        // the original bug: the instant any flake landed and freed a slot,
        // the ballooned backlog dumped enough queued spawns to instantly
        // refill to maxFlakes in one frame, pinning the on-screen flake
        // count at the cap for every intensity level (조금/보통/펑펑 looked
        // identical). But a hard reset to 0 (the first fix) overcorrected:
        // it meant the instant a slot freed, NOTHING could spawn again for
        // up to 1/rate seconds — visible as a sudden stall/gap in the
        // falling snow, worst right after lowering intensity (low rate =>
        // long stall), and most noticeable soon after launch when the
        // initial burst of near-simultaneously-spawned flakes tends to land
        // in a synchronized wave, freeing many slots at once. Clamping to 1
        // keeps growth bounded (still no mask-the-cap burst) while letting
        // the very next freed slot refill immediately rather than stalling,
        // and lets density converge smoothly to the new rate afterward.
        spawnAccumulator = min(spawnAccumulator, 1.0)
        while spawnAccumulator >= 1, flakes.count < maxFlakes {
            spawnAccumulator -= 1
            spawnFlake()
        }
    }

    private func spawnFlake() {
        let radius = CGFloat.random(in: 1.0...2.6)
        let node = dequeueFlakeNode()
        node.size = CGSize(width: radius * 2, height: radius * 2)
        node.alpha = CGFloat.random(in: 0.55...0.95)
        node.position = CGPoint(x: CGFloat.random(in: 0...size.width), y: size.height + CGFloat.random(in: 0...20))
        node.zPosition = 10
        node.isHidden = false

        let speed = CGFloat.random(in: 18...52) * (radius / 1.8)
        let flake = Flake(
            node: node,
            velocityY: -speed,
            swayPhase: CGFloat.random(in: 0...(2 * .pi)),
            swaySpeed: CGFloat.random(in: 0.6...1.8),
            swayAmplitude: CGFloat.random(in: 4...18)
        )
        flakes.append(flake)
    }

    private func advanceFlakes(dt: TimeInterval) {
        guard !flakes.isEmpty else { return }
        var survivors: [Flake] = []
        survivors.reserveCapacity(flakes.count)

        for flake in flakes {
            flake.swayPhase += flake.swaySpeed * CGFloat(dt)
            let sway = sin(flake.swayPhase) * flake.swayAmplitude * CGFloat(dt)
            let effectiveWind = lowPowerMode ? 0 : windVelocity
            flake.node.position.x += sway + effectiveWind * CGFloat(dt)
            flake.node.position.y += flake.velocityY * CGFloat(dt)

            let x = flake.node.position.x
            let y = flake.node.position.y

            if x < -10 { flake.node.position.x = size.width + 10 }
            if x > size.width + 10 { flake.node.position.x = -10 }

            if let landing = landingSurface(atX: x, belowY: y) {
                accumulator.deposit(atX: x, amount: flake.depositAmount, preferSurface: landing.state)
                releaseFlakeNode(flake.node)
                continue
            }

            if y < -40 {
                // Fell past everything (shouldn't normally happen since
                // screenBottom always exists) — just drop it.
                releaseFlakeNode(flake.node)
                continue
            }

            survivors.append(flake)
        }
        flakes = survivors
    }

    /// How far above the flake's y a surface top may sit and still count as
    /// "at or below" it — covers one frame of fall at max flake speed so a
    /// flake that overshoots a surface slightly in a single frame still
    /// lands on it, rather than requiring an exact y match.
    private let landingTolerance: CGFloat = 4

    /// The top-most surface whose snow sits directly below the flake's x AND
    /// at or below the flake's current y, i.e. the highest surface top the
    /// flake would actually hit while falling. Without the `belowY` filter
    /// this returned the globally highest top at x regardless of the
    /// flake's y, which let flakes (and spilled clumps) falling past the
    /// side edge of a tall window deposit UPWARD into that window from
    /// below — vanishing mid-air and crediting their mass far above where
    /// they actually were. Must return the surface itself (not just its y)
    /// so deposit() lands snow on the same surface the flake actually
    /// stopped at — otherwise deposit()'s own lookup (first x-range match)
    /// always resolves to screenBottom, since screenBottom's range spans
    /// the full screen width.
    private func landingSurface(atX x: CGFloat, belowY y: CGFloat) -> (state: SnowAccumulator.SurfaceState, top: CGFloat)? {
        var best: (state: SnowAccumulator.SurfaceState, top: CGFloat)?
        for state in accumulator.states {
            guard state.surface.minX <= x, x <= state.surface.maxX else { continue }
            let top = accumulator.topY(of: state, atX: x)
            guard top <= y + landingTolerance else { continue }
            if best == nil || top > best!.top {
                best = (state, top)
            }
        }
        return best
    }

    // MARK: - SnowSceneAPI

    func updateSurfaces(_ surfaces: [Surface]) {
        guard accumulator != nil else { return }
        var all = surfaces
        if !all.contains(where: { if case .screenBottom = $0.kind { return true }; return false }) {
            all.append(fallbackBottomSurface)
        }
        _ = accumulator.updateSurfaces(all)
    }

    func surfaceRemoved(_ surface: Surface) {
        guard accumulator != nil else { return }
        guard let state = accumulator.states.first(where: { $0.surface.kind == surface.kind }) else { return }
        spillSnow(from: state)
        accumulator.remove(state)
        // Closing a window must only spill+clear THAT surface's snow — it
        // must never touch the user's built snowmen/snowballs. Do not call
        // interactionDelegate?.resetAll() here; that is resetAllSnow()'s job.
    }

    /// Convert a removed surface's accumulated snow into falling clumps that
    /// re-land on surfaces below (feature 04). Clumps are driven through the
    /// same live `flakes` advance/landing-test loop as ordinary flakes
    /// (`advanceFlakes` / `landingSurface`) rather than a canned SKAction
    /// animation to a fixed fall distance — the canned animation ignored
    /// whatever surface was actually below, so clumps visually passed
    /// through windows and deposit()'s surface-less lookup (`bestSurface`)
    /// then matched screenBottom first regardless, since screenBottom spans
    /// the full screen width and sorts before window surfaces.
    private func spillSnow(from state: SnowAccumulator.SurfaceState) {
        let totalHeight = state.heights.reduce(0, +)
        guard totalHeight > 0 else { return }
        let clumpCount = min(max(Int(totalHeight / 6), 1), 24)
        for _ in 0..<clumpCount {
            let x = CGFloat.random(in: state.surface.minX...max(state.surface.maxX, state.surface.minX + 1))
            let y = state.surface.y + CGFloat.random(in: 0...6)
            let radius = CGFloat.random(in: 3...6)
            let node = dequeueFlakeNode()
            node.size = CGSize(width: radius * 2, height: radius * 2)
            node.alpha = 0.95
            node.position = CGPoint(x: x, y: y)
            node.zPosition = 10
            node.isHidden = false

            let clump = Flake(
                node: node,
                velocityY: -CGFloat.random(in: 60...140),
                swayPhase: CGFloat.random(in: 0...(2 * .pi)),
                swaySpeed: CGFloat.random(in: 0.6...1.8),
                swayAmplitude: CGFloat.random(in: 2...10),
                depositAmount: CGFloat.random(in: 3...6)
            )
            flakes.append(clump)
        }
    }

    /// Guards against overlapping plows: without this, repeated menu clicks
    /// (the run is 1.2s+, easy to double-click) spawn multiple trucks that
    /// drive the same surface simultaneously and race `clearRange` calls.
    private var plowInFlight = false

    func summonSnowplow() {
        guard accumulator != nil else { return }
        guard !plowInFlight else { return }
        guard let target = plowTarget() else { return }
        plowInFlight = true
        Snowplow.summon(in: effectsLayer, accumulator: accumulator, target: target, sceneWidth: size.width) { [weak self] in
            self?.plowInFlight = false
        }
    }

    /// Picks which surface's snow the plow clears. Prefers the most-laden
    /// surface that ISN'T screenBottom when it holds a meaningful amount of
    /// snow: screenBottom sits at scene y=0, which on a real desktop is
    /// where the system Dock lives — the Dock's window renders above our
    /// overlay, so a plow working the bottom pile there would be invisible.
    /// Falls back to screenBottom (or whatever surface exists) so summoning
    /// the plow always gives visible feedback, even with zero accumulation
    /// anywhere (feature request: menu action should never be a silent
    /// no-op).
    private func plowTarget() -> SnowAccumulator.SurfaceState? {
        let meaningfulSnow: CGFloat = 20
        let nonBottom = accumulator.states.filter { if case .screenBottom = $0.surface.kind { return false }; return true }
        if let best = nonBottom.max(by: { $0.heights.reduce(0, +) < $1.heights.reduce(0, +) }),
           best.heights.reduce(0, +) >= meaningfulSnow {
            return best
        }
        return accumulator.mostLadenSurface() ?? accumulator.states.first
    }

    func resetAllSnow() {
        guard accumulator != nil else { return }
        accumulator.clearAll()
        interactionDelegate?.resetAll()
    }

    func clearAccumulatedSnow() {
        guard accumulator != nil else { return }
        accumulator.clearAll()
    }

    func isInteractive(atScenePoint p: CGPoint) -> Bool {
        if accumulator != nil, accumulator.isInteractive(atScenePoint: p) {
            return true
        }
        return interactionDelegate?.isInteractive(atScenePoint: p) ?? false
    }

    func scoopSnow(atScenePoint p: CGPoint) -> CGFloat {
        guard accumulator != nil else { return 0 }
        return accumulator.scoop(atScenePoint: p)
    }

    // MARK: - Mouse forwarding

    private var lastDragPoint: CGPoint?
    private var lastDragTime: TimeInterval?

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        lastDragPoint = p
        lastDragTime = CACurrentMediaTime()
        interactionDelegate?.mouseDown(atScenePoint: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.location(in: self)
        let now = CACurrentMediaTime()
        var velocity = CGVector(dx: 0, dy: 0)
        if let lastPoint = lastDragPoint, let lastTime = lastDragTime, now > lastTime {
            let dt = now - lastTime
            velocity = CGVector(dx: (p.x - lastPoint.x) / CGFloat(dt), dy: (p.y - lastPoint.y) / CGFloat(dt))
        }
        lastDragPoint = p
        lastDragTime = now
        interactionDelegate?.mouseDragged(toScenePoint: p, velocity: velocity)
    }

    override func mouseUp(with event: NSEvent) {
        let p = event.location(in: self)
        let now = CACurrentMediaTime()
        var velocity = CGVector(dx: 0, dy: 0)
        if let lastPoint = lastDragPoint, let lastTime = lastDragTime, now > lastTime {
            let dt = now - lastTime
            velocity = CGVector(dx: (p.x - lastPoint.x) / CGFloat(dt), dy: (p.y - lastPoint.y) / CGFloat(dt))
        }
        lastDragPoint = nil
        lastDragTime = nil
        interactionDelegate?.mouseUp(atScenePoint: p, velocity: velocity)
    }
}
