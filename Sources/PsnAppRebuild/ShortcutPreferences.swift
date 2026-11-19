import AppKit
import Carbon
import CoreGraphics

struct ShortcutChord: Codable, Equatable {
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    static let paste = ShortcutChord(kVK_ANSI_V, .maskCommand, "V")
    let keyCode: UInt16
    let modifiers: UInt64
    let key: String

    init(_ keyCode: Int, _ flags: CGEventFlags, _ key: String) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = flags.intersection(Self.relevant).rawValue
        self.key = key
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }
    var display: String {
        [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined() + key
    }
    var carbonFlags: UInt32 {
        [(CGEventFlags.maskControl, controlKey), (.maskAlternate, optionKey),
         (.maskShift, shiftKey), (.maskCommand, cmdKey)].reduce(0) { value, entry in
            flags.contains(entry.0) ? value | UInt32(entry.1) : value
        }
    }

    func matches(code: Int64, flags: CGEventFlags) -> Bool {
        code == Int64(keyCode) && flags.intersection(Self.relevant) == self.flags
    }

    func conflicts(with other: ShortcutChord) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    static func recorded(from event: NSEvent) -> ShortcutChord? {
        var flags: CGEventFlags = []
        for (source, destination) in [(NSEvent.ModifierFlags.control, CGEventFlags.maskControl),
                                      (.option, .maskAlternate), (.shift, .maskShift), (.command, .maskCommand)]
        where event.modifierFlags.contains(source) { flags.insert(destination) }
        guard !flags.isEmpty, !event.isARepeat else { return nil }
        let fixed: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let printable = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = fixed[event.keyCode] ?? printable.flatMap { value in
            value.isEmpty || value.unicodeScalars.contains(where: { $0.value < 32 || (0xF700...0xF8FF).contains($0.value) })
                ? nil : String(value.uppercased().prefix(5))
        } ?? "键 \(event.keyCode)"
        return ShortcutChord(Int(event.keyCode), flags, key)
    }
}

struct ShortcutPreferences: Codable, Equatable {
    enum Action: UInt32, Codable, CaseIterable {
        case capture = 1, clipboard = 2, legacyLongCapture = 4

        var title: String {
            switch self {
            case .capture: "区域截图"
            case .clipboard: "剪贴板历史"
            case .legacyLongCapture: "滚动长截图"
            }
        }
    }

    struct Binding: Codable, Equatable {
        let action: Action
        var chord: ShortcutChord
        var hold = false
        var milliseconds = 600
        var display: String { chord.display + (hold ? " · 长按 \(milliseconds) ms" : "") }
    }

    var bindings: [Binding]
    static let defaultClipboardHoldMilliseconds = 300
    static let defaults = Self(bindings: [
        Binding(action: .capture, chord: ShortcutChord(kVK_ANSI_2, .maskAlternate, "2")),
    ])
    static let displayOrder: [Action] = [.capture]
    private static let key = "cuts.shortcuts"

    static var saved: Self {
        load(UserDefaults.standard.data(forKey: key))
    }

    private static func load(_ data: Data?) -> Self {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults }
        // Older versions stored the two now-removed hotkeys alongside capture.
        value.bindings.removeAll { !displayOrder.contains($0.action) }
        guard (try? value.validate()) != nil else { return .defaults }
        return value
    }

    static func clipboardHold(milliseconds: Int) -> Binding {
        Binding(action: .clipboard, chord: .paste, hold: true, milliseconds: milliseconds)
    }

    static func clipboardShortcutLabel(milliseconds: Int) -> String { "\(ShortcutChord.paste.display)·\(milliseconds)" }

    func store() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    subscript(action: Action) -> Binding {
        get { bindings.first(where: { $0.action == action }) ?? Self.defaults.bindings.first(where: { $0.action == action })! }
        set {
            if let index = bindings.firstIndex(where: { $0.action == action }) { bindings[index] = newValue }
        }
    }

    func validate() throws {
        guard bindings.map(\.action) == Self.displayOrder,
              let binding = bindings.first,
              binding.chord.modifiers != 0, (250...2000).contains(binding.milliseconds) else {
            throw Self.failure("快捷键需要至少一个修饰键，长按时长需在 250–2000 ms。")
        }
        if binding.chord.conflicts(with: .paste) {
            throw Self.failure("⌘V 已用于普通粘贴和剪贴板长按，请为此功能选另一个组合。")
        }
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "Cuts.Shortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func verify() -> Bool {
        var candidate = Self.defaults
        candidate[.capture].chord = ShortcutChord(kVK_ANSI_X, .maskCommand, "X")
        candidate[.capture].hold = true
        guard (try? candidate.validate()) != nil,
              candidate[.capture].display == "⌘X · 长按 600 ms",
              candidate[.capture].chord.matches(code: Int64(kVK_ANSI_X), flags: .maskCommand),
              !candidate[.capture].chord.matches(code: Int64(kVK_ANSI_X), flags: [.maskCommand, .maskShift])
        else { return false }
        var legacy = candidate
        legacy.bindings.append(.init(action: .clipboard, chord: ShortcutChord(kVK_ANSI_C, [.maskCommand, .maskShift], "C")))
        legacy.bindings.append(.init(action: .legacyLongCapture, chord: ShortcutChord(kVK_ANSI_S, [.maskCommand, .maskAlternate], "S"), hold: true))
        guard load(try? JSONEncoder().encode(legacy)) == candidate,
              (try? legacy.validate()) == nil,
              clipboardHold(milliseconds: defaultClipboardHoldMilliseconds).display == "⌘V · 长按 300 ms",
              clipboardShortcutLabel(milliseconds: defaultClipboardHoldMilliseconds) == "⌘V·300",
              clipboardShortcutLabel(milliseconds: 500) == "⌘V·500" else { return false }
        candidate[.capture].chord = .paste
        return (try? candidate.validate()) == nil
    }
}
