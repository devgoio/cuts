import AppKit

enum MenuIcon {
    static let size = NSSize(width: 16, height: 16)

    static func symbol(_ name: String, description: String) -> NSImage {
        let source = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: description)!
        let image = source.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            ?? source
        image.size = size
        image.isTemplate = true
        return image
    }

    static func tool(_ tool: EditTool) -> NSImage {
        guard let image = ToolIcon.image(for: tool) else {
            return symbol(tool.symbol, description: tool.title)
        }
        image.size = size
        return image
    }

    static func fontSample(_ family: String) -> NSImage {
        let specimen = family == "PingFang SC" ? "字" : "Aa"
        let style = AnnotationTextStyle(fontName: family, fontSize: 11, color: .black, bold: false, italic: false)
        let image = NSImage(size: size, flipped: false) { rect in
            let sample = NSAttributedString(string: specimen, attributes: style.attributes(scale: 1))
            let measured = sample.size()
            sample.draw(at: CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.65).setStroke()
            color.setFill()
            let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12))
            circle.lineWidth = 0.7
            circle.fill()
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
