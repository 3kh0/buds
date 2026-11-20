import AppKit
import SwiftUI

enum PixelArtwork {
    static func image(_ name: String) -> NSImage {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources")
        guard let url, let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled Pixel Buds artwork: \(name)")
        }
        return image
    }

    static func menuBarImage(for selection: EarbudSelection = .both) -> NSImage {
        let single = selection == .left || selection == .right
        let width: CGFloat = single ? 14 : 23
        let sides = selection == .left ? [false] : selection == .right ? [true] : [false, true]
        let icon = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            for mirrored in sides {
                NSGraphicsContext.saveGraphicsState()
                let transform = AffineTransform(translationByX: mirrored ? width : 0, byY: 0)
                (transform as NSAffineTransform).concat()
                if mirrored { NSAffineTransform(transform: AffineTransform(scaleByX: -1, byY: 1)).concat() }
                let tip = NSBezierPath()
                tip.move(to: NSPoint(x: 4, y: 6))
                tip.curve(to: NSPoint(x: 4, y: 12), controlPoint1: NSPoint(x: 0, y: 5), controlPoint2: NSPoint(x: 0, y: 13))
                tip.lineWidth = 1.35
                tip.lineCapStyle = .round
                tip.stroke()
                let shell = NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 7, height: 10), xRadius: 3.5, yRadius: 3.5)
                shell.lineWidth = 1.35
                shell.stroke()
                let detail = NSBezierPath()
                detail.move(to: NSPoint(x: 5.4, y: 11.2))
                detail.line(to: NSPoint(x: 7.6, y: 11.2))
                detail.lineWidth = 1
                detail.lineCapStyle = .round
                detail.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = selection == .left ? "Left Pixel Bud" : selection == .right ? "Right Pixel Bud" : "Pixel Buds"
        return icon
    }

}

struct PixelBudsArtwork: View {
    let name: String
    var body: some View {
        Image(nsImage: PixelArtwork.image(name)).resizable().aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}
