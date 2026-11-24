import SpriteKit

/// Tiny procedural 8-bit pixel-art engine (feature: pixel-art snowman kinds).
///
/// A "sculpture" is authored as a small grid of palette-key characters — see
/// `PixelSculptures.swift` for the actual creature grids. `PixelSculpt`'s job
/// is purely mechanical: rasterize one `(grid, palette)` pair once into a
/// crisp, non-antialiased `SKTexture` (one flat-colored 1px cell per
/// character; any character absent from the palette — including "." — is
/// left fully transparent, so grids can be ragged on the right edge with no
/// special-casing) and cache the result so repeated spawns of the same
/// `(kind, colorway)` combination are a dictionary hit, not a re-render.
///
/// Textures are displayed via an `SKSpriteNode` with `filteringMode =
/// .nearest`, which is what keeps the pixels chunky/crisp at any render
/// scale instead of blurring like a normal bitmap blown up.
enum PixelSculpt {
    /// One row per string, top to bottom. Each `Character` is a palette
    /// key; a key not present in the palette passed to `texture(...)`
    /// (most commonly ".", used everywhere below as "empty") renders fully
    /// transparent. Rows may be shorter than the grid's widest row — the
    /// missing trailing cells are simply never drawn, i.e. transparent.
    typealias Grid = [String]
    typealias Palette = [Character: SKColor]

    private static var textureCache: [String: SKTexture] = [:]

    /// Renders (and caches by `cacheKey`) one `(grid, palette)` result.
    /// Callers should use a stable key unique to the visual result — e.g.
    /// `"\(kind)-\(colorway)"` — so repeat spawns of the same look are free.
    static func texture(cacheKey: String, grid: Grid, palette: Palette) -> SKTexture {
        if let cached = textureCache[cacheKey] { return cached }
        let texture = render(grid: grid, palette: palette)
        textureCache[cacheKey] = texture
        return texture
    }

    /// Native width/height ratio of `grid`, so a caller can size the sprite
    /// that will display a texture rendered from it while preserving the
    /// grid's own proportions (a tall narrow grid stays tall and narrow).
    static func aspectRatio(of grid: Grid) -> CGFloat {
        let rows = grid.count
        let cols = grid.map(\.count).max() ?? 1
        guard rows > 0, cols > 0 else { return 1 }
        return CGFloat(cols) / CGFloat(rows)
    }

    private static func render(grid: Grid, palette: Palette) -> SKTexture {
        let rows = grid.count
        let cols = grid.map(\.count).max() ?? 0
        guard
            rows > 0, cols > 0,
            let context = CGContext(
                data: nil,
                width: cols,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return SKTexture() }

        // No anti-aliasing/interpolation anywhere in this context — every
        // fill below is an exact, pixel-aligned 1x1 rect, so this mostly
        // guards against CG ever softening an edge, which would betray the
        // "8-bit" look at the small sizes these render at.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)

        for (rowIndex, row) in grid.enumerated() {
            // Grid row 0 is the sculpture's TOP, but a CGContext bitmap's
            // row 0 is its bottom — flip while writing so the authored
            // grid reads top-to-bottom exactly as typed.
            let y = rows - 1 - rowIndex
            for (colIndex, char) in row.enumerated() {
                guard let color = palette[char] else { continue }
                let rgba = color.pixelRGBA
                context.setFillColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
                context.fill(CGRect(x: colIndex, y: y, width: 1, height: 1))
            }
        }

        guard let image = context.makeImage() else { return SKTexture() }
        let texture = SKTexture(cgImage: image)
        // The one line that makes the whole engine worthwhile: without
        // this, SpriteKit's default linear sampling blurs the sharp pixel
        // edges the second the sprite is scaled to its on-screen size.
        texture.filteringMode = .nearest
        return texture
    }
}

private extension SKColor {
    /// RGBA in device RGB. Not every color literal used by the sculptures
    /// below is already RGB (`calibratedWhite:` builds a grayscale-space
    /// color), and `getRed(_:green:blue:alpha:)` can't read those directly
    /// — converting first makes every color constructor safe to use here.
    var pixelRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}

extension SKColor {
    /// Derived shading tones for a pixel-art "base" body color: a flat,
    /// slightly darker shadow and a flat, slightly lighter highlight.
    /// Blended toward mid-gray/white rather than pure black/white so they
    /// stay in the same pastel family as the base — matte "packed snow"
    /// shading, not a glossy render — and read as a deliberate 3-tone pixel
    /// palette rather than a gradient.
    func pixelShadow() -> SKColor { blended(withFraction: 0.3, of: SKColor(calibratedWhite: 0.45, alpha: 1)) ?? self }
    func pixelHighlight() -> SKColor { blended(withFraction: 0.4, of: .white) ?? self }
}
