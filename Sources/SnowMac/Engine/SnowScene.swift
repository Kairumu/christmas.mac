import Foundation
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
    /// Effective flake cap for the CURRENT intensity (see `SnowIntensity.
    /// maxFlakes`), clamped further in low power mode so a heavy level
    /// doesn't still render its full density while throttled. The flake
    /// pool reuses nodes (see `flakePool` below), so peak allocation for the
    /// process's lifetime is simply the highest cap ever in effect this
    /// session, not this property's live value.
    private var maxFlakes: Int {
        lowPowerMode ? min(intensity.maxFlakes, 500) : intensity.maxFlakes
    }
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

    // MARK: - Blizzard storm (블리자드 one-shot burst)
    //
    // Independent of `intensity`: a ~10s phased burst (ramp-up → full fury →
    // die-down) that overrides spawn rate/cap/wind for its duration, then
    // hands control back to whatever the user's selected intensity already
    // governs. The normal wind-gust state machine above is simply not
    // ticked while a storm is active (see `update(_:)`), so it resumes
    // exactly where it left off once the storm ends.
    private enum BlizzardPhase: Equatable { case none, rampUp, fullFury, dieDown }
    private var blizzardPhase: BlizzardPhase = .none
    private var blizzardPhaseElapsed: TimeInterval = 0
    private var blizzardWindDirection: CGFloat = 1
    private var blizzardWindMagnitude: CGFloat = 0
    private let blizzardRampUpDuration: TimeInterval = 2.0
    private let blizzardFullFuryDuration: TimeInterval = 6.0
    private let blizzardDieDownDuration: TimeInterval = 2.0
    /// ~2000/s at full fury; halved in low power mode (cheap guard — storms
    /// are rare one-shots, no need for finer-grained scaling).
    private var blizzardSpawnRate: Double { lowPowerMode ? 1000 : 2000 }
    private var blizzardFlakeCap: Int { lowPowerMode ? 1000 : 2000 }
    /// Columns are pushed toward this during full fury, not all the way to
    /// `SnowAccumulator.maxHeight` — "near, not at, the cap" per spec, so
    /// surfaces read as buried without clipping flush to the ceiling.
    private static let blizzardSurfaceFillCap: CGFloat = SnowAccumulator.maxHeight * 0.9
    /// Height units/sec deposited directly onto every column of every
    /// surface during full fury; tuned against `blizzardFullFuryDuration`
    /// so a bare surface visibly fills most of the way to the storm cap by
    /// the time full fury ends.
    private static let blizzardSurfaceFillRate: CGFloat = 6.5

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

    /// Cached once — `ProcessInfo.environment` doesn't change mid-process —
    /// so the frame-time probe below costs nothing when SNOWMAC_DEBUG isn't set.
    private static let debugTimingEnabled = ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil
    private static var slowFrameCount = 0

    override func update(_ currentTime: TimeInterval) {
        let debugFrameStart = Self.debugTimingEnabled ? Date() : nil
        defer {
            // Dev-only probe for diagnosing main-thread stutter (see
            // Accumulation.swift's rebuild-budget/change-threshold logic,
            // added for exactly this): logs any update() call over 8ms,
            // which is where SKShapeNode.path re-tessellation spikes showed
            // up before that fix. No-op (not even a Date() allocation)
            // unless SNOWMAC_DEBUG is set.
            if let debugFrameStart {
                let elapsedMs = Date().timeIntervalSince(debugFrameStart) * 1000
                if elapsedMs > 8 {
                    Self.slowFrameCount += 1
                    FileHandle.standardError.write("SNOWMAC_DEBUG frame: update()=\(String(format: "%.2f", elapsedMs))ms slowCount=\(Self.slowFrameCount)\n".data(using: .utf8)!)
                }
            }
        }

        let dt: TimeInterval
        if let last = lastUpdateTime {
            dt = min(currentTime - last, 0.1)
        } else {
            dt = 1.0 / 60.0
        }
        lastUpdateTime = currentTime

        guard size.width > 0, size.height > 0, accumulator != nil else { return }

        if blizzardPhase != .none {
            // Storm wind fully overrides the ambient gust state machine for
            // its duration — the machine is simply not ticked, so it
            // resumes from exactly where it left off once the storm ends.
            updateBlizzard(dt: dt)
        } else if !lowPowerMode {
            updateWind(dt: dt)
        }
        spawnFlakes(dt: dt)
        advanceFlakes(dt: dt)
        accumulator.tick(deltaTime: dt)

        if let sweeper {
            // The surface she's working can vanish wholesale (window closed,
            // Space switch, occlusion re-segmentation). Her internal abort
            // path just fades her out — which read as "영서 disappears when I
            // switch screens." Instead: teleport her (cancel this run,
            // resummon via the normal poof-arrival path) onto the next
            // most-laden surface, if any still holds meaningful snow;
            // otherwise let her go.
            if !sweeper.isAirborne,
               !accumulator.states.contains(where: { $0 === sweeper.surfaceState }) {
                sweeper.cancel()
                self.sweeper = nil
                sweeperInFlight = false
                if let next = accumulator.mostLadenSurface(),
                   next.heights.reduce(0, +) >= 20 {
                    summonSweeper()
                }
            } else {
                sweeper.update(dt: dt)
                // Plow-passes-영서 interaction: only meaningful when both are
                // active on the SAME surface (by reference — two different
                // surfaces can coincidentally share x-ranges, e.g. two windows
                // that haven't been laid out yet, so identity is the only safe
                // check here).
                if let plowCurrentSurface, let plowCurrentX, plowCurrentSurface === sweeper.surfaceState {
                    sweeper.notifyPlowProximity(plowX: plowCurrentX)
                }
            }
        }

        interactionDelegate?.tick(dt: dt)
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

    /// Drives the blizzard's 2s ramp-up → 6s full fury → 2s die-down phase
    /// machine (reusing the wind-gust ramp pattern above), overriding
    /// `windVelocity` directly, and depositing extra mass onto every
    /// surface during full fury. `spawnFlakes`/`spawnFlake` separately
    /// check `blizzardPhase` to override spawn rate/cap/position/speed.
    private func updateBlizzard(dt: TimeInterval) {
        blizzardPhaseElapsed += dt
        switch blizzardPhase {
        case .none:
            return
        case .rampUp:
            let t = min(blizzardPhaseElapsed / blizzardRampUpDuration, 1.0)
            windVelocity = blizzardWindDirection * blizzardWindMagnitude * CGFloat(t)
            guard blizzardPhaseElapsed >= blizzardRampUpDuration else { return }
            blizzardPhase = .fullFury
            blizzardPhaseElapsed = 0
        case .fullFury:
            windVelocity = blizzardWindDirection * blizzardWindMagnitude
            depositBlizzardMassOnAllSurfaces(dt: dt)
            guard blizzardPhaseElapsed >= blizzardFullFuryDuration else { return }
            blizzardPhase = .dieDown
            blizzardPhaseElapsed = 0
        case .dieDown:
            let t = min(blizzardPhaseElapsed / blizzardDieDownDuration, 1.0)
            windVelocity = blizzardWindDirection * blizzardWindMagnitude * (1 - CGFloat(t))
            guard blizzardPhaseElapsed >= blizzardDieDownDuration else { return }
            // Storm over: hand back to whatever the current intensity
            // already governs. windVelocity/spawn rate/cap all read
            // `blizzardPhase` elsewhere, so resetting it to `.none` here is
            // the single switch that restores normal behavior.
            blizzardPhase = .none
            blizzardPhaseElapsed = 0
            windVelocity = 0
        }
    }

    /// Directly deposits mass onto every column of every tracked surface
    /// (not routed through falling flakes at all) so surfaces visibly bury
    /// within the full-fury window regardless of how long an individual
    /// flake takes to fall and land. Clamped to `blizzardSurfaceFillCap`
    /// ("near, not at" `SnowAccumulator.maxHeight`) rather than the real
    /// deposit cap, so storm filling never flush-caps a surface.
    private func depositBlizzardMassOnAllSurfaces(dt: TimeInterval) {
        guard accumulator != nil else { return }
        let amount = Self.blizzardSurfaceFillRate * CGFloat(dt)
        for state in accumulator.states {
            for i in 0..<state.heights.count where state.heights[i] < Self.blizzardSurfaceFillCap {
                state.heights[i] = min(state.heights[i] + amount, Self.blizzardSurfaceFillCap)
            }
        }
    }

    /// Spawn rate for the CURRENT instant: the intensity-driven rate while
    /// no storm is running, otherwise ramped in lockstep with the wind
    /// (same t as `updateBlizzard`'s phase ramps) so the storm's density
    /// builds up and winds down rather than snapping instantly, matching
    /// the "build-up"/"die-down" phase names.
    private var effectiveSpawnRate: Double {
        let base = intensity.spawnPerSecond * (lowPowerMode ? 0.3 : 1.0)
        switch blizzardPhase {
        case .none:
            return base
        case .rampUp:
            let t = min(blizzardPhaseElapsed / blizzardRampUpDuration, 1.0)
            return base + (blizzardSpawnRate - base) * t
        case .fullFury:
            return blizzardSpawnRate
        case .dieDown:
            let t = min(blizzardPhaseElapsed / blizzardDieDownDuration, 1.0)
            return blizzardSpawnRate + (base - blizzardSpawnRate) * t
        }
    }

    private func spawnFlakes(dt: TimeInterval) {
        let rate = effectiveSpawnRate
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
        // in a synchronized wave, freeing many slots at once. Clamping
        // keeps growth bounded (still no mask-the-cap burst) while letting
        // the very next freed slot refill immediately rather than stalling.
        //
        // The clamp bound must be ONE FRAME'S WORTH at the current rate,
        // not a flat 1.0: a flat 1.0 silently capped spawning at one flake
        // per update (~60/s), which flattened every rate above ~60 — 보통
        // (80), 많음 (220), 펑펑 (660), and the blizzard override (2000)
        // all produced identical ~60/s snowfall, so the heavy levels never
        // actually differentiated.
        spawnAccumulator = min(spawnAccumulator, max(1.0, Double(rate) * dt))
        let cap = blizzardPhase == .none ? maxFlakes : blizzardFlakeCap
        while spawnAccumulator >= 1, flakes.count < cap {
            spawnAccumulator -= 1
            spawnFlake()
        }
    }

    /// Normal spawn position: random x along the top edge. During an
    /// active storm, roughly half of flakes instead enter from the
    /// windward screen edge (the side the storm wind blows FROM) at a
    /// random height, so the sustained lateral wind visibly fills the sky
    /// from the side too, not just from above.
    private func spawnPosition() -> CGPoint {
        guard blizzardPhase != .none, Bool.random() else {
            return CGPoint(x: CGFloat.random(in: 0...size.width), y: size.height + CGFloat.random(in: 0...20))
        }
        let windwardX: CGFloat = blizzardWindDirection > 0 ? 0 : size.width
        return CGPoint(x: windwardX, y: CGFloat.random(in: 0...size.height))
    }

    private func spawnFlake() {
        let radius = CGFloat.random(in: 1.0...2.6)
        let node = dequeueFlakeNode()
        node.size = CGSize(width: radius * 2, height: radius * 2)
        node.alpha = CGFloat.random(in: 0.55...0.95)
        node.position = spawnPosition()
        node.zPosition = 10
        node.isHidden = false

        // 펑펑 flakes fall noticeably faster than the other levels, so the
        // extra density reads as driving snow in the air rather than a
        // static wall, and so density actually differentiates from 많음.
        // An active storm layers its own, larger boost on top, independent
        // of the currently selected intensity.
        let speedBoost: CGFloat = intensity == .blizzard ? CGFloat.random(in: 1.25...1.35) : 1.0
        let stormBoost: CGFloat = blizzardPhase == .none ? 1.0 : CGFloat.random(in: 1.5...2.0)
        let speed = CGFloat.random(in: 18...52) * (radius / 1.8) * speedBoost * stormBoost
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
            let previousY = flake.node.position.y
            flake.node.position.x += sway + effectiveWind * CGFloat(dt)
            flake.node.position.y += flake.velocityY * CGFloat(dt)

            let x = flake.node.position.x
            let y = flake.node.position.y

            if x < -10 { flake.node.position.x = size.width + 10 }
            if x > size.width + 10 { flake.node.position.x = -10 }

            // Landing needs BOTH halves: the surface must be at/below where
            // the flake WAS (belowY: previousY — so a flake drifting past a
            // tall window's side never deposits upward into it), AND the
            // flake must have actually fallen to the snow top THIS frame
            // (y <= top + tolerance). The second check was lost in a
            // refactor once: landingSurface alone always matches — some
            // surface (screenBottom) is always below — so every flake
            // "landed" on its first frame: accumulation grew while falling
            // snow was invisible.
            if let landing = landingSurface(atX: x, belowY: previousY),
               y <= landing.top + landingTolerance {
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
        // Reconciliation drops (and returns) the SurfaceState for any
        // surface missing from `all` this poll — not just real window
        // closes (those are already spilled+removed via the explicit
        // surfaceRemoved(_:) path below, BEFORE this runs, so they're
        // already gone from accumulator.states and never show up here
        // again). This is the safety net for every other way a surface can
        // drop out of the incoming list without going through that path:
        // WindowTracker suppresses the explicit spill whenever
        // windowStillExists(id) is true (Space switch/minimize, or a
        // closing window briefly still queryable mid fade-out animation
        // while its shrinking bounds already fail windowSurfaces()'s
        // size/alpha filters), and an occlusion-driven segment
        // reindex/merge on a still-open window can likewise make an old
        // segment's Kind vanish from `all` with nothing upstream ever
        // calling surfaceRemoved for it. This used to be `_ =
        // accumulator.updateSurfaces(all)` — discarding exactly the
        // states the doc comment above updateSurfaces says are "returned
        // so the caller can drop their snow" — which is what let snow
        // vanish instead of spilling in those cases.
        let droppedByReconciliation = accumulator.updateSurfaces(all)
        for state in droppedByReconciliation {
            spillSnow(from: state)
        }
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

    /// Column height (per SnowAccumulator.columnWidth-wide column) at or
    /// above which a contiguous run of columns spills as a small number of
    /// big, fast clumps rather than dispersing into many small, slow ones.
    /// 뭉텅이가 크면 빠르게 떨어짐 — deep snow falls as a heavy mass; shallow
    /// snow scatters and drifts down slowly.
    private static let deepSpillThreshold: CGFloat = 15

    /// Convert a removed surface's accumulated snow into falling mass that
    /// re-lands on surfaces below (feature 04), through the same live
    /// `flakes` advance/landing-test loop as ordinary flakes
    /// (`advanceFlakes` / `landingSurface`) rather than a canned SKAction
    /// animation to a fixed fall distance — the canned animation ignored
    /// whatever surface was actually below, so clumps visually passed
    /// through windows and deposit()'s surface-less lookup (`bestSurface`)
    /// then matched screenBottom first regardless, since screenBottom spans
    /// the full screen width and sorts before window surfaces.
    ///
    /// Walks `heights` as contiguous runs of same-depth-class columns (deep
    /// vs shallow vs empty) rather than treating the whole surface as one
    /// blob, so a surface that's part deep drift / part thin dusting spills
    /// each part the way it actually looks: the drift falls as a few heavy
    /// clumps, the dusting scatters. Each run hands its own exact mass sum
    /// to spillDeepRegion/spillShallowRegion, so total spilled mass across
    /// the whole surface conserves `heights.reduce(0,+)` exactly (modulo
    /// float rounding) rather than the old flat random-amount-per-clump
    /// approximation.
    private func spillSnow(from state: SnowAccumulator.SurfaceState) {
        let heights = state.heights
        guard heights.reduce(0, +) > 0 else { return }

        var i = 0
        while i < heights.count {
            guard heights[i] > 0 else { i += 1; continue }
            let isDeep = heights[i] >= Self.deepSpillThreshold
            var j = i
            var regionMass: CGFloat = 0
            while j < heights.count, heights[j] > 0, (heights[j] >= Self.deepSpillThreshold) == isDeep {
                regionMass += heights[j]
                j += 1
            }
            let regionMinX = state.surface.minX + CGFloat(i) * SnowAccumulator.columnWidth
            let regionMaxX = state.surface.minX + CGFloat(j) * SnowAccumulator.columnWidth
            if isDeep {
                spillDeepRegion(mass: regionMass, minX: regionMinX, maxX: regionMaxX, y: state.surface.y)
            } else {
                spillShallowRegion(mass: regionMass, minX: regionMinX, maxX: regionMaxX, y: state.surface.y)
            }
            i = j
        }
    }

    /// A deep run (every column >= deepSpillThreshold) falls as a handful
    /// of big, fast, barely-swaying clumps — 뭉텅이가 크면 빠르게 떨어짐.
    private func spillDeepRegion(mass: CGFloat, minX: CGFloat, maxX: CGFloat, y: CGFloat) {
        guard mass > 0 else { return }
        let clumpCount = min(max(Int(mass / 10), 1), 8)
        let perClump = mass / CGFloat(clumpCount)
        for _ in 0..<clumpCount {
            let x = CGFloat.random(in: minX...max(maxX, minX + 1))
            spawnFallingMass(
                at: CGPoint(x: x, y: y + CGFloat.random(in: 0...6)),
                amount: perClump,
                radius: CGFloat.random(in: 7...12),
                velocityY: -CGFloat.random(in: 180...280),
                swayAmplitude: CGFloat.random(in: 0...2)
            )
        }
    }

    /// A shallow run (every column < deepSpillThreshold) disperses into
    /// several small, slow, wide-swaying flakes instead of a few clumps —
    /// 흩뿌려져서 천천히 가라앉음.
    private func spillShallowRegion(mass: CGFloat, minX: CGFloat, maxX: CGFloat, y: CGFloat) {
        guard mass > 0 else { return }
        let flakeCount = min(max(Int(mass / 1.5), 2), 20)
        let perFlake = mass / CGFloat(flakeCount)
        for _ in 0..<flakeCount {
            let x = CGFloat.random(in: minX...max(maxX, minX + 1))
            spawnFallingMass(
                at: CGPoint(x: x, y: y + CGFloat.random(in: 0...6)),
                amount: perFlake,
                radius: CGFloat.random(in: 1.5...3),
                velocityY: -CGFloat.random(in: 18...45),
                swayAmplitude: CGFloat.random(in: 12...24)
            )
        }
    }

    /// Spawns a single falling mass at `point` carrying `amount` of snow,
    /// driven through the same live flake advance/landing-test loop as
    /// ordinary flakes (advanceFlakes/landingSurface) so it lands correctly
    /// on whatever surface is actually below it. Shared by
    /// spillDeepRegion/spillShallowRegion (mass-dependent spill, above).
    private func spawnFallingMass(at point: CGPoint, amount: CGFloat, radius: CGFloat, velocityY: CGFloat, swayAmplitude: CGFloat) {
        let node = dequeueFlakeNode()
        node.size = CGSize(width: radius * 2, height: radius * 2)
        node.alpha = 0.95
        node.position = point
        node.zPosition = 10
        node.isHidden = false

        let mass = Flake(
            node: node,
            velocityY: velocityY,
            swayPhase: CGFloat.random(in: 0...(2 * .pi)),
            swaySpeed: CGFloat.random(in: 0.6...1.8),
            swayAmplitude: swayAmplitude,
            depositAmount: amount
        )
        flakes.append(mass)
    }

    /// Spawns a single falling "clump" flake at `point` carrying `amount` of
    /// snow mass, driven through the same live flake advance/landing-test
    /// loop as ordinary flakes (advanceFlakes/landingSurface) so it lands
    /// correctly on whatever surface is actually below it. Used by
    /// SweeperCharacter's end-of-run overflow dump (mass that didn't fit
    /// under the accumulation cap when she pushed her mound to the
    /// surface's edge) — kept as its own fixed-range spawn, separate from
    /// spillSnow's mass-dependent big/dispersed split above, since the
    /// sweeper's overflow isn't a "removed surface" and doesn't carry a
    /// per-column depth to classify.
    private func spawnClump(at point: CGPoint, amount: CGFloat) {
        let radius = CGFloat.random(in: 3...6)
        spawnFallingMass(
            at: point,
            amount: amount,
            radius: radius,
            velocityY: -CGFloat.random(in: 60...140),
            swayAmplitude: CGFloat.random(in: 2...10)
        )
    }

    /// Guards against overlapping plow runs: without this, repeated menu
    /// clicks (a full multi-surface run can take a while) spawn multiple
    /// trucks that drive surfaces simultaneously and race `clearRange` calls.
    /// Separate from `sweeperInFlight` — 제설차 and 영서 are independent
    /// features that can both be active at once.
    private var plowInFlight = false
    /// Live position of the currently-driving plow, reported each frame via
    /// Snowplow's onTick — used only to detect it passing 영서 on the same
    /// surface (see update()). Both nil whenever no plow is driving.
    private var plowCurrentX: CGFloat?
    private weak var plowCurrentSurface: SnowAccumulator.SurfaceState?

    /// A surface below this total height isn't worth a dedicated plow visit
    /// once the big piles are gone.
    private let meaningfulSnowThreshold: CGFloat = 20

    /// 제설차 부르기: clears surfaces SEQUENTIALLY, most-laden first — drives
    /// one surface end-to-end via Snowplow.summon, then (via its onFinish)
    /// immediately picks the next most-laden surface still holding
    /// meaningful snow and drives that, repeating until none remain.
    /// Surfaces already driven during the CURRENT plow chain. Without this
    /// the chain never ends: snow keeps falling while the plow works, so by
    /// the time it finishes a few surfaces the first one has re-accumulated
    /// past the threshold again and gets re-picked forever ("제설차가 계속
    /// 나오네"). Each surface gets at most one pass per summon.
    private var plowVisited = Set<ObjectIdentifier>()

    func summonSnowplow() {
        guard accumulator != nil else { return }
        guard !plowInFlight else { return }
        plowVisited.removeAll()
        guard let first = nextPlowTarget() else { return }
        plowInFlight = true
        driveNextPlowSurface(first)
    }

    /// 블리자드: one-shot storm. Re-entrant while already running is a no-op
    /// (blizzardPhase != .none guards it) — does not touch `intensity` at
    /// all; `updateBlizzard`/`spawnFlakes`/`spawnFlake` key off
    /// `blizzardPhase` to override behavior for the run's duration, then
    /// hand control straight back to whatever `intensity` already governs.
    func triggerBlizzard() {
        guard accumulator != nil, blizzardPhase == .none else { return }
        blizzardPhase = .rampUp
        blizzardPhaseElapsed = 0
        blizzardWindDirection = Bool.random() ? 1 : -1
        blizzardWindMagnitude = CGFloat.random(in: 180...250)
    }

    /// Picks the next surface for the plow chain: the most-laden surface
    /// still holding at least `meaningfulSnowThreshold`, screenBottom
    /// included (see historical note below on why screenBottom isn't
    /// special-cased out).
    ///
    /// This used to special-case screenBottom OUT (only picked it when no
    /// other surface held >=20 units), on the theory that the real macOS
    /// Dock renders above our overlay at scene y=0, hiding a plow working
    /// the bottom pile. That theory doesn't hold: our overlay window level
    /// is `.statusBar - 1` (OverlayWindow.swift) = 24; the Dock's own window
    /// level is `CGWindowLevelForKey(.dockWindow)` = 20 — verified both as
    /// raw NSWindow.Level/CGWindowLevelForKey values and against the real
    /// on-screen Dock-bar window's kCGWindowLayer on this machine. 24 > 20,
    /// so our overlay renders IN FRONT of the Dock, not behind it; a plow
    /// (or snow pile) at screenBottom is visible. The "bottom plow looked
    /// invisible" symptom that motivated this special case was actually the
    /// unrelated dead-scene bug described in OverlayWindow.swift (every menu
    /// action, snowplow included, was silently forwarded to a throwaway
    /// scene) — already fixed there. With that fixed, biasing away from
    /// screenBottom only caused the opposite bug: while ANY window held
    /// >=20 units, screenBottom's own pile — however large — could never be
    /// picked, so "제설차가 바닥 눈을 못 치움" (plow never clears the bottom).
    private func nextPlowTarget() -> SnowAccumulator.SurfaceState? {
        accumulator.states
            .filter { !plowVisited.contains(ObjectIdentifier($0)) }
            .filter { $0.heights.reduce(0, +) >= meaningfulSnowThreshold }
            .max { $0.heights.reduce(0, +) < $1.heights.reduce(0, +) }
    }

    private func driveNextPlowSurface(_ target: SnowAccumulator.SurfaceState) {
        plowVisited.insert(ObjectIdentifier(target))
        plowCurrentSurface = target
        // Clear any stale x from the surface just finished — otherwise it
        // briefly pairs with the NEW target (via plowCurrentSurface, set
        // above) until this surface's own onTick fires its first real
        // value, which could spuriously read as "near" 영서 for a frame.
        plowCurrentX = nil
        Snowplow.summon(
            in: effectsLayer,
            accumulator: accumulator,
            target: target,
            sceneWidth: size.width,
            onTick: { [weak self] x in self?.plowCurrentX = x }
        ) { [weak self] in
            guard let self else { return }
            if let next = self.nextPlowTarget() {
                self.driveNextPlowSurface(next)
            } else {
                self.plowCurrentX = nil
                self.plowCurrentSurface = nil
                self.plowInFlight = false
            }
        }
    }

    /// Guards against overlapping 영서 summons, separate from `plowInFlight`
    /// — the two features are independent and can both be active at once.
    private var sweeperInFlight = false
    private var sweeper: SweeperCharacter?

    /// 분노의 눈덩이 splat nodes handed off by SweeperCharacter (see its
    /// `onRageSplat`/`landRageSplat` docs) — each one's ~10s fade-and-remove
    /// runs here via `beginRageSplatLifecycle`, independent of the
    /// SweeperCharacter instance that spawned it (which may already be gone
    /// by the time the fade finishes). `resetAllSnow()` clears this array
    /// directly so an in-flight splat is removed immediately even with no
    /// sweeper left to ask.
    private var activeRageSplats: [SKNode] = []
    /// How slowly a rage splat fades once it lands — kept here (not in
    /// SweeperCharacter) since this scene, not she, owns the splat's
    /// lifecycle after handoff.
    private static let rageSplatFadeDuration: TimeInterval = 10.0

    /// Takes ownership of a freshly-landed rage splat: tracks it (for
    /// cancel-safety) and starts its slow fade-out/removal, which keeps
    /// running to completion regardless of what happens to the
    /// SweeperCharacter that created it.
    private func beginRageSplatLifecycle(_ splat: SKNode) {
        activeRageSplats.append(splat)
        let fade = SKAction.sequence([
            .fadeAlpha(to: 0, duration: Self.rageSplatFadeDuration),
            .removeFromParent()
        ])
        splat.run(fade) { [weak self] in
            self?.activeRageSplats.removeAll { $0 === splat }
        }
    }

    /// 영서 소환: teleports her onto the most snow-laden surface (screenBottom
    /// included) and starts her push-mound sweep.
    func summonSweeper() {
        guard accumulator != nil else { return }
        guard !sweeperInFlight else { return }
        guard let target = accumulator.mostLadenSurface() else { return }
        sweeperInFlight = true
        sweeper = SweeperCharacter.summon(
            in: effectsLayer,
            accumulator: accumulator,
            target: target,
            spawnClump: { [weak self] point, amount in
                self?.spawnClump(at: point, amount: amount)
            },
            onRageSplat: { [weak self] splat in
                self?.beginRageSplatLifecycle(splat)
            }
        ) { [weak self] in
            self?.sweeperInFlight = false
            self?.sweeper = nil
        }
        if sweeper == nil {
            // Texture load failed (already SNOWMAC_DEBUG-logged inside
            // summon()) — distinct feature from the plow now, so this is
            // simply a no-op, not a fallback to Snowplow.
            sweeperInFlight = false
        }
    }

    /// 영서에게 눈사람 부탁: same "already busy" guard as summonSweeper(), but
    /// summons her in SweeperCharacter's buildSnowman mode instead of the
    /// normal lazy-sweep routine.
    func summonSweeperForSnowman() {
        guard accumulator != nil else { return }
        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            let laden = accumulator.mostLadenSurface()
            let span = laden.map { $0.surface.maxX - $0.surface.minX }
            FileHandle.standardError.write("SNOWMAC_DEBUG snowman: summonSweeperForSnowman sweeperActive=\(sweeper != nil) airborne=\(sweeper?.isAirborne ?? false) raging=\(sweeper?.isRaging ?? false) targetKind=\(String(describing: laden?.surface.kind)) targetSpan=\(span.map { String(format: "%.1f", $0) } ?? "nil")\n".data(using: .utf8)!)
        }
        // If she's ALREADY summoned (영서 소환), the request isn't ignored:
        // she drops whatever she was doing and poof-teleports back in build
        // mode — consistent with her teleport language, and far simpler
        // than mutating her (deliberately immutable) mode mid-run. Only a
        // rage throw in progress or being held/falling blocks the switch.
        if let sweeper {
            guard !sweeper.isAirborne, !sweeper.isRaging else { return }
            sweeper.cancel()
            self.sweeper = nil
            sweeperInFlight = false
        }
        guard !sweeperInFlight else { return }
        guard let target = accumulator.mostLadenSurface() else { return }
        sweeperInFlight = true
        sweeper = SweeperCharacter.summon(
            in: effectsLayer,
            accumulator: accumulator,
            target: target,
            mode: .buildSnowman,
            spawnClump: { [weak self] point, amount in
                self?.spawnClump(at: point, amount: amount)
            },
            onBuildSnowman: { [weak self] p in
                self?.interactionDelegate?.buildSnowman(atScenePoint: p)
            }
        ) { [weak self] in
            self?.sweeperInFlight = false
            self?.sweeper = nil
        }
        if sweeper == nil {
            sweeperInFlight = false
        }
    }

    func resetAllSnow() {
        guard accumulator != nil else { return }
        accumulator.clearAll()
        // A mid-routine reset must never leave 영서 or her floating poof/
        // heart effects orphaned on screen once the snow she's standing on
        // has been wiped out from under her.
        sweeper?.cancel()
        sweeper = nil
        sweeperInFlight = false
        // In-flight rage splats are owned by this scene, not by `sweeper`
        // (see activeRageSplats' doc) — remove them directly so a reset
        // mid-fade never leaves one lingering on screen.
        for splat in activeRageSplats { splat.removeFromParent() }
        activeRageSplats.removeAll()
        interactionDelegate?.resetAll()
    }

    func clearAccumulatedSnow() {
        guard accumulator != nil else { return }
        accumulator.clearAll()
    }

    func isInteractive(atScenePoint p: CGPoint) -> Bool {
        if let sweeper, sweeper.contains(scenePoint: p) {
            return true
        }
        if accumulator != nil, accumulator.isInteractive(atScenePoint: p) {
            return true
        }
        return interactionDelegate?.isInteractive(atScenePoint: p) ?? false
    }

    func scoopSnow(atScenePoint p: CGPoint) -> CGFloat {
        guard accumulator != nil else { return 0 }
        return accumulator.scoop(atScenePoint: p)
    }

    /// Same shape as a falling flake's landing rule — reuses
    /// `landingSurface(atX:belowY:)` directly rather than duplicating its
    /// per-surface scan — so a resting object and a falling flake agree on
    /// exactly which surface counts as "below" at a given point.
    func restingHeight(atX x: CGFloat, belowY y: CGFloat) -> CGFloat {
        guard accumulator != nil else { return 0 }
        return landingSurface(atX: x, belowY: y)?.top ?? 0
    }

    // MARK: - Mouse forwarding

    private var lastDragPoint: CGPoint?
    private var lastDragTime: TimeInterval?

    /// Non-nil between a mouseDown on 영서 and the decision of whether it's
    /// a click (poke → annoyed) or a drag (pick her up).
    private var sweeperMouseDownPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        // Pressing on 영서: defer the click/drag decision to mouseDragged/
        // mouseUp — and never also scoop the snow she's standing on.
        if let sweeper, sweeper.contains(scenePoint: p) {
            sweeperMouseDownPoint = p
            lastDragPoint = p
            lastDragTime = CACurrentMediaTime()
            return
        }
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

        if let sweeper, sweeperMouseDownPoint != nil || sweeper.isDragging {
            if let start = sweeperMouseDownPoint, !sweeper.isDragging,
               hypot(p.x - start.x, p.y - start.y) > 5 {
                sweeper.beginDrag(at: p)
            }
            if sweeper.isDragging {
                sweeper.dragTo(p)
            }
            return
        }
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

        if let sweeper, sweeperMouseDownPoint != nil || sweeper.isDragging {
            if sweeper.isDragging {
                sweeper.endDrag(velocity: velocity)
            } else {
                sweeper.poke()
            }
            sweeperMouseDownPoint = nil
            return
        }
        sweeperMouseDownPoint = nil
        interactionDelegate?.mouseUp(atScenePoint: p, velocity: velocity)
    }

    /// Right-click creates a snowball directly from deep accumulated snow,
    /// without the left-click pickup/drag sequence. Only reaches here where
    /// isInteractive(atScenePoint:) is already true (deep snow qualifies —
    /// see OverlayManager's click-through toggling), but re-checks the exact
    /// same depth rule the scoop path uses so a right-click elsewhere in
    /// that interactive radius (e.g. just past the snow's edge) is a no-op.
    override func rightMouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        // Right-clicking 영서 herself does nothing special (no poke) — just
        // ignore, unlike left-click's mouseDown.
        if let sweeper, sweeper.contains(scenePoint: p) {
            return
        }
        guard accumulator != nil, accumulator.isInteractive(atScenePoint: p) else { return }
        interactionDelegate?.spawnSnowball(atScenePoint: p)
    }
}
