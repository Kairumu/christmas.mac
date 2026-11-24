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
    //
    // .window carries `segment` because one real window can now produce
    // MULTIPLE Surfaces: WindowTracker splits a window's top-edge span
    // wherever another window in front of it actually covers that row
    // (z-order occlusion), so the back window doesn't catch snow under a
    // window that's visibly on top of it there. `segment` (stable left-to-
    // right index among that window's open sub-intervals this poll) keeps
    // each piece's reconciliation identity distinct — without it, every
    // segment of the same window would collide on the same `.window(id:)`
    // key and Accumulation's reconcile-by-kind would only ever track one
    // of them, silently dropping/merging the rest.
    enum Kind: Equatable { case window(id: CGWindowID, segment: Int = 0), dock, screenBottom(displayID: CGDirectDisplayID) }
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
    /// Teleports 영서 onto the most snow-laden surface and has her sweep it.
    /// Distinct from summonSnowplow(): both can be summoned and active at
    /// once.
    func summonSweeper()
    /// Teleports 영서 onto the most snow-laden surface for a short, focused
    /// gather stint, then has her build a complete snowman from what she
    /// collected (영서에게 눈사람 부탁). Distinct routine from summonSweeper()
    /// but shares the same "she's busy" guard — only one of either can be
    /// active at a time.
    func summonSweeperForSnowman()
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
    /// Right-click on deep-enough accumulated snow: spawn a standalone
    /// snowball at rest at p (no hold/drag), consuming a scoop's worth of
    /// snow there. Distinct from the left-click mouseDown pickup path.
    func spawnSnowball(atScenePoint p: CGPoint)
    /// 영서가 눈사람을 만들어주는 메뉴: assemble a complete snowman at p using
    /// the same staged pop-in sequence as a player-stacked snowman.
    func buildSnowman(atScenePoint p: CGPoint)
    /// True if interaction owns content at p (snowball/snowman hit area).
    func isInteractive(atScenePoint p: CGPoint) -> Bool
    func resetAll()
}
