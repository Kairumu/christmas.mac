import SpriteKit

/// One pixel-sculpture "look": a hand-authored grid (see `PixelSculpt.Grid`)
/// plus a function from the spawn's rolled `SnowmanColorway` to that grid's
/// full render palette.
///
/// Every grid below shares the same base vocabulary of characters so a
/// reader can tell at a glance what's colorway-driven vs. fixed:
///   "."  empty / transparent (never present in any palette dict on purpose)
///   "O"  ink — outlines, eyes, mouths. Near-black, constant across every
///        colorway (mirrors `Snowman`'s own near-black `faceInkColor`).
///   "W"  body base       — SnowmanColorway.base (near-white "snow" tone —
///        see SnowmanKind.swift; shading below is generous since that's
///        most of what reads as "roundness" on an otherwise near-white body)
///   "S"  body shadow     — SnowmanColorway.shadow
///   "H"  body highlight  — SnowmanColorway.highlight
///   "P"  blush — soft pink, constant everywhere, kept SMALL. Same cheap
///        cuteness cue the classic kind's face uses.
///   "A"  colorway accent — SnowmanColorway.accent, the colorway's
///        full-strength pastel identity (what "W" used to be before the
///        snow-white pass). Available to every grid for a scarf/cap/
///        cheek/bow detail that should track the rolled colorway; most
///        kinds instead give that role to a kind-specific FIXED accent
///        below (beak, lens, button, …) that stays constant across every
///        colorway roll — `mushroom` is the one kind where "A" carries the
///        big cap so the cap is what "uses the colorway strongly".
/// Anything past those 7 keys is a kind-specific FIXED accent (beak, lens,
/// cap trim, button, …) — these stay constant per kind rather than
/// colorway-swapped, but are themselves picked soft/pastel so they
/// harmonize with any roll. `mushroom` is the deliberate exception: there,
/// "W"/"S" stay with the plain snowman body underneath (now genuinely
/// snow-white) while "A" goes to its big polka-dot cap — see that grid's
/// comment.
enum PixelSculptures {
    static let library: [SnowmanKind: PixelSculpture] = [
        .bunnyCat: bunnyCat,
        .forestSpirit: forestSpirit,
        .shades: shades,
        .penguin: penguin,
        .snowDuck: snowDuck,
        .bear: bear,
        .robot: robot,
        .mushroom: mushroom,
        .ghost: ghost,
    ]
}

/// A grid + the palette-builder that turns one rolled colorway into that
/// grid's full `PixelSculpt.Palette` (shared body keys substituted, this
/// kind's fixed accents merged on top).
struct PixelSculpture {
    let grid: PixelSculpt.Grid
    let palette: (SnowmanColorway) -> PixelSculpt.Palette
}

// MARK: - Shared body keys

private let pixelInk = SKColor(calibratedWhite: 0.05, alpha: 1)
private let pixelBlush = SKColor(calibratedRed: 0.97, green: 0.62, blue: 0.64, alpha: 1)

/// The 7-key shared palette every grid below is built on top of — see the
/// enum doc comment above for what each key means.
private func bodyPalette(_ colorway: SnowmanColorway) -> PixelSculpt.Palette {
    [
        "O": pixelInk,
        "W": colorway.base,
        "S": colorway.shadow,
        "H": colorway.highlight,
        "P": pixelBlush,
        "A": colorway.accent,
    ]
}

/// Merges a kind's fixed accents on top of the shared body palette for one
/// rolled colorway — the one-liner every sculpture's `palette` closure below
/// reduces to.
private func fullPalette(_ colorway: SnowmanColorway, accents: PixelSculpt.Palette) -> PixelSculpt.Palette {
    bodyPalette(colorway).merging(accents) { _, accent in accent }
}

// MARK: - bunnyCat (몰랑 토끼냥)

/// One plump rounded body (no separate head/torso) with two short stubby
/// ears — each ear a SOLID white coin (thin "O" outline, "W" fill) with a
/// small inner-pink ("P") patch low in the middle, never a black lump: the
/// ear's own outline is the only near-black in it. Tiny dot eyes, a tiny
/// 2px mouth, small cheek blush, and soft "S"/"H" rim-shading down both
/// flanks of the body (generous, since the body itself is near-white and
/// that's what reads as "round" rather than "flat") stand in for nub arms
/// resting on the belly.
private let bunnyCat = PixelSculpture(
    grid: [
        ".........OO............OO.........",
        ".......OOWWOO........OOWWOO.......",
        "......OWWWWWWO......OWWWWWWO......",
        "......OWWPPWWO......OWWPPWWO......",
        "......OWPPPPWO......OWPPPPWO......",
        "......OWPPPPWWOOOOOOWWPPPPWO......",
        "......OWWPPWWWWWWWWWWWWPPWWO......",
        ".......OWWWWWWWWWWWWWWWWWWO.......",
        ".....OOWWWWWWWWWWWWWWWWWWWWOO.....",
        "....OSSSSWWOWWWWWWWWOWWWWHHHHO....",
        "....OSSSSWWWWWWWWWWWWWWWWHHHHO....",
        "...OSSSPSWWWWWWWWWWWWWWWPHHHHHO...",
        "...OSSSSSWWWWWWOWOWWWWWWWHHHHHO...",
        "...OSSSSSWWWWWWWWWWWWWWWWHHHHHO...",
        "...OSSSSSWWWWWWWWWWWWWWWWHHHHHO...",
        "...OSSSSSWWWWWWWWWWWWWWWWHHHHHO...",
        "...OSOSSSWWWWWWWWWWWWWWWWHOHHHO...",
        "....OSSSSWWWWWWWWWWWWWWWWWWWWO....",
        ".....OSSSWWWWWWWWWWWWWWWWWWWO.....",
        "......OOSWWWWWWWWWWWWWWWWWOO......",
        "........OOOWWWWWWWWWWWWOOO........",
        "...........OOOOOOOOOOOO...........",
    ],
    palette: { fullPalette($0, accents: [:]) }
)

// MARK: - forestSpirit (숲요정)

private let forestBelly = SKColor(calibratedWhite: 0.96, alpha: 1)
private let forestChevron = SKColor(calibratedRed: 0.55, green: 0.45, blue: 0.38, alpha: 1)

/// A generic totoro-ish forest spirit: a proper BELL silhouette — a narrow
/// rounded crown that widens with a smooth CONVEX curve (quadratic-ish,
/// slow-then-fast, like a true dome rather than a straight cone) over
/// ~9 rows to the full-width robe, with two small solid pointed ear
/// triangles sitting right on the crown (not floating sticks above it). A
/// round pale belly patch with two small "^" chevron marks, whisker dots
/// either side of the round eyes, and generous "S"/"H" rim-shading down
/// the lower skirt for roundness.
private let forestSpirit = PixelSculpture(
    grid: [
        "..........O............O..........",
        ".........OWO..........OWO.........",
        "........OWWWO........OWWWO........",
        "........OWWWWOOOOOOOOWWWWO........",
        ".......OOWWWWWWWWWWWWWWWWOO.......",
        ".........OWWWWWWWWWWWWWWO.........",
        "........OWWWWWWWWWWWWWWWWO........",
        ".......OWWWWWWWWWWWWWWWWWWO.......",
        "......OWWWWOWWWWWWWWWWOWWWWO......",
        ".....OOWWWWWWWWWWWWWWWWWWWWOO.....",
        "....OWWWWPWWWWWWWWWWWWWWPWWWWO....",
        "....OOWWWWWWWBBBBBBBBWWWWWWWOO....",
        "...OWWWWWWWBBBBBBBBBBBBWWWWWWWO...",
        "...OWWWWWWBBBVBBBBBBVBBBWWWWWWO...",
        "..OWWWWWWWBBVBVBBBBVBVBBWWWWWWWO..",
        "..OWWWWWWWBBBBBBBBBBBBBBWWWWWWWO..",
        "..OSSWWWWWBBBBBBVBBBBBBBWWWWWHHO..",
        ".OSSWWWWWWBBVBBVBVBBBVBBWWWWWWHHO.",
        ".OSSWWWWWWWVBVBBBBBBVBVWWWWWWWHHO.",
        ".OSSWWWWWWWWBBBBBBBBBBWWWWWWWWHHO.",
        ".OSSWWWWWWWWWWBBBBBBWWWWWWWWWWHHO.",
        ".OSSWWWWWWWWWWWWWWWWWWWWWWWWWWHHO.",
        ".OSSWWWWWWWWWWWWWWWWWWWWWWWWWWHHO.",
        ".OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO.",
    ],
    palette: { fullPalette($0, accents: ["B": forestBelly, "V": forestChevron]) }
)

// MARK: - shades (썬글라스)

private let shadesHatRed = SKColor(calibratedRed: 0.82, green: 0.3, blue: 0.28, alpha: 1)
private let shadesTrimWhite = SKColor(calibratedRed: 0.98, green: 0.95, blue: 0.9, alpha: 1)
private let shadesLens = SKColor(calibratedWhite: 0.03, alpha: 1)
private let shadesGlint = SKColor(calibratedWhite: 1.0, alpha: 0.95)
private let shadesScarf = SKColor(calibratedRed: 0.93, green: 0.55, blue: 0.4, alpha: 1)
private let shadesMitten = SKColor(calibratedRed: 0.4, green: 0.26, blue: 0.14, alpha: 1)

/// The classic 2-ball snowman silhouette, pixel-art — a SMALL round head
/// ball sitting on a CLEARLY BIGGER round body ball (each its own circle,
/// not merged into one blob, with the scarf band bridging the neck seam
/// between them): the sunglasses are one solid near-black band spanning
/// wider than the head itself (classic oversized "deal with it" overhang),
/// with two glint pixels so the lenses read as glossy rather than merging
/// into the outline ink. The santa hat floats clear of the head with a
/// gap row so hat and face never touch. The mitten stick-arms are painted
/// directly adjacent to the body's own "O" outline column (zero gap) so
/// they read as attached, not floating nubs, and generous "S"/"H" rim
/// shading rounds out the body.
private let shades = PixelSculpture(
    grid: [
        "................M..............",
        "...............MMM.............",
        "..............RRRRR............",
        ".............RRRRRRR...........",
        "........MMMMMMMMMMMMMMM........",
        ".........MMMMMMMMMMMMM.........",
        "...............................",
        "...............................",
        ".............OOOOO.............",
        "...........OOWWWWWOO...........",
        "........LLGLLLLLLLLGLLL........",
        "........LLLLLLLLLLLLLLL........",
        "..........OWWLLLLWWWO..........",
        "..........OWWWOOWWWWO..........",
        "...........OPWWWWPWO...........",
        "...........OOWWWWWOO...........",
        ".............OOOOO.............",
        ".......CCCCCCCCCCCCCCCCC.......",
        ".......CCCCCCCCCCCCCCCCC.......",
        "............OOOOOOO............",
        "..........OOWWWWWWWOO..........",
        ".........OWWWWWWWWWWWO.........",
        "........OSWWWWWWWWWWWHO........",
        ".......OSSWWWWWWWWWWWHHO.......",
        ".......OSSWWWWWWWWWWWHHO.......",
        ".....KOSSSWWWWWWWWWWWHHHOK.....",
        ".....KOSSSWWWWWWWWWWWHHHOK.....",
        ".....KOSSSWWWWWWWWWWWHHHOK.....",
        "......OSSSWWWWWWWWWWWHHHO......",
        "......OSSSWWWWWWWWWWWHHHO......",
        ".......OSSWWWWWWWWWWWHHO.......",
        ".......OSSWWWWWWWWWWWHHO.......",
        "........OSWWWWWWWWWWWHO........",
        ".........OWWWWWWWWWWWO.........",
        "..........OOOOOOOOOOO..........",
    ],
    palette: { fullPalette($0, accents: ["R": shadesHatRed, "M": shadesTrimWhite, "L": shadesLens, "G": shadesGlint, "C": shadesScarf, "K": shadesMitten]) }
)

// MARK: - penguin

private let penguinBelly = SKColor(calibratedWhite: 0.96, alpha: 1)
private let penguinBeak = SKColor(calibratedRed: 1.0, green: 0.52, blue: 0.16, alpha: 1)

/// A round penguin: pale belly patch, a tiny orange beak and feet, and
/// darker flipper-arm shading down both flanks.
private let penguin = PixelSculpture(
    grid: [
        "...........OOOOOOOOOOO...........",
        "........OOOWWWWWWWWWWWOOO........",
        "......OOWWWWWWWWWWWWWWWWWOO......",
        "....OOWWWWWWWWWWWWWWWWWWWWWOO....",
        "...OWWWWWWWWWWWWWWWWWWWWWWWWWO...",
        "..OWWWWWWWWWOWWWWWWOWWWWWWWWWWO..",
        "..OSSSSWWWWWWWWWWWWWWWWWWWSSSSO..",
        ".OSSSSSWWWWWWWWKKWWWWWWWWWSSSSSO.",
        ".OSSSSSWWPWWWWWWWWWWWWPWWWSSSSSO.",
        ".OSSSSSWWWWWWWWWWWWWWWWWWWSSSSSO.",
        ".OSSSSSWWWWWWWWWWWWWWWWWWWSSSSSO.",
        "..OSSSSWWWWWBBBBBBBBBWWWWWSSSSO..",
        "..OSSSSWWWWBBBBBBBBBBBWWWWSSSSO..",
        "...OSSSWWWBBBBBBBBBBBBBWWWSSSO...",
        "....OOSWWBBBBBBBBBBBBBBBWWSOO....",
        "......OOWBBBBBBBBBBBBBBBWOO......",
        "........OOOBBBBBBBBBBBOOO........",
        "...........OOKKOOOKKOO...........",
    ],
    palette: { fullPalette($0, accents: ["B": penguinBelly, "K": penguinBeak]) }
)

// MARK: - snowDuck (눈오리)

private let snowDuckBeak = SKColor(calibratedRed: 1.0, green: 0.52, blue: 0.16, alpha: 1)

/// 눈오리 in true SIDE PROFILE, redrawn as a plump TEARDROP lying down (the
/// previous pass went flat-sided past the equator and read as a brick): a
/// small head bump on the left with a single dot eye and a tiny flat beak
/// poking out zero-gap past the head's own outline, atop a body whose
/// back arcs smoothly up and over the top, round and curving all the way
/// down the right side to a slightly-raised rounded tail tip — ONLY the
/// ground-contact edge along the bottom is cut flat. Completely limbless,
/// no feet, with generous "S"/"H" rim shading down both flanks.
private let snowDuck = PixelSculpture(
    grid: [
        ".........OOOO.......................",
        "........OWWWWO......................",
        ".......OWWWWWWO.....................",
        "......OWWWOWWWWO....................",
        "...KKKKWWWWWWWWWOOOOOOOOOO..........",
        "...KKKKWWWWWWWWWWWWWWWWWWWOOOO......",
        "......OWWWWWWWWWWWWWWWWWWWWWWWOOOO..",
        ".......OSSWWWWWWWWWWWWWWWWWWWWWWHHO.",
        "........OSSWWWWWWWWWWWWWWWWWWWWWHHO.",
        "........OSSWWWWWWWWWWWWWWWWWWWWWHHO.",
        "........OSSWWWWWWWWWWWWWWWWWWWWWHHO.",
        ".........OSSWWWWWWWWWWWWWWWWWWWHHO..",
        "..........OOSWWWWWWWWWWWWWWWWWHOO...",
        "............OOOOOOOOOOOOOOOOOOO.....",
    ],
    palette: { fullPalette($0, accents: ["K": snowDuckBeak]) }
)

// MARK: - bear (곰돌이)

private let bearMuzzle = SKColor(calibratedRed: 0.96, green: 0.88, blue: 0.74, alpha: 1)

/// A round teddy bear: two SOLID round ears attached directly to the top
/// corners of the head — a filled coin shape (body-color "W" fill, "O"
/// outline tracing only the OUTSIDE edge, a single darker "S" center dot
/// with fill on every side of it) rather than outline threaded through
/// every column, which is what read as a hollow hook/antler before. Small
/// dot eyes sit clear above a cream muzzle patch with a tiny nose and
/// mouth, soft cheek blush, a lighter oval tummy patch, and generous "S"
/// rim-shading down the left flank round out the look.
private let bear = PixelSculpture(
    grid: [
        // Ears are solid coins whose bottom row lands ON the head's top
        // outline (no gap, no open bottom) — detached/open ears read as
        // hooks/antlers at render size, which took three passes to learn.
        ".......OOOO............OOOO.......",
        "......OWWWWO..........OWWWWO......",
        ".....OWWSSWWO........OWWSSWWO.....",
        ".....OWWSSWWO........OWWSSWWO.....",
        "......OWSSWWWOOOOOOOOWWWSSWO......",
        "......OWWWWWWWWWWWWWWWWWWWWO......",
        "......OWWWWWWWWWWWWWWWWWWWWO......",
        ".....OWWWWWOWWWWWWWWOWWWWWWWO.....",
        "....OWWPWWWWWWWWWWWWWWWWPWWWWO....",
        "...OWWWWWWWWWWWWWWWWWWWWWWWWWWO...",
        "...OWWWWWWWWWWWUUUUWWWWWWWWWWWO...",
        "...OSSWWWWWWWUUUUUUUUWWWWWWWWWO...",
        "...OSSWWWWWWUUUUOUUUUUWWWWWWWWO...",
        "...OSSWWWWWUUUUUUUUUUUUWWWWWWWO...",
        "...OSSWWWWWWUUUOUOUUUUWWWWWWWWO...",
        "....OSWWWWWWHUUUUUUUUHWWWWWWWO....",
        ".....OWWWWWHHHHUUUUHHHHWWWWWO.....",
        "......OOWWWWHHHHHHHHHHWWWWOO......",
        "........OOOWWWHHHHHHWWWOOO........",
        "...........OOOOOOOOOOOO...........",
    ],
    palette: { fullPalette($0, accents: ["U": bearMuzzle]) }
)

// MARK: - robot

private let robotEyeLED = SKColor(calibratedRed: 0.55, green: 0.92, blue: 0.95, alpha: 1)
private let robotPanel = SKColor(calibratedWhite: 0.35, alpha: 1)
private let robotButton = SKColor(calibratedRed: 0.95, green: 0.55, blue: 0.3, alpha: 1)

/// A boxy 8-bit robot snowman: chamfered square antenna'd head, rectangular
/// LED eyes either side of a center seam, a panel-line stripe, two buttons,
/// and "S"/"H" rim-shading down the body's flanks.
private let robot = PixelSculpture(
    grid: [
        "..............O..............",
        "..............O..............",
        "..............O..............",
        "..........OOOOOOOOO..........",
        ".........OWWWWWWWWWO.........",
        "........OWWWWWWWWWWWO........",
        "........OWDDDWWWDDDWO........",
        "........OWDDDOOODDDWO........",
        "........OWWWWWWWWWWWO........",
        "........OWWWWWWWWWWWO........",
        ".........OWWWWWWWWWO.........",
        "..........OWWWWWWWO..........",
        "......OOOOWWWWWWWWWOOOO......",
        ".....OWWWWWWWWWWWWWWWWWO.....",
        "....ONNNNNNNNNNNNNNNNNNNO....",
        "....OSSWWWWWWWWWWWWWWWHHO....",
        "....OSSWWWWWWWWWWWWWWWHHO....",
        "....OSSWWWYWWWWWWYWWWWHHO....",
        "....OSSWWWYWWWWWWYWWWWHHO....",
        "....OSSWWWWWWWWWWWWWWWHHO....",
        ".....OSWWWWWWWWWWWWWWWHO.....",
        "......OOOOOOOOOOOOOOOOO......",
    ],
    palette: { fullPalette($0, accents: ["D": robotEyeLED, "N": robotPanel, "Y": robotButton]) }
)

// MARK: - mushroom

private let mushroomDot = SKColor(calibratedWhite: 0.97, alpha: 1)

/// A plain little snowman wearing a big polka-dot mushroom cap as a hat —
/// deliberately the one kind where "A" (the rolled colorway's full-strength
/// accent) goes to the cap instead of a kind-fixed tone, so the colorway
/// shows up strongly there; the body underneath is the plain shared
/// snow-white "W"/"S"/"H" system like every other kind, so it never
/// competes with the cap for attention.
private let mushroom = PixelSculpture(
    grid: [
        "............OOOOOOOOOOO............",
        "........OOOOATAAAAATAAAOOOO........",
        ".....OOOTAAAAAAAAAAAAAAAATAOOO.....",
        "....OAAAAAAAAAAAATAAAAAAAAAAAAO....",
        "...OAAAAAATAAAATAAAAAAATAAAAAAAO...",
        "...OOOOOOOOOOOOAAAAAOOOOOOOOOOOO...",
        "...............OWWWO...............",
        ".............OOWWWWWOO.............",
        "............OWWWWWWWWWO............",
        "...........OWWWWWWWWWWWO...........",
        "...........OWWOWWWWOWWWO...........",
        "...........OPWWWWWWWWPHO...........",
        "...........OSWWWOOWWWWHO...........",
        "............OWWWWWWWWWO............",
        ".............OOWWWWWOO.............",
        "...............OOOOO...............",
    ],
    palette: { fullPalette($0, accents: ["T": mushroomDot]) }
)

// MARK: - ghost

private let ghostTongue = SKColor(calibratedRed: 0.92, green: 0.42, blue: 0.5, alpha: 1)

/// A cute round ghost: a perfectly smooth round dome top (no ear-like
/// bumps), a pair of SOLID near-black vertical ovals for eyes (3 wide x 5
/// tall, with the two OUTER corners left as body fill to round that side —
/// a hollow ring/cross construction here read as knocked-out "+" eyes, not
/// cute), a tiny tongue, soft blush, nub arms that poke 1px PAST the
/// body's own silhouette (zero-gap against the body's own outline column,
/// a real protrusion rather than internal shading, so they can't be
/// mistaken for ears), and a wavy hem two rows deep so the scallops and
/// their transparent notches both actually read at display size.
private let ghost = PixelSculpture(
    grid: [
        "............OOOOOOOOO............",
        ".........OOOWWWWWWWWWOOO.........",
        ".......OOWWWWWWWWWWWWWWWOO.......",
        "......OWWWWWWWWWWWWWWWWWWWO......",
        ".....OWWWWWWWWWWWWWWWWWWWWWO.....",
        "....OWWWWWOOWWWWWWWWOOWWWWWWO....",
        "....OWWWWOOOWWWWWWWWOOOWWWWWO....",
        "...OWWWWWOOOWWWWWWWWOOOWWWWWWO...",
        "...OWWWWWOOOWWWWWWWWOOOWWWWWWO...",
        "...OWWWWWWOOWWWWWWWWOOWWWWWWWO...",
        "...OWWPWWWWWWWWWWWWWWWWWWPWWWO...",
        "..SOWWWWWWWWWWWTTWWWWWWWWWWWWOS..",
        "....OWWWWWWWWWWTWWWWWWWWWWWWO....",
        "....OWWWWWWWWWWWWWWWWWWWWWWWO....",
        ".....OWWWWWWWWWWWWWWWWWWWWWO.....",
        "......OWWWOOWWWWOOWWWWOOWWWO.....",
        "......OWWO..OWWO..OWWO..OWO......",
        "......OOOO..OOOO..OOOO..OOO......",
    ],
    palette: { fullPalette($0, accents: ["T": ghostTongue]) }
)
