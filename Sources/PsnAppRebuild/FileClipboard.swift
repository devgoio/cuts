import AppKit

enum FileClipboard {
    static let filenameList = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func paths(in pasteboard: NSPasteboard) -> [String] {
        func path(of url: URL) -> String? {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return ((url as NSURL).filePathURL ?? url).standardizedFileURL.path
        }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        let objectPaths = objects.compactMap { ($0 as? URL).flatMap(path(of:)) }
        let urlPaths = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            for type: NSPasteboard.PasteboardType in [.fileURL, .URL] {
                if let value = item.string(forType: type), let url = URL(string: value), let file = path(of: url) {
                    return file
                }
            }
            return nil
        }
        let legacyPaths = (pasteboard.propertyList(forType: filenameList) as? [String] ?? []).compactMap { value in
            value.hasPrefix("/") ? path(of: URL(fileURLWithPath: value)) : nil
        }
        var seen = Set<String>()
        return (objectPaths + urlPaths + legacyPaths).filter { seen.insert($0).inserted }
    }

    static func write(_ paths: [String], to pasteboard: NSPasteboard) -> Bool {
        guard !paths.isEmpty else { return false }
        var items: [NSPasteboardItem] = []
        for path in paths {
            let file = URL(fileURLWithPath: path)
            let item = NSPasteboardItem()
            guard item.setString(file.absoluteString, forType: .fileURL),
                  item.setString(file.absoluteString, forType: .URL) else { return false }
            item.setString(file.lastPathComponent, forType: NSPasteboard.PasteboardType("public.url-name"))
            items.append(item)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return false }
        // AppKit accepts the legacy flavor on the board, not on an item, which
        // accepts UTI strings only. Adding it here retains all modern URL items.
        if !pasteboard.setPropertyList(paths, forType: filenameList) {
            CutsLog.write(.warning, "clipboard", "legacy file-list format unavailable; restored file URLs")
        }
        return true
    }
}
