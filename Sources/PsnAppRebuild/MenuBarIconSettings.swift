import AppKit
import CryptoKit

enum MenuBarIconSettings {
    enum Choice: Equatable {
        case standard
        case custom(name: String, data: Data)

        var description: String {
            switch self {
            case .standard: "默认剪切图标"
            case .custom(let name, _): "自定义 SVG · \(name)"
            }
        }
    }
    private static let enabledKey = "cuts.menuBarIcon.customEnabled"
    private static let nameKey = "cuts.menuBarIcon.customName"
    private static let maximumBytes = 1_000_000
    private static let originalToolboxHash = "45dfbf52d8dca9f9eb5e1af654f2120869c108f09fd77e4d86e5b2f989413662"
    private static var defaultURL: URL? {
        Bundle.main.url(forResource: "CutsDefault", withExtension: "svg")
    }

    private static var storedURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Cuts", isDirectory: true)
            .appendingPathComponent("MenuBarIcon.svg")
    }

    private static func isUncroppedToolbox(_ data: Data) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == originalToolboxHash
    }

    static var saved: Choice {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let data = try? Data(contentsOf: storedURL), !isUncroppedToolbox(data) else { return .standard }
        return .custom(name: UserDefaults.standard.string(forKey: nameKey) ?? "MenuBarIcon.svg", data: data)
    }

    static func image() -> NSImage? { image(for: saved, size: 16) }

    static func image(for choice: Choice, size: CGFloat) -> NSImage? {
        let image: NSImage?
        if case .custom(_, let data) = choice { image = NSImage(data: data) }
        else if let defaultURL { image = NSImage(contentsOf: defaultURL) }
        else {
            image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cuts")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        }
        // Menu-bar symbols are visually smaller than app icons; the cropped SVG has no built-in margin.
        image?.size = NSSize(width: size, height: size)
        image?.isTemplate = true
        return image
    }

    static func readSVG(from source: URL) throws -> Choice {
        guard source.pathExtension.lowercased() == "svg" else {
            throw NSError(domain: "Cuts.Icon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请选择 SVG 文件。"])
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumBytes else {
            throw NSError(domain: "Cuts.Icon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SVG 文件必须小于 1 MB。"])
        }
        let data = try Data(contentsOf: source)
        guard let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<svg", options: .caseInsensitive) != nil,
              xml.range(of: "<script", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              xml.range(of: "<foreignObject", options: .caseInsensitive) == nil,
              NSImage(data: data) != nil else {
            throw NSError(domain: "Cuts.Icon", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法安全读取这个 SVG 图标。"])
        }
        return isUncroppedToolbox(data) ? .standard : .custom(name: source.lastPathComponent, data: data)
    }

    static func save(_ choice: Choice) throws {
        guard case .custom(let name, let data) = choice else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            return
        }
        let target = storedURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        UserDefaults.standard.set(name, forKey: nameKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }
}
