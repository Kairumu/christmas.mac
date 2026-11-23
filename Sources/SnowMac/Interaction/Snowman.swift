import SpriteKit

/// A fully assembled snowman: base, torso, head, arms, eyes, nose, scarf, and an
/// optional hat, each appearing one-by-one with a pop-in animation (feature 06).
/// Once assembled it loops idle animations (feature 07): breathing, occasional arm
/// wave, and a rare little dance.
final class Snowman: SKNode {
    let variant: SnowmanVariant
    let hitRadius: CGFloat

    private var torsoNode: SKNode?
    private var armLeft: SKShapeNode?
    private var armRight: SKShapeNode?
    private var idleStarted = false

    init(basePoint: CGPoint, variant: SnowmanVariant, baseRadius: CGFloat, torsoRadius: CGFloat, headRadius: CGFloat) {
        self.variant = variant
        self.hitRadius = max(baseRadius, torsoRadius, headRadius) * 1.6 + headRadius
        super.init()
        position = basePoint
        name = "snowman"
        zPosition = 100
        assemble(baseRadius: baseRadius, torsoRadius: torsoRadius, headRadius: headRadius)
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

    private func assemble(baseRadius: CGFloat, torsoRadius: CGFloat, headRadius: CGFloat) {
        let overlap: CGFloat = 0.3
        let baseCenterY = baseRadius
        let torsoCenterY = baseCenterY + baseRadius * (1 - overlap) + torsoRadius * (1 - overlap)
        let headCenterY = torsoCenterY + torsoRadius * (1 - overlap) + headRadius * (1 - overlap)

        let base = ballShape(radius: baseRadius)
        base.position = CGPoint(x: 0, y: baseCenterY)
        addChild(base)

        let torso = ballShape(radius: torsoRadius)
        torso.position = CGPoint(x: 0, y: torsoCenterY)
        popIn(torso, after: 0.12)
        addChild(torso)
        torsoNode = torso

        let head = ballShape(radius: headRadius)
        head.position = CGPoint(x: 0, y: headCenterY)
        popIn(head, after: 0.28)
        addChild(head)

        let armLength = torsoRadius * 1.6
        let leftArm = makeArm(length: armLength, flip: false)
        leftArm.position = CGPoint(x: -torsoRadius * 0.8, y: torsoCenterY + torsoRadius * 0.1)
        leftArm.zRotation = 0.5
        popIn(leftArm, after: 0.46)
        addChild(leftArm)
        armLeft = leftArm

        let rightArm = makeArm(length: armLength, flip: true)
        rightArm.position = CGPoint(x: torsoRadius * 0.8, y: torsoCenterY + torsoRadius * 0.1)
        rightArm.zRotation = -0.5
        popIn(rightArm, after: 0.6)
        addChild(rightArm)
        armRight = rightArm

        let eyes = makeEyes(headRadius: headRadius)
        eyes.position = CGPoint(x: 0, y: headCenterY + headRadius * 0.15)
        popIn(eyes, after: 0.78)
        addChild(eyes)

        let nose = makeNose(headRadius: headRadius)
        nose.position = CGPoint(x: 0, y: headCenterY)
        popIn(nose, after: 0.94)
        addChild(nose)

        let scarf = makeScarf(radius: (torsoRadius + headRadius) / 2, color: variant.scarfColor)
        scarf.position = CGPoint(x: 0, y: torsoCenterY + torsoRadius * (1 - overlap) * 0.6)
        popIn(scarf, after: 1.1)
        addChild(scarf)

        if let hat = makeHat(headRadius: headRadius, style: variant.hat) {
            hat.position = CGPoint(x: 0, y: headCenterY + headRadius * 0.85)
            popIn(hat, after: 1.26)
            addChild(hat)
        }

        run(.sequence([.wait(forDuration: 1.5), .run { [weak self] in self?.startIdleAnimations() }]))
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
        arm.strokeColor = SKColor(calibratedRed: 0.35, green: 0.22, blue: 0.1, alpha: 1)
        arm.lineWidth = 3
        arm.lineCap = .round
        return arm
    }

    private func makeEyes(headRadius: CGFloat) -> SKNode {
        let container = SKNode()
        let spacing = headRadius * 0.4
        for side: CGFloat in [-1, 1] {
            if (variant.face == .wink && side > 0) || variant.face == .sleepy {
                let line = SKShapeNode(rectOf: CGSize(width: headRadius * 0.22, height: 2), cornerRadius: 1)
                line.fillColor = .black
                line.strokeColor = .clear
                line.position = CGPoint(x: side * spacing, y: 0)
                container.addChild(line)
                continue
            }
            let eyeRadius: CGFloat = variant.face == .surprised ? headRadius * 0.14 : headRadius * 0.1
            let eye = SKShapeNode(circleOfRadius: eyeRadius)
            eye.fillColor = .black
            eye.strokeColor = .clear
            eye.position = CGPoint(x: side * spacing, y: 0)
            container.addChild(eye)
        }
        if variant.face == .grumpy {
            for side: CGFloat in [-1, 1] {
                let brow = SKShapeNode(rectOf: CGSize(width: headRadius * 0.3, height: 2), cornerRadius: 1)
                brow.fillColor = .black
                brow.strokeColor = .clear
                brow.position = CGPoint(x: side * spacing, y: headRadius * 0.18)
                brow.zRotation = side * 0.35
                container.addChild(brow)
            }
        }
        return container
    }

    private func makeNose(headRadius: CGFloat) -> SKNode {
        let length = headRadius * 0.9
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: length * 0.15))
        path.addLine(to: CGPoint(x: length, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -length * 0.15))
        path.closeSubpath()
        let nose = SKShapeNode(path: path)
        nose.fillColor = SKColor(calibratedRed: 0.95, green: 0.45, blue: 0.1, alpha: 1)
        nose.strokeColor = SKColor(calibratedRed: 0.7, green: 0.3, blue: 0.05, alpha: 1)
        nose.lineWidth = 0.5
        return nose
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

    private func makeHat(headRadius: CGFloat, style: HatStyle) -> SKNode? {
        switch style {
        case .none:
            return nil
        case .topHat:
            let container = SKNode()
            let brim = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.6, height: headRadius * 0.35))
            brim.fillColor = .black
            brim.strokeColor = .clear
            container.addChild(brim)
            let top = SKShapeNode(rectOf: CGSize(width: headRadius * 1.1, height: headRadius * 1.1), cornerRadius: 2)
            top.fillColor = .black
            top.strokeColor = .clear
            top.position = CGPoint(x: 0, y: headRadius * 0.55)
            container.addChild(top)
            return container
        case .santa:
            let container = SKNode()
            let cone = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.5, height: headRadius * 0.9))
            cone.fillColor = SKColor(calibratedRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
            cone.strokeColor = .clear
            cone.position = CGPoint(x: headRadius * 0.15, y: headRadius * 0.25)
            cone.zRotation = -0.3
            container.addChild(cone)
            let trim = SKShapeNode(rectOf: CGSize(width: headRadius * 1.6, height: headRadius * 0.3), cornerRadius: headRadius * 0.15)
            trim.fillColor = .white
            trim.strokeColor = .clear
            container.addChild(trim)
            let pom = SKShapeNode(circleOfRadius: headRadius * 0.2)
            pom.fillColor = .white
            pom.strokeColor = .clear
            pom.position = CGPoint(x: headRadius * 0.85, y: headRadius * 0.65)
            container.addChild(pom)
            return container
        case .beanie:
            let container = SKNode()
            let dome = SKShapeNode(ellipseOf: CGSize(width: headRadius * 1.5, height: headRadius * 0.9))
            dome.fillColor = SKColor(calibratedRed: 0.15, green: 0.55, blue: 0.3, alpha: 1)
            dome.strokeColor = .clear
            dome.position = CGPoint(x: 0, y: headRadius * 0.2)
            container.addChild(dome)
            let brim = SKShapeNode(rectOf: CGSize(width: headRadius * 1.6, height: headRadius * 0.25), cornerRadius: headRadius * 0.1)
            brim.fillColor = SKColor(calibratedRed: 0.1, green: 0.4, blue: 0.2, alpha: 1)
            brim.strokeColor = .clear
            container.addChild(brim)
            return container
        case .earmuffs:
            let container = SKNode()
            let band = SKShapeNode(rectOf: CGSize(width: headRadius * 1.5, height: headRadius * 0.15), cornerRadius: headRadius * 0.07)
            band.fillColor = SKColor(calibratedRed: 0.4, green: 0.25, blue: 0.5, alpha: 1)
            band.strokeColor = .clear
            band.position = CGPoint(x: 0, y: headRadius * 0.55)
            container.addChild(band)
            for side: CGFloat in [-1, 1] {
                let muff = SKShapeNode(circleOfRadius: headRadius * 0.28)
                muff.fillColor = SKColor(calibratedRed: 0.4, green: 0.25, blue: 0.5, alpha: 1)
                muff.strokeColor = .clear
                muff.position = CGPoint(x: side * headRadius * 0.95, y: headRadius * 0.1)
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

    private func scheduleArmWave() {
        let wait = SKAction.wait(forDuration: Double.random(in: 4...9))
        let wave = SKAction.run { [weak self] in
            guard let self, let arm = [self.armLeft, self.armRight].randomElement(), let arm else { return }
            let base = arm.zRotation
            arm.run(.sequence([
                .rotate(toAngle: base + 0.4, duration: 0.2),
                .rotate(toAngle: base - 0.2, duration: 0.2),
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
