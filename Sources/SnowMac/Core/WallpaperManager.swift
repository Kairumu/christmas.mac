import AppKit
import CoreGraphics

/// Generates 10 winter wallpapers with CoreGraphics (no binary assets), caches them
/// as PNGs, and applies them to every screen via NSWorkspace.
final class WallpaperManager {
    static let shared = WallpaperManager()

    let wallpaperCount = 10

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SnowMac/wallpapers", isDirectory: true)
    }

    func apply(wallpaperIndex: Int) {
        captureOriginalWallpapersIfNeeded()

        // Render (or fetch from cache) per screen at ITS OWN pixel size,
        // not once at the main screen's size applied to every screen — a
        // 1440x900 laptop image stretched 2.7x onto a 4K external display
        // reads as visibly soft, and re-applying after plugging in a
        // bigger display used to return the stale small cached PNG.
        for screen in NSScreen.screens {
            guard let url = cachedWallpaperURL(index: wallpaperIndex, pixelSize: pixelSize(for: screen)) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    // MARK: - Original wallpaper restore (P6)

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func originalWallpaperKey(for displayID: CGDirectDisplayID) -> String {
        "snowmac.originalWallpaper.\(displayID)"
    }

    /// Marks a screen as "we tried to capture its original wallpaper and
    /// couldn't trust the result" — distinct from the key being absent
    /// (meaning "capture simply hasn't happened yet"). Lets restore tell
    /// the user why nothing happened instead of silently no-oping or,
    /// worse, applying whatever NSWorkspace handed back anyway.
    private static let uncapturableSentinel = "snowmac.uncapturable"

    /// A captured URL is only trustworthy if it's a real file that exists
    /// right now AND isn't one of our OWN generated wallpapers. The second
    /// check matters because `apply()` always calls this capture function
    /// first — if a SnowMac wallpaper was already on screen when capture
    /// ran (e.g. an earlier session that quit without ever restoring),
    /// NSWorkspace.desktopImageURL(for:) would legitimately return OUR PNG
    /// path, and persisting that as "the original" would make restore just
    /// reapply one of our own winter wallpapers instead of the user's real
    /// one.
    private func isTrustworthyOriginal(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let ownDir = cacheDirectory.standardizedFileURL.path
        return !url.standardizedFileURL.path.hasPrefix(ownDir)
    }

    /// Captures each screen's current desktop image URL before this app's
    /// FIRST wallpaper apply this run, persisted so it survives restarts.
    /// Only captures when no saved original exists yet for that screen —
    /// otherwise a second apply would overwrite the real original with one
    /// of our own winter wallpapers.
    private func captureOriginalWallpapersIfNeeded() {
        let defaults = UserDefaults.standard
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let key = originalWallpaperKey(for: displayID)
            guard defaults.string(forKey: key) == nil else { continue }
            // NSWorkspace.desktopImageURL(for:) can return nil outright (a
            // dynamic/rotating wallpaper has no single static file to
            // report), or — the failure mode actually found persisted on
            // this machine's real defaults, both screens — a URL that
            // isn't the user's real original at all. Validate before
            // trusting it; if it fails, store a sentinel rather than
            // either a bogus URL or nothing, so restore can tell "this
            // screen can't be restored" from "not captured yet" and say so
            // instead of quietly doing nothing.
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), isTrustworthyOriginal(url) {
                defaults.set(url.absoluteString, forKey: key)
            } else {
                defaults.set(WallpaperManager.uncapturableSentinel, forKey: key)
            }
        }
    }

    /// Restores each screen's original wallpaper, if one was captured.
    /// Screens with no saved original are skipped gracefully. A screen
    /// whose saved value is detectably wrong — the uncapturable sentinel,
    /// a URL pointing at a now-missing file, or (from an older build) one
    /// of our own generated wallpapers — has its stored key CLEARED rather
    /// than left in place, so the next apply() re-captures whatever is
    /// actually on screen then instead of staying stuck on dead/self data
    /// forever. Shows one alert if any screen couldn't be restored.
    func restoreOriginalWallpapers() {
        let defaults = UserDefaults.standard
        var anyUncapturable = false
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let key = originalWallpaperKey(for: displayID)
            guard let stored = defaults.string(forKey: key) else { continue }

            if stored == WallpaperManager.uncapturableSentinel {
                anyUncapturable = true
                continue
            }
            guard let url = URL(string: stored), isTrustworthyOriginal(url) else {
                defaults.removeObject(forKey: key)
                continue
            }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }

        if anyUncapturable {
            let alert = NSAlert()
            alert.messageText = "원래 배경화면을 복원할 수 없어요"
            alert.informativeText = "현재 배경화면 방식(동적 배경 등)은 자동 저장을 지원하지 않아요."
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    private func pixelSize(for screen: NSScreen) -> CGSize {
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    private func cachedWallpaperURL(index: Int, pixelSize: CGSize) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Pixel size is part of the cache key so each screen's own
        // resolution gets its own rendered PNG instead of sharing (and
        // being stuck with) whichever size happened to render first.
        let fileURL = cacheDirectory.appendingPathComponent("wallpaper-\(index)-\(Int(pixelSize.width))x\(Int(pixelSize.height)).png")
        if fm.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        guard let image = renderWallpaper(index: index, size: pixelSize) else { return nil }
        guard let data = pngData(from: image) else { return nil }

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    private func pngData(from cgImage: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Rendering

    private struct Palette {
        let skyTop: CGColor
        let skyBottom: CGColor
        let hill: CGColor
        let hillFar: CGColor
        let star: CGColor
        let tree: CGColor
    }

    private func palette(for index: Int) -> Palette {
        let palettes: [Palette] = [
            Palette(skyTop: CGColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 1), skyBottom: CGColor(red: 0.08, green: 0.1, blue: 0.25, alpha: 1), hill: CGColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1), hillFar: CGColor(red: 0.65, green: 0.7, blue: 0.82, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9), tree: CGColor(red: 0.05, green: 0.12, blue: 0.08, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.05, green: 0.06, blue: 0.2, alpha: 1), skyBottom: CGColor(red: 0.15, green: 0.12, blue: 0.3, alpha: 1), hill: CGColor(red: 0.8, green: 0.84, blue: 0.93, alpha: 1), hillFar: CGColor(red: 0.6, green: 0.62, blue: 0.78, alpha: 1), star: CGColor(red: 1, green: 0.96, blue: 0.9, alpha: 0.9), tree: CGColor(red: 0.08, green: 0.1, blue: 0.12, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.95, green: 0.65, blue: 0.5, alpha: 1), skyBottom: CGColor(red: 0.98, green: 0.85, blue: 0.75, alpha: 1), hill: CGColor(red: 0.95, green: 0.92, blue: 0.9, alpha: 1), hillFar: CGColor(red: 0.85, green: 0.78, blue: 0.78, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5), tree: CGColor(red: 0.2, green: 0.12, blue: 0.14, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1), skyBottom: CGColor(red: 0.8, green: 0.88, blue: 0.96, alpha: 1), hill: CGColor(red: 0.98, green: 0.98, blue: 1, alpha: 1), hillFar: CGColor(red: 0.88, green: 0.9, blue: 0.96, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 0.3), tree: CGColor(red: 0.1, green: 0.25, blue: 0.15, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 1), skyBottom: CGColor(red: 0.04, green: 0.06, blue: 0.16, alpha: 1), hill: CGColor(red: 0.3, green: 0.34, blue: 0.45, alpha: 1), hillFar: CGColor(red: 0.18, green: 0.2, blue: 0.3, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 1), tree: CGColor(red: 0.02, green: 0.04, blue: 0.04, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1), skyBottom: CGColor(red: 0.5, green: 0.3, blue: 0.4, alpha: 1), hill: CGColor(red: 0.9, green: 0.85, blue: 0.88, alpha: 1), hillFar: CGColor(red: 0.7, green: 0.6, blue: 0.68, alpha: 1), star: CGColor(red: 1, green: 0.9, blue: 0.95, alpha: 0.8), tree: CGColor(red: 0.08, green: 0.06, blue: 0.1, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.0, green: 0.08, blue: 0.1, alpha: 1), skyBottom: CGColor(red: 0.0, green: 0.2, blue: 0.22, alpha: 1), hill: CGColor(red: 0.75, green: 0.9, blue: 0.9, alpha: 1), hillFar: CGColor(red: 0.5, green: 0.7, blue: 0.72, alpha: 1), star: CGColor(red: 0.6, green: 1, blue: 0.9, alpha: 0.7), tree: CGColor(red: 0.03, green: 0.1, blue: 0.09, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.12, green: 0.05, blue: 0.2, alpha: 1), skyBottom: CGColor(red: 0.3, green: 0.1, blue: 0.3, alpha: 1), hill: CGColor(red: 0.88, green: 0.82, blue: 0.9, alpha: 1), hillFar: CGColor(red: 0.6, green: 0.5, blue: 0.68, alpha: 1), star: CGColor(red: 1, green: 0.85, blue: 1, alpha: 0.8), tree: CGColor(red: 0.06, green: 0.03, blue: 0.1, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.03, green: 0.04, blue: 0.1, alpha: 1), skyBottom: CGColor(red: 0.1, green: 0.14, blue: 0.22, alpha: 1), hill: CGColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1), hillFar: CGColor(red: 0.7, green: 0.75, blue: 0.85, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 1), tree: CGColor(red: 0.04, green: 0.08, blue: 0.06, alpha: 1)),
            Palette(skyTop: CGColor(red: 0.85, green: 0.9, blue: 0.98, alpha: 1), skyBottom: CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1), hill: CGColor(red: 1, green: 1, blue: 1, alpha: 1), hillFar: CGColor(red: 0.9, green: 0.93, blue: 0.98, alpha: 1), star: CGColor(red: 1, green: 1, blue: 1, alpha: 0), tree: CGColor(red: 0.15, green: 0.3, blue: 0.18, alpha: 1)),
        ]
        return palettes[index % palettes.count]
    }

    private func renderWallpaper(index: Int, size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let pal = palette(for: index)

        // Sky gradient.
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [pal.skyTop, pal.skyBottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }

        // Stars.
        var rngState: UInt64 = UInt64(1000 + index)
        func nextRandom() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            return Double((rngState >> 33)) / Double(1 << 31)
        }

        ctx.setFillColor(pal.star)
        for _ in 0..<140 {
            let x = nextRandom() * Double(width)
            let y = rect.maxY - nextRandom() * Double(height) * 0.6
            let r = 0.5 + nextRandom() * 1.5
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }

        // Far hill silhouette.
        drawHill(ctx: ctx, rect: rect, baseline: rect.height * 0.32, amplitude: rect.height * 0.05, color: pal.hillFar, seedOffset: index)
        // Near hill silhouette.
        drawHill(ctx: ctx, rect: rect, baseline: rect.height * 0.18, amplitude: rect.height * 0.07, color: pal.hill, seedOffset: index + 50)

        // Simple trees along the near hill.
        ctx.setFillColor(pal.tree)
        let treeCount = 7 + (index % 4)
        for t in 0..<treeCount {
            let fx = (Double(t) + 0.5) / Double(treeCount) * Double(width)
            let baseY = rect.height * 0.2
            drawTree(ctx: ctx, x: CGFloat(fx), baseY: baseY, canvasHeight: rect.height, scale: CGFloat(1 + (t % 3)))
        }

        return ctx.makeImage()
    }

    private func drawHill(ctx: CGContext, rect: CGRect, baseline: CGFloat, amplitude: CGFloat, color: CGColor, seedOffset: Int) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        let steps = 24
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = CGFloat(t) * rect.width
            let wave = sin(t * 3.0 + Double(seedOffset)) * 0.5 + sin(t * 7.0 + Double(seedOffset) * 1.3) * 0.3
            let y = baseline + amplitude * CGFloat(wave)
            points.append(CGPoint(x: x, y: y))
        }
        path.addLines(between: points)
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()

        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func drawTree(ctx: CGContext, x: CGFloat, baseY: CGFloat, canvasHeight: CGFloat, scale: CGFloat) {
        // Every other silhouette (sky/hills) scales with the canvas; trees
        // were the one shape drawn at fixed absolute pixels, so on a
        // ~2880px-tall Retina canvas the tallest tree was 42px — 1.5% of
        // the image height, invisible against the 518px hill it stands on.
        let unit = canvasHeight * 0.035
        let height = unit * scale
        let width = unit * 0.57 * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: baseY + height))
        path.addLine(to: CGPoint(x: x - width / 2, y: baseY))
        path.addLine(to: CGPoint(x: x + width / 2, y: baseY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
}
