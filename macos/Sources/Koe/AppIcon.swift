import AppKit

// The app icon drawn in code (the bundle ships no .icns): the speech-bubble "o" from the menu bar
// icon (KoeIcon in main.swift) on a rounded dark square. Used for NSApp.applicationIconImage, so
// alerts such as the update prompt (UpdatePrompt.swift) show Koe instead of the generic app icon.
enum AppIcon {
    static let size: CGFloat = 256

    static func make(size: CGFloat = AppIcon.size) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = size / 18  // KoeIcon draws in an 18 pt box
            // background: rounded square, like macOS app icons
            let inset = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
            let background = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)
            background.setFill()
            NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            // bubble (same shapes as KoeIcon.make(filled: true), scaled): a white bubble with the
            // three bars in the background colour, which reads better at icon sizes than the outline
            NSColor.white.set()
            let ring = NSRect(x: 1.8 * s, y: 3.25 * s, width: 14.4 * s, height: 13.3 * s).insetBy(dx: size * 0.06, dy: size * 0.06)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 4.4 * s, y: 7.2 * s))
            tail.line(to: NSPoint(x: 3.2 * s, y: 2.4 * s))
            tail.line(to: NSPoint(x: 8.0 * s, y: 4.8 * s))
            tail.close()
            tail.fill()
            NSBezierPath(ovalIn: ring).fill()
            background.setFill()
            for (x, h) in [(6.5, 2.9), (9.0, 5.4), (11.5, 2.9)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: (x - 0.95) * s, y: (9.9 - h / 2) * s, width: 1.9 * s, height: h * s),
                             xRadius: 0.95 * s, yRadius: 0.95 * s).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static let image = make()
}
