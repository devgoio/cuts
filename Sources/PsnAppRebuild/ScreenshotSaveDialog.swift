import AppKit
import UniformTypeIdentifiers

@MainActor
enum ScreenshotSaveDialog {
    enum Outcome {
        case saved(URL)
        case cancelled
        case busy
        case failed(Error)
    }

    private final class NoOverwrite: NSObject, NSOpenSavePanelDelegate {
        func panel(_ sender: Any, validate url: URL) throws {
            if FileManager.default.fileExists(atPath: url.path) {
                throw NSError(domain: "Cuts.Save", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "同名文件已存在，请换一个文件名。",
                ])
            }
        }
    }

    private static var busy = false

    static func save(_ image: CGImage, topic: String, willPresent: () -> Void) async -> Outcome {
        guard !busy else { return .busy }
        busy = true
        defer { busy = false }
        let preferred = ImageSaveSettings.directory
        let preferredFormat = ImageSaveSettings.format
        let format = ImageSaveSettings.exportFormat(preferred: preferredFormat, width: image.width, height: image.height)
        var isDirectory: ObjCBool = false
        let available = FileManager.default.fileExists(atPath: preferred.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let directory = available ? preferred : ImageSaveSettings.defaultDirectory
        let panel = makePanel(directory: directory, prefix: ImageSaveSettings.prefix, format: format,
                              naming: ImageSaveSettings.naming, unavailable: !available,
                              formatFallback: format != preferredFormat)
        willPresent()
        NSApp.activate(ignoringOtherApps: true)
        CutsLog.write(.info, topic, "save dialog opened format=\(format.rawValue)")
        guard let url = await choose(panel) else {
            CutsLog.write(.info, topic, "save dialog cancelled")
            return .cancelled
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try ImageSaveSettings.save(image, to: url, format: format)
            }.value
            CutsLog.write(.info, topic, "image saved format=\(format.rawValue)")
            return .saved(url)
        } catch {
            CutsLog.failure(topic, "save image", error)
            return .failed(error)
        }
    }

    private static func makePanel(directory: URL, prefix: String, format: ImageSaveSettings.Format,
                                  naming: ImageSaveSettings.Naming, unavailable: Bool = false,
                                  formatFallback: Bool = false) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.prompt = "保存"
        panel.message = [
            formatFallback ? "图片超过 WebP 的尺寸上限，本次按原尺寸保存为 PNG。" : nil,
            unavailable ? "默认保存位置不可用，请选择其他目录。" : nil
        ].compactMap { $0 }.joined(separator: "\n")
        panel.nameFieldLabel = "文件名："
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [format == .png ? .png : .webP]
        panel.directoryURL = directory
        panel.nameFieldStringValue = ImageSaveSettings.previewFilename(in: directory, prefix: prefix,
                                                                       format: format, naming: naming)
        return panel
    }

    private static func choose(_ panel: NSSavePanel) async -> URL? {
        let validator = NoOverwrite()
        return await withCheckedContinuation { continuation in
            panel.delegate = validator
            panel.begin { response in
                withExtendedLifetime(validator) {
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }

    static func verifyLivePanel() async -> Bool {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("Cuts-Save-Panel-\(UUID())", isDirectory: true)
        do { try files.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { return false }
        defer { try? files.removeItem(at: folder) }
        let panel = makePanel(directory: folder, prefix: "Preview", format: .webp, naming: .sequence)
        guard panel.nameFieldStringValue == "Preview-0001.webp",
              panel.directoryURL?.standardizedFileURL.path == folder.standardizedFileURL.path,
              panel.allowedContentTypes == [.webP] else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let validator = NoOverwrite()
        panel.delegate = validator
        panel.begin { _ in }
        // Cocoa handles confirmation in a remote view; avoid invoking its
        // action methods from a synthetic process. The fixture exits after visibility.
        for _ in 0..<20 {
            if panel.isVisible {
                withExtendedLifetime(validator) {}
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
