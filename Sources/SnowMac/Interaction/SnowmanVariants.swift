import SpriteKit

/// Hat shape drawn on top of a snowman's head.
enum HatStyle: CaseIterable {
    case topHat, santa, beanie, none, earmuffs
}

/// Eye/brow styling applied to a snowman's face.
enum FaceExpression: CaseIterable {
    case happy, surprised, sleepy, grumpy, wink
}

/// One of the 5 built-in snowman looks (feature 08): differs by hat, scarf color,
/// and face expression. Scarf colors are warm pastels (part of the cuteness
/// pass) so every variant reads as a distinct, soft plush outfit rather than
/// a saturated primary color.
struct SnowmanVariant {
    let hat: HatStyle
    let scarfColor: SKColor
    let face: FaceExpression

    static let all: [SnowmanVariant] = [
        // Coral red scarf, classic top hat.
        SnowmanVariant(hat: .topHat, scarfColor: SKColor(calibratedRed: 0.93, green: 0.5, blue: 0.46, alpha: 1), face: .happy),
        // Butter yellow scarf against the softened Santa red.
        SnowmanVariant(hat: .santa, scarfColor: SKColor(calibratedRed: 0.98, green: 0.84, blue: 0.5, alpha: 1), face: .surprised),
        // Mint beanie + scarf.
        SnowmanVariant(hat: .beanie, scarfColor: SKColor(calibratedRed: 0.6, green: 0.86, blue: 0.74, alpha: 1), face: .wink),
        // No hat, so the pastel sky-blue scarf carries the whole look.
        SnowmanVariant(hat: .none, scarfColor: SKColor(calibratedRed: 0.55, green: 0.75, blue: 0.92, alpha: 1), face: .sleepy),
        // Lavender earmuffs + scarf.
        SnowmanVariant(hat: .earmuffs, scarfColor: SKColor(calibratedRed: 0.78, green: 0.62, blue: 0.82, alpha: 1), face: .grumpy)
    ]

    private static var roundRobinCursor = 0

    /// Picks variants in round-robin order so consecutive snowmen look distinct.
    static func next() -> SnowmanVariant {
        let variant = all[roundRobinCursor % all.count]
        roundRobinCursor += 1
        return variant
    }
}
