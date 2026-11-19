import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageReader {
    // Accepted bytes on disk and pixels allocated by a decoder are different limits.
    static let pixelBudget = 48_000_000
    enum Failure: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这张图片"
            case .tooLarge: "图片像素过多，未打开标注。仍可从历史复制原图。"
            }
        }
    }

    static func withinBudget(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= pixelBudget / height
    }

    static func decode(_ url: URL, maximumSide: Int? = nil) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int else { throw Failure.unreadable }
        guard withinBudget(width: width, height: height) else { throw Failure.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumSide ?? max(width, height), max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw Failure.unreadable }
        return image
    }

    static func thumbnail(_ url: URL) -> Data? {
        let data = NSMutableData()
        guard let image = try? decode(url, maximumSide: 160),
              let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}
