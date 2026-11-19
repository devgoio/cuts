import AppKit

enum AppIcon {
    static var mark: NSImage? {
        Bundle.main.url(forResource: "CutsDefault", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
    }

    static func render(to url: URL, size: Int = 1024) -> Bool {
        guard size > 0, let mark,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                     xRadius: 192, yRadius: 192).fill()
        // The SVG is also the default menu-bar glyph. Preserve its proportions.
        let extent: CGFloat = size <= 64 ? 884 : 840
        mark.draw(in: CGRect(x: (1024 - extent) / 2, y: (1024 - extent) / 2,
                             width: extent, height: extent), from: .zero,
                  operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func renderIconSet(to directory: URL) -> Bool {
        let variants: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        return variants.allSatisfy { name, size in
            render(to: directory.appendingPathComponent(name), size: size)
        }
    }
}
