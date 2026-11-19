import AppKit
import CoreGraphics

enum CaptureShape: String, CaseIterable, Codable {
    case rectangle, ellipse, circle

    var title: String {
        switch self {
        case .rectangle: "矩形选区"
        case .ellipse: "椭圆选区"
        case .circle: "圆形选区"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .ellipse: "oval"
        case .circle: "circle.dashed"
        }
    }

    func path(in rect: CGRect) -> NSBezierPath {
        self == .rectangle ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
    }

    func masked(_ image: CGImage) -> CGImage? {
        guard self != .rectangle else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addEllipse(in: frame)
        context.clip()
        context.draw(image, in: frame)
        return context.makeImage()
    }

    static func verifyMask() -> Bool {
        guard let context = CGContext(data: nil, width: 100, height: 60,
                                      bitsPerComponent: 8, bytesPerRow: 400,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        guard let source = context.makeImage(),
              let result = CaptureShape.ellipse.masked(source) else { return false }
        let pixels = NSBitmapImageRep(cgImage: result)
        let corner = pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
        let center = pixels.colorAt(x: 50, y: 30)?.alphaComponent ?? 0
        return result.width == 100 && result.height == 60 && corner < 0.05 && center > 0.95
    }
}
