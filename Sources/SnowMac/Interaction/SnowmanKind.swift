import SpriteKit

/// The 10 looks a completed snowman can take (feature: pixel-art snowman
/// kinds). `classic` is the original SKShapeNode-composed snowman (vector
/// balls + `SnowmanVariant`'s 5 hat/face combos) — every other case is a
/// single-body 8-bit pixel sculpture rendered by `PixelSculpt` from a grid
/// in `PixelSculptures.swift`.
enum SnowmanKind: CaseIterable {
    case classic
    case bunnyCat
    case forestSpirit
    case shades
    case penguin
    case snowDuck
    case bear
    case robot
    case mushroom
    case ghost

    /// `classic` carries all of `SnowmanVariant`'s hat/face variety, so it
    /// keeps the lion's share of spawns (~40%); the 9 pixel-sculpture kinds
    /// split the remaining ~60% evenly between them (~6.7% each).
    private var weight: Double {
        switch self {
        case .classic: return 40
        default: return 60.0 / 9.0
        }
    }

    /// True for every kind except `classic` — these are single-body final
    /// forms rendered by `PixelSculpt` instead of `Snowman.assemble`'s ball
    /// stack, and (per `Snowman.isTwoTier`) are never upgrade-matched by a
    /// loose ball the way a classic 2-tier snowman is.
    var isSculpture: Bool { self != .classic }

    /// Weighted pick used by every completion path (3-ball stack, the
    /// 2-ball "이대로 눈사람 완성" menu, 영서's build, and the fresh snowman a
    /// classic 2-tier→3-tier upgrade replaces) — see the weights above.
    static func random() -> SnowmanKind {
        let total = allCases.reduce(0) { $0 + $1.weight }
        var roll = Double.random(in: 0..<total)
        for kind in allCases {
            if roll < kind.weight { return kind }
            roll -= kind.weight
        }
        return .classic
    }
}

/// Snow-sculpture colorway for the 9 pixel-sculpture kinds (feature:
/// pixel-art snowman kinds) — rolled fresh per spawn, independent of
/// `SnowmanKind`. `classic` ignores this entirely; it keeps its own
/// 5-variant palette system (`SnowmanVariant`).
///
/// Each case carries two tones:
/// - `base` is the sculpture's BODY tone — near-white (snow), with only a
///   faint pastel tint, so bodies read as "carved from snow" rather than
///   full-saturation pastel blobs. `Snowman`/`PixelSculptures` derive the
///   matching shadow/highlight off this near-white base via
///   `SKColor.pixelShadow()`/`pixelHighlight()` so every sculpture's
///   shading stays internally consistent without each kind hand-picking
///   its own 3 tones.
/// - `accent` is the colorway's full-strength pastel identity, carried by
///   grid accents (scarf/cap/cheek/bow details) instead of the body —
///   see `PixelSculptures`'s "A" palette key.
enum SnowmanColorway: CaseIterable {
    case snowWhite
    case ivory
    case rose        // 연빨
    case peach        // 연주황
    case butter       // 연노랑
    case mint         // 연초록
    case sky          // 연파랑
    case periwinkle   // 연남
    case lilac        // 연보라

    /// Near-white "packed snow" body tone — each colorway's old pastel base
    /// blended ~75% toward white. `snowWhite`/`ivory` were already close to
    /// white, so their bodies land almost indistinguishable from plain snow
    /// (by design: they're the "plain" colorways); the other 7 keep a
    /// faint, just-barely-there tint of their identity.
    var base: SKColor {
        switch self {
        case .snowWhite:   return SKColor(calibratedWhite: 0.99, alpha: 1)
        case .ivory:       return SKColor(calibratedRed: 0.99, green: 0.98, blue: 0.97, alpha: 1)
        case .rose:        return SKColor(calibratedRed: 0.99, green: 0.95, blue: 0.955, alpha: 1)
        case .peach:       return SKColor(calibratedRed: 0.99, green: 0.96, blue: 0.93, alpha: 1)
        case .butter:      return SKColor(calibratedRed: 0.99, green: 0.98, blue: 0.93, alpha: 1)
        case .mint:        return SKColor(calibratedRed: 0.94, green: 0.98, blue: 0.96, alpha: 1)
        case .sky:         return SKColor(calibratedRed: 0.93, green: 0.97, blue: 0.99, alpha: 1)
        case .periwinkle:  return SKColor(calibratedRed: 0.95, green: 0.95, blue: 0.99, alpha: 1)
        case .lilac:       return SKColor(calibratedRed: 0.97, green: 0.95, blue: 0.98, alpha: 1)
        }
    }

    /// The colorway's full-strength pastel identity (what `base` used to be
    /// before the snow-white pass above) — for `snowWhite`/`ivory`, whose
    /// old base was already too close to white to read as an accent, this
    /// is instead a distinct signature tone (icy blue / honey gold) so
    /// every colorway still has a usable, visible accent.
    var accent: SKColor {
        switch self {
        case .snowWhite:   return SKColor(calibratedRed: 0.66, green: 0.81, blue: 0.92, alpha: 1)
        case .ivory:       return SKColor(calibratedRed: 0.92, green: 0.78, blue: 0.48, alpha: 1)
        case .rose:        return SKColor(calibratedRed: 0.98, green: 0.80, blue: 0.82, alpha: 1)
        case .peach:       return SKColor(calibratedRed: 0.99, green: 0.84, blue: 0.72, alpha: 1)
        case .butter:      return SKColor(calibratedRed: 0.99, green: 0.93, blue: 0.70, alpha: 1)
        case .mint:        return SKColor(calibratedRed: 0.74, green: 0.93, blue: 0.84, alpha: 1)
        case .sky:         return SKColor(calibratedRed: 0.73, green: 0.87, blue: 0.97, alpha: 1)
        case .periwinkle:  return SKColor(calibratedRed: 0.78, green: 0.80, blue: 0.96, alpha: 1)
        case .lilac:       return SKColor(calibratedRed: 0.87, green: 0.78, blue: 0.93, alpha: 1)
        }
    }

    var shadow: SKColor { base.pixelShadow() }
    var highlight: SKColor { base.pixelHighlight() }

    static func random() -> SnowmanColorway { allCases.randomElement() ?? .snowWhite }
}
