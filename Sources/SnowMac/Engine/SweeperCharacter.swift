import AppKit
import SpriteKit

/// Animates 영서 (freshly extracted pixel-art frames under Resources/sweeper/)
/// teleporting onto the most snow-laden surface and sweeping it. Unlike
/// Snowplow, the snow she passes is never deleted — it is pushed forward
/// into a mound ahead of her shovel, which travels with her along the
/// surface. There the mound settles as a tall pile at the edge; any
/// mass that still can't fit under the accumulation height cap spills off
/// the edge as falling clumps (SnowScene.spawnClump — the same clump path
/// spillSnow() uses, so they land correctly through the existing flake
/// landing logic).
///
/// Driven by `update(dt:)` from SnowScene's main loop (like the flake
/// simulation) rather than a single SKAction sequence, because her routine
/// must be pausable/resumable mid-stroke: the plow driving past her
/// (notifyPlowProximity) and her own random idle quirks both need to
/// interrupt the walk/push loop and resume it afterward, which a fixed-
/// duration SKAction can't do cleanly.
///
/// 영서는 일하는 걸 좋아하지 않아 — she's a lazy worker. Rather than a straight
/// end-to-end sweep, she runs a little state machine (see `Activity`):
/// short sweeping strokes, interspersed with rests, aimless opposite-
/// direction strolls, and occasional direction switches that push the
/// mound back the other way. See `rollNextActivity()` for the bias.
final class SweeperCharacter {

    /// Which routine she runs once summoned. `.sweep` (the default, used by
    /// every existing call site) is the normal lazy-worker sweep/clear loop.
    /// `.buildSnowman` (영서에게 눈사람 부탁) instead rolls two growing
    /// snowballs (big -> small) over to a chosen build spot and
    /// stacks them there, no quirks/rest/stroll along the way, then hands
    /// off to assemble the real snowman at the same spot — see
    /// `beginSweeping()`/`beginBuild()`/`advanceBuild(dt:)`.
    enum Mode {
        case sweep
        case buildSnowman
    }

    private enum Travel {
        case leftToRight
        case rightToLeft

        var opposite: Travel { self == .leftToRight ? .rightToLeft : .leftToRight }
    }

    private enum Quirk {
        case heart, look, wipe, tilt, sulk
    }

    /// What she's doing on the current stretch of her lazy loop; drives
    /// which branch `update(dt:)` advances each frame. See
    /// `rollNextActivity()` for how one leads to the next.
    private enum Activity {
        case sweeping
        case strolling
        case resting
    }

    /// `.buildSnowman` mode's own sub-state machine for a single ball — see
    /// `beginBuildWalkAway()`/`beginBuildRolling()`/`beginBuildPlacing()`.
    /// Entirely separate from `Activity` above (the two modes never run at
    /// once on one instance), driven by `advanceBuild(dt:)` instead of the
    /// `Activity` switch in `update(dt:)`.
    private enum BuildPhase {
        /// Walking a short stretch away from the build spot before turning
        /// around to roll back toward it — reuses `idleTextures` at a walk
        /// pace, same look as a lazy-mode stroll.
        case walkingAway
        /// Walking back toward the build spot while pushing/growing the
        /// prop snowball ahead of her feet.
        case rolling
        /// Ball just reached the build spot; for balls 2 and 3 this plays a
        /// brief lift-and-place hop onto the stack before the next ball
        /// (or the final handoff) begins.
        case placing
    }

    /// Rendered height of the character, in points; each frame's width is
    /// scaled to keep ITS OWN native aspect ratio at this height (the raw
    /// PNGs are individually, tightly cropped and don't share one canvas
    /// size, so a single locked aspect would visibly squash/stretch some
    /// frames).
    private static let displayHeight: CGFloat = 60

    /// Heart and look-around are the "common" quirks; the rest are rarer —
    /// expressed as repeated entries rather than a weighted-random helper,
    /// since the pool is tiny and fixed.
    private static let quirkPool: [Quirk] = [.heart, .heart, .heart, .look, .look, .look, .wipe, .tilt, .sulk]

    /// Randomized per-stroke walk speed (points/sec) — she's lazy, not
    /// brisk. Deliberately NOT derived from `s`: walk speed is a pacing
    /// choice, not a visual size, so it stays in absolute pt/s regardless
    /// of how big she's drawn.
    private static let lazySpeedRange: ClosedRange<CGFloat> = 35...55

    /// Safety cap on total active (working) time before she's forced to
    /// wrap up regardless of remaining snow — keeps the lazy back-and-forth
    /// from running forever.
    private static let safetyCapSeconds: TimeInterval = 90

    /// She's considered finished once the surface's total remaining snow
    /// drops below this — the back-and-forth pushing dumps mass off the
    /// surface edges over time (existing overflow/spill handles it), so
    /// this always eventually terminates on its own.
    private static let finishThreshold: CGFloat = 8

    /// `.buildSnowman` mode's 2 prop-snowball target radii, big -> small
    /// (ball 1/2) — deliberately matching InteractionController's 2-tier
    /// `builtSnowmanBaseRadius`/`HeadRadius` (30/18) so the real snowman
    /// that pops in at the end lands at the exact same size as the props
    /// it's replacing; keep the two in sync if either changes. Only 2
    /// balls (base + head, no torso): a 3-tier 영서 build read as too
    /// tall/unsettling to the user ("너무 징그러워"). The resulting 2-tier
    /// snowman can still be upgraded to 3-tier afterward by dropping a
    /// ball on it, same as any other 2-tier snowman.
    private static let buildBallTargetRadii: [CGFloat] = [30, 18]
    /// Every prop ball is "born" tiny and grows toward its target radius as
    /// she rolls it (see `advanceBuildRolling(dt:)`).
    private static let buildBallStartRadius: CGFloat = 3
    /// Distance from her arrival point to the chosen build spot, and each
    /// ball's walk-away-and-back stretch. Absolute points, NOT a span
    /// fraction (screenBottom's span can be the full screen width, which a
    /// percentage-based stretch would blow the whole sequence's ~8-14s
    /// budget on) — same reasoning as `lazySpeedRange` staying absolute.
    private static let buildSpotOffsetRange: ClosedRange<CGFloat> = 70...130
    private static let buildWalkAwayRange: ClosedRange<CGFloat> = 35...70
    /// Minimum clearance kept between the chosen build spot and either
    /// surface edge, so the stacked snowman never ends up flush against one.
    private static let buildSpotMargin: CGFloat = 40
    /// Lift-and-place hop duration for balls 2 and 3 once their roll reaches
    /// the build spot (ball 1 just settles in place as the base — no hop).
    private static let buildPlaceHopDuration: TimeInterval = 0.4

    // MARK: - Rage (분노의 눈덩이 투척)

    /// Once her carried (overflowed-while-pushing) snow crosses this, the
    /// surface she's sweeping is considered SO maxed out she can't push it
    /// anywhere anymore — `pushSnow` keeps returning nearly everything as
    /// overflow — and she rages instead of continuing the lazy loop, in
    /// `.sweep` mode only (`.buildSnowman` never calls `advanceSweepSegment`,
    /// where this is checked, so it never rages). `carriedSnow` is a direct
    /// proxy for "stuck": it only grows while a push overflows, so it stays
    /// near 0 during ordinary sweeping (her push window ahead still has
    /// room) and climbs quickly once the pile immediately ahead saturates.
    // Raised 60 → 150 and gated behind a minimum active time: on a
    // saturated (blizzard-buried) surface every push overflows, so the old
    // threshold tripped within ~2-4 seconds of arriving — she'd rage-throw
    // and exit almost immediately after being summoned, which users read
    // as "영서가 바로 꺼진다". Rage should be a rare "I've been at this
    // forever and it's hopeless" moment, not her opening move.
    private static let rageCarriedSnowThreshold: CGFloat = 150
    /// She never rages before this much active working time has passed,
    /// no matter how much overflow she's carrying.
    private static let rageMinActiveTime: TimeInterval = 12
    /// Pack pose hold duration (step 2 of the sequence) — also how long the
    /// prop ball takes to pop up to its packed size.
    private static let ragePackHoldDuration: TimeInterval = 0.6
    /// Hold duration for each of the two generated packing frames (throw_0
    /// then throw_1) — only used when the throw sprite set loaded; see
    /// `beginRagePack()`. Independent of `ragePackHoldDuration` above
    /// (which still times the placeholder-frame fallback and the prop
    /// ball's pop-up animation).
    private static let rageThrowFrameHoldDuration: TimeInterval = 0.5
    /// Wind-up pose (throw_2) hold before the throw launches — only used
    /// when the throw sprite set loaded; see `beginRageThrow()`.
    private static let rageWindupHoldDuration: TimeInterval = 0.4
    private static let rageBallPackedRadiusRange: ClosedRange<CGFloat> = 8...10
    private static let rageThrowDurationRange: ClosedRange<TimeInterval> = 0.5...0.7
    private static let rageBallThrowScaleRange: ClosedRange<CGFloat> = 25...40
    /// Random offset magnitude (each axis, sign rolled separately) added to
    /// scene center to pick the impact point, before clamping into bounds.
    private static let rageImpactOffsetRange: ClosedRange<CGFloat> = 10...1024
    private static let rageImpactEdgeInset: CGFloat = 40
    private static let rageSplatAlpha: CGFloat = 0.92
    /// Her own fade (step 5) — longer than the normal 0.4s finish fade
    /// (`fadeOutAndDespawn`'s default) since it must stay in sync with the
    /// splat's own much slower ~10s fade, which SnowScene starts the same
    /// instant (see `landRageSplat`).
    private static let rageSelfFadeDurationRange: ClosedRange<TimeInterval> = 1.5...2.0

    // MARK: - Texture loading

    /// Loaded once and cached for the process's lifetime; frames never
    /// change at runtime.
    private static var textureCache: [String: SKTexture] = [:]

    /// Name SwiftPM generates for this target's resource bundle
    /// (`<package>_<target>.bundle`, both "SnowMac" here) — needed for the
    /// packaged-app fallback lookup below.
    private static let resourceBundleName = "SnowMac_SnowMac.bundle"

    private static func frameURL(named name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources/sweeper") {
            return url
        }
        // Bundle.module's generated accessor looks for the resource bundle
        // at Bundle.main.bundleURL, which for a real .app is the .app's own
        // top level — but a top-level item there (outside Contents/) breaks
        // codesign's resource seal, so scripts/build_app.sh instead places
        // the bundle in the standard Contents/Resources location. Mirror
        // that lookup here as a fallback for the packaged app.
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourcesURL
            .appendingPathComponent(resourceBundleName)
            .appendingPathComponent("Resources/sweeper")
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func texture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] { return cached }
        guard
            let url = frameURL(named: name),
            let image = NSImage(contentsOf: url)
        else { return nil }
        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        textureCache[name] = texture
        return texture
    }

    private static func textures(prefix: String, count: Int) -> [SKTexture]? {
        var result: [SKTexture] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let t = texture(named: "\(prefix)_\(i)") else { return nil }
            result.append(t)
        }
        return result
    }

    // MARK: - Frame-sequence playback

    /// Steps through `frames` at `timePerFrame` each as `advance(by:)` is
    /// called. Non-looping sequences set `isFinished` once the last frame's
    /// time has elapsed; looping ones never finish. This is the pausable
    /// primitive everything below is built on — unlike `SKAction.animate`,
    /// nothing here commits to a fixed total duration up front.
    private final class FrameSequence {
        let frames: [SKTexture]
        private let timePerFrame: TimeInterval
        private let loops: Bool
        private var index = 0
        private var elapsed: TimeInterval = 0
        private(set) var isFinished = false

        init(frames: [SKTexture], timePerFrame: TimeInterval, loops: Bool) {
            self.frames = frames
            self.timePerFrame = timePerFrame
            self.loops = loops
        }

        var currentTexture: SKTexture { frames[index] }

        func advance(by dt: TimeInterval) {
            guard !isFinished, frames.count > 1 || !loops else { return }
            elapsed += dt
            while elapsed >= timePerFrame {
                elapsed -= timePerFrame
                index += 1
                if index >= frames.count {
                    if loops {
                        index = 0
                    } else {
                        index = frames.count - 1
                        isFinished = true
                        break
                    }
                }
            }
        }
    }

    // MARK: - Summon

    /// Teleports 영서 onto `state`'s surface and starts her sweep. Returns
    /// nil (after a SNOWMAC_DEBUG log) if her sprite frames fail to load —
    /// a distinct feature from the plow now, so this is a plain no-op, not
    /// a fallback to Snowplow. `spawnClump` is SnowScene's clump-spawning
    /// hook for overflow mass at the end of her run. Calls `onFinish` once
    /// she's removed (including on an aborted run — target surface closed
    /// mid-sweep).
    static func summon(
        in parent: SKNode,
        accumulator: SnowAccumulator,
        target state: SnowAccumulator.SurfaceState,
        mode: Mode = .sweep,
        spawnClump: @escaping (CGPoint, CGFloat) -> Void,
        onBuildSnowman: ((CGPoint) -> Void)? = nil,
        onRageSplat: @escaping (SKNode) -> Void = { _ in },
        onFinish: @escaping () -> Void
    ) -> SweeperCharacter? {
        guard
            let idleTextures = textures(prefix: "idle", count: 3),
            let sweepLR = textures(prefix: "sweep_lr", count: 4),
            let sweepRL = textures(prefix: "sweep_rl", count: 4),
            let wipeTextures = textures(prefix: "wipe", count: 3),
            let lookTextures = textures(prefix: "look", count: 3),
            let sulkTextures = textures(prefix: "sulk", count: 4),
            let miscTextures = textures(prefix: "misc", count: 2)
        else {
            if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
                FileHandle.standardError.write("SNOWMAC_DEBUG sweeper: texture load failed, 영서 소환 no-op\n".data(using: .utf8)!)
            }
            return nil
        }
        // Newer, optional sprite sets — nil (NOT a summon failure) on a
        // bundle built before these existed. Every call site that uses one
        // falls back to the pre-existing look when it's nil.
        let rollLRTextures = textures(prefix: "roll_lr", count: 4)
        let rollRLTextures = textures(prefix: "roll_rl", count: 4)
        let throwTextures = textures(prefix: "throw", count: 4)

        // Start from whichever end holds less snow, so she sweeps toward
        // (and builds her mound into) the heavier end — reads more natural
        // than an arbitrary fixed direction. This is her nominal/overall
        // direction (`travel`); it does NOT change when she lazily switches
        // sweep direction mid-run (see `currentTravel`) — the final pile
        // still settles at this original heavy-end edge.
        let mid = state.heights.count / 2
        let leftTotal = state.heights[0..<mid].reduce(0, +)
        let rightTotal = state.heights[mid...].reduce(0, +)
        let travel: Travel = leftTotal <= rightTotal ? .leftToRight : .rightToLeft

        return SweeperCharacter(
            parent: parent,
            accumulator: accumulator,
            state: state,
            travel: travel,
            mode: mode,
            idleTextures: idleTextures,
            sweepLRTextures: sweepLR,
            sweepRLTextures: sweepRL,
            wipeTextures: wipeTextures,
            lookTextures: lookTextures,
            sulkTextures: sulkTextures,
            miscTextures: miscTextures,
            rollLRTextures: rollLRTextures,
            rollRLTextures: rollRLTextures,
            throwTextures: throwTextures,
            spawnClump: spawnClump,
            onBuildSnowman: onBuildSnowman,
            onRageSplat: onRageSplat,
            onFinish: onFinish
        )
    }

    // MARK: - Instance

    private let node: SKSpriteNode
    private let accumulator: SnowAccumulator
    private let mode: Mode
    /// 눈사람 부탁's hand-off, invoked once from `finishBuildSnowman()` with
    /// her position right before she steps aside. Always nil in `.sweep`
    /// mode.
    private let onBuildSnowman: ((CGPoint) -> Void)?
    /// `.buildSnowman` mode's own sub-state machine — see `BuildPhase`.
    /// Unused in `.sweep` mode.
    private var buildPhase: BuildPhase = .walkingAway
    /// Which of the 2 balls (0 = big/base, 1 = small/head) is currently
    /// in progress.
    private var buildIndex = 0
    /// The x she picked (once, in `beginBuild()`) to roll both balls to.
    private var buildSpotX: CGFloat = 0
    /// `walkX` at the moment the CURRENT ball's rolling pass began — the
    /// denominator for the roll-progress-driven growth in
    /// `advanceBuildRolling(dt:)`.
    private var buildRollStartX: CGFloat = 0
    /// The ball x (leading-edge, same offset as the sweep shovel) last
    /// fed into the accumulator strip-clear — the window this tick's
    /// `clearRange` call spans, mirroring `lastShovelX`'s role for sweeping.
    private var buildLastFeedX: CGFloat = 0
    /// Countdown for the current ball's lift-and-place hop (balls 2/3
    /// only); reaching zero advances to the next ball or the handoff.
    private var buildPlaceRemaining: TimeInterval = 0
    /// The ball currently being rolled, if any — nil during `.walkingAway`/
    /// `.placing`. Registered in `activeEffects` so `cancel()` cleans it up
    /// for free.
    private var buildBallNode: SKShapeNode?
    /// True while the CURRENT roll is showing a generated roll sprite
    /// (rather than the idle-frames fallback) — that sheet already draws a
    /// snowball in her hands, so the code-drawn prop ball underneath is
    /// hidden (alpha 0) for the duration to avoid two balls rendering at
    /// once. The prop keeps tracking size/position/physics throughout
    /// regardless, so it can simply pop back to visible (alpha 1) the
    /// instant she reaches the build spot — see `beginBuildRolling()` and
    /// `advanceBuildRolling(dt:)`.
    private var buildBallHiddenForRollSprite = false
    /// Balls already rolled into place at the build spot (base first, then
    /// stacked upward), kept around until `finishBuildSnowman()` pops them
    /// all at once for the real-snowman handoff. Also registered in
    /// `activeEffects`.
    private var buildPlacedBalls: [SKShapeNode] = []
    /// The surface she's sweeping — exposed so SnowScene can compare it
    /// (by reference) against the plow's current surface for the
    /// plow-passes-her interaction.
    /// Hands a freshly-landed rage splat composition to SnowScene — see the
    /// doc at `landRageSplat` for why ownership must transfer there instead
    /// of staying in this instance's `activeEffects`. Defaults to a no-op
    /// since `.buildSnowman` mode never rages and never calls this.
    private let onRageSplat: (SKNode) -> Void
    private(set) var surfaceState: SnowAccumulator.SurfaceState
    /// Her nominal/overall direction, fixed for the whole run — only used
    /// to pick which edge the final mound settles against
    /// (`dumpCarriedSnowAndSpillOverflow`). Her live, moment-to-moment
    /// sweep direction is `currentTravel`, which the lazy state machine is
    /// free to flip.
    private let travel: Travel
    private var currentTravel: Travel
    /// Her nominal facing direction, for cosmetic use (e.g. heart drift) —
    /// tracks `currentTravel`, not necessarily the direction she's moving
    /// RIGHT NOW (that's `segmentSign`, which differs from this during a
    /// stroll).
    private var travelSign: CGFloat { currentTravel == .leftToRight ? 1 : -1 }
    private let columnStep: Int
    private let startX: CGFloat
    /// Live surface bounds — computed, not captured at init, so when the
    /// window she's standing on MOVES, her clamping/segment logic follows
    /// its new frame instead of the stale original span (she used to be
    /// left hovering at the window's old position).
    private var surfaceMinX: CGFloat { surfaceState.surface.minX }
    private var surfaceMaxX: CGFloat { surfaceState.surface.maxX }
    private var endX: CGFloat { travel == .leftToRight ? surfaceMaxX : surfaceMinX }
    private var span: CGFloat { surfaceMaxX - surfaceMinX }
    /// Previous poll's surface minX — the delta against the live value is
    /// how far the window moved this frame; she rides along with it.
    private var lastSurfaceMinX: CGFloat
    private let spawnClump: (CGPoint, CGFloat) -> Void
    private let onFinish: () -> Void

    private let idleTextures: [SKTexture]
    private let sweepLRTextures: [SKTexture]
    private let sweepRLTextures: [SKTexture]
    private let wipeTextures: [SKTexture]
    private let lookTextures: [SKTexture]
    private let sulkTextures: [SKTexture]
    private let miscTextures: [SKTexture]
    /// Optional newer sprite sets — nil on a bundle built before they
    /// existed; every call site that uses one falls back to the
    /// pre-existing look (idle/misc placeholder) when nil.
    private let rollLRTextures: [SKTexture]?
    private let rollRLTextures: [SKTexture]?
    private let throwTextures: [SKTexture]?

    private var walkAnim: FrameSequence
    /// Non-nil while a one-shot (or held) foreground animation is playing —
    /// a quirk, the hurt/angry reaction, or the finish wipe/idle. While set,
    /// `update(dt:)` drives ONLY this and skips the activity state machine
    /// entirely, which is what makes her routine pausable.
    private var overlay: FrameSequence?
    private var onOverlayFinished: (() -> Void)?

    /// Her feet's x along the surface — the single source of truth for
    /// position; `node.position` is derived from this (and the live
    /// surface top), never the other way around, so a one-off visual nudge
    /// (the hurt jolt) can never leave a lasting drift.
    private var walkX: CGFloat
    private(set) var currentX: CGFloat
    private var lastShovelX: CGFloat
    private var carriedSnow: CGFloat = 0

    /// Rendered-size scale factor, relative to the original 90pt design
    /// size this kit was tuned at. Every size-coupled constant below is
    /// derived from this one knob, so retuning `displayHeight` rescales the
    /// whole kit together.
    private var s: CGFloat { Self.displayHeight / 90 }

    private var shovelOffset: CGFloat { 14 * s }
    private let pushColumns = 3
    private let finalPileColumns = 4

    // MARK: - Lazy-worker state machine

    /// What she's doing on the current stretch; see `Activity`.
    private var activity: Activity = .sweeping
    /// Sign of her CURRENT movement (sweep or stroll) — can differ from
    /// `travelSign` during a stroll, which walks opposite her sweep
    /// direction without sweeping.
    private var segmentSign: CGFloat = 1
    /// Walk speed for the current stroke/stroll, re-rolled each segment.
    private var currentSpeed: CGFloat = SweeperCharacter.lazySpeedRange.lowerBound
    /// Where the current sweep/stroll segment ends (always clamped to the
    /// surface's bounds); reaching it triggers `rollNextActivity()`.
    private var segmentTargetX: CGFloat = 0
    /// Countdown for the current rest; reaching zero triggers
    /// `rollNextActivity()`.
    private var restRemaining: TimeInterval = 0
    /// Total time spent actively working (sweeping/strolling/resting,
    /// i.e. excluding poof/quirk/hurt overlays) since she landed — the
    /// ~90s safety cap below is measured against this.
    private var activeTime: TimeInterval = 0
    private var hasTriggeredSafetyCap = false

    /// Per-column height below which a sweep segment shows her plain walk
    /// look instead of the shoveling frames — there's nothing left there
    /// worth pretending to shovel. Well below `finishThreshold` (that's a
    /// whole-surface total; this is a per-column depth check).
    // Must sit comfortably ABOVE Accumulation's visual speck threshold
    // (columns under ~2 units render as bare ground): with a lower value
    // she'd shovel snow the user literally cannot see — fresh dustings
    // push raw heights past a sub-2 threshold within seconds of snowfall,
    // which made her look like she was always shoveling bare ground.
    private static let sweepSnowThreshold: CGFloat = 3.0
    /// Whether the CURRENT sweep segment's `walkAnim` is showing the
    /// shoveling frames (true) or the plain-walk look (false) — flips
    /// mid-stroke as `advanceSweepSegment` finds real snow under/ahead of
    /// her shovel, or runs out of it. Only `updateSweepVisual` writes this,
    /// and only when it actually flips (see that method).
    private var sweepVisualActive = true

    private var poofRemaining: TimeInterval = 0.35
    private var isWorking = false
    private var isDone = false
    private var isInHurtOrAngry = false
    /// Latches once a hurt/angry trigger fires so a plow sitting within
    /// range doesn't retrigger every frame; clears once the plow moves
    /// far enough away (or the pass ends) so the next pass can trigger again.
    private var hurtLatched = false

    private var quirkTimer: TimeInterval = 0
    private var nextQuirkDelay: TimeInterval = .random(in: 6...14)

    /// Poof circles and floating hearts — tracked only so `cancel()` can
    /// remove them immediately; a natural finish lets them play out and
    /// self-remove on their own schedule.
    private var activeEffects: [SKNode] = []

    /// Latches once 분노의 눈덩이 fires so it never fires twice in the same
    /// summon — see `rageCarriedSnowThreshold`'s doc. Also reused to block
    /// the plow/poke interrupt reactions once she's mid-rage (see
    /// `notifyPlowProximity`/`poke`), since either would clobber the
    /// pack/throw overlay chain and orphan `rageBallNode`.
    private var hasRaged = false
    /// Whether the rage throw sequence has begun (it latches and runs to
    /// her exit) — exposed so SnowScene can refuse to interrupt it (e.g.
    /// a 눈사람 부탁 while she's mid-throw just lets the rage play out).
    var isRaging: Bool { hasRaged }
    /// The packed/thrown snowball prop, while still owned by her (also
    /// tracked in `activeEffects`, so `cancel()` removes it for free if
    /// interrupted mid-flight). Set to nil the instant it's replaced by the
    /// splat in `landRageSplat`.
    private var rageBallNode: SKShapeNode?

    private init(
        parent: SKNode,
        accumulator: SnowAccumulator,
        state: SnowAccumulator.SurfaceState,
        travel: Travel,
        mode: Mode,
        idleTextures: [SKTexture],
        sweepLRTextures: [SKTexture],
        sweepRLTextures: [SKTexture],
        wipeTextures: [SKTexture],
        lookTextures: [SKTexture],
        sulkTextures: [SKTexture],
        miscTextures: [SKTexture],
        rollLRTextures: [SKTexture]?,
        rollRLTextures: [SKTexture]?,
        throwTextures: [SKTexture]?,
        spawnClump: @escaping (CGPoint, CGFloat) -> Void,
        onBuildSnowman: ((CGPoint) -> Void)?,
        onRageSplat: @escaping (SKNode) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.accumulator = accumulator
        self.surfaceState = state
        self.travel = travel
        self.currentTravel = travel
        self.mode = mode
        self.onBuildSnowman = onBuildSnowman
        self.onRageSplat = onRageSplat
        self.columnStep = travel == .leftToRight ? 1 : -1
        self.startX = travel == .leftToRight ? state.surface.minX : state.surface.maxX
        self.lastSurfaceMinX = state.surface.minX
        self.spawnClump = spawnClump
        self.onFinish = onFinish
        self.idleTextures = idleTextures
        self.sweepLRTextures = sweepLRTextures
        self.sweepRLTextures = sweepRLTextures
        self.wipeTextures = wipeTextures
        self.lookTextures = lookTextures
        self.sulkTextures = sulkTextures
        self.miscTextures = miscTextures
        self.rollLRTextures = rollLRTextures
        self.rollRLTextures = rollRLTextures
        self.throwTextures = throwTextures
        // Placeholder until beginSweeping() kicks off the first real
        // segment once the arrival poof finishes; never rendered as-is.
        self.walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.25, loops: true)

        self.walkX = startX
        self.currentX = startX
        // Placeholder — real seed is set below, once `self` is fully formed
        // and the real `shovelOffset`/`travelSign` computed properties are
        // usable (Swift forbids touching those before every stored
        // property, including `node` just below, has a value).
        self.lastShovelX = startX

        let startY = accumulator.topY(of: state, atX: startX)
        let spriteNode = SKSpriteNode(texture: idleTextures[0])
        spriteNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        spriteNode.zPosition = 30
        spriteNode.position = CGPoint(x: startX, y: startY)
        self.node = spriteNode
        parent.addChild(spriteNode)
        applyFrame(idleTextures[0])

        spawnPoof(in: parent, at: spriteNode.position)

        self.lastShovelX = startX + travelSign * shovelOffset
    }

    // MARK: - Per-frame update (called from SnowScene.update)

    func update(dt: TimeInterval) {
        guard !isDone else { return }

        // Held or falling: she's not standing on anything — skip the
        // ride/pin logic and the whole routine until she touches down.
        switch airState {
        case .dragging:
            return
        case .falling:
            advanceFall(dt: dt)
            return
        case .none:
            break
        }

        // Keep her vertically pinned to the live surface top at her current
        // x even while paused (overlay/poof) — if the plow or another
        // process alters snow near her while she's not actively sweeping,
        // she shouldn't float or clip.
        if accumulator.states.contains(where: { $0 === surfaceState }) {
            // Ride the window: when the surface she's standing on moves,
            // shift her whole x-state by the same delta so she stays
            // planted on the same spot OF THE WINDOW (she used to hover
            // in place at the window's old screen position). Clamp into
            // the new span so a resize can't strand her off the edge.
            let dx = surfaceState.surface.minX - lastSurfaceMinX
            if dx != 0 {
                lastSurfaceMinX = surfaceState.surface.minX
                walkX = clampToSurface(walkX + dx)
                currentX = clampToSurface(currentX + dx)
                lastShovelX += dx
                segmentTargetX = clampToSurface(segmentTargetX + dx)
                if mode == .buildSnowman {
                    // Keep the build spot, the current roll's progress
                    // baseline, and every prop ball (in-flight or already
                    // stacked) riding along with the window too — none of
                    // these are covered by the x-state above.
                    buildSpotX += dx
                    buildRollStartX += dx
                    buildLastFeedX += dx
                    buildBallNode?.position.x += dx
                    for ball in buildPlacedBalls { ball.position.x += dx }
                }
                node.position.x = currentX
            } else {
                // Width-only resize (minX unchanged): just keep her inside.
                if currentX > surfaceMaxX {
                    walkX = clampToSurface(walkX)
                    currentX = clampToSurface(currentX)
                    segmentTargetX = clampToSurface(segmentTargetX)
                    node.position.x = currentX
                }
            }
            node.position.y = accumulator.topY(of: surfaceState, atX: currentX)
        }

        if poofRemaining > 0 {
            poofRemaining -= dt
            if poofRemaining <= 0 {
                poofRemaining = 0
                beginSweeping()
            }
            return
        }

        if let overlay {
            overlay.advance(by: dt)
            applyFrame(overlay.currentTexture)
            if overlay.isFinished {
                self.overlay = nil
                let callback = onOverlayFinished
                onOverlayFinished = nil
                callback?()
            }
            return
        }

        guard isWorking else { return }

        // The target surface can be removed mid-sweep (its window closed
        // while she was working it), in any activity — rest/stroll
        // included. Abort straight to the fade-out rather than freezing.
        guard accumulator.states.contains(where: { $0 === surfaceState }) else {
            beginFinish(aborted: true)
            return
        }

        activeTime += dt
        if activeTime >= Self.safetyCapSeconds, !hasTriggeredSafetyCap {
            hasTriggeredSafetyCap = true
            triggerSafetyCapFinish()
            return
        }

        // `.buildSnowman` mode doesn't terminate on remaining-snow totals —
        // it has its own fixed completion criterion (2 balls placed) — and
        // its rolling pass actively consumes snow via clearRange, which this
        // threshold would otherwise trip well before the sequence is done.
        if mode != .buildSnowman, surfaceState.heights.reduce(0, +) < Self.finishThreshold {
            beginFinish(aborted: false)
            return
        }

        if mode == .buildSnowman {
            advanceBuild(dt: dt)
            return
        }

        switch activity {
        case .sweeping:
            advanceSweepSegment(dt: dt)
        case .strolling:
            advanceStrollSegment(dt: dt)
        case .resting:
            advanceRestSegment(dt: dt)
        }
    }

    private func applyFrame(_ texture: SKTexture) {
        node.texture = texture
        // NEVER mix `.size =` with setScale here. SKSpriteNode.size is the
        // RENDERED size (it bakes the node's current scale in): on the
        // second applyFrame call, `node.size = texture.size()` on a node
        // whose scale was already displayHeight/h re-inflated the rendered
        // size back to the texture's native ~267pt — so she appeared at
        // full sprite-sheet size the moment any animation advanced, no
        // matter what displayHeight said. Set the target rendered size
        // directly and leave scale at 1 forever.
        let native = texture.size()
        guard native.height > 0 else { return }
        node.size = CGSize(
            width: Self.displayHeight * native.width / native.height,
            height: Self.displayHeight
        )
    }

    private func playOverlay(_ frames: [SKTexture], timePerFrame: TimeInterval, loops: Bool = false, then: @escaping () -> Void = {}) {
        overlay = FrameSequence(frames: frames, timePerFrame: timePerFrame, loops: loops)
        onOverlayFinished = then
    }

    // MARK: - Lazy-worker loop

    private func beginSweeping() {
        isWorking = true
        activeTime = 0
        if mode == .buildSnowman {
            // On a mission: no landing quirk, straight into picking the
            // build spot and rolling the first (biggest) ball toward it.
            beginBuild()
            return
        }
        beginSweepSegment(direction: currentTravel)
        // Nice-to-have: sometimes strike a quirky pose right as she lands.
        if Double.random(in: 0..<1) < 0.3, let quirk = randomQuirk() {
            playQuirk(quirk, then: {})
        }
    }

    private func clampToSurface(_ x: CGFloat) -> CGFloat {
        min(max(x, surfaceMinX), surfaceMaxX)
    }

    /// Starts (or continues) an actual sweeping stroke in `direction` — a
    /// short random stretch (10-25% of the surface span). This both reads
    /// and sets `currentTravel`, since "continue" and "switch direction"
    /// are both expressed as calls to this with different `direction`s.
    private func beginSweepSegment(direction: Travel) {
        currentTravel = direction
        activity = .sweeping
        currentSpeed = .random(in: Self.lazySpeedRange)
        let stretch = CGFloat.random(in: 0.10...0.25) * span
        segmentSign = direction == .leftToRight ? 1 : -1
        segmentTargetX = clampToSurface(walkX + segmentSign * stretch)
        // Fresh shovel baseline for this stroke — avoids a phantom push
        // across whatever ground a preceding stroll (which doesn't push)
        // or a direction switch crossed without sweeping.
        lastShovelX = walkX + segmentSign * shovelOffset
        let frames = direction == .leftToRight ? sweepLRTextures : sweepRLTextures
        walkAnim = FrameSequence(frames: frames, timePerFrame: 0.3, loops: true)
        // A fresh stroke always STARTS by showing the shoveling look;
        // advanceSweepSegment corrects this within a tick or two if the
        // ground right there turns out to already be bare.
        sweepVisualActive = true
    }

    /// Walks the opposite way from her current sweep direction WITHOUT
    /// sweeping — shovel down, mound untouched. Short (5-15% of span),
    /// reuses her idle frames at walking pace since there's no dedicated
    /// "walking, not working" sprite set.
    private func beginStrollSegment() {
        activity = .strolling
        currentSpeed = .random(in: Self.lazySpeedRange)
        let stretch = CGFloat.random(in: 0.05...0.15) * span
        segmentSign = -travelSign
        segmentTargetX = clampToSurface(walkX + segmentSign * stretch)
        walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.2, loops: true)
    }

    /// Stops entirely and cycles idle frames at a relaxed pace for a few
    /// seconds — resting IS the break, so no quirks fire during it.
    private func beginRestSegment() {
        activity = .resting
        restRemaining = .random(in: 2...5)
        walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.5, loops: true)
    }

    /// Re-rolled every time a stroke/stroll/rest completes. Biased so she
    /// still makes net progress: mostly continues sweeping forward, with
    /// occasional rests, backward strolls, and outright direction switches
    /// (which flip `currentTravel`, so pushSnow starts pushing the other
    /// way — she lazily shoves the mound back and forth).
    private func rollNextActivity() {
        let roll = Double.random(in: 0..<1)
        switch roll {
        case 0..<0.60:
            beginSweepSegment(direction: currentTravel)
        case 0.60..<0.75:
            beginRestSegment()
        case 0.75..<0.90:
            beginStrollSegment()
        default:
            beginSweepSegment(direction: currentTravel.opposite)
        }
    }

    /// Shared walk/animate step for both sweeping and strolling — advances
    /// `walkX` toward `segmentTargetX` at `currentSpeed`, re-pins the node,
    /// and steps `walkAnim`. Returns true once the segment's target is
    /// reached (and clamps `walkX` exactly to it).
    private func advanceWalk(dt: TimeInterval) -> Bool {
        let step = segmentSign * currentSpeed * CGFloat(dt)
        walkX += step
        let reached = segmentSign > 0 ? walkX >= segmentTargetX : walkX <= segmentTargetX
        if reached { walkX = segmentTargetX }
        walkX = clampToSurface(walkX)
        currentX = walkX
        node.position = CGPoint(x: walkX, y: accumulator.topY(of: surfaceState, atX: walkX))

        walkAnim.advance(by: dt)
        applyFrame(walkAnim.currentTexture)

        return reached
    }

    // MARK: - Build-a-snowman (rolling balls)

    /// Picks the build spot once (a point `buildSpotOffsetRange` away from
    /// her arrival point, in her nominal travel direction — i.e. further
    /// onto the surface, away from the edge she teleported onto — clamped
    /// so it never ends up within `buildSpotMargin` of either edge), then
    /// kicks off ball 1's walk-away leg.
    private func beginBuild() {
        let offset = CGFloat.random(in: Self.buildSpotOffsetRange)
        let rawSpot = walkX + travelSign * offset
        let margin = min(Self.buildSpotMargin, span * 0.3)
        let lo = surfaceMinX + margin
        let hi = surfaceMaxX - margin
        buildSpotX = lo <= hi ? min(max(rawSpot, lo), hi) : (surfaceMinX + surfaceMaxX) / 2
        buildIndex = 0
        beginBuildWalkAway()
    }

    /// Ball `buildIndex`'s pre-roll leg: walk a random short stretch away
    /// from `buildSpotX` (whichever side she's currently on; a coin flip if
    /// she's exactly on it), then `advanceBuild(dt:)` turns her around into
    /// `beginBuildRolling()` once `advanceWalk` reports the stretch is done.
    private func beginBuildWalkAway() {
        buildPhase = .walkingAway
        currentSpeed = .random(in: Self.lazySpeedRange)
        let stretch = CGFloat.random(in: Self.buildWalkAwayRange)
        let awaySign: CGFloat
        if walkX > buildSpotX { awaySign = 1 }
        else if walkX < buildSpotX { awaySign = -1 }
        else { awaySign = Bool.random() ? 1 : -1 }
        segmentSign = awaySign
        segmentTargetX = clampToSurface(walkX + awaySign * stretch)
        walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.2, loops: true)
    }

    /// Turns around and starts rolling ball `buildIndex` back toward
    /// `buildSpotX`, spawning its (initially tiny) prop node at her leading
    /// edge.
    private func beginBuildRolling() {
        buildPhase = .rolling
        currentSpeed = .random(in: Self.lazySpeedRange)
        buildRollStartX = walkX
        segmentSign = buildSpotX >= walkX ? 1 : -1
        segmentTargetX = buildSpotX
        // Rolling toward the build spot: use the direction-matched roll
        // sheet (roll_lr when heading right, roll_rl when heading left) if
        // it loaded; older bundles without it fall back to the idle look,
        // same as before this sheet existed.
        if let rollFrames = segmentSign > 0 ? rollLRTextures : rollRLTextures {
            walkAnim = FrameSequence(frames: rollFrames, timePerFrame: 0.22, loops: true)
            buildBallHiddenForRollSprite = true
        } else {
            walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.2, loops: true)
            buildBallHiddenForRollSprite = false
        }

        buildLastFeedX = walkX + segmentSign * shovelOffset
        guard let parent = node.parent else { return }
        let targetRadius = Self.buildBallTargetRadii[buildIndex]
        let ball = makeBuildBallNode(radius: targetRadius)
        ball.setScale(Self.buildBallStartRadius / targetRadius)
        // When the roll sheet is active it already draws a snowball in her
        // hands — hide this code-drawn prop underneath it so the two don't
        // double up visually. The prop keeps growing/tracking position
        // every tick regardless (see advanceBuildRolling(dt:)), so it can
        // simply fade back in the instant she reaches the build spot,
        // where it becomes the visible stacked ball.
        ball.alpha = buildBallHiddenForRollSprite ? 0 : 1
        ball.position = CGPoint(x: buildLastFeedX, y: accumulator.topY(of: surfaceState, atX: buildLastFeedX) + Self.buildBallStartRadius)
        ball.zPosition = node.zPosition - 1
        parent.addChild(ball)
        activeEffects.append(ball)
        buildBallNode = ball
    }

    /// A plain white circle standing in for a snowball she's pushing — no
    /// dedicated rolling sprite exists yet (see the SEAM comment in
    /// `beginBuildRolling()`). Built at its FINAL target radius with a
    /// couple of off-center dots as children, then grown/shrunk via
    /// `setScale` elsewhere — that keeps the dots correctly proportioned
    /// at every size and makes the zRotation applied while rolling actually
    /// read as rolling instead of a static disc.
    private func makeBuildBallNode(radius: CGFloat) -> SKShapeNode {
        let ball = SKShapeNode(circleOfRadius: radius)
        ball.fillColor = .white
        ball.strokeColor = SKColor(white: 0.85, alpha: 1)
        ball.lineWidth = 1
        for _ in 0..<2 {
            let dot = SKShapeNode(circleOfRadius: max(radius * 0.16, 1))
            dot.fillColor = SKColor(white: 0.78, alpha: 0.7)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: CGFloat.random(in: -radius * 0.4...radius * 0.4), y: CGFloat.random(in: -radius * 0.4...radius * 0.4))
            ball.addChild(dot)
        }
        return ball
    }

    /// Dispatches to whichever build sub-phase is active; called from
    /// `update(dt:)` in place of the `Activity` switch while
    /// `mode == .buildSnowman`. Like that switch, this is simply never
    /// reached while `overlay` is set or `isWorking` is false, which is
    /// what makes the whole build pausable/resumable by the hurt/angry
    /// reaction exactly like a sweep segment.
    private func advanceBuild(dt: TimeInterval) {
        switch buildPhase {
        case .walkingAway:
            if advanceWalk(dt: dt) {
                beginBuildRolling()
            }
        case .rolling:
            advanceBuildRolling(dt: dt)
        case .placing:
            advanceBuildPlacing(dt: dt)
        }
    }

    /// Walks toward `buildSpotX` while growing the rolling ball in step
    /// with how far she's come (so it always starts tiny and reaches its
    /// full target radius exactly as she arrives, regardless of how long
    /// this particular roll turned out to be), keeping it pinned to her
    /// leading edge and resting on the live snow top, spinning it slightly,
    /// and clearing the thin strip of accumulation it just rolled over —
    /// snow visibly feeding the ball, the same "shovel strip" shape as
    /// `advanceSweepSegment`'s push, just consumed instead of pushed.
    private func advanceBuildRolling(dt: TimeInterval) {
        let reached = advanceWalk(dt: dt)
        guard let ball = buildBallNode else {
            if reached { beginBuildPlacing() }
            return
        }

        let targetRadius = Self.buildBallTargetRadii[buildIndex]
        let totalDistance = max(abs(buildSpotX - buildRollStartX), 1)
        let traveled = min(abs(walkX - buildRollStartX), totalDistance)
        let progress = traveled / totalDistance
        let currentRadius = Self.buildBallStartRadius + (targetRadius - Self.buildBallStartRadius) * progress

        let ballX = walkX + segmentSign * shovelOffset
        ball.setScale(currentRadius / targetRadius)
        ball.position = CGPoint(x: ballX, y: accumulator.topY(of: surfaceState, atX: ballX) + currentRadius)
        ball.zRotation += (segmentSign * currentSpeed * CGFloat(dt)) / max(currentRadius, 1)

        let minX = min(buildLastFeedX, ballX)
        let maxX = max(buildLastFeedX, ballX)
        if maxX > minX {
            // Take only PART of each column she rolls over — fully zeroing
            // the path (old clearRange) stripped a single-surface screen
            // bare, which read as "부탁하면 눈이 다 사라진다" on machines where
            // screenBottom is the only snowy surface.
            accumulator.consumeRange(surfaceState, minX: minX, maxX: maxX, fraction: 0.45)
        }
        buildLastFeedX = ballX

        if reached {
            // She's arrived: whether or not the roll sprite hid it, this
            // prop IS the visible stacked ball from here through the
            // placing hop and the eventual handoff.
            ball.alpha = 1
            ball.setScale(1.0)
            ball.position = buildStackedPosition(forBallIndex: buildIndex)
            ball.zRotation = 0
            beginBuildPlacing()
        }
    }

    /// Ball `buildIndex` just reached the build spot. Ball 1 (index 0) just
    /// stays put as the base — no hop, straight on to the next ball. Ball 2
    /// (the head) gets a brief lift-and-place arc up onto its stacked spot.
    private func beginBuildPlacing() {
        buildPhase = .placing
        guard let ball = buildBallNode else {
            finishCurrentBall()
            return
        }
        buildPlacedBalls.append(ball)
        buildBallNode = nil

        guard buildIndex > 0 else {
            buildPlaceRemaining = 0
            finishCurrentBall()
            return
        }

        let stackedPosition = buildStackedPosition(forBallIndex: buildIndex)
        let liftPoint = CGPoint(x: stackedPosition.x, y: stackedPosition.y + 14 * s)
        let rise = SKAction.move(to: liftPoint, duration: Self.buildPlaceHopDuration * 0.45)
        rise.timingMode = .easeOut
        let drop = SKAction.move(to: stackedPosition, duration: Self.buildPlaceHopDuration * 0.55)
        drop.timingMode = .easeIn
        ball.run(.sequence([rise, drop]))
        buildPlaceRemaining = Self.buildPlaceHopDuration
    }

    /// Just keeps her idling in place while ball `buildIndex`'s hop (if any)
    /// plays out, then moves on.
    private func advanceBuildPlacing(dt: TimeInterval) {
        walkAnim.advance(by: dt)
        applyFrame(walkAnim.currentTexture)
        buildPlaceRemaining -= dt
        if buildPlaceRemaining <= 0 {
            finishCurrentBall()
        }
    }

    /// Advances to the next ball, or — once all 3 are stacked — to the
    /// real-snowman handoff.
    private func finishCurrentBall() {
        buildIndex += 1
        if buildIndex >= Self.buildBallTargetRadii.count {
            finishBuildSnowman()
        } else {
            beginBuildWalkAway()
        }
    }

    /// Where ball `index` rests once stacked, relative to the live surface
    /// top at `buildSpotX` — mirrors Snowman.assemble's own 2-tier
    /// (base/head, no torso) stacking math (same 0.3 overlap fraction) so
    /// the props sit exactly where the real balls will appear, including
    /// using the same radii (see `buildBallTargetRadii`'s doc comment) —
    /// the handoff in `finishBuildSnowman()` only reads as seamless if
    /// nothing jumps.
    private func buildStackedPosition(forBallIndex index: Int) -> CGPoint {
        let overlap: CGFloat = 0.3
        let baseY = accumulator.topY(of: surfaceState, atX: buildSpotX)
        let r0 = Self.buildBallTargetRadii[0]
        let r1 = Self.buildBallTargetRadii[1]
        let baseCenterY = baseY + r0
        let headCenterY = baseCenterY + r0 * (1 - overlap) + r1 * (1 - overlap)
        switch index {
        case 0: return CGPoint(x: buildSpotX, y: baseCenterY)
        default: return CGPoint(x: buildSpotX, y: headCenterY)
        }
    }

    /// Removes any still-in-flight rolling ball and any already-placed-but-
    /// not-yet-handed-off balls from the scene. `finishBuildSnowman()`
    /// handles its own (successful) handoff moment directly, so this is
    /// only exercised by the OTHER ways a build can end: the safety cap, or
    /// `beginFinish`'s own abort path. A no-op outside `.buildSnowman` mode
    /// or once nothing is left to clean.
    private func cleanupBuildProps() {
        if let ball = buildBallNode {
            ball.removeFromParent()
            activeEffects.removeAll { $0 === ball }
            buildBallNode = nil
        }
        for ball in buildPlacedBalls {
            ball.removeFromParent()
            activeEffects.removeAll { $0 === ball }
        }
        buildPlacedBalls.removeAll()
    }

    private func advanceSweepSegment(dt: TimeInterval) {
        let reached = advanceWalk(dt: dt)

        // Shovel leads her feet by a small offset in the walk direction;
        // she pushes the next few columns ahead of IT, not her feet.
        let shovelX = walkX + segmentSign * shovelOffset
        let minX = min(lastShovelX, shovelX)
        let maxX = max(lastShovelX, shovelX)

        // Checked BEFORE pushSnow (which zeroes these columns) — whether
        // there's any real snow in the strip her shovel is about to cross
        // decides whether this tick looks like shoveling or just walking.
        updateSweepVisual(hasSnow: columnsHaveSnow(minX: minX, maxX: maxX))

        if maxX > minX {
            let direction = segmentSign > 0 ? 1 : -1
            let overflow = accumulator.pushSnow(surfaceState, minX: minX, maxX: maxX, direction: direction, pushColumns: pushColumns)
            carriedSnow += overflow
        }
        lastShovelX = shovelX

        // 분노의 눈덩이 투척: the mound ahead of her shovel is SO maxed out
        // that pushing it just keeps overflowing back into carriedSnow
        // instead of fitting anywhere — see rageCarriedSnowThreshold's doc.
        // Fires at most once per summon (hasRaged latches) and preempts
        // the rest of this tick (quirks, rollNextActivity) entirely.
        if !hasRaged,
           activeTime >= Self.rageMinActiveTime,
           carriedSnow >= Self.rageCarriedSnowThreshold {
            hasRaged = true
            beginRage()
            return
        }

        // Random quirks only ever fire while actually sweeping (not during
        // rest/stroll — rest IS already a break), and this path is
        // unreachable while `overlay` is set — so a quirk can never
        // interrupt the hurt/angry reaction, which itself always plays
        // through `overlay`.
        maybeTriggerRandomQuirk(dt: dt)

        if reached {
            rollNextActivity()
        }
    }

    /// True if any column spanning [minX, maxX] (her shovel's strip this
    /// tick) still holds real snow, per `sweepSnowThreshold`.
    private func columnsHaveSnow(minX: CGFloat, maxX: CGFloat) -> Bool {
        let startIdx = max(accumulator.columnIndex(for: minX, in: surfaceState), 0)
        let endIdx = min(accumulator.columnIndex(for: maxX, in: surfaceState), surfaceState.heights.count - 1)
        guard startIdx <= endIdx else { return false }
        for i in startIdx...endIdx {
            if surfaceState.heights[i] > Self.sweepSnowThreshold { return true }
        }
        return false
    }

    /// Swaps `walkAnim` between the sweep frames and the plain-walk look
    /// ONLY when `hasSnow` differs from `sweepVisualActive` — swapping (and
    /// thereby re-creating the FrameSequence) every tick would restart it
    /// at frame 0 every tick, i.e. freeze it there. The sweep frames
    /// themselves are picked from `currentTravel`, same as `beginSweepSegment`,
    /// so flipping back on mid-stroke still shows the correct direction.
    private func updateSweepVisual(hasSnow: Bool) {
        guard hasSnow != sweepVisualActive else { return }
        sweepVisualActive = hasSnow
        if hasSnow {
            let frames = currentTravel == .leftToRight ? sweepLRTextures : sweepRLTextures
            walkAnim = FrameSequence(frames: frames, timePerFrame: 0.3, loops: true)
        } else {
            walkAnim = FrameSequence(frames: idleTextures, timePerFrame: 0.2, loops: true)
        }
        // advanceWalk() already called applyFrame this tick with the OLD
        // walkAnim's texture (it ran before this check) — re-apply now so
        // the swap is visible the same tick it happens, not one tick late.
        applyFrame(walkAnim.currentTexture)
    }

    private func advanceStrollSegment(dt: TimeInterval) {
        if advanceWalk(dt: dt) {
            rollNextActivity()
        }
    }

    private func advanceRestSegment(dt: TimeInterval) {
        walkAnim.advance(by: dt)
        applyFrame(walkAnim.currentTexture)
        restRemaining -= dt
        if restRemaining <= 0 {
            rollNextActivity()
        }
    }

    // MARK: - Rage (분노의 눈덩이 투척)

    /// Trigger fired (see `rageCarriedSnowThreshold`): ends her run entirely.
    /// Stops sweeping, plays the angry sulk once (step 1), then chains
    /// through pack (`beginRagePack`, step 2) -> wind-up (`beginRageThrow`,
    /// step 3a) -> throw (`launchRageBall`, step 3b) -> splat
    /// (`landRageSplat`, steps 4-5). `isWorking = false` mirrors
    /// `beginFinish`'s shape, but nothing after this re-enters the lazy
    /// activity loop — the whole rest of the sequence is overlay-driven,
    /// same mechanism as the hurt/angry reaction.
    private func beginRage() {
        isWorking = false
        playOverlay(sulkTextures, timePerFrame: 0.3) { [weak self] in
            self?.beginRagePack()
        }
    }

    /// Step 2: holds a pack pose while a small prop ball appears at her
    /// hands and pops up to its packed size.
    private func beginRagePack() {
        guard let parent = node.parent else { return }
        let packedRadius = CGFloat.random(in: Self.rageBallPackedRadiusRange)
        let ball = SKShapeNode(circleOfRadius: packedRadius)
        ball.fillColor = .white
        ball.strokeColor = SKColor(white: 0.85, alpha: 1)
        ball.lineWidth = 1
        ball.alpha = 0
        ball.setScale(0.05)
        ball.zPosition = node.zPosition + 1
        ball.position = CGPoint(x: node.position.x + travelSign * 6 * s, y: node.position.y + Self.displayHeight * 0.45)
        parent.addChild(ball)
        activeEffects.append(ball)
        rageBallNode = ball

        let pop = SKAction.sequence([
            .scale(to: 1.15, duration: Self.ragePackHoldDuration * 0.7),
            .scale(to: 1.0, duration: Self.ragePackHoldDuration * 0.3)
        ])
        ball.run(.group([.fadeIn(withDuration: 0.12), pop]))

        // Packing beat: throw_0 (pressing the snowball, annoyed) then
        // throw_1 (compacting it, angrier) when the throw sprite set
        // loaded; older bundles fall back to the placeholder misc-frame
        // hold, same as before this sheet existed.
        if let throwTextures {
            playOverlay([throwTextures[0], throwTextures[1]], timePerFrame: Self.rageThrowFrameHoldDuration) { [weak self] in
                self?.beginRageThrow()
            }
        } else {
            playOverlay([miscTextures[1]], timePerFrame: Self.ragePackHoldDuration) { [weak self] in
                self?.beginRageThrow()
            }
        }
    }

    /// Step 3a: wind-up pose (throw_2, over-the-shoulder) before the throw,
    /// when the throw sprite set loaded; older bundles skip straight to
    /// `launchRageBall`, same as before this sheet existed.
    private func beginRageThrow() {
        guard let throwTextures else {
            launchRageBall(impactOverlayFrames: [miscTextures[1]])
            return
        }
        playOverlay([throwTextures[2]], timePerFrame: Self.rageWindupHoldDuration) { [weak self] in
            self?.launchRageBall(impactOverlayFrames: [throwTextures[3]])
        }
    }

    /// Step 3b: throws the packed ball at a random point near scene center,
    /// clamped into the visible bounds, while it scales up dramatically to
    /// read as flying toward the viewer. `impactOverlayFrames` is the pose
    /// held for the flight's duration — throw_3 (hurling it at the viewer)
    /// when the throw sprite set loaded, the placeholder misc-frame
    /// otherwise (see `beginRageThrow()`).
    private func launchRageBall(impactOverlayFrames: [SKTexture]) {
        guard let ball = rageBallNode else { return }
        let sceneSize = node.scene?.size ?? CGSize(width: 2000, height: 1200)
        let center = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        let rawTarget = CGPoint(
            x: center.x + CGFloat.random(in: Self.rageImpactOffsetRange) * (Bool.random() ? 1 : -1),
            y: center.y + CGFloat.random(in: Self.rageImpactOffsetRange) * (Bool.random() ? 1 : -1)
        )
        let inset = Self.rageImpactEdgeInset
        let impact = CGPoint(
            x: min(max(rawTarget.x, inset), max(sceneSize.width - inset, inset)),
            y: min(max(rawTarget.y, inset), max(sceneSize.height - inset, inset))
        )

        let flightDuration = TimeInterval.random(in: Self.rageThrowDurationRange)
        let move = SKAction.move(to: impact, duration: flightDuration)
        move.timingMode = .easeIn
        let grow = SKAction.scale(to: CGFloat.random(in: Self.rageBallThrowScaleRange), duration: flightDuration)
        grow.timingMode = .easeIn
        let spin = SKAction.rotate(byAngle: CGFloat.random(in: -2...2), duration: flightDuration)
        ball.run(.group([move, grow, spin]))

        playOverlay(impactOverlayFrames, timePerFrame: flightDuration) { [weak self] in
            self?.landRageSplat(at: impact)
        }
    }

    /// Steps 4-5: the ball's arrived — swap it for the splat composition and
    /// hand the splat off to SnowScene (`onRageSplat`). From this instant
    /// the splat belongs to the SCENE's effectsLayer/lifecycle, not to this
    /// instance: it must keep fading for ~10s even after she's gone (her
    /// `onFinish` fires at the end of the fade kicked off right below), so
    /// tracking it in `activeEffects` — cleared by both `cancel()` and her
    /// own natural finish — would drop it the moment either of those runs.
    /// SnowScene's own cancel-safe array is what `resetAllSnow()` can still
    /// reach once this instance is deallocated.
    private func landRageSplat(at point: CGPoint) {
        guard let parent = node.parent else { return }
        if let ball = rageBallNode {
            ball.removeFromParent()
            activeEffects.removeAll { $0 === ball }
            rageBallNode = nil
        }

        let sceneWidth = node.scene?.size.width ?? 2000
        let splat = Self.makeRageSplatNode(at: point, sceneWidth: sceneWidth)
        parent.addChild(splat)
        onRageSplat(splat)

        // 가려졌을 때 fading 되는 시점에 영서도 같이 fading: her own fade starts
        // in the same instant the splat's fade begins (SnowScene starts
        // that synchronously inside onRageSplat above) — no wipe/idle tail,
        // this IS how the run ends.
        fadeOutAndDespawn(duration: .random(in: Self.rageSelfFadeDurationRange))
    }

    /// Builds the 분노의 눈덩이 splat: an irregular cluster of overlapping
    /// white blobs plus a few smaller satellite droplets, sized to roughly
    /// cover 0.6-0.7x the scene's width, with a couple of slow drip
    /// extensions for cheap juice. Caller places/owns the returned node —
    /// see `landRageSplat`.
    private static func makeRageSplatNode(at point: CGPoint, sceneWidth: CGFloat) -> SKNode {
        let container = SKNode()
        container.position = point
        container.zPosition = 60
        container.alpha = Self.rageSplatAlpha

        let targetWidth = sceneWidth * CGFloat.random(in: 0.6...0.7)
        let baseRadius = targetWidth * 0.3

        for _ in 0..<Int.random(in: 5...8) {
            let radius = baseRadius * CGFloat.random(in: 0.55...1.0)
            let offset = baseRadius * CGFloat.random(in: 0...0.55)
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let blob = SKShapeNode(circleOfRadius: radius)
            blob.fillColor = .white
            blob.strokeColor = .clear
            blob.position = CGPoint(x: cos(angle) * offset, y: sin(angle) * offset)
            container.addChild(blob)
        }

        for _ in 0..<Int.random(in: 3...5) {
            let radius = baseRadius * CGFloat.random(in: 0.08...0.18)
            let distance = baseRadius * CGFloat.random(in: 0.9...1.3)
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let droplet = SKShapeNode(circleOfRadius: radius)
            droplet.fillColor = .white
            droplet.strokeColor = .clear
            droplet.position = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
            container.addChild(droplet)
        }

        for _ in 0..<Int.random(in: 2...3) {
            let dripWidth = baseRadius * CGFloat.random(in: 0.12...0.2)
            let dripHeight = baseRadius * CGFloat.random(in: 0.5...0.9)
            let drip = SKShapeNode(ellipseOf: CGSize(width: dripWidth, height: dripHeight))
            drip.fillColor = .white
            drip.strokeColor = .clear
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            drip.position = CGPoint(x: cos(angle) * baseRadius * 0.85, y: sin(angle) * baseRadius * 0.85 - dripHeight * 0.3)
            container.addChild(drip)
            let slide = SKAction.moveBy(x: 0, y: -CGFloat.random(in: 3...7), duration: 2.0)
            slide.timingMode = .easeIn
            drip.run(slide)
        }

        return container
    }

    // MARK: - Plow interaction

    /// Called every frame by SnowScene when the plow is driving the SAME
    /// surface she is, with the plow's current x. Triggers a hurt→angry
    /// reaction once per pass. Works regardless of her current activity —
    /// getting plowed while resting or strolling still triggers it, since
    /// this is checked by `update(dt:)` ahead of the activity dispatch.
    func notifyPlowProximity(plowX: CGFloat) {
        // `!hasRaged` also covers "mid-rage": once she's raging, the plow
        // passing by must never interrupt the pack/throw overlay chain —
        // it would orphan the in-flight ball the same way beginDrag's
        // cleanup guards against (see that comment).
        guard !isDone, !isAirborne, !hasRaged else { return }
        let distance = abs(plowX - currentX)
        if distance > 60 {
            hurtLatched = false
            return
        }
        guard distance <= 30, !hurtLatched, !isInHurtOrAngry else { return }
        hurtLatched = true
        triggerHurtAngry(plowX: plowX)
    }

    /// Hit area for clicking her, in scene coords (effectsLayer is at the
    /// scene origin, unscaled, so node.frame is already scene-space). Small
    /// negative inset so a slightly-off click still counts at 40pt size.
    func contains(scenePoint p: CGPoint) -> Bool {
        guard !isDone else { return false }
        return node.frame.insetBy(dx: -6, dy: -6).contains(p)
    }

    // MARK: - Drag & drop

    private enum AirState { case none, dragging, falling }
    private var airState: AirState = .none
    private var fallVX: CGFloat = 0
    private var fallVY: CGFloat = 0

    var isDragging: Bool { if case .dragging = airState { return true }; return false }
    /// True while she's held or falling — SnowScene must NOT retarget/
    /// resummon her in this window even if her old surface vanishes.
    var isAirborne: Bool { if case .none = airState { return false }; return true }

    /// She's been grabbed: freeze the routine, startled face, follow the cursor.
    func beginDrag(at p: CGPoint) {
        guard !isDone else { return }
        if mode == .buildSnowman {
            // Grabbed mid-build: the illusion can't continue once she's
            // yanked away mid-roll, so scrap it cleanly right here rather
            // than leaving half-built prop balls behind or trying to
            // resume wherever she eventually lands.
            cleanupBuildProps()
        }
        if let ball = rageBallNode {
            // Grabbed mid-pack/throw: the ball's flight SKAction has no
            // completion handler of its own (landRageSplat is only reached
            // via the overlay chain below, which we're about to clear) —
            // without this cleanup it would keep flying/growing forever
            // with nothing left to turn it into a splat.
            ball.removeFromParent()
            activeEffects.removeAll { $0 === ball }
            rageBallNode = nil
        }
        airState = .dragging
        overlay = nil
        onOverlayFinished = nil
        isInHurtOrAngry = false
        applyFrame(miscTextures[1])
        dragTo(p)
    }

    func dragTo(_ p: CGPoint) {
        guard isDragging else { return }
        // Held roughly by the scruff: cursor sits a bit above her middle.
        node.position = CGPoint(x: p.x, y: p.y - Self.displayHeight * 0.55)
    }

    /// Released mid-air: fall with the throw's momentum under gravity.
    func endDrag(velocity: CGVector) {
        guard isDragging else { return }
        airState = .falling
        fallVX = min(max(velocity.dx, -600), 600)
        fallVY = min(max(velocity.dy, -200), 400)
    }

    private func advanceFall(dt: TimeInterval) {
        fallVY -= 900 * CGFloat(dt)
        fallVX *= max(0, 1 - 1.5 * CGFloat(dt))
        let sceneWidth = node.scene?.size.width ?? 10_000
        let oldY = node.position.y
        let newX = min(max(node.position.x + fallVX * CGFloat(dt), 0), sceneWidth)
        let newY = oldY + fallVY * CGFloat(dt)
        node.position.x = newX

        // Land on the highest surface top at newX that was at/below her
        // previous y — same shape as the flake landing rule.
        var best: (state: SnowAccumulator.SurfaceState, top: CGFloat)?
        for state in accumulator.states {
            guard state.surface.minX <= newX, newX <= state.surface.maxX else { continue }
            let top = accumulator.topY(of: state, atX: newX)
            guard top <= oldY + 4 else { continue }
            if best == nil || top > best!.top {
                best = (state, top)
            }
        }
        if let best, newY <= best.top {
            land(on: best.state, atX: newX, topY: best.top)
            return
        }
        if newY < -60 {
            // Fell past everything (screenBottom should always catch her —
            // defensive only): give up gracefully.
            airState = .none
            beginFinish(aborted: true)
            return
        }
        node.position.y = newY
    }

    /// Touchdown: re-anchor onto whatever surface she landed on (may be a
    /// different one than she was summoned to), impact puff, one round of
    /// being annoyed about the whole thing, then back to work right there.
    private func land(on state: SnowAccumulator.SurfaceState, atX x: CGFloat, topY: CGFloat) {
        airState = .none
        fallVX = 0
        fallVY = 0
        surfaceState = state
        lastSurfaceMinX = state.surface.minX
        walkX = min(max(x, state.surface.minX), state.surface.maxX)
        currentX = walkX
        lastShovelX = walkX
        node.position = CGPoint(x: currentX, y: topY)
        if let parent = node.parent {
            spawnPoof(in: parent, at: node.position)
        }
        isInHurtOrAngry = true
        if mode == .buildSnowman {
            // The build was already scrapped the instant she was grabbed
            // (beginDrag's cleanupBuildProps) — nothing left to build, so
            // settle straight into the normal wipe/idle finish once she's
            // done being annoyed about the fall, instead of resuming a
            // build with no pieces left.
            isWorking = false
            playOverlay(sulkTextures, timePerFrame: 0.25) { [weak self] in
                self?.isInHurtOrAngry = false
                self?.playFinishWipeIdle()
            }
            return
        }
        beginSweepSegment(direction: currentTravel)
        isWorking = true
        playOverlay(sulkTextures, timePerFrame: 0.25) { [weak self] in
            self?.isInHurtOrAngry = false
        }
    }

    /// The user clicked her — 짜증: a little jolt straight into the sulk
    /// animation. Repeat clicks while she's already reacting are ignored
    /// (no escalation, she just finishes being annoyed first).
    func poke() {
        // `!hasRaged`: same reasoning as notifyPlowProximity's guard — a
        // poke mid-rage must not clobber the pack/throw overlay chain.
        guard !isDone, !isInHurtOrAngry, !isAirborne, !hasRaged else { return }
        isInHurtOrAngry = true
        node.position.x += CGFloat.random(in: -4 * s...4 * s)
        playOverlay(sulkTextures, timePerFrame: 0.25) { [weak self] in
            self?.isInHurtOrAngry = false
        }
    }

    /// 치고 감: impact flash + snow puff at her position, then a short
    /// knockback hop away from the plow, THEN the existing hurt(misc_1)→
    /// angry(sulk) overlay. `plowX` is the plow's live x (vs. `currentX`,
    /// hers) — its sign relative to her is the only thing that decides
    /// which way she gets shoved.
    private func triggerHurtAngry(plowX: CGFloat) {
        isInHurtOrAngry = true
        spawnImpactEffect()
        performKnockback(awayFromPlowX: plowX)
        playOverlay([miscTextures[1]], timePerFrame: 0.5) { [weak self] in
            guard let self else { return }
            self.playOverlay(self.sulkTextures, timePerFrame: 0.3) { [weak self] in
                self?.isInHurtOrAngry = false
            }
        }
    }

    /// Shoves her a short hop away from the plow's travel direction. `node`
    /// plays the visual arc itself (SKAction), but `walkX`/`currentX` (and
    /// the shovel baseline `lastShovelX`) are snapped to the landing x
    /// immediately — `update(dt:)`'s ride-window block re-derives
    /// `node.position` from `currentX` EVERY frame (even while an overlay
    /// is playing), so leaving those stale would yank her straight back to
    /// her pre-knockback spot the instant the next tick ran.
    private func performKnockback(awayFromPlowX plowX: CGFloat) {
        let shoveSign: CGFloat = currentX >= plowX ? 1 : -1
        let landingX = clampToSurface(currentX + shoveSign * 18 * s)
        let actualShoveX = landingX - currentX
        let landingY = accumulator.topY(of: surfaceState, atX: landingX)
        let hopUp = 10 * s

        let rise = SKAction.moveBy(x: actualShoveX * 0.55, y: hopUp, duration: 0.15)
        rise.timingMode = .easeOut
        // The descent targets an ABSOLUTE y (`moveTo: landingY`), not a
        // relative drop back to the height she hopped FROM — those only
        // match by coincidence (surface height can differ between her old
        // x and `landingX`). An absolute target here is what keeps the
        // hop's landing and the per-frame ride-window pin (which takes
        // over immediately after, using the now-updated `currentX`)
        // continuous instead of popping.
        let fall = SKAction.group([
            .moveBy(x: actualShoveX * 0.45, y: 0, duration: 0.2),
            .moveTo(y: landingY, duration: 0.2)
        ])
        fall.timingMode = .easeIn
        node.run(.sequence([rise, fall]))

        walkX = landingX
        currentX = landingX
        // Fresh shovel baseline at the landing spot — same reasoning as
        // beginSweepSegment's own reset: without this, the next sweep tick
        // would see a huge, stale [lastShovelX, shovelX] gap spanning the
        // whole knockback and push/collect a big phantom swath of snow.
        lastShovelX = landingX + segmentSign * shovelOffset
    }

    /// 치고 감 flash: a couple of small star-bursts pop outward and fade,
    /// plus a smaller/fewer-count version of the arrival snow puff — both
    /// at her current position.
    private func spawnImpactEffect() {
        guard let parent = node.parent else { return }
        let point = node.position

        let starCount = Int.random(in: 2...3)
        for _ in 0..<starCount {
            let star = Self.makeStarNode(scale: s)
            star.position = point
            star.zPosition = 32
            star.alpha = 0
            parent.addChild(star)
            activeEffects.append(star)

            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let travelDistance = CGFloat.random(in: 10...18) * s
            let pop = SKAction.moveBy(x: cos(angle) * travelDistance, y: sin(angle) * travelDistance, duration: 0.4)
            pop.timingMode = .easeOut
            let appear = SKAction.sequence([
                .fadeAlpha(to: 1, duration: 0.05),
                .wait(forDuration: 0.15),
                .fadeOut(withDuration: 0.2)
            ])
            let spin = SKAction.rotate(byAngle: CGFloat.random(in: -1...1), duration: 0.4)
            star.run(.group([pop, appear, spin])) { [weak self, weak star] in
                star?.removeFromParent()
                guard let star else { return }
                self?.activeEffects.removeAll { $0 === star }
            }
        }

        for i in 0..<2 {
            let circle = SKShapeNode(circleOfRadius: 4 * s)
            circle.fillColor = .white
            circle.strokeColor = .clear
            circle.alpha = 0.8
            circle.position = point
            circle.zPosition = 29
            parent.addChild(circle)
            activeEffects.append(circle)

            let delay = SKAction.wait(forDuration: Double(i) * 0.03)
            let expand = SKAction.scale(to: CGFloat.random(in: 1.6...2.2), duration: 0.3)
            let fade = SKAction.fadeOut(withDuration: 0.3)
            circle.run(.sequence([delay, .group([expand, fade]), .removeFromParent()])) { [weak self, weak circle] in
                guard let circle else { return }
                self?.activeEffects.removeAll { $0 === circle }
            }
        }
    }

    private static func makeStarNode(scale: CGFloat) -> SKShapeNode {
        let outer: CGFloat = 5 * scale
        let inner: CGFloat = 2 * scale
        let path = CGMutablePath()
        for i in 0..<8 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        let shape = SKShapeNode(path: path)
        shape.fillColor = Bool.random() ? .white : SKColor(red: 1, green: 0.9, blue: 0.4, alpha: 1)
        shape.strokeColor = .clear
        return shape
    }

    // MARK: - Quirks

    private func randomQuirk() -> Quirk? {
        Self.quirkPool.randomElement()
    }

    private func playQuirk(_ quirk: Quirk, then: @escaping () -> Void) {
        switch quirk {
        case .heart:
            spawnHeart()
            playOverlay([miscTextures[0]], timePerFrame: 1.0, then: then)
        case .look:
            playOverlay(lookTextures, timePerFrame: 0.25, then: then)
        case .wipe:
            playOverlay(wipeTextures, timePerFrame: 0.25, then: then)
        case .tilt:
            playOverlay([miscTextures[1]], timePerFrame: 0.8, then: then)
        case .sulk:
            playOverlay(Array(sulkTextures.prefix(2)), timePerFrame: 0.25, then: then)
        }
    }

    private func maybeTriggerRandomQuirk(dt: TimeInterval) {
        quirkTimer += dt
        guard quirkTimer >= nextQuirkDelay else { return }
        quirkTimer = 0
        nextQuirkDelay = .random(in: 6...14)
        guard let quirk = randomQuirk() else { return }
        playQuirk(quirk, then: {})
    }

    private func spawnHeart() {
        guard let parent = node.parent else { return }
        let heart = Self.makeHeartNode(scale: s)
        heart.position = CGPoint(x: node.position.x, y: node.position.y + Self.displayHeight * 0.75)
        parent.addChild(heart)
        activeEffects.append(heart)

        let drift = SKAction.moveBy(x: travelSign * 14 * s, y: 26 * s, duration: 1.2)
        let wobble = SKAction.sequence([
            .moveBy(x: 5 * s, y: 0, duration: 0.2),
            .moveBy(x: -10 * s, y: 0, duration: 0.3),
            .moveBy(x: 5 * s, y: 0, duration: 0.2)
        ])
        let fade = SKAction.sequence([.wait(forDuration: 0.6), .fadeOut(withDuration: 0.6)])
        heart.run(.group([drift, wobble, fade])) { [weak self, weak heart] in
            heart?.removeFromParent()
            guard let heart else { return }
            self?.activeEffects.removeAll { $0 === heart }
        }
    }

    private static func makeHeartNode(scale: CGFloat) -> SKShapeNode {
        let size: CGFloat = 7 * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -size * 1.1))
        path.addCurve(to: CGPoint(x: -size, y: size * 0.5), control1: CGPoint(x: -size * 1.3, y: -size * 0.3), control2: CGPoint(x: -size * 1.4, y: size * 0.5))
        path.addArc(center: CGPoint(x: -size * 0.5, y: size * 0.55), radius: size * 0.5, startAngle: .pi, endAngle: 0, clockwise: false)
        path.addArc(center: CGPoint(x: size * 0.5, y: size * 0.55), radius: size * 0.5, startAngle: .pi, endAngle: 0, clockwise: false)
        path.addCurve(to: CGPoint(x: 0, y: -size * 1.1), control1: CGPoint(x: size * 1.4, y: size * 0.5), control2: CGPoint(x: size * 1.3, y: -size * 0.3))
        path.closeSubpath()
        let shape = SKShapeNode(path: path)
        shape.fillColor = SKColor(red: 0.95, green: 0.3, blue: 0.45, alpha: 1)
        shape.strokeColor = .clear
        shape.zPosition = 31
        return shape
    }

    // MARK: - Arrival poof

    private func spawnPoof(in parent: SKNode, at point: CGPoint) {
        for i in 0..<4 {
            let circle = SKShapeNode(circleOfRadius: 6 * s)
            circle.fillColor = .white
            circle.strokeColor = .clear
            circle.alpha = 0.85
            circle.position = point
            circle.zPosition = 29
            parent.addChild(circle)
            activeEffects.append(circle)

            let delay = SKAction.wait(forDuration: Double(i) * 0.04)
            let expand = SKAction.scale(to: CGFloat.random(in: 2.2...3.2), duration: 0.35)
            let fade = SKAction.fadeOut(withDuration: 0.35)
            let sequence = SKAction.sequence([delay, .group([expand, fade]), .removeFromParent()])
            circle.run(sequence) { [weak self, weak circle] in
                guard let circle else { return }
                self?.activeEffects.removeAll { $0 === circle }
            }
        }
    }

    // MARK: - Finish

    /// Forced wrap-up once the ~90s active-time safety cap is hit: she
    /// does the sulk animation once (annoyed she's been at this so long —
    /// not the probabilistic pre-fadeout quirk), dumps whatever she's
    /// carrying, then proceeds through the normal wipe/idle/fade-out tail
    /// regardless of how much snow is left.
    private func triggerSafetyCapFinish() {
        isWorking = false
        cleanupBuildProps()
        dumpCarriedSnowAndSpillOverflow()
        playQuirk(.sulk, then: { [weak self] in self?.playFinishWipeIdle() })
    }

    private func beginFinish(aborted: Bool) {
        isWorking = false
        cleanupBuildProps()
        guard !aborted else {
            fadeOutAndDespawn()
            return
        }
        dumpCarriedSnowAndSpillOverflow()
        let proceedToWipe: () -> Void = { [weak self] in self?.playFinishWipeIdle() }
        if Double.random(in: 0..<1) < 0.3, let quirk = randomQuirk() {
            playQuirk(quirk, then: proceedToWipe)
        } else {
            proceedToWipe()
        }
    }

    /// `.buildSnowman` mode's wrap-up, reached once both balls
    /// (beginBuildWalkAway/advanceBuildRolling/beginBuildPlacing) are rolled
    /// and stacked at `buildSpotX`. Steps her aside first so the real
    /// snowman node about to pop in doesn't appear on top of her, THEN pops
    /// every prop ball out and fires the handoff IN THE SAME TICK — the
    /// illusion only reads as seamless if the fake balls vanish the exact
    /// instant the real ones appear, not a beat before or after — then the
    /// proud heart quirk, then the normal wipe/idle fade-out tail.
    private func finishBuildSnowman() {
        isWorking = false
        if ProcessInfo.processInfo.environment["SNOWMAC_DEBUG"] != nil {
            FileHandle.standardError.write("SNOWMAC_DEBUG snowman: finishBuildSnowman buildSpotX=\(String(format: "%.1f", buildSpotX)) surfaceSpan=[\(String(format: "%.1f", surfaceMinX)), \(String(format: "%.1f", surfaceMaxX))] placedBalls=\(buildPlacedBalls.count)\n".data(using: .utf8)!)
        }
        // Her current position IS the build spot — the last ball's rolling
        // pass walked her exactly there (segmentTargetX == buildSpotX).
        let buildPoint = node.position
        stepAside()
        for ball in buildPlacedBalls {
            ball.removeFromParent()
            activeEffects.removeAll { $0 === ball }
        }
        buildPlacedBalls.removeAll()
        onBuildSnowman?(buildPoint)
        playQuirk(.heart, then: { [weak self] in self?.playFinishWipeIdle() })
    }

    /// Shifts her a few points along her current direction so she's not
    /// standing inside the snowman node about to pop in at her old spot.
    /// Mirrors performKnockback's pattern: node plays a short visual step
    /// (SKAction), while walkX/currentX/lastShovelX are snapped to the
    /// landing x immediately — update(dt:)'s per-frame ride-window pin
    /// (which re-derives node.position.y from currentX every frame, even
    /// mid-overlay) would otherwise yank her straight back.
    private func stepAside() {
        let sideStep: CGFloat = 16 * s
        let shoveSign: CGFloat = segmentSign != 0 ? segmentSign : travelSign
        let landingX = clampToSurface(currentX + shoveSign * sideStep)
        let landingY = accumulator.topY(of: surfaceState, atX: landingX)
        node.run(.move(to: CGPoint(x: landingX, y: landingY), duration: 0.25))
        walkX = landingX
        currentX = landingX
        lastShovelX = landingX
    }

    private func playFinishWipeIdle() {
        playOverlay(wipeTextures, timePerFrame: 0.25) { [weak self] in
            guard let self else { return }
            self.playOverlay(self.idleTextures, timePerFrame: 0.25) { [weak self] in
                self?.fadeOutAndDespawn()
            }
        }
    }

    /// Dumps everything she was carrying into the columns at the end of her
    /// nominal (`travel`) direction — not necessarily where she currently
    /// stands, since the lazy loop can leave her anywhere on the surface —
    /// where it settles into the tall pile at that edge. Whatever still
    /// doesn't fit under the cap spills as falling clumps off the surface
    /// edge.
    private func dumpCarriedSnowAndSpillOverflow() {
        guard accumulator.states.contains(where: { $0 === surfaceState }) else { return }
        let edgeIdx = travel == .leftToRight ? surfaceState.heights.count - 1 : 0
        let leftover = accumulator.depositCapped(surfaceState, amount: carriedSnow, startIdx: edgeIdx, direction: -columnStep, maxColumns: finalPileColumns)
        guard leftover > 0 else { return }
        let clumpCount = min(max(Int(leftover / 5), 1), 12)
        let perClump = leftover / CGFloat(clumpCount)
        let edgeX = travel == .leftToRight ? surfaceState.surface.maxX + 6 : surfaceState.surface.minX - 6
        for _ in 0..<clumpCount {
            let point = CGPoint(x: edgeX + CGFloat.random(in: -4...4), y: surfaceState.surface.y + CGFloat.random(in: 0...6))
            spawnClump(point, perClump)
        }
    }

    private func fadeOutAndDespawn(duration: TimeInterval = 0.4) {
        isDone = true
        node.run(.sequence([.fadeOut(withDuration: duration), .removeFromParent()])) { [weak self] in
            self?.onFinish()
        }
    }

    // MARK: - Cancellation

    /// Immediately removes her and any still-floating effects (poof/heart)
    /// — used by resetAllSnow() so a mid-routine reset never leaves orphaned
    /// nodes behind. Does NOT call onFinish (the caller already knows it's
    /// cancelling, not waiting on a natural finish).
    func cancel() {
        guard !isDone else { return }
        isDone = true
        node.removeAllActions()
        node.removeFromParent()
        for effect in activeEffects { effect.removeFromParent() }
        activeEffects.removeAll()
    }
}
