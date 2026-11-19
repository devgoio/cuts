import AppKit

@MainActor
final class SaveSettingsPanel: NSObject {
    private let panel: NSPanel
    private let directoryLabel = NSTextField(labelWithString: "")
    private let prefixField = SingleLineInputField(alignment: .left)
    private var directory = ImageSaveSettings.directory
    private var format = ImageSaveSettings.format
    private var naming = ImageSaveSettings.naming
    private var choices: [String: NSButton] = [:]

    override init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 470, height: 312),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        setup()
    }

    func show() {
        directory = ImageSaveSettings.directory
        format = ImageSaveSettings.format
        naming = ImageSaveSettings.naming
        prefixField.stringValue = ImageSaveSettings.prefix
        updateChoices()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func setup() {
        panel.title = "截图保存设置"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = LEStyle.container.withAlphaComponent(0.82)
        panel.appearance = NSAppearance(named: .darkAqua)
        guard let content = panel.contentView else { return }
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur, positioned: .below, relativeTo: nil)
        let tint = NSView(frame: content.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = LEStyle.container.withAlphaComponent(0.85).cgColor
        content.addSubview(tint, positioned: .above, relativeTo: blur)

        label("截图保存设置", x: 22, y: 264, width: 310, size: 16, parent: content)
        label("保存到", x: 22, y: 222, width: 80, parent: content)
        directoryLabel.frame = CGRect(x: 22, y: 191, width: 345, height: 26)
        directoryLabel.textColor = LEStyle.secondary
        directoryLabel.font = .systemFont(ofSize: 12)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(directoryLabel)
        let choose = button("选择目录…", x: 366, y: 188, width: 84, parent: content,
                            action: #selector(chooseDirectory))
        choose.setAccessibilityLabel("选择截图保存目录")

        label("文件名前缀", x: 22, y: 151.5, width: 92, parent: content, centered: true)
        prefixField.frame = CGRect(x: 120, y: 147, width: 330, height: 28)
        prefixField.font = .systemFont(ofSize: 12)
        prefixField.backgroundColor = LEStyle.elevated
        prefixField.textColor = LEStyle.text
        content.addSubview(prefixField)

        label("命名", x: 22, y: 112, width: 72, parent: content)
        let timestamp = button("时间戳", x: 120, y: 104, width: 98, parent: content,
                               action: #selector(choiceClicked(_:)))
        timestamp.identifier = NSUserInterfaceItemIdentifier("timestamp")
        choices["timestamp"] = timestamp
        let sequence = button("顺序编号", x: 226, y: 104, width: 98, parent: content,
                              action: #selector(choiceClicked(_:)))
        sequence.identifier = NSUserInterfaceItemIdentifier("sequence")
        choices["sequence"] = sequence

        label("格式", x: 22, y: 71, width: 72, parent: content)
        let png = button("PNG", x: 120, y: 63, width: 98, parent: content,
                         action: #selector(choiceClicked(_:)))
        png.identifier = NSUserInterfaceItemIdentifier("png")
        choices["png"] = png
        let webp = button("WebP", x: 226, y: 63, width: 98, parent: content,
                          action: #selector(choiceClicked(_:)))
        webp.identifier = NSUserInterfaceItemIdentifier("webp")
        choices["webp"] = webp

        let save = button("保存设置", x: 352, y: 17, width: 98, parent: content,
                          action: #selector(saveSettings))
        save.layer?.backgroundColor = LEStyle.primary.cgColor
        updateChoices()
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                       size: CGFloat = 12, parent: NSView, centered: Bool = false) {
        let field = centered ? SingleLineInputField.rowLabel(text) : NSTextField(labelWithString: text)
        field.frame = CGRect(x: x, y: y, width: width, height: size + 7)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = LEStyle.text
        parent.addSubview(field)
    }

    @discardableResult
    private func button(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat,
                        parent: NSView, action: Selector) -> NSButton {
        let button = PointingButton(title: title, target: self, action: action)
        button.frame = CGRect(x: x, y: y, width: width, height: 29)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = LEStyle.elevated.cgColor
        button.contentTintColor = LEStyle.text
        parent.addSubview(button)
        return button
    }

    private func updateChoices() {
        directoryLabel.stringValue = directory.path
        directoryLabel.toolTip = directory.path
        for (key, button) in choices {
            let active = key == format.rawValue || key == naming.rawValue
            button.layer?.backgroundColor = active ? LEStyle.selected.cgColor : LEStyle.elevated.cgColor
            button.contentTintColor = active ? .white : LEStyle.text
        }
    }

    @objc private func choiceClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        if let choice = ImageSaveSettings.Format(rawValue: raw) { format = choice }
        if let choice = ImageSaveSettings.Naming(rawValue: raw) { naming = choice }
        updateChoices()
    }

    @objc private func chooseDirectory() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = directory
        chooser.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = chooser.url else { return }
            self?.directory = url
            self?.updateChoices()
        }
    }

    @objc private func saveSettings() {
        ImageSaveSettings.configure(directory: directory, prefix: prefixField.stringValue,
                                    format: format, naming: naming)
        panel.close()
        ActionFeedback.show("截图保存设置已更新")
    }
}
