import SpriteKit

/// Builds and animates a programmatically-drawn snowplow truck that drives
/// across a surface, clearing accumulated snow as its blade passes.
enum Snowplow {
    /// Drives a plow across `state`'s surface (or screenBottom-style y),
    /// zeroing accumulation columns as the blade's x sweeps past. Calls
    /// `onFinish` after the plow despawns.
    static func summon(
        in parent: SKNode,
        accumulator: SnowAccumulator,
        target state: SnowAccumulator.SurfaceState,
        sceneWidth: CGFloat,
        onFinish: @escaping () -> Void
    ) {
        let truck = makeTruckNode()
        let startX = state.surface.minX - 60
        let endX = state.surface.maxX + 60
        // Ride along the TOP of the accumulated snow (surface baseline +
        // current column height at this x), not the fixed surface baseline.
        // Riding the baseline meant a plow working a snow-bottom pile (or
        // any tall pile) visually sank into/under the snow it was supposed
        // to be clearing, and for screenBottom specifically it sat exactly
        // at scene y=0 where the real macOS Dock (which renders above our
        // overlay) hides it entirely. `wheelClearance` matches the truck
        // art's own wheel offset (wheels are drawn at y=-8 relative to the
        // truck root in makeTruckNode(), see below) so the wheels visually
        // land right on the local snow top instead of floating above it.
        let wheelClearance: CGFloat = 8
        truck.position = CGPoint(x: startX, y: accumulator.topY(of: state, atX: startX) + wheelClearance)
        truck.zPosition = 30
        parent.addChild(truck)

        let distance = endX - startX
        let duration = max(Double(distance) / 260.0, 1.2)

        var lastX = startX
        let bladeHalfWidth: CGFloat = 26

        let drive = SKAction.customAction(withDuration: duration) { node, elapsed in
            // The target surface can be removed mid-drive (its window
            // closed while the plow was working it). Once gone, stop
            // reading/mutating its now-detached heights — freeze in place
            // and let the sequence's despawn step clean up on schedule,
            // rather than riding a stale, frozen profile forever.
            guard accumulator.states.contains(where: { $0 === state }) else { return }
            let t = CGFloat(elapsed / CGFloat(duration))
            let x = startX + t * distance
            // Read the ride height BEFORE this frame's clear so the truck
            // reflects the snow profile it's about to plow, not the ground
            // it just flattened.
            let rideY = accumulator.topY(of: state, atX: x) + wheelClearance
            node.position = CGPoint(x: x, y: rideY)
            if x > lastX {
                accumulator.clearRange(state, minX: lastX - bladeHalfWidth, maxX: x + bladeHalfWidth)
            }
            lastX = x
        }

        let despawn = SKAction.run { [weak truck] in
            truck?.removeFromParent()
            onFinish()
        }

        truck.run(.sequence([drive, despawn]))
    }

    // MARK: - Art

    private static func makeTruckNode() -> SKNode {
        let root = SKNode()

        // Wheels
        for dx: CGFloat in [-18, 14] {
            let wheel = SKShapeNode(circleOfRadius: 7)
            wheel.fillColor = .black
            wheel.strokeColor = .clear
            wheel.position = CGPoint(x: dx, y: -8)
            wheel.zPosition = 1
            root.addChild(wheel)
        }

        // Cab body (orange)
        let body = SKShapeNode(rectOf: CGSize(width: 44, height: 20), cornerRadius: 4)
        body.fillColor = SKColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1)
        body.strokeColor = SKColor(red: 0.6, green: 0.3, blue: 0.0, alpha: 1)
        body.lineWidth = 1.5
        body.position = CGPoint(x: 0, y: 0)
        body.zPosition = 2
        root.addChild(body)

        // Cab roof / cabin window
        let cabin = SKShapeNode(rectOf: CGSize(width: 18, height: 14), cornerRadius: 3)
        cabin.fillColor = SKColor(red: 0.6, green: 0.85, blue: 0.95, alpha: 0.9)
        cabin.strokeColor = SKColor(red: 0.6, green: 0.3, blue: 0.0, alpha: 1)
        cabin.lineWidth = 1
        cabin.position = CGPoint(x: 10, y: 12)
        cabin.zPosition = 3
        root.addChild(cabin)

        // 산타모자 red accent on the cab roof
        let santaHatBody = SKShapeNode()
        let hatPath = CGMutablePath()
        hatPath.move(to: CGPoint(x: -4, y: 0))
        hatPath.addLine(to: CGPoint(x: 4, y: 0))
        hatPath.addLine(to: CGPoint(x: 1, y: 9))
        hatPath.closeSubpath()
        santaHatBody.path = hatPath
        santaHatBody.fillColor = SKColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        santaHatBody.strokeColor = .clear
        santaHatBody.position = CGPoint(x: 10, y: 19)
        santaHatBody.zPosition = 4
        root.addChild(santaHatBody)

        let pom = SKShapeNode(circleOfRadius: 2)
        pom.fillColor = .white
        pom.strokeColor = .clear
        pom.position = CGPoint(x: 11, y: 28)
        pom.zPosition = 4
        root.addChild(pom)

        // Plow blade (angled, in front = left since truck moves left->right
        // and the blade pushes snow ahead of the direction of travel).
        let blade = SKShapeNode()
        let bladePath = CGMutablePath()
        bladePath.move(to: CGPoint(x: 0, y: -10))
        bladePath.addLine(to: CGPoint(x: -14, y: -10))
        bladePath.addLine(to: CGPoint(x: -20, y: 6))
        bladePath.addLine(to: CGPoint(x: -4, y: 10))
        bladePath.closeSubpath()
        blade.path = bladePath
        blade.fillColor = SKColor(white: 0.85, alpha: 1)
        blade.strokeColor = SKColor(white: 0.5, alpha: 1)
        blade.lineWidth = 1.5
        blade.position = CGPoint(x: -22, y: -2)
        blade.zPosition = 2
        root.addChild(blade)

        return root
    }
}
