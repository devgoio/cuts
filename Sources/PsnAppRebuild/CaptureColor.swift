import CoreGraphics
import Foundation

enum CaptureColor {
    /// Read the frozen display image, without sampling the dimmed selection overlay.
    static func hex(in image: CGImage, at point: CGPoint, bounds: CGRect) -> String? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let x = Int((point.x - bounds.minX) / bounds.width * CGFloat(image.width))
        let y = image.height - 1 - Int((point.y - bounds.minY) / bounds.height * CGFloat(image.height))
        guard x >= 0, x < image.width, y >= 0, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba: [UInt8] = [0, 0, 0, 0]
        let drew = rgba.withUnsafeMutableBytes { bytes -> Bool in
            let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space, bitmapInfo: flags) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew, rgba[3] > 0 else { return nil }
        func channel(_ index: Int) -> Int {
            min(255, (Int(rgba[index]) * 255 + Int(rgba[3]) / 2) / Int(rgba[3]))
        }
        return String(format: "#%02X%02X%02X", channel(0), channel(1), channel(2))
    }
}
