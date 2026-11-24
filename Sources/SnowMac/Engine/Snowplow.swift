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
        onTick: ((CGFloat) -> Void)? = nil,
        onFinish: @escaping () -> Void
    ) {
        let truck = makeTruckNode()
        // Overall visual size knob. SKShapeNode scales as vectors, so this
        // is lossless; wheelClearance below must scale with it (the wheel
        // art's local y=-8 offset becomes -8 * truckScale on screen).
        let truckScale: CGFloat = 1.6
        truck.setScale(truckScale)
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
        let wheelClearance: CGFloat = 8 * truckScale
        truck.position = CGPoint(x: startX, y: accumulator.topY(of: state, atX: startX) + wheelClearance)
        truck.zPosition = 30
        parent.addChild(truck)

        // Soft exhaust puffs — tiny gray circles spawned periodically at
        // the truck's current world position (behind the cab), left to
        // drift up and fade on their own. Spawned here rather than inside
        // makeTruckNode() because they need world-space positions that
        // keep trailing behind as the truck keeps driving, not a position
        // frozen relative to the truck's own local space.
        let exhaustLoop = SKAction.repeatForever(.sequence([
            .wait(forDuration: 0.4, withRange: 0.35),
            .run { [weak truck] in
                guard let truck else { return }
                spawnExhaustPuff(in: parent, at: CGPoint(x: truck.position.x - 20, y: truck.position.y + 3))
            }
        ]))
        truck.run(exhaustLoop)

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
            // Reports live x so a caller chaining multiple surfaces (feature
            // update: 제설차 now clears sequentially) can also detect this
            // plow passing 영서 on the same surface.
            onTick?(x)
        }

        let despawn = SKAction.run { [weak truck] in
            truck?.removeFromParent()
            onFinish()
        }

        truck.run(.sequence([drive, despawn]))
    }

    // MARK: - Art

    /// Builds the plow truck's node graph — purely declarative, no `parent`
    /// captured, so it stays reusable regardless of where `summon()` ends
    /// up parenting it. The truck always drives in +x (left-to-right, per
    /// `summon()`'s startX < endX), so "front" below means the +x side.
    ///
    /// Wheel centers MUST stay at local y=-8: `summon()`'s `wheelClearance`
    /// rides the truck at `topY + 8` specifically so these sit right on the
    /// snow line (see the comment there) — moving them would desync the
    /// ride height from the art.
    private static func makeTruckNode() -> SKNode {
        let root = SKNode()

        // Wheels — dark tire + lighter hub, 3 across the chassis. Drawn
        // BEHIND the body (zPosition 1/2 vs. body's 3) so the body's
        // bottom edge crops their top halves — reads as wheel arches
        // without needing separate arch shapes.
        for dx: CGFloat in [-15, 1, 17] {
            let tire = SKShapeNode(circleOfRadius: 4.5)
            tire.fillColor = SKColor(white: 0.07, alpha: 1)
            tire.strokeColor = .clear
            tire.position = CGPoint(x: dx, y: -8)
            tire.zPosition = 1
            root.addChild(tire)

            let hub = SKShapeNode(circleOfRadius: 1.7)
            hub.fillColor = SKColor(white: 0.6, alpha: 1)
            hub.strokeColor = .clear
            hub.position = tire.position
            hub.zPosition = 2
            root.addChild(hub)
        }

        // Body / bed — the main orange chassis the cab and wheels attach to.
        let body = SKShapeNode(rectOf: CGSize(width: 36, height: 11), cornerRadius: 3)
        body.fillColor = SKColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1)
        body.strokeColor = SKColor(red: 0.55, green: 0.26, blue: 0.0, alpha: 1)
        body.lineWidth = 1.5
        body.position = CGPoint(x: -3, y: 0)
        body.zPosition = 3
        root.addChild(body)

        // Cab, toward the front (+x) — windshield is a slight trapezoid
        // (narrower at the top), leaning back like a real cab, with an
        // inset lighter-blue "glass" fill.
        let cab = SKShapeNode(rectOf: CGSize(width: 14, height: 8), cornerRadius: 2)
        cab.fillColor = SKColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1)
        cab.strokeColor = SKColor(red: 0.55, green: 0.26, blue: 0.0, alpha: 1)
        cab.lineWidth = 1.5
        cab.position = CGPoint(x: 6, y: 8)
        cab.zPosition = 3
        root.addChild(cab)

        let windshieldPath = CGMutablePath()
        windshieldPath.move(to: CGPoint(x: -5, y: -3))
        windshieldPath.addLine(to: CGPoint(x: 5, y: -3))
        windshieldPath.addLine(to: CGPoint(x: 3.5, y: 3))
        windshieldPath.addLine(to: CGPoint(x: -3.5, y: 3))
        windshieldPath.closeSubpath()
        let windshield = SKShapeNode(path: windshieldPath)
        windshield.fillColor = SKColor(red: 0.6, green: 0.85, blue: 0.95, alpha: 0.9)
        windshield.strokeColor = SKColor(white: 0.3, alpha: 0.8)
        windshield.lineWidth = 0.75
        windshield.position = CGPoint(x: 6, y: 8.5)
        windshield.zPosition = 4
        root.addChild(windshield)

        // Headlight, at the front of the body near the blade mount.
        let headlight = SKShapeNode(circleOfRadius: 1.4)
        headlight.fillColor = SKColor(red: 1, green: 0.95, blue: 0.6, alpha: 1)
        headlight.strokeColor = .clear
        headlight.position = CGPoint(x: 14, y: -1.5)
        headlight.zPosition = 4
        root.addChild(headlight)

        // Plow blade — angled at the front (+x, the leading edge for the
        // left-to-right drive), with a slight curl at the top lip and a
        // visibly darker scraping edge along the bottom.
        let bladePath = CGMutablePath()
        bladePath.move(to: CGPoint(x: 9, y: -10))
        bladePath.addLine(to: CGPoint(x: 21, y: -9))
        bladePath.addLine(to: CGPoint(x: 23, y: 2))
        bladePath.addQuadCurve(to: CGPoint(x: 15, y: 7.5), control: CGPoint(x: 21, y: 6.5))
        bladePath.addLine(to: CGPoint(x: 8, y: 2))
        bladePath.closeSubpath()
        let blade = SKShapeNode(path: bladePath)
        blade.fillColor = SKColor(white: 0.82, alpha: 1)
        blade.strokeColor = SKColor(white: 0.45, alpha: 1)
        blade.lineWidth = 1.25
        blade.zPosition = 5
        root.addChild(blade)

        let scrapeEdgePath = CGMutablePath()
        scrapeEdgePath.move(to: CGPoint(x: 9, y: -10))
        scrapeEdgePath.addLine(to: CGPoint(x: 21, y: -9))
        scrapeEdgePath.addLine(to: CGPoint(x: 21, y: -7.3))
        scrapeEdgePath.addLine(to: CGPoint(x: 9, y: -8.3))
        scrapeEdgePath.closeSubpath()
        let scrapeEdge = SKShapeNode(path: scrapeEdgePath)
        scrapeEdge.fillColor = SKColor(white: 0.35, alpha: 1)
        scrapeEdge.strokeColor = .clear
        scrapeEdge.zPosition = 6
        root.addChild(scrapeEdge)

        // Warning beacon — small amber dome on the roof, blinking.
        let beacon = SKShapeNode(circleOfRadius: 2)
        beacon.fillColor = SKColor(red: 1.0, green: 0.7, blue: 0.1, alpha: 1)
        beacon.strokeColor = .clear
        beacon.position = CGPoint(x: 5, y: 13.5)
        beacon.zPosition = 7
        beacon.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.3, duration: 0.45),
            .fadeAlpha(to: 1.0, duration: 0.45)
        ])))
        root.addChild(beacon)

        // 산타모자 charm — kept, perched on the cab roof beside the beacon.
        let santaHatBody = SKShapeNode()
        let hatPath = CGMutablePath()
        hatPath.move(to: CGPoint(x: -3.5, y: 0))
        hatPath.addLine(to: CGPoint(x: 3.5, y: 0))
        hatPath.addLine(to: CGPoint(x: 1, y: 7.5))
        hatPath.closeSubpath()
        santaHatBody.path = hatPath
        santaHatBody.fillColor = SKColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        santaHatBody.strokeColor = .clear
        santaHatBody.position = CGPoint(x: -1, y: 12)
        santaHatBody.zPosition = 7
        root.addChild(santaHatBody)

        let pom = SKShapeNode(circleOfRadius: 1.3)
        pom.fillColor = .white
        pom.strokeColor = .clear
        pom.position = CGPoint(x: -0.3, y: 19.4)
        pom.zPosition = 7
        root.addChild(pom)

        return root
    }

    /// Tiny gray circle spawned at `point` (a snapshot of the truck's
    /// current world position, taken by the caller) that drifts up and
    /// fades — reused every ~0.4-0.75s while the plow drives (see the
    /// `exhaustLoop` action in `summon()`).
    private static func spawnExhaustPuff(in parent: SKNode, at point: CGPoint) {
        let puff = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.6...2.4))
        puff.fillColor = SKColor(white: 0.75, alpha: 0.55)
        puff.strokeColor = .clear
        puff.position = point
        puff.zPosition = 29
        parent.addChild(puff)

        let drift = SKAction.moveBy(x: CGFloat.random(in: -3...3), y: CGFloat.random(in: 10...16), duration: 0.8)
        let grow = SKAction.scale(to: 1.6, duration: 0.8)
        let fade = SKAction.fadeOut(withDuration: 0.8)
        puff.run(.sequence([.group([drift, grow, fade]), .removeFromParent()]))
    }
}
