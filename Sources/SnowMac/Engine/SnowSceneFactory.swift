import SpriteKit

/// Single seam Core wires through to obtain the real engine scene.
enum SnowSceneFactory {
    static func make(size: CGSize) -> SKScene & SnowSceneAPI {
        SnowScene(size: size)
    }
}
