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
/// and face expression.
struct SnowmanVariant {
    let hat: HatStyle
    let scarfColor: SKColor
    let face: FaceExpression

    static let all: [SnowmanVariant] = [
        SnowmanVariant(hat: .topHat, scarfColor: SKColor(calibratedRed: 0.75, green: 0.1, blue: 0.15, alpha: 1), face: .happy),
        SnowmanVariant(hat: .santa, scarfColor: SKColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1), face: .surprised),
        SnowmanVariant(hat: .beanie, scarfColor: SKColor(calibratedRed: 0.95, green: 0.6, blue: 0.1, alpha: 1), face: .wink),
        SnowmanVariant(hat: .none, scarfColor: SKColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1), face: .sleepy),
        SnowmanVariant(hat: .earmuffs, scarfColor: SKColor(calibratedRed: 0.2, green: 0.55, blue: 0.3, alpha: 1), face: .grumpy)
    ]

    private static var roundRobinCursor = 0

    /// Picks variants in round-robin order so consecutive snowmen look distinct.
    static func next() -> SnowmanVariant {
        let variant = all[roundRobinCursor % all.count]
        roundRobinCursor += 1
        return variant
    }
}
