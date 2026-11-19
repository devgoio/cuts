import Foundation

enum CutsLog {
    enum Level: Int, CaseIterable {
        case error = 0, warning, info, debug

        var title: String {
            switch self {
            case .error: "错误"
            case .warning: "警告"
            case .info: "信息"
            case .debug: "调试"
            }
        }

        var tag: String {
            switch self {
            case .error: "ERROR"
            case .warning: "WARN"
            case .info: "INFO"
            case .debug: "DEBUG"
            }
        }
    }

    private static let enabledKey = "cuts.diagnosticLogs.enabled"
    private static let levelKey = "cuts.diagnosticLogs.level"
    private static let isDiagnosticCommand = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    private static let writer = DispatchQueue(label: "com.psn.Cuts.diagnosticLog", qos: .utility)
    private static let date: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let session = UUID().uuidString.prefix(8)
    static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Cuts", isDirectory: true)

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var level: Level {
        get { (UserDefaults.standard.object(forKey: levelKey) as? Int).flatMap(Level.init(rawValue:)) ?? .info }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: levelKey) }
    }

    static func write(_ severity: Level, _ topic: String, _ event: @autoclosure () -> String) {
        guard !isDiagnosticCommand, permits(severity, enabled: enabled, level: level) else { return }
        let message = event()
        let timestamp = Date()
        writer.async {
            guard permits(severity, enabled: enabled, level: level) else { return }
            let line = "\(date.string(from: timestamp)) [\(severity.tag)] [\(session)] \(topic) \(message)\n"
            try? append(Data(line.utf8), directory: directory, limit: 1_048_576)
        }
    }

    static func failure(_ topic: String, _ operation: String, _ error: Error) {
        let info = error as NSError
        write(.error, topic, "\(operation) failed domain=\(info.domain) code=\(info.code)")
    }

    private static let filenames = ["Cuts.log", "Cuts.1.log", "Cuts.2.log"]

    static func clear() async throws {
        try await performIO { try clear(in: directory) }
    }

    private static func clear(in target: URL) throws {
        let files = FileManager.default
        for name in filenames {
            let url = target.appendingPathComponent(name)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
    }

    static func exportDiagnosticSummary(to url: URL) async throws {
        try await performIO {
            let content = filenames.reversed().compactMap { name in
                try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            }.joined(separator: "\n")
            let summary = diagnosticSummary(content)
            try Data(summary.utf8).write(to: url, options: .atomic)
        }
    }

    private static func performIO(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writer.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    // Never copy free-form messages or session IDs into a shareable report.
    private static func diagnosticSummary(_ content: String) -> String {
        let topics: Set<String> = ["app", "capture", "clipboard", "editor", "longCapture", "menu", "mouse",
                                   "ocr", "pin", "settings", "shortcuts"]
        let levels: Set<String> = ["[ERROR]", "[WARN]", "[INFO]", "[DEBUG]"]
        let rows = content.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: " ", maxSplits: 4)
            guard fields.count == 5, date.date(from: String(fields[0])) != nil,
                  levels.contains(String(fields[1])), topics.contains(String(fields[3])) else { return nil }
            let suffix = fields[4].split(separator: " ").last.map(String.init) ?? ""
            let errorCode = suffix.hasPrefix("code=") ? Int(suffix.dropFirst(5)) : nil
            return "\(fields[0]) \(fields[1]) \(fields[3])" + (errorCode.map { " code=\($0)" } ?? "")
        }
        return (["Cuts \(CutsVersion.value) · 脱敏诊断", "仅保留时间、级别、功能和错误代码。"] + rows).joined(separator: "\n") + "\n"
    }

    private static func permits(_ severity: Level, enabled: Bool, level: Level) -> Bool {
        enabled && severity.rawValue <= level.rawValue
    }

    private static func append(_ data: Data, directory: URL, limit: Int) throws {
        let files = FileManager.default
        let active = directory.appendingPathComponent("Cuts.log")
        let previous = directory.appendingPathComponent("Cuts.1.log")
        let older = directory.appendingPathComponent("Cuts.2.log")
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let exists = files.fileExists(atPath: active.path)
        let size = (try? active.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if exists && size + data.count > limit {
            if files.fileExists(atPath: older.path) { try files.removeItem(at: older) }
            if files.fileExists(atPath: previous.path) { try files.moveItem(at: previous, to: older) }
            try files.moveItem(at: active, to: previous)
        }
        if !files.fileExists(atPath: active.path) {
            files.createFile(atPath: active.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: active)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func verifyTemporaryLog() -> Bool {
        guard !permits(.error, enabled: false, level: .debug),
              !permits(.info, enabled: true, level: .warning),
              permits(.error, enabled: true, level: .warning),
              !permits(.debug, enabled: true, level: .info),
              permits(.debug, enabled: true, level: .debug) else { return false }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("CutsLog-Test-\(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: directory) }
        do {
            for sample in ["one\n", "two\n", "three\n", "four\n"] {
                try append(Data(sample.utf8), directory: directory, limit: 7)
            }
            let expected = ["Cuts.log": "four\n", "Cuts.1.log": "three\n", "Cuts.2.log": "two\n"]
            let rotated = try files.contentsOfDirectory(atPath: directory.path).count == 3
                && expected.allSatisfy { filename, contents in
                    (try? String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8)) == contents
                }
            let summary = diagnosticSummary("2026-11-19T11:24:22.338Z [ERROR] [secret-session] capture /private/file code=19\n")
            try clear(in: directory)
            let empty = try files.contentsOfDirectory(atPath: directory.path).isEmpty
            return rotated && summary.contains("[ERROR] capture code=19") && !summary.contains("secret-session")
                && !summary.contains("/private/file") && empty
        } catch { return false }
    }
}
