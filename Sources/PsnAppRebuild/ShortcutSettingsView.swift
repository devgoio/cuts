import AppKit

@MainActor
final class ShortcutSettingsView: NSView {
    var preferences = ShortcutPreferences.saved { didSet { refresh() } }
    private var applied = ShortcutPreferences.saved
    private var commitButton: NSButton?
    var onApply: ((ShortcutPreferences) throws -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var showError: ((String) -> Void)?
    private var recording: ShortcutPreferences.Action?
    private var eventMonitor: Any?
    private var combos: [ShortcutPreferences.Action: NSButton] = [:]
    private var modes: [ShortcutPreferences.Action: NSButton] = [:]
    private var sliders: [ShortcutPreferences.Action: NSSlider] = [:]
    private var times: [ShortcutPreferences.Action: NSTextField] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        label("快捷键", x: 18, y: 345, width: 250, bold: true)
        label("支持按下触发或长按触发。长按模式下，短按保留原操作。", x: 18, y: 316, width: 406)
        for (index, action) in ShortcutPreferences.displayOrder.enumerated() {
            let y = 274 - CGFloat(index) * 75
            label(action.title, x: 18, y: y + 5, width: 110, bold: true)
            let combo = makeButton("", x: 138, y: y, width: 126, selector: #selector(record(_:)))
            combo.tag = Int(action.rawValue)
            combo.setAccessibilityLabel("\(action.title)组合键")
            combos[action] = combo
            let mode = makeButton("", x: 278, y: y, width: 143, selector: #selector(changeMode(_:)))
            mode.tag = Int(action.rawValue)
            mode.setAccessibilityLabel("\(action.title)触发方式")
            modes[action] = mode
            label("长按时长", x: 18, y: y - 28, width: 110)
            let slider = NSSlider(value: 600, minValue: 250, maxValue: 2000, target: self,
                                  action: #selector(changeDelay(_:)))
            slider.frame = CGRect(x: 138, y: y - 31, width: 207, height: 25)
            slider.tag = Int(action.rawValue)
            slider.isContinuous = true
            slider.setAccessibilityLabel("\(action.title)长按时长")
            addSubview(slider)
            sliders[action] = slider
            let time = label("", x: 349, y: y - 27, width: 70)
            time.alignment = .right
            times[action] = time
        }
        _ = makeButton("恢复默认", x: 18, y: 20, width: 97, selector: #selector(restoreDefaults))
        commitButton = makeButton("应用", x: 349, y: 20, width: 72, selector: #selector(applyChanges))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = CGRect(x: x, y: y, width: width, height: bold && y > 330 ? 24 : 20)
        field.font = .systemFont(ofSize: bold && y > 330 ? 17 : 12, weight: bold ? .semibold : .regular)
        field.textColor = bold ? LEStyle.text : LEStyle.secondary
        addSubview(field)
        return field
    }

    private func makeButton(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, selector: Selector) -> NSButton {
        let button = PointingButton(title: title, target: self, action: selector)
        button.frame = CGRect(x: x, y: y, width: width, height: 29)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        LEStyle.icon(button)
        CutsSettingsStyle.control(button)
        addSubview(button)
        return button
    }

    private func refresh() {
        CutsSettingsStyle.commit(commitButton, dirty: preferences != applied)
        for action in ShortcutPreferences.displayOrder {
            let value = preferences[action]
            combos[action]?.title = recording == action ? "请按组合键…" : value.chord.display
            modes[action]?.title = value.hold ? "触发：长按" : "触发：按下"
            CutsSettingsStyle.control(modes[action], selected: value.hold)
            sliders[action]?.isEnabled = value.hold
            sliders[action]?.integerValue = value.milliseconds
            times[action]?.stringValue = value.hold ? "\(value.milliseconds) ms" : "—"
        }
    }

    func load(_ preferences: ShortcutPreferences) {
        applied = preferences
        self.preferences = preferences
    }

    @objc private func record(_ sender: NSButton) {
        guard let action = ShortcutPreferences.Action(rawValue: UInt32(sender.tag)), let window else { return }
        if recording == action { endRecording(); return }
        endRecording()
        recording = action
        onRecordingChange?(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self, weak window] event in
            guard let self, window?.isKeyWindow == true else { return event }
            if event.keyCode == 53 { self.endRecording(); return nil }
            guard let chord = ShortcutChord.recorded(from: event) else { NSSound.beep(); return nil }
            self.preferences[action].chord = chord
            self.endRecording()
            return nil
        }
        refresh()
    }

    func endRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        guard recording != nil else { return }
        recording = nil
        onRecordingChange?(false)
        refresh()
    }

    @objc private func changeMode(_ sender: NSButton) {
        endRecording()
        guard let action = ShortcutPreferences.Action(rawValue: UInt32(sender.tag)) else { return }
        preferences[action].hold.toggle()
        CutsMotion.accent(in: sender)
    }

    @objc private func changeDelay(_ sender: NSSlider) {
        guard let action = ShortcutPreferences.Action(rawValue: UInt32(sender.tag)) else { return }
        preferences[action].milliseconds = Int((sender.doubleValue / 10).rounded()) * 10
    }

    @objc private func restoreDefaults() {
        endRecording()
        preferences = .defaults
    }

    @objc private func applyChanges() {
        endRecording()
        guard preferences != applied else { return }
        do {
            try preferences.validate()
            try onApply?(preferences)
            applied = preferences
            refresh()
        } catch { showError?(error.localizedDescription) }
    }

    static func verify() -> Bool {
        let page = ShortcutSettingsView(frame: CGRect(x: 0, y: 0, width: 440, height: 390))
        page.load(.defaults)
        guard let mode = page.modes[.capture], let slider = page.sliders[.capture],
              page.commitButton?.isEnabled == false,
              page.combos.count == 1, page.modes.count == 1,
              !slider.isEnabled, page.combos[.capture]?.title == "⌥2" else { return false }
        mode.performClick(nil)
        slider.doubleValue = 630
        page.changeDelay(slider)
        guard slider.isEnabled, page.times[.capture]?.stringValue == "630 ms",
              page.preferences[.capture].hold, page.preferences[.capture].milliseconds == 630,
              page.commitButton?.isEnabled == true else { return false }
        var requested: ShortcutPreferences?
        page.onApply = { requested = $0 }
        page.applyChanges()
        return requested?[.capture].milliseconds == 630 && page.commitButton?.isEnabled == false
    }
}
