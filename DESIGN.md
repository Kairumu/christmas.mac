# SnowMac (눈 내리는 맥) — Design & Contracts

macOS menu-bar app that overlays falling/accumulating snow on the desktop,
replicating the 11 features observed in `_resource/snow.mp4`.

## Requirements (from video analysis)

1. Snow accumulates on the TOP EDGE of every visible window
2. Snow accumulates on the Dock (matching its width/position)
3. "제설차 부르기" — snowplow sprite drives across a surface and clears its snow
4. Closing a window drops its accumulated snow; it falls and re-accumulates below
5. Click accumulated snow (glove cursor) to scoop; drag to roll a growing snowball
6. Stack snowballs → snowman assembles (arms, eyes, nose, hat appear one by one)
7. Snowman idle animations: breathing, waving, dancing
8. 5 snowman variants (hat / scarf / face differ)
9. Throw snowball/snowman: physics velocity, bounces off screen edges, shatters on impact
10. Snow intensity setting: 조금 / 보통 / 펑펑
11. 10 built-in winter wallpapers, applied instantly via NSWorkspace

Non-functional: menu-bar only app (LSUIElement), click-through overlay except on
interactive snow content, multi-display, SwiftPM build (no Xcode project),
programmatically drawn art (no binary assets), macOS 13+.

## Architecture

- SwiftPM executable target `SnowMac` (AppKit + SpriteKit, programmatic NSApplication).
- One borderless transparent `OverlayWindow` per screen, `level = .statusBar - 1`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`,
  `ignoresMouseEvents = true` by default. A global mouseMoved monitor asks the scene
  `isInteractive(at:)`; if true → `ignoresMouseEvents = false` (so clicks reach us),
  else true (click-through). No Screen Recording permission needed — we only use
  window BOUNDS from `CGWindowListCopyWindowInfo` (not names).
- `WindowTracker` polls `CGWindowListCopyWindowInfo(.optionOnScreenOnly | .excludeDesktopElements)`
  at 10 Hz on a timer, converts CG (top-left origin) to scene coords, and publishes
  `[Surface]`. Dock surface found via owner name "Dock" (kCGWindowOwnerName works
  without permission). Screen-bottom surface is always present. Window disappearance
  → `surfaceRemoved` callback (feature 04).

## File ownership (STRICT — do not edit files you don't own)

| Path (Sources/SnowMac/) | Owner |
|---|---|
| Core/* (main, AppDelegate, StatusBarController, SettingsStore, OverlayManager, OverlayWindow, WindowTracker, WallpaperManager, SnowSceneAPI.swift) | worker-1 |
| Engine/* (SnowScene, Accumulation, Snowplow) | worker-2 |
| Interaction/* (InteractionController, Snowball, Snowman, SnowmanVariants, ShatterEffect, GloveCursor) | worker-3 |

worker-2 may replace `Engine/PlaceholderSnowScene.swift` created by worker-1.
worker-3 must NOT edit Engine/* — integrate only through the protocols below.

## Contracts (defined in Core/SnowSceneAPI.swift — worker-1 creates EXACTLY this)

```swift
import Foundation
import CoreGraphics

enum SnowIntensity: String, CaseIterable, Codable {
    case light = "조금", normal = "보통", heavy = "펑펑"
    var spawnPerSecond: Double { switch self { case .light: 25; case .normal: 80; case .heavy: 220 } }
}

struct Surface: Equatable {
    enum Kind: Equatable { case window(id: CGWindowID), dock, screenBottom }
    let kind: Kind
    /// Top edge segment in SCENE coordinates (origin bottom-left of the screen).
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
}

/// Implemented by the SpriteKit scene (worker-2). Called by Core & Interaction.
protocol SnowSceneAPI: AnyObject {
    var intensity: SnowIntensity { get set }
    func updateSurfaces(_ surfaces: [Surface])
    /// Window closed → drop that surface's snow so it falls and re-accumulates (feature 04).
    func surfaceRemoved(_ surface: Surface)
    func summonSnowplow()
    func resetAllSnow()
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
```

Wiring (worker-1 in OverlayManager): create concrete `SnowScene` (worker-2 type,
instantiated via `SnowSceneFactory.make(size:)` — worker-2 provides this factory in
Engine/), create `InteractionController(scene:)` (worker-3 type exposing
`init(scene: SnowSceneAPI & SKScene)`), assign as `interactionDelegate`.
Until workers 2/3 land, worker-1 ships `PlaceholderSnowScene` (simple falling dots)
and skips the interaction controller behind `#if`-free optional wiring so the
scaffold builds standalone.

## Settings & menu

`SettingsStore` (UserDefaults): intensity (default 보통), snowOnWindows,
snowOnDock (both on). StatusBar menu: 눈 양 ▸ (조금/보통/펑펑 radio), 제설차 부르기,
배경화면 ▸ (겨울 배경 1…10), 눈 모두 치우기, 눈사람/눈덩이 리셋, SnowMac 종료.
Changes propagate via NotificationCenter (`SettingsStore.didChange`).

`WallpaperManager`: draws 10 distinct winter scenes (night-sky gradients, snow hills,
trees — CoreGraphics) at each screen's pixel size, caches PNGs under
`~/Library/Application Support/SnowMac/wallpapers/`, applies with
`NSWorkspace.setDesktopImageURL` for every screen.

## Build & bundle

- `Package.swift`: swift-tools 5.9, platforms: [.macOS(.v13)], single executable target,
  linkedFrameworks AppKit/SpriteKit via standard import (no extra settings needed).
- `scripts/build_app.sh`: swift build -c release → assemble `build/SnowMac.app`
  (Contents/MacOS/SnowMac, Info.plist with CFBundleIdentifier com.kairu.snowmac,
  LSUIElement true, NSHighResolutionCapable true), `codesign --force --deep -s -`.

## Verification

`swift build` must pass after every task. Task 4 additionally runs build_app.sh and
inspects the bundle.
