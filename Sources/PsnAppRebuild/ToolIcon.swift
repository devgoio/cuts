import AppKit

enum ToolIcon {
    static func image(for tool: EditTool) -> NSImage? {
        if [.rectangle, .circle, .ellipse].contains(tool) {
            let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { _ in
                NSColor.black.setStroke()
                let rect = tool == .circle ? CGRect(x: 4.75, y: 4.75, width: 10.5, height: 10.5)
                    : CGRect(x: 3.5, y: 5.5, width: 13, height: 9)
                let path = tool == .rectangle ? NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                    : NSBezierPath(ovalIn: rect)
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }
        guard [.text, .mosaic, .eraser].contains(tool) else { return nil }
        if tool == .mosaic {
            let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
                // The supplied four-tile SVG, drawn natively as a 12 pt glyph
                // inside a 20 pt image box to align with the adjacent symbols.
                NSColor.black.setFill()
                NSBezierPath(rect: CGRect(x: 4, y: 10, width: 6, height: 6)).fill()
                NSBezierPath(rect: CGRect(x: 10, y: 4, width: 6, height: 6)).fill()
                NSColor.black.withAlphaComponent(0.2).setFill()
                NSBezierPath(rect: CGRect(x: 10, y: 10, width: 6, height: 6)).fill()
                NSBezierPath(rect: CGRect(x: 4, y: 4, width: 6, height: 6)).fill()
                return true
            }
            image.isTemplate = true
            return image
        }
        if tool == .eraser {
            let image = NSImage(systemSymbolName: "eraser.fill", accessibilityDescription: "橡皮擦")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            image?.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let bar = NSBezierPath()
            bar.lineWidth = 1.5
            bar.lineCapStyle = .round
            bar.move(to: CGPoint(x: 5, y: 15))
            bar.line(to: CGPoint(x: 15, y: 15))
            bar.move(to: CGPoint(x: 10, y: 15))
            bar.line(to: CGPoint(x: 10, y: 5))
            bar.move(to: CGPoint(x: 7.75, y: 5))
            bar.line(to: CGPoint(x: 12.25, y: 5))
            bar.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
