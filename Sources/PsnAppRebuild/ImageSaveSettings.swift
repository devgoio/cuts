import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@_silgen_name("WebPEncodeLosslessRGBA")
private func webPEncodeLosslessRGBA(_ rgba: UnsafePointer<UInt8>, _ width: Int32,
                                    _ height: Int32, _ stride: Int32,
                                    _ output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int
@_silgen_name("WebPFree")
private func webPFree(_ pointer: UnsafeMutableRawPointer?)

enum ImageSaveSettings {
    enum Format: String, CaseIterable { case png, webp }
    enum Naming: String, CaseIterable { case timestamp, sequence }
    // WEBP_MAX_DIMENSION in libwebp's encode.h.
    static let maxWebPDimension = 16_383

    static func exportFormat(preferred: Format, width: Int, height: Int) -> Format {
        if preferred == .webp, max(width, height) > maxWebPDimension { return .png }
        return preferred
    }

    private static let directoryKey = "cuts.imageSaveDirectory"
    private static let prefixKey = "cuts.imageSavePrefix"
    private static let formatKey = "cuts.imageSaveFormat"
    private static let namingKey = "cuts.imageSaveNaming"

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: directoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultDirectory
    }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
    static var prefix: String { UserDefaults.standard.string(forKey: prefixKey) ?? "Cuts" }
    static var format: Format { Format(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .png }
    static var naming: Naming { Naming(rawValue: UserDefaults.standard.string(forKey: namingKey) ?? "") ?? .timestamp }

    static func configure(directory: URL, prefix: String, format: Format, naming: Naming) {
        UserDefaults.standard.set(directory.path, forKey: directoryKey)
        UserDefaults.standard.set(safePrefix(prefix), forKey: prefixKey)
        UserDefaults.standard.set(format.rawValue, forKey: formatKey)
        UserDefaults.standard.set(naming.rawValue, forKey: namingKey)
    }

    private static func safePrefix(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return String((cleaned.isEmpty ? "Cuts" : cleaned).prefix(48))
    }

    private static func nameStem(prefix: String, naming: Naming, date: Date) -> String {
        let base = safePrefix(prefix)
        guard naming == .timestamp else { return base }
        let timestamp = DateFormatter()
        timestamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(base)-\(timestamp.string(from: date))"
    }

    private static func candidate(in directory: URL, stem: String, format: Format,
                                  naming: Naming, index: Int) -> URL {
        let suffix = naming == .sequence ? String(format: "-%04d", index + 1)
            : index == 0 ? "" : "-\(index)"
        return directory.appendingPathComponent("\(stem)\(suffix).\(format.rawValue)")
    }

    static func previewFilename(in directory: URL, prefix: String, format: Format,
                                naming: Naming, date: Date = Date()) -> String {
        let stem = nameStem(prefix: prefix, naming: naming, date: date)
        for index in 0..<100_000 {
            let url = candidate(in: directory, stem: stem, format: format, naming: naming, index: index)
            if !FileManager.default.fileExists(atPath: url.path) { return url.lastPathComponent }
        }
        return candidate(in: directory, stem: stem, format: format,
                         naming: naming, index: 100_000).lastPathComponent
    }

    static func save(_ image: CGImage, to url: URL, format: Format) throws {
        guard url.pathExtension.lowercased() == format.rawValue else {
            throw NSError(domain: "Cuts.Save", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "文件名扩展名需为 .\(format.rawValue)。"])
        }
        try encode(image, format: format).write(to: url, options: .withoutOverwriting)
    }

    static func encode(_ image: CGImage, format: Format) throws -> Data {
        if format == .png {
            let data = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { return data as Data }
            }
            throw NSError(domain: "Cuts.Save", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败。"])
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0, exportFormat(preferred: .webp, width: width, height: height) == .webp else {
            throw NSError(domain: "Cuts.Save", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "图片尺寸超出 WebP 编码限制。"])
        }
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw NSError(domain: "Cuts.Save", code: 5,
                                       userInfo: [NSLocalizedDescriptionKey: "无法转换 WebP 像素。"]) }
        for pixel in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[pixel + 3])
            guard alpha > 0 && alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[pixel + channel] = UInt8(min(255, (Int(pixels[pixel + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let length = pixels.withUnsafeBufferPointer { buffer in
            webPEncodeLosslessRGBA(buffer.baseAddress!, Int32(width), Int32(height), Int32(stride), &output)
        }
        guard length > 0, let output else {
            throw NSError(domain: "Cuts.Save", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "WebP 编码失败。"])
        }
        defer { webPFree(output) }
        return Data(bytes: output, count: length)
    }

    static func verifySynthetic() -> Bool {
        guard exportFormat(preferred: .webp, width: 30, height: maxWebPDimension) == .webp,
              exportFormat(preferred: .webp, width: maxWebPDimension + 1, height: 30) == .png,
              exportFormat(preferred: .webp, width: 30, height: maxWebPDimension + 1) == .png,
              let longImage = CGContext(data: nil, width: 8, height: maxWebPDimension + 1,
                                        bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage(),
              (try? encode(longImage, format: .webp)) == nil,
              let longPNG = try? encode(longImage, format: .png),
              let source = CGImageSourceCreateWithData(longPNG as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil)?.height == maxWebPDimension + 1 else { return false }
        guard let context = CGContext(data: nil, width: 8, height: 8,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
        guard let image = context.makeImage(),
              let png = try? encode(image, format: .png), png.starts(with: [137, 80, 78, 71]),
              let webp = try? encode(image, format: .webp), webp.count > 12 else { return false }
        guard webp[0..<4].elementsEqual("RIFF".utf8),
              webp[8..<12].elementsEqual("WEBP".utf8),
              let webPSource = CGImageSourceCreateWithData(webp as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(webPSource, 0, nil),
              decoded.width == 8, decoded.height == 8 else { return false }
        var decodedPixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let alphaPreserved = decodedPixels.withUnsafeMutableBytes { raw -> Bool in
            guard let bitmap = CGContext(data: raw.baseAddress, width: 8, height: 8,
                                         bitsPerComponent: 8, bytesPerRow: 32,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard alphaPreserved, decodedPixels[3] == 0,
              decodedPixels[(3 * 8 + 3) * 4 + 3] == 255 else { return false }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuts-save-test-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { return false }
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("Cuts-0001.webp")
        let edited = folder.appendingPathComponent("Renamed Export.png")
        do {
            guard previewFilename(in: folder, prefix: "Cuts", format: .webp, naming: .sequence) == first.lastPathComponent
            else { return false }
            try save(image, to: first, format: .webp)
            try save(image, to: edited, format: .png)
            guard previewFilename(in: folder, prefix: "Cuts", format: .webp, naming: .sequence) == "Cuts-0002.webp",
                  try Data(contentsOf: first) == webp, try Data(contentsOf: edited) == png else { return false }
            do {
                try save(image, to: edited, format: .png)
                return false
            } catch {
                return try Data(contentsOf: edited) == png
            }
        } catch { return false }
    }
}
