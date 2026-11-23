import AppKit

/// Green glove cursor (programmatically drawn, no binary assets) shown while
/// scooping/rolling/dragging interactive content; restores the arrow otherwise.
enum GloveCursor {
    private static var isPushed = false
    private static let gloveCursor: NSCursor = makeCursor()

    static func push() {
        guard !isPushed else { return }
        gloveCursor.push()
        isPushed = true
    }

    static func pop() {
        guard isPushed else { return }
        NSCursor.pop()
        isPushed = false
    }

    private static func makeCursor() -> NSCursor {
        let size = CGSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { _ in
            drawGlove()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 6, y: 26))
    }

    private static func drawGlove() {
        let green = NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.2, alpha: 1.0)
        let darkGreen = NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.12, alpha: 1.0)
        let white = NSColor.white

        green.setFill()
        darkGreen.setStroke()

        let palm = NSBezierPath(roundedRect: CGRect(x: 8, y: 4, width: 16, height: 16), xRadius: 6, yRadius: 6)
        palm.lineWidth = 1.2
        palm.fill()
        palm.stroke()

        let thumb = NSBezierPath(roundedRect: CGRect(x: 3, y: 13, width: 7, height: 10), xRadius: 3, yRadius: 3)
        thumb.lineWidth = 1.2
        thumb.fill()
        thumb.stroke()

        for i in 0..<4 {
            let fingerX = 9 + CGFloat(i) * 4.2
            let fingerHeight: CGFloat = 10 - CGFloat(i % 2) * 2
            let finger = NSBezierPath(
                roundedRect: CGRect(x: fingerX, y: 18, width: 3.4, height: fingerHeight),
                xRadius: 1.6, yRadius: 1.6
            )
            finger.lineWidth = 1.0
            finger.fill()
            finger.stroke()
        }

        white.setFill()
        let cuff = NSBezierPath(roundedRect: CGRect(x: 8, y: 1, width: 16, height: 4), xRadius: 2, yRadius: 2)
        cuff.fill()
    }
}
