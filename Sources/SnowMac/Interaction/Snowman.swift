import AppKit
import SpriteKit

/// A fully assembled snowman: base, torso, head, arms, eyes, nose, scarf, and an
/// optional hat, each appearing one-by-one with a pop-in animation (feature 06).
/// Once assembled it loops idle animations (feature 07): breathing, occasional arm
/// wave, and a rare little dance.
///
/// Visual style is deliberately "kawaii plush toy" rather than realistic: an
/// oversized round head, glossy baby-proportioned eyes, rosy cheeks, and a
/// stubby carrot nose. All of the plumping happens to *rendered* sizes inside
/// `assemble` — the stored `baseRadius`/`headRadius`/`isTwoTier` that
/// InteractionController reads keep their original ball-physics meaning.
/// Classic snowman arm pose (feature: arm pose variety), rolled ~50/50 per
/// spawn — see `ArmPose.random()`. `.raisedCozy` is the original fixed
/// look: short stubby twigs angled up and in, which can read as hands
/// near/covering the face. `.spreadWide` sends them out near-horizontal
/// and away from the body instead (팔을 밖으로 활짝 펼친 형태), for variety.
/// Only `kind == .classic` snowmen ever render arms at all (see
/// `assembleSculpture`), but this is still rolled unconditionally at
/// init, same as `colorway` is for every kind even though only
/// pixel-sculpture kinds read it.
private enum ArmPose {
    case raisedCozy
    case spreadWide

    static func random() -> ArmPose {
        Bool.random() ? .raisedCozy : .spreadWide
    }

    /// Arm length as a multiple of the shoulder-ball radius — the spread
    /// pose reads better a touch longer than the cozy one.
    var lengthScale: CGFloat {
        switch self {
        case .raisedCozy: return 1.05
        case .spreadWide: return 1.25
        }
    }

    /// Base zRotation (radians) for the LEFT arm (`makeArm(flip: false)`);
    /// the right arm mirrors it with the negated value, same as the
    /// original fixed ±0.85 pose did. `.spreadWide`'s larger magnitude
    /// rotates `makeArm`'s own slightly-upward-angled path (local slope
    /// 0.25) the rest of the way around to point outward, near-horizontal,
    /// away from the body instead of up and in toward the face.
    var leftArmRotation: CGFloat {
        switch self {
        case .raisedCozy: return 0.85
        case .spreadWide: return 2.63
        }
    }
}

final class Snowman: SKNode {
    let variant: SnowmanVariant
    /// Which of the 10 looks this snowman is (feature: pixel-art snowman
    /// kinds). `.classic` runs the original ball-stack assembly below;
    /// every other case is a single-body 8-bit pixel sculpture rendered by
    /// `PixelSculpt` — see `assembleSculpture`.
    let kind: SnowmanKind
    /// Pastel colorway rolled for this spawn. Only `kind != .classic`
    /// sculptures actually use it — `.classic` keeps its own 5-variant
    /// `SnowmanVariant` palette and ignores this entirely.
    let colorway: SnowmanColorway
    let hitRadius: CGFloat
    /// Ball sizes this snowman was assembled with, kept around so a later
    /// ball drop can read them back to upgrade a 2-tier snowman to 3-tier
    /// (see InteractionController.upgradeToThreeTier).
    let baseRadius: CGFloat
    let headRadius: CGFloat
    /// True when assembled without a torso (base + head only). A classic
    /// 2-tier snowman is never a dead end — dropping a ball near it
    /// upgrades it. Pixel-sculpture kinds are single-body FINAL forms and
    /// are always `false` here regardless of whether a torso radius was
    /// supplied, so they're never matched by that upgrade path (see
    /// `assembleSculpture`'s caller in `init`).
    let isTwoTier: Bool
    /// Rolled once per spawn — see `ArmPose`. Stored (not just a local in
    /// `assemble`) so a future caller could inspect/reuse it; currently
    /// only `assemble` itself reads it.
    private let armPose: ArmPose

    /// Set to the sculpture's sprite (or the classic torso ball) so
    /// `startIdleAnimations`'s breathe pulse has a single node to animate —
    /// deliberately reused across both assembly paths rather than adding a
    /// second stored property.
    private var torsoNode: SKNode?
    private var armLeft: SKShapeNode?
    private var armRight: SKShapeNode?
    private var idleStarted = false

    /// Coal-black used for eyes and mouth strokes — near-black rather than
    /// pure black so it reads as material, not a flat cutout.
    private static let faceInkColor = SKColor(white: 0.05, alpha: 1)

    /// How much bigger the rendered head ball is than the stored
    /// `headRadius`. A big-head/small-body ratio is the single strongest
    /// "chibi" cue — purely a rendering choice, so stacking math and
    /// hit-testing elsewhere keep working off the real radius.
    private static let cuteHeadScale: CGFloat = 1.22

    /// Converts a sculpture's ball radii into a total on-screen height, so
    /// a pixel-sculpture kind spawned from the same radii as a classic
    /// snowman renders at a comparable overall size. Tuned against
    /// InteractionController's 2-tier built-snowman radii (30/18, torso
    /// approximated as their midpoint 24 — see `effectiveTorso` below):
    /// that sums to 72, and a classic assembled from base/head 30/18 stands
    /// roughly 105-110pt tall head to toe — 72 * 1.55 lands right in that
    /// range.
    private static let sculptureHeightScale: CGFloat = 1.55

    /// `torsoRadius` nil assembles a 2-tier snowman (base + head only;
    /// arms/scarf attach to the base ball instead of a torso) for
    /// `kind == .classic`. For a pixel-sculpture `kind`, `torsoRadius` only
    /// ever affects the sculpture's overall rendered size (see
    /// `assembleSculpture`) — it never changes `isTwoTier`, which is always
    /// `false` for a sculpture.
    init(basePoint: CGPoint, kind: SnowmanKind, colorway: SnowmanColorway, variant: SnowmanVariant, baseRadius: CGFloat, torsoRadius: CGFloat?, headRadius: CGFloat) {
        self.kind = kind
        self.colorway = colorway
        self.variant = variant
        self.baseRadius = baseRadius
        self.headRadius = headRadius
        self.isTwoTier = kind == .classic && torsoRadius == nil
        self.armPose = ArmPose.random()
        self.hitRadius = max(baseRadius, torsoRadius ?? 0, headRadius) * 1.6 + headRadius
        super.init()
        position = basePoint
        name = "snowman"
        zPosition = 100
        if kind == .classic {
            assemble(baseRadius: baseRadius, torsoRadius: torsoRadius, headRadius: headRadius)
        } else {
            assembleSculpture(kind: kind, colorway: colorway, baseRadius: baseRadius, torsoRadius: torsoRadius, headRadius: headRadius)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Snowman does not support coder init")
    }

    func contains(scenePoint p: CGPoint) -> Bool {
        hypot(p.x - position.x, p.y - position.y) <= hitRadius
    }

    // MARK: - Assembly

    private func ballShape(radius: CGFloat) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = .white
        node.strokeColor = SKColor(white: 0.85, alpha: 1)
        node.lineWidth = 1
        return node
    }

    /// A faint contact shadow dropped at a ball seam before the ball above
    /// it is added, so a soft crescent of shade peeks out from underneath —
    /// gives the stack a touch of plush-toy dimensionality.
    private func seamShadow(width: CGFloat) -> SKShapeNode {
        let shadow = SKShapeNode(ellipseOf: CGSize(width: width, height: width * 0.3))
        shadow.fillColor = SKColor(white: 0, alpha: 0.07)
        shadow.strokeColor = .clear
        return shadow
    }

    private func popIn(_ node: SKNode, after delay: TimeInterval) {
        node.alpha = 0
        node.setScale(0.01)
        node.run(.sequence([
            .wait(forDuration: delay),
            .group([
                .fadeIn(withDuration: 0.15),
                .sequence([.scale(to: 1.2, duration: 0.14), .scale(to: 1.0, duration: 0.1)])
            ])
        ]))
    }

    private func assemble(baseRadius: CGFloat, torsoRadius: CGFloat?, headRadius: CGFloat) {
        // Snug, cuddly stacking — balls nestle into each other noticeably
        // more than a realistic snowman would, which reads as "soft toy"
        // instead of "gappy snow golem".
        let overlap: CGFloat = 0.38
        let baseCenterY = baseRadius

        // The head renders larger than its stored radius (see
        // cuteHeadScale) for baby-like proportions — big head, small body.
        let cuteHeadRadius = headRadius * Self.cuteHeadScale

        let base = ballShape(radius: baseRadius)
        base.position = CGPoint(x: 0, y: baseCenterY)
        addChild(base)

        // Arms/scarf attach to the "shoulder" ball: the torso for a
        // 3-tier snowman, or the base ball itself when there's no torso
        // (2-tier) — everything below just parameterizes on whichever it is.
        let shoulderRadius: CGFloat
        let shoulderCenterY: CGFloat
        let headCenterY: CGFloat

        if let torsoRadius {
            let torsoCenterY = baseCenterY + baseRadius * (1 - overlap) + torsoRadius * (1 - overlap)

            let torsoSeam = seamShadow(width: min(baseRadius, torsoRadius) * 1.7)
            torsoSeam.position = CGPoint(x: 0, y: baseCenterY + baseRadius * (1 - overlap))
            addChild(torsoSeam)

            let torso = ballShape(radius: torsoRadius)
            torso.position = CGPoint(x: 0, y: torsoCenterY)
            popIn(torso, after: 0.12)
            addChild(torso)
            torsoNode = torso

            shoulderRadius = torsoRadius
            shoulderCenterY = torsoCenterY
            headCenterY = torsoCenterY + torsoRadius * (1 - overlap) + cuteHeadRadius * (1 - overlap)
        } else {
            shoulderRadius = baseRadius
            shoulderCenterY = baseCenterY
            headCenterY = baseCenterY + baseRadius * (1 - overlap) + cuteHeadRadius * (1 - overlap)
        }

        let headSeam = seamShadow(width: min(shoulderRadius, cuteHeadRadius) * 1.7)
        headSeam.position = CGPoint(x: 0, y: shoulderCenterY + shoulderRadius * (1 - overlap))
        addChild(headSeam)

        let head = ballShape(radius: cuteHeadRadius)
        head.position = CGPoint(x: 0, y: headCenterY)
        popIn(head, after: 0.28)
        addChild(head)

        // Short, stubby twigs — either angled up and in (`.raisedCozy`, the
        // original "waving hello" pose) or spread out near-horizontal,
        // away from the body (`.spreadWide`), per `armPose` (rolled once
        // at spawn — see `ArmPose`), instead of long spindly branches.
        let armLength = shoulderRadius * armPose.lengthScale
        let leftArmRotation = armPose.leftArmRotation
        let leftArm = makeArm(length: armLength, flip: false)
        leftArm.position = CGPoint(x: -shoulderRadius * 0.75, y: shoulderCenterY + shoulderRadius * 0.25)
        leftArm.zRotation = leftArmRotation
        popIn(leftArm, after: 0.46)
        addChild(leftArm)
        armLeft = leftArm

        let rightArm = makeArm(length: armLength, flip: true)
        rightArm.position = CGPoint(x: shoulderRadius * 0.75, y: shoulderCenterY + shoulderRadius * 0.25)
        rightArm.zRotation = -leftArmRotation
        popIn(rightArm, after: 0.6)
        addChild(rightArm)
        armRight = rightArm

        // Face features get a zPosition well above the body/scarf/hat so
        // they always read on top, regardless of child-add order — a hat
        // or scarf positioned low enough to geometrically overlap the face
        // (e.g. on a small player-stacked head) can never cover it.
        let cheeks = makeCheeks(headRadius: cuteHeadRadius)
        cheeks.position = CGPoint(x: 0, y: headCenterY - cuteHeadRadius * 0.05)
        cheeks.zPosition = 19
        popIn(cheeks, after: 0.7)
        addChild(cheeks)

        let eyes = makeEyes(headRadius: cuteHeadRadius)
        eyes.position = CGPoint(x: 0, y: headCenterY + cuteHeadRadius * 0.08)
        eyes.zPosition = 20
        popIn(eyes, after: 0.78)
        addChild(eyes)

        let nose = makeNose(headRadius: cuteHeadRadius)
        nose.position = CGPoint(x: 0, y: headCenterY - cuteHeadRadius * 0.02)
        nose.zPosition = 21
        popIn(nose, after: 0.94)
        addChild(nose)

        let mouth = makeMouth(headRadius: cuteHeadRadius)
        mouth.position = CGPoint(x: 0, y: headCenterY - cuteHeadRadius * 0.24)
        mouth.zPosition = 22
        popIn(mouth, after: 1.1)
        addChild(mouth)

        let scarf = makeScarf(radius: (shoulderRadius + cuteHeadRadius) / 2, color: variant.scarfColor)
        scarf.position = CGPoint(x: 0, y: shoulderCenterY + shoulderRadius * (1 - overlap) * 0.6)
        popIn(scarf, after: 1.26)
        addChild(scarf)

        if let hat = makeHat(headRadius: cuteHeadRadius, style: variant.hat) {
            hat.position = CGPoint(x: 0, y: headCenterY + cuteHeadRadius * 0.85)
            popIn(hat, after: 1.42)
            addChild(hat)
        }

        run(.sequence([.wait(forDuration: 1.7), .run { [weak self] in self?.startIdleAnimations() }]))
    }

    // MARK: - Pixel-sculpture assembly (feature: pixel-art snowman kinds)

    /// Single-body assembly path for every `kind != .classic`: when a
    /// generated snow-sculpture sprite shipped for `kind` (see
    /// `sculptureTexture(for:)`), builds the body from that; otherwise
    /// falls back to rendering `kind`'s grid through `PixelSculpt` into one
    /// cached texture (older bundles without the generated art). Either
    /// way the body is sized to a "3-tier-equivalent" height derived from
    /// whichever ball radii fed this spawn (works whether this came from a
    /// 3-ball stack, a 2-ball "이대로 눈사람 완성", or 영서's build), and pops
    /// it in — a cheap "staged" feel (per-part stagger without a second
    /// texture render) comes from the sprite's own bounce-in plus a small
    /// twinkle that pops in a beat later near the top.
    private func assembleSculpture(kind: SnowmanKind, colorway: SnowmanColorway, baseRadius: CGFloat, torsoRadius: CGFloat?, headRadius: CGFloat) {
        // No real torso ball for a 2-ball completion — approximate one as
        // the base/head midpoint so the size formula still has 3 terms to
        // work with, same shape as a real 3-ball spawn.
        let effectiveTorso = torsoRadius ?? (baseRadius + headRadius) / 2
        let totalHeight = (baseRadius + effectiveTorso + headRadius) * Self.sculptureHeightScale

        let sprite: SKSpriteNode
        if let generatedTexture = Self.sculptureTexture(for: kind) {
            let nativeSize = generatedTexture.size()
            let aspect = nativeSize.height > 0 ? nativeSize.width / nativeSize.height : 1
            sprite = SKSpriteNode(texture: generatedTexture)
            sprite.size = CGSize(width: totalHeight * aspect, height: totalHeight)
            // Colorway applied as a SUBTLE tint rather than the grid path's
            // hard per-pixel palette swap below — these sprites already
            // carry their own full rendering, so a strong tint would fight
            // it. snowWhite stays untinted: it IS the sprite's own native
            // coloring already.
            sprite.color = colorway.accent
            sprite.colorBlendFactor = colorway == .snowWhite ? 0 : 0.14
        } else {
            guard let sculpture = PixelSculptures.library[kind] else { return }
            let palette = sculpture.palette(colorway)
            let texture = PixelSculpt.texture(cacheKey: "\(kind)-\(colorway)", grid: sculpture.grid, palette: palette)
            let aspect = PixelSculpt.aspectRatio(of: sculpture.grid)
            sprite = SKSpriteNode(texture: texture)
            sprite.size = CGSize(width: totalHeight * aspect, height: totalHeight)
        }
        // Anchored at bottom-center so the sculpture's feet sit exactly at
        // `basePoint` (this node's position) — the same ground-contact
        // convention SweeperCharacter's sprite uses.
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.position = .zero
        addChild(sprite)
        // Reused for the idle breathe pulse — see `startIdleAnimations`.
        torsoNode = sprite

        popIn(sprite, after: 0.05)
        let twinkle = makeTwinkle(sizeHint: totalHeight)
        twinkle.position = CGPoint(x: sprite.size.width * 0.28, y: totalHeight * 0.88)
        twinkle.zPosition = 30
        addChild(twinkle)
        twinkle.alpha = 0
        twinkle.run(.sequence([
            .wait(forDuration: 0.4),
            .fadeIn(withDuration: 0.1),
            .wait(forDuration: 0.3),
            .fadeOut(withDuration: 0.35),
            .removeFromParent()
        ]))

        run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.startIdleAnimations() }]))
    }

    // MARK: - Generated snow-sculpture sprite loading (feature: AI snow-
    // sculpture art)

    /// Loaded once and cached for the process's lifetime — mirrors
    /// `SweeperCharacter`'s own texture cache.
    private static var sculptureTextureCache: [SnowmanKind: SKTexture] = [:]

    /// Name SwiftPM generates for this target's resource bundle — see
    /// `SweeperCharacter.resourceBundleName`'s doc for why the
    /// packaged-app fallback below is needed.
    private static let resourceBundleName = "SnowMac_SnowMac.bundle"

    private static func sculptureFrameURL(named name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources/snowmen") {
            return url
        }
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourcesURL
            .appendingPathComponent(resourceBundleName)
            .appendingPathComponent("Resources/snowmen")
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The generated sprite for `kind`, if its PNG shipped in this bundle —
    /// nil for `.classic` (no file exists for it) and for any kind whose
    /// asset is missing (older bundle), in which case `assembleSculpture`
    /// falls back to the `PixelSculpt` grid texture.
    private static func sculptureTexture(for kind: SnowmanKind) -> SKTexture? {
        if let cached = sculptureTextureCache[kind] { return cached }
        guard
            let url = sculptureFrameURL(named: String(describing: kind)),
            let image = NSImage(contentsOf: url)
        else { return nil }
        let texture = SKTexture(image: image)
        // These are soft, high-res generated sprites — not PixelSculpt's
        // nearest-filter pixel grids — so linear sampling is correct here.
        texture.filteringMode = .linear
        sculptureTextureCache[kind] = texture
        return texture
    }

    /// A tiny 4-point sparkle — the cheap "second part" of a sculpture's
    /// staged pop-in. No texture, just a couple of crossed strokes, so it
    /// costs nothing beyond one extra shape node that removes itself.
    private func makeTwinkle(sizeHint: CGFloat) -> SKShapeNode {
        let r = max(2.5, sizeHint * 0.05)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -r, y: 0))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.move(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: 0, y: r))
        let star = SKShapeNode(path: path)
        star.strokeColor = SKColor(calibratedWhite: 1.0, alpha: 0.95)
        star.lineWidth = max(1, r * 0.3)
        star.lineCap = .round
        return star
    }

    private func makeArm(length: CGFloat, flip: Bool) -> SKShapeNode {
        let dir: CGFloat = flip ? -1 : 1
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: dir * length, y: length * 0.25))
        path.move(to: CGPoint(x: dir * length * 0.62, y: length * 0.1))
        path.addLine(to: CGPoint(x: dir * length * 0.85, y: length * 0.42))
        path.move(to: CGPoint(x: dir * length * 0.78, y: length * 0.12))
        path.addLine(to: CGPoint(x: dir * length * 1.02, y: length * 0.0))
        let arm = SKShapeNode(path: path)
        arm.strokeColor = SKColor(calibratedRed: 0.4, green: 0.26, blue: 0.14, alpha: 1)
        arm.lineWidth = 4.2
        arm.lineCap = .round
        return arm
    }

    /// Big, round, glossy eyes — the single biggest lever for "cute" vs
    /// "creepy" at this scale. Each eye is a tall ink-colored oval with a
    /// white specular highlight dot offset to the upper-right (reads as a
    /// shiny toy-plastic bead rather than a beady dot), spaced close
    /// together and sat low on the face for baby-like proportions.
    private func makeEyes(headRadius: CGFloat) -> SKNode {
        let container = SKNode()
        let spacing = headRadius * 0.3
        let eyeWidth = headRadius * 0.26
        let eyeHeight = headRadius * 0.34
        let closedLineHeight = max(1.8, headRadius * 0.09)

        func glossyEye(scale: CGFloat = 1) -> SKNode {
            let eye = SKNode()
            let pupil = SKShapeNode(ellipseOf: CGSize(width: eyeWidth * scale, height: eyeHeight * scale))
            pupil.fillColor = Self.faceInkColor
            pupil.strokeColor = .clear
            eye.addChild(pupil)
            let highlight = SKShapeNode(circleOfRadius: eyeWidth * 0.22 * scale)
            highlight.fillColor = .white
            highlight.strokeColor = .clear
            highlight.alpha = 0.9
            highlight.position = CGPoint(x: eyeWidth * 0.22 * scale, y: eyeHeight * 0.22 * scale)
            eye.addChild(highlight)
            return eye
        }

        // A soft downward-curved closed-eye line (a tiny smiling "⌣")
        // instead of a flat dash — reads as sleepy/content, never injured.
        func closedLashLine() -> SKNode {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -eyeWidth * 0.5, y: closedLineHeight * 0.4))
            path.addQuadCurve(to: CGPoint(x: eyeWidth * 0.5, y: closedLineHeight * 0.4), control: CGPoint(x: 0, y: -closedLineHeight * 1.4))
            let line = SKShapeNode(path: path)
            line.strokeColor = Self.faceInkColor
            line.lineWidth = closedLineHeight
            line.lineCap = .round
            return line
        }

        for side: CGFloat in [-1, 1] {
            let eye: SKNode
            switch variant.face {
            case .sleepy:
                eye = closedLashLine()
            case .wink:
                eye = side > 0 ? closedLashLine() : glossyEye()
            case .surprised:
                eye = glossyEye(scale: 1.15)
            case .grumpy:
                // Pouty, not angry: slightly narrowed glossy eyes with no
                // brows — the pout lives entirely in the mouth shape.
                eye = glossyEye(scale: 0.88)
            case .happy:
                eye = glossyEye()
            }
            eye.position = CGPoint(x: side * spacing, y: 0)
            container.addChild(eye)
        }
        return container
    }

    /// Soft rosy blush on both cheeks — low-alpha so it tints rather than
    /// paints — applied to every variant regardless of expression. This is
    /// the cheapest, highest-impact cuteness cue in the whole face.
    private func makeCheeks(headRadius: CGFloat) -> SKNode {
        let container = SKNode()
        let radius = headRadius * 0.22
        let spacing = headRadius * 0.62
        for side: CGFloat in [-1, 1] {
            let blush = SKShapeNode(circleOfRadius: radius)
            blush.fillColor = SKColor(calibratedRed: 1.0, green: 0.55, blue: 0.55, alpha: 0.35)
            blush.strokeColor = .clear
            blush.position = CGPoint(x: side * spacing, y: 0)
            container.addChild(blush)
        }
        return container
    }

    /// Stubby baby-carrot: a short, rounded-tip wedge instead of the long
    /// sharp spike a realistic carrot nose would be — spikes read as
    /// witchy/scary at this face scale, not charming.
    private func makeNose(headRadius: CGFloat) -> SKNode {
        let length = headRadius * 0.5
        let halfWidth = length * 0.34
        let tipRadius = halfWidth * 0.55
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: halfWidth))
        path.addLine(to: CGPoint(x: length - tipRadius, y: tipRadius * 0.5))
        path.addQuadCurve(
            to: CGPoint(x: length - tipRadius, y: -tipRadius * 0.5),
            control: CGPoint(x: length + tipRadius * 0.4, y: 0)
        )
        path.addLine(to: CGPoint(x: 0, y: -halfWidth))
        path.closeSubpath()
        let nose = SKShapeNode(path: path)
        nose.fillColor = SKColor(calibratedRed: 1.0, green: 0.52, blue: 0.16, alpha: 1)
        nose.strokeColor = SKColor(calibratedRed: 0.75, green: 0.34, blue: 0.08, alpha: 1)
        nose.lineWidth = max(0.6, headRadius * 0.04)
        nose.lineJoin = .round
        nose.zRotation = -0.12
        return nose
    }

    /// Mouth/expression, drawn per-variant so all 5 faces are readable at a
    /// glance: a small smile/smirk curve, a tiny pout, a small open "o", or
    /// a flat resting line — kept small and thin-stroked (per the cuteness
    /// pass) so the face stays "soft toy" rather than "jack-o'-lantern".
    private func makeMouth(headRadius: CGFloat) -> SKNode {
        let strokeColor = Self.faceInkColor
        let lineWidth = max(1.2, headRadius * 0.07)
        let width = headRadius * 0.2
        let dip = headRadius * 0.13

        switch variant.face {
        case .happy:
            return smileShape(width: width, dip: dip, strokeColor: strokeColor, lineWidth: lineWidth)
        case .wink:
            return smileShape(width: width * 0.9, dip: dip * 0.85, strokeColor: strokeColor, lineWidth: lineWidth, asymmetric: true)
        case .grumpy:
            // A tiny soft pout rather than a deep frown — "pouty-cute", not
            // angry. Paired with the plain cheek blush above.
            return frownShape(width: width * 0.65, rise: dip * 0.55, strokeColor: strokeColor, lineWidth: lineWidth)
        case .surprised:
            let mouth = SKShapeNode(ellipseOf: CGSize(width: headRadius * 0.16, height: headRadius * 0.2))
            mouth.fillColor = strokeColor
            mouth.strokeColor = strokeColor
            mouth.lineWidth = lineWidth * 0.5
            return mouth
        case .sleepy:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -width * 0.6, y: 0))
            path.addLine(to: CGPoint(x: width * 0.6, y: 0))
            let mouth = SKShapeNode(path: path)
            mouth.strokeColor = strokeColor
            mouth.lineWidth = lineWidth
            mouth.lineCap = .round
            return mouth
        }
    }

    /// Smile/smirk: a "⌣" curve — corners above a dipped middle. `asymmetric`
    /// raises one corner more than the other for the wink variant's smirk.
    private func smileShape(width: CGFloat, dip: CGFloat, strokeColor: SKColor, lineWidth: CGFloat, asymmetric: Bool = false) -> SKShapeNode {
        let path = CGMutablePath()
        let leftY: CGFloat = asymmetric ? dip * 0.2 : dip * 0.5
        let rightY: CGFloat = asymmetric ? dip * 0.9 : dip * 0.5
        path.move(to: CGPoint(x: -width, y: leftY))
        path.addQuadCurve(to: CGPoint(x: width, y: rightY), control: CGPoint(x: 0, y: -dip))
        let mouth = SKShapeNode(path: path)
        mouth.strokeColor = strokeColor
        mouth.lineWidth = lineWidth
        mouth.lineCap = .round
        return mouth
    }

    /// Pout/frown: a "⌢" curve — corners below a raised middle.
    private func frownShape(width: CGFloat, rise: CGFloat, strokeColor: SKColor, lineWidth: CGFloat) -> SKShapeNode {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -width, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: 0, y: rise))
        let mouth = SKShapeNode(path: path)
        mouth.strokeColor = strokeColor
        mouth.lineWidth = lineWidth
        mouth.lineCap = .round
        return mouth
    }

    private func makeScarf(radius: CGFloat, color: SKColor) -> SKNode {
        let container = SKNode()
        let strokeColor = color.blended(withFraction: 0.3, of: .black) ?? color
        let band = SKShapeNode(rectOf: CGSize(width: radius * 2.1, height: radius * 0.6), cornerRadius: radius * 0.2)
        band.fillColor = color
        band.strokeColor = strokeColor
        band.lineWidth = 1
        container.addChild(band)

        let tail = SKShapeNode(rectOf: CGSize(width: radius * 0.45, height: radius * 1.3), cornerRadius: radius * 0.15)
        tail.fillColor = color
        tail.strokeColor = strokeColor
        tail.position = CGPoint(x: radius * 0.5, y: -radius * 0.9)
        tail.zRotation = -0.15
        container.addChild(tail)
        return container
    }

    /// Hat shapes, sized a touch oversized/floppy for charm and in a softer
    /// palette than a literal Santa-red/forest-green toy would use — warm
    /// pastels paired per variant so all 5 silhouettes stay distinct.
    private func makeHat(headRadius: CGFloat, style: HatStyle) -> SKNode? {
        switch style {
        case .none:
            return nil
        case .topHat:
            let container = SKNode()
            let brim = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.75, height: headRadius * 0.36))
            brim.fillColor = SKColor(white: 0.14, alpha: 1)
            brim.strokeColor = .clear
            container.addChild(brim)
            let top = SKShapeNode(rectOf: CGSize(width: headRadius * 1.15, height: headRadius * 1.2), cornerRadius: headRadius * 0.12)
            top.fillColor = SKColor(white: 0.14, alpha: 1)
            top.strokeColor = .clear
            top.position = CGPoint(x: 0, y: headRadius * 0.58)
            container.addChild(top)
            // A thin band in the snowman's own scarf color ties the hat and
            // scarf together as one outfit.
            let band = SKShapeNode(rectOf: CGSize(width: headRadius * 1.18, height: headRadius * 0.17), cornerRadius: headRadius * 0.06)
            band.fillColor = variant.scarfColor
            band.strokeColor = .clear
            band.position = CGPoint(x: 0, y: headRadius * 0.08)
            container.addChild(band)
            return container
        case .santa:
            let container = SKNode()
            let cone = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.65, height: headRadius * 1.0))
            cone.fillColor = SKColor(calibratedRed: 0.82, green: 0.3, blue: 0.28, alpha: 1)
            cone.strokeColor = .clear
            cone.position = CGPoint(x: headRadius * 0.15, y: headRadius * 0.28)
            cone.zRotation = -0.3
            container.addChild(cone)
            let trim = SKShapeNode(rectOf: CGSize(width: headRadius * 1.7, height: headRadius * 0.32), cornerRadius: headRadius * 0.16)
            trim.fillColor = SKColor(calibratedRed: 0.98, green: 0.95, blue: 0.9, alpha: 1)
            trim.strokeColor = .clear
            container.addChild(trim)
            let pom = SKShapeNode(circleOfRadius: headRadius * 0.22)
            pom.fillColor = SKColor(calibratedRed: 0.98, green: 0.95, blue: 0.9, alpha: 1)
            pom.strokeColor = .clear
            pom.position = CGPoint(x: headRadius * 0.9, y: headRadius * 0.72)
            container.addChild(pom)
            return container
        case .beanie:
            let container = SKNode()
            let dome = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.6, height: headRadius * 1.0))
            dome.fillColor = SKColor(calibratedRed: 0.52, green: 0.8, blue: 0.68, alpha: 1)
            dome.strokeColor = .clear
            dome.position = CGPoint(x: 0, y: headRadius * 0.22)
            container.addChild(dome)
            let brim = SKShapeNode(rectOf: CGSize(width: headRadius * 1.7, height: headRadius * 0.27), cornerRadius: headRadius * 0.12)
            brim.fillColor = SKColor(calibratedRed: 0.4, green: 0.65, blue: 0.55, alpha: 1)
            brim.strokeColor = .clear
            container.addChild(brim)
            let pom = SKShapeNode(circleOfRadius: headRadius * 0.17)
            pom.fillColor = SKColor(calibratedRed: 0.98, green: 0.95, blue: 0.9, alpha: 1)
            pom.strokeColor = .clear
            pom.position = CGPoint(x: 0, y: headRadius * 0.78)
            container.addChild(pom)
            return container
        case .earmuffs:
            let container = SKNode()
            let band = SKShapeNode(rectOf: CGSize(width: headRadius * 1.55, height: headRadius * 0.16), cornerRadius: headRadius * 0.08)
            band.fillColor = SKColor(calibratedRed: 0.74, green: 0.6, blue: 0.82, alpha: 1)
            band.strokeColor = .clear
            band.position = CGPoint(x: 0, y: headRadius * 0.55)
            container.addChild(band)
            for side: CGFloat in [-1, 1] {
                let muff = SKShapeNode(circleOfRadius: headRadius * 0.3)
                muff.fillColor = SKColor(calibratedRed: 0.74, green: 0.6, blue: 0.82, alpha: 1)
                muff.strokeColor = .clear
                muff.position = CGPoint(x: side * headRadius * 0.98, y: headRadius * 0.1)
                container.addChild(muff)
            }
            return container
        }
    }

    // MARK: - Idle animations

    private func startIdleAnimations() {
        guard !idleStarted else { return }
        idleStarted = true

        if let torso = torsoNode {
            let breathe = SKAction.sequence([
                .scaleY(to: 1.05, duration: 1.4),
                .scaleY(to: 1.0, duration: 1.4)
            ])
            breathe.timingMode = .easeInEaseOut
            torso.run(.repeatForever(breathe), withKey: "breathe")
        }

        scheduleArmWave()
        scheduleDance()
    }

    /// Reads each arm's CURRENT zRotation as `base` at wave-time (never a
    /// hardcoded constant) and only ever applies small relative deltas
    /// (+0.3/-0.15 rad) before returning to that same `base` — so this
    /// composes correctly for either `ArmPose` without modification: the
    /// deltas are small enough that `rotate(toAngle:)`'s shortest-arc path
    /// never wraps oddly regardless of whether `base` is `.raisedCozy`'s
    /// ±0.85 or `.spreadWide`'s ±2.63, and the arm always settles back to
    /// its own pose's base rotation, never snapping to a different one.
    private func scheduleArmWave() {
        let wait = SKAction.wait(forDuration: Double.random(in: 4...9))
        let wave = SKAction.run { [weak self] in
            guard let self, let arm = [self.armLeft, self.armRight].randomElement(), let arm else { return }
            let base = arm.zRotation
            arm.run(.sequence([
                .rotate(toAngle: base + 0.3, duration: 0.2),
                .rotate(toAngle: base - 0.15, duration: 0.2),
                .rotate(toAngle: base, duration: 0.2)
            ]))
        }
        run(.sequence([wait, wave, .run { [weak self] in self?.scheduleArmWave() }]))
    }

    private func scheduleDance() {
        let wait = SKAction.wait(forDuration: Double.random(in: 20...45))
        let dance = SKAction.run { [weak self] in
            guard let self else { return }
            let hop = SKAction.sequence([
                .moveBy(x: 0, y: 10, duration: 0.15),
                .moveBy(x: 0, y: -10, duration: 0.15)
            ])
            let wiggle = SKAction.sequence([
                .rotate(byAngle: 0.15, duration: 0.1),
                .rotate(byAngle: -0.3, duration: 0.2),
                .rotate(byAngle: 0.15, duration: 0.1)
            ])
            self.run(.sequence([.repeat(hop, count: 2), wiggle]))
        }
        run(.sequence([wait, dance, .run { [weak self] in self?.scheduleDance() }]))
    }
}
