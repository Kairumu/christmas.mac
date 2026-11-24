import Foundation
import CoreGraphics

enum SnowIntensity: String, CaseIterable, Codable {
    // Declaration order drives the menu order (StatusBarController populates
    // from allCases): 끄기 / 조금 / 보통 / 많음 / 펑펑. `.heavy` ("많음") now
    // carries the old `.blizzard` ("펑펑")'s feel, and the new `.blizzard`
    // is substantially heavier still (사용자 요청: "진짜 많이 오도록").
    case off = "끄기", light = "조금", normal = "보통", heavy = "많음", blizzard = "펑펑"

    var spawnPerSecond: Double {
        switch self {
        case .off: 0
        case .light: 25
        case .normal: 80
        case .heavy: 220
        case .blizzard: 660
        }
    }

    // Global `maxFlakes` cap used to pin every heavy level to identical
    // on-screen density (same bug as the spawnAccumulator backlog issue
    // documented in SnowScene.spawnFlakes) — each intensity now gets its
    // own cap so density actually differentiates between levels. The flake
    // pool reuses nodes, so peak allocation this session is just whichever
    // cap was highest among levels actually selected.
    var maxFlakes: Int {
        switch self {
        case .off: 0
        case .light: 400
        case .normal: 600
        case .heavy: 900
        case .blizzard: 1500
        }
    }
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
    /// 블리자드: one-shot ~10s storm burst (ramp-up → full fury → die-down).
    /// Does NOT change `intensity` — normal spawn/cap/wind resume from the
    /// current intensity setting once the storm ends. Re-entrant calls while
    /// a storm is already running are a no-op.
    func triggerBlizzard()
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
    /// Where a bottom-anchored object resting at (x, y) should settle: the
    /// TOP (baseline + current snow height) of the highest surface whose
    /// x-range contains x AND whose top sits at/below y (+ small
    /// tolerance) — i.e. the surface such an object would actually land on
    /// while falling. Falls back to 0 (scene bottom) when nothing
    /// qualifies. Used by the interaction layer to make loose snowmen/
    /// snowballs/partial stacks fall when their support disappears and
    /// ride a growing pile, mirroring 영서's own live surface-top pin.
    func restingHeight(atX x: CGFloat, belowY y: CGFloat) -> CGFloat
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
    /// Per-frame tick (called from SnowScene.update, right after the
    /// sweeper block): lets the interaction layer drop loose objects whose
    /// support just vanished (gravity fall, landing on `restingHeight`) and
    /// gently ride a pile that's growing/shrinking beneath them.
    func tick(dt: TimeInterval)
    func resetAll()
}
