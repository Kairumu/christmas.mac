import Foundation
import CoreGraphics

enum SnowIntensity: String, CaseIterable, Codable {
    case light = "조금", normal = "보통", heavy = "펑펑", off = "끄기"
    var spawnPerSecond: Double { switch self { case .light: 25; case .normal: 80; case .heavy: 220; case .off: 0 } }
}

struct Surface: Equatable {
    // screenBottom carries its own displayID so two screens' bottom edges
    // are distinct `Kind`s — without this, Accumulation's reconcile-by-kind
    // treats every screen's screenBottom as the SAME surface and collapses
    // their heightmaps into one (see displayID below for the full fix).
    enum Kind: Equatable { case window(id: CGWindowID), dock, screenBottom(displayID: CGDirectDisplayID) }
    let kind: Kind
    /// Which physical display this surface belongs to. OverlayManager uses
    /// this to route a surface to only its own screen's scene — without it,
    /// every scene received every screen's surfaces (including windows that
    /// don't exist on that screen at all).
    let displayID: CGDirectDisplayID
    /// Top edge segment in SCENE coordinates (origin bottom-left of the screen).
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
}

/// Implemented by the SpriteKit scene (worker-2). Called by Core & Interaction.
protocol SnowSceneAPI: AnyObject {
    var intensity: SnowIntensity { get set }
    /// When true (macOS Low Power Mode), spawn rate is reduced and wind
    /// gusts are suppressed. NOT a pause — isPaused is owned by the caller.
    var lowPowerMode: Bool { get set }
    func updateSurfaces(_ surfaces: [Surface])
    /// Window closed → drop that surface's snow so it falls and re-accumulates (feature 04).
    func surfaceRemoved(_ surface: Surface)
    func summonSnowplow()
    func resetAllSnow()
    /// "눈 모두 치우기": clears accumulated snow only, leaves snowballs/snowmen intact.
    func clearAccumulatedSnow()
    /// Hit-test for click-through toggling: accumulated snow, snowballs, snowmen.
    func isInteractive(atScenePoint p: CGPoint) -> Bool
    /// Scoop snow near p. Returns grams scooped (0 = nothing there). Reduces accumulation.
    func scoopSnow(atScenePoint p: CGPoint) -> CGFloat
    /// Interaction layer node container (worker-3 adds its nodes here).
    var interactionDelegate: SnowInteractionDelegate? { get set }
}

/// Implemented by InteractionController (worker-3). SnowScene forwards raw input.
protocol SnowInteractionDelegate: AnyObject {
    func mouseDown(atScenePoint p: CGPoint)
    func mouseDragged(toScenePoint p: CGPoint, velocity: CGVector)
    func mouseUp(atScenePoint p: CGPoint, velocity: CGVector)
    /// True if interaction owns content at p (snowball/snowman hit area).
    func isInteractive(atScenePoint p: CGPoint) -> Bool
    func resetAll()
}
