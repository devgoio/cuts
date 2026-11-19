import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsPanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private static let pageNames = ["截图", "默认", "快捷键", "剪贴板", "鼠标", "通用", "日志"]
    static func writePreview(to url: URL, page name: String, dirty: Bool = false, editing: Bool = false) -> Bool {
        let settings = SettingsPanel()
        let path = name.split(separator: "/", maxSplits: 1).map(String.init)
        let page = path.first ?? name
        settings.selectPage(page == "标注默认" ? "默认" : page)
        if path.count == 2, page == "默认" || page == "标注默认" {
            settings.annotationPage?.selectPreviewTab(path[1], example: dirty)
        }
        settings.updateChoices()
        settings.updateMouseControls()
        settings.refreshRuntimeState()
        if dirty, name == "鼠标", let toggle = settings.mouseButtons["vertical"] { settings.toggleMouseOption(toggle) }
        if editing {
            let field: SingleLineInputField?
            switch name {
            case "截图": field = settings.prefixField
            case "剪贴板": field = settings.holdDelayField
            case "鼠标": field = settings.mouseSpeedField
            default: field = nil
            }
            if let field {
                settings.panel.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }
        settings.panel.displayIfNeeded()
        guard let content = settings.panel.contentView,
              let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func verifyOffscreen() -> Bool {
        let settings = SettingsPanel()
        guard ShortcutSettingsView.verify(), AnnotationDefaults.verify(), SingleLineInputField.verifyOffscreen(),
              settings.prefixField.alignment == .left,
              [settings.holdDelayField, settings.mouseSpeedField].allSatisfy({ $0.alignment == .center && $0.lineIsCentered() }),
              settings.pages.count == Self.pageNames.count, settings.navigation.count == Self.pageNames.count,
              settings.navigation.values.allSatisfy({ $0 is PointingButton }),
              settings.pages["通用"]?.subviews.contains(where: {
                  ($0 as? PointingButton)?.title == "导入 SVG…"
              }) == true,
              settings.logLevelButtons.count == CutsLog.Level.allCases.count,
              settings.choices.count == 4, settings.mouseButtons.count == 4,
              settings.pages["通用"]?.subviews.contains(where: {
                  ($0 as? NSTextField)?.stringValue == CutsVersion.label
              }) == true else { return false }
        settings.prefixField.stringValue = "Preview/Test"
        settings.format = .webp
        settings.naming = .sequence
        settings.updateFilenamePreview()
        guard settings.filenamePreview.stringValue.hasPrefix("Preview-Test-"),
              settings.filenamePreview.stringValue.hasSuffix(".webp") else { return false }
        guard let content = settings.panel.contentView,
              !settings.panel.isOpaque,
              let backdrop = content.subviews.compactMap({ $0 as? NSVisualEffectView }).first,
              backdrop.blendingMode == .behindWindow, backdrop.alphaValue < 1,
              content.layer?.borderColor == LEStyle.primary.withAlphaComponent(0.52).cgColor,
              content.subviews.contains(where: { $0.layer?.backgroundColor == LEStyle.container.withAlphaComponent(0.25).cgColor }),
              settings.pages.values.allSatisfy({ $0.layer?.backgroundColor == LEStyle.elevated.withAlphaComponent(0.27).cgColor }),
              settings.panel.titleVisibility == .hidden,
              !content.subviews.contains(where: { ($0 as? NSTextField)?.stringValue == "Cuts 设置" }),
              let firstNavigation = settings.navigation["截图"],
              let sidebar = firstNavigation.superview,
              sidebar.layer?.backgroundColor == LEStyle.elevated.withAlphaComponent(0.30).cgColor,
              (30...44).contains(content.bounds.maxY - sidebar.frame.maxY),
              settings.clipboardShortcutLabel?.stringValue.contains("⌘V·300") == true else { return false }
        for name in Self.pageNames {
            settings.selectPage(name)
            guard settings.pages[name]?.isHidden == false,
                  settings.pages.filter({ $0.key != name }).allSatisfy({ $0.value.isHidden }) else { return false }
        }
        settings.mouseSettings = MouseSettings()
        settings.savedMouse = settings.mouseSettings
        settings.mouseSpeedField.stringValue = "1.0"
        settings.updateMouseControls()
        settings.updateCommitStates()
        var appliedMouse: MouseSettings?
        settings.onMouseChange = { appliedMouse = $0 }
        guard let reverseButton = settings.mouseButtons["vertical"], let apply = settings.commits["mouse"],
              !apply.isEnabled, let unchanged = apply.layer?.backgroundColor,
              unchanged == CutsSettingsStyle.restingCommit.cgColor else { return false }
        settings.toggleMouseOption(reverseButton)
        guard appliedMouse == nil, apply.isEnabled, apply.layer?.backgroundColor != unchanged else { return false }
        settings.toggleMouseOption(reverseButton)
        guard !apply.isEnabled, apply.layer?.backgroundColor == unchanged else { return false }
        settings.toggleMouseOption(reverseButton)
        apply.performClick(nil)
        guard appliedMouse?.reverseVertical == true,
              settings.mouseSettings.reverseVertical,
              reverseButton.title == "已开启", !apply.isEnabled,
              apply.layer?.backgroundColor == unchanged else { return false }
        settings.panel.orderFrontRegardless()
        defer { settings.panel.orderOut(nil) }
        for name in Self.pageNames {
            settings.selectPage(name)
            guard let page = settings.pages[name], !page.isHidden else { return false }
            guard (page.layer?.animation(forKey: "cuts.arrival.transform") != nil) == CutsMotion.enabled else {
                print("settings page motion missing or not reduced: \(name)")
                return false
            }
        }
        settings.selectPage("默认")
        settings.panel.makeKey()
        guard settings.annotationPage?.verifyPreview() == true else { return false }
        settings.panel.orderOut(nil)
        settings.show()
        settings.prefixField.stringValue = "Pending test name"
        settings.panel.close()
        settings.show()
        guard settings.prefixField.stringValue == "Pending test name" else { return false }
        return true
    }

    private let panel: NSPanel
    private var hasBeenShown = false
    private var pages: [String: NSView] = [:]
    private var navigation: [String: NSButton] = [:]
    private var logToggle: NSButton?
    private var logLevelButtons: [CutsLog.Level: NSButton] = [:]
    private var shortcutPage: ShortcutSettingsView?
    private var annotationPage: AnnotationDefaultsView?
    private var selectedPage = "截图"
    private let directoryLabel = NSTextField(labelWithString: "")
    private let prefixField = SingleLineInputField(alignment: .left)
    private let filenamePreview = NSTextField(labelWithString: "")
    private let holdDelayField = SingleLineInputField()
    private let holdButton = PointingButton()
    private var clipboardShortcutLabel: NSTextField?
    private let loginButton = PointingButton()
    private let loginStatus = NSTextField(labelWithString: "")
    private let iconStatus = NSTextField(labelWithString: "")
    private let iconPreview = NSImageView()
    private let mouseSpeedField = SingleLineInputField()
    private let pointerSpeedSlider = NSSlider()
    private let pointerSpeedValue = NSTextField(labelWithString: "")
    private let mouseRuntimeStatus = NSTextField(labelWithString: "")
    private var mouseRetry: NSButton?
    private var mouseButtons: [String: NSButton] = [:]
    private var choices: [String: NSButton] = [:]
    private var directory = ImageSaveSettings.directory
    private var format = ImageSaveSettings.format
    private var naming = ImageSaveSettings.naming
    private var commits: [String: NSButton] = [:]
    private var savedHoldEnabled = true
    private var savedHoldDelay = ShortcutPreferences.defaultClipboardHoldMilliseconds
    private var savedMouse = MouseSettings.saved
    private var savedPointerStep = 0
    private var savedLogin = false
    private var loginDraft = false
    private var savedIcon = MenuBarIconSettings.saved
    private var iconDraft = MenuBarIconSettings.saved
    private var logsEnabled = CutsLog.enabled
    private var logLevel = CutsLog.level

    var onHoldChange: ((Bool, Int) throws -> Void)?
    var onShortcutsChange: ((ShortcutPreferences) throws -> Void)?
    var onShortcutRecordingChange: ((Bool) -> Void)?
    var shortcutPreferences = ShortcutPreferences.saved
    var onIconChange: (() -> Void)?
    var onMouseChange: ((MouseSettings) throws -> Void)?
    var onMouseRetry: (() throws -> Void)?
    var holdEnabled = true
    var holdMilliseconds = ShortcutPreferences.defaultClipboardHoldMilliseconds
    var mouseSettings = MouseSettings.saved
    var mouseMonitorActive = false
    var lastScrollResult: MouseEventMonitor.ScrollResult?
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 628, height: 444),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        setup()
        loadDrafts()
    }

    func show() {
        if panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if !hasBeenShown {
            loadDrafts()
            hasBeenShown = true
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let content = panel.contentView { CutsMotion.appear(content, .window, from: CGPoint(x: 0, y: -7)) }
    }

    private func loadDrafts() {
        annotationPage?.reload()
        shortcutPage?.load(shortcutPreferences)
        directory = ImageSaveSettings.directory
        format = ImageSaveSettings.format
        naming = ImageSaveSettings.naming
        prefixField.stringValue = ImageSaveSettings.prefix
        holdDelayField.stringValue = String(holdMilliseconds)
        savedHoldEnabled = holdEnabled
        savedHoldDelay = holdMilliseconds
        mouseSettings = MouseSettings.saved
        savedMouse = mouseSettings
        mouseSpeedField.stringValue = String(format: "%.1f", mouseSettings.speed)
        syncPointerSpeedSlider()
        savedPointerStep = pointerStep
        savedLogin = LoginLaunchSettings.status == .enabled || LoginLaunchSettings.status == .requiresApproval
        loginDraft = savedLogin
        savedIcon = MenuBarIconSettings.saved
        iconDraft = savedIcon
        logsEnabled = CutsLog.enabled
        logLevel = CutsLog.level
        refreshRuntimeState()
        updateChoices()
        updateMouseControls()
        selectPage(selectedPage)
    }

    func refreshRuntimeState() {
        holdButton.title = holdEnabled ? "已开启" : "已关闭"
        CutsSettingsStyle.control(holdButton, selected: holdEnabled)
        let display = ShortcutPreferences.clipboardShortcutLabel(milliseconds: savedHoldDelay)
        clipboardShortcutLabel?.stringValue = savedHoldEnabled
            ? "历史记录：文字、图片和文件；\(display) 打开。"
            : "历史记录：文字、图片和文件；可从菜单栏打开。"
        refreshGeneral()
        refreshMouseRuntimeState()
        updateCommitStates()
    }

    private func refreshGeneral() {
        if loginDraft != savedLogin {
            loginButton.title = loginDraft ? "已开启" : "已关闭"
            loginStatus.stringValue = "应用后更新登录启动"
        } else { switch LoginLaunchSettings.status {
        case .enabled:
            loginButton.title = "已开启"
            loginStatus.stringValue = "Cuts 会在登录 Mac 后自动运行"
        case .requiresApproval:
            loginButton.title = "等待批准"
            loginStatus.stringValue = "请在系统设置的登录项中允许 Cuts"
        case .notRegistered, .notFound:
            loginButton.title = "已关闭"
            loginStatus.stringValue = "默认不随系统启动"
        @unknown default:
            loginButton.title = "检查状态"
            loginStatus.stringValue = "无法确认登录项状态"
        } }
        CutsSettingsStyle.control(loginButton, selected: loginDraft)
        iconStatus.stringValue = iconDraft.description
        iconPreview.image = MenuBarIconSettings.image(for: iconDraft, size: 56)
    }

    func refreshMouseRuntimeState() {
        if mouseMonitorActive {
            switch lastScrollResult {
            case .modified: mouseRuntimeStatus.stringValue = "滚轮处理：已收到滚动，并应用当前设置"
            case .preservedGesture: mouseRuntimeStatus.stringValue = "滚轮处理：最近一次滚动被保留（手势模式）"
            case nil: mouseRuntimeStatus.stringValue = "滚轮处理：运行中，等待滚动"
            }
        } else {
            mouseRuntimeStatus.stringValue = savedMouse.needsMonitor
                ? "滚轮处理：未运行，请检查辅助功能权限" : "滚轮处理：未启用"
        }
        mouseRuntimeStatus.textColor = mouseMonitorActive ? LEStyle.text : LEStyle.secondary
        mouseRetry?.isHidden = mouseMonitorActive || !savedMouse.needsMonitor
    }

    private func setup() {
        panel.delegate = self
        panel.title = "Cuts 设置"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.6
        content.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.52).cgColor
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.90
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        let tint = NSView(frame: content.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = LEStyle.container.withAlphaComponent(0.25).cgColor
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        let sidebar = NSView(frame: CGRect(x: 12, y: 18, width: 148, height: 390))
        settingsCard(sidebar, opacity: 0.30)
        content.addSubview(sidebar)
        for (index, name) in Self.pageNames.enumerated() {
            let item = button("\u{2002}\(name)", x: 11, y: 340 - CGFloat(index) * 41,
                              width: 126, parent: sidebar, action: #selector(changePage(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(name)
            item.alignment = .left
            item.setAccessibilityLabel(name)
            navigation[name] = item
        }
        let pageRect = CGRect(x: 174, y: 18, width: 440, height: 390)
        for name in Self.pageNames {
            let page = NSView(frame: pageRect)
            settingsCard(page, opacity: 0.27)
            content.addSubview(page)
            pages[name] = page
        }
        buildScreenshotPage(pages["截图"]!)
        let annotations = AnnotationDefaultsView(frame: pages["默认"]!.bounds)
        annotations.showError = { [weak self] in self?.report($0) }
        pages["默认"]?.addSubview(annotations)
        annotationPage = annotations
        buildShortcutsPage(pages["快捷键"]!)
        buildClipboardPage(pages["剪贴板"]!)
        buildMousePage(pages["鼠标"]!)
        buildGeneralPage(pages["通用"]!)
        buildLoggingPage(pages["日志"]!)
        selectPage("截图")
    }

    func windowWillClose(_ notification: Notification) {
        shortcutPage?.endRecording()
        annotationPage?.dismissPicker()
    }
    func windowDidResignKey(_ notification: Notification) { shortcutPage?.endRecording() }

    private func buildShortcutsPage(_ page: NSView) {
        let shortcuts = ShortcutSettingsView(frame: page.bounds)
        shortcutPage = shortcuts
        shortcuts.onApply = { [weak self] preferences in
            guard let self else { return }
            try self.onShortcutsChange?(preferences)
            self.shortcutPreferences = preferences
        }
        shortcuts.onRecordingChange = { [weak self] in self?.onShortcutRecordingChange?($0) }
        shortcuts.showError = { [weak self] in self?.report($0) }
        page.addSubview(shortcuts)
    }

    private func settingsCard(_ view: NSView, opacity: CGFloat) {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = LEStyle.elevated.withAlphaComponent(opacity).cgColor
        view.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.42).cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
    }

    private func buildScreenshotPage(_ page: NSView) {
        label("截图保存", x: 18, y: 345, width: 250, size: 17, parent: page)
        label("保存位置", x: 18, y: 302, width: 100, parent: page)
        directoryLabel.frame = CGRect(x: 18, y: 270, width: 300, height: 25)
        directoryLabel.textColor = LEStyle.secondary
        directoryLabel.font = .systemFont(ofSize: 12)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        page.addSubview(directoryLabel)
        button("选择…", x: 334, y: 267, width: 87, parent: page,
               action: #selector(chooseDirectory)).setAccessibilityLabel("选择截图保存目录")
        label("文件名前缀", x: 18, y: 222.5, width: 100, parent: page, centered: true)
        prefixField.frame = CGRect(x: 122, y: 218, width: 298, height: 29)
        prefixField.font = .systemFont(ofSize: 12)
        prefixField.backgroundColor = LEStyle.elevated
        prefixField.textColor = LEStyle.text
        prefixField.delegate = self
        page.addSubview(prefixField)
        label("命名方式", x: 18, y: 177, width: 95, parent: page)
        choice("时间戳", key: "timestamp", x: 122, y: 169, parent: page)
        choice("顺序编号", key: "sequence", x: 226, y: 169, parent: page)
        label("保存格式", x: 18, y: 129, width: 95, parent: page)
        choice("PNG", key: "png", x: 122, y: 121, parent: page)
        choice("WebP", key: "webp", x: 226, y: 121, parent: page)
        label("文件名预览", x: 18, y: 89, width: 95, parent: page)
        filenamePreview.frame = CGRect(x: 122, y: 85, width: 298, height: 22)
        filenamePreview.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        filenamePreview.textColor = LEStyle.text
        filenamePreview.lineBreakMode = .byTruncatingMiddle
        page.addSubview(filenamePreview)
        label("预览按当前时间和已有文件推算；格式仅影响保存。", x: 18, y: 48,
              width: 405, parent: page, color: LEStyle.secondary)
        addCommit("保存", key: "capture", to: page, action: #selector(saveScreenshotSettings))
    }

    private func buildClipboardPage(_ page: NSView) {
        label("剪贴板", x: 18, y: 345, width: 250, size: 17, parent: page)
        let hint = NSTextField(labelWithString: "")
        hint.frame = CGRect(x: 18, y: 311, width: 404, height: 20)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = LEStyle.secondary
        page.addSubview(hint)
        clipboardShortcutLabel = hint
        label("长按 ⌘V 打开历史", x: 18, y: 258, width: 240, parent: page)
        holdButton.frame = CGRect(x: 324, y: 251, width: 97, height: 29)
        style(holdButton, action: #selector(toggleHold))
        page.addSubview(holdButton)
        label("触发时长", x: 18, y: 205.5, width: 100, parent: page, centered: true)
        holdDelayField.frame = CGRect(x: 122, y: 201, width: 88, height: 29)
        holdDelayField.font = .systemFont(ofSize: 12)
        holdDelayField.backgroundColor = LEStyle.elevated
        holdDelayField.textColor = LEStyle.text
        holdDelayField.delegate = self
        page.addSubview(holdDelayField)
        label("毫秒（250–2000）", x: 223, y: 205.5, width: 175, parent: page,
              color: LEStyle.secondary, centered: true)
        label("短按 ⌘V 仍执行普通粘贴。", x: 18, y: 157,
              width: 390, parent: page, color: LEStyle.secondary)
        addCommit("应用", key: "clipboard", to: page, action: #selector(applyHoldDelay))
    }

    private func buildGeneralPage(_ page: NSView) {
        label("通用", x: 18, y: 345, width: 250, size: 17, parent: page)
        let version = NSTextField(labelWithString: CutsVersion.label)
        version.frame = CGRect(x: 271, y: 347, width: 150, height: 19)
        version.alignment = .right
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        version.textColor = LEStyle.secondary
        page.addSubview(version)
        label("登录 Mac 时启动", x: 18, y: 295, width: 220, parent: page)
        loginButton.frame = CGRect(x: 324, y: 287, width: 97, height: 29)
        style(loginButton, action: #selector(toggleLoginLaunch))
        page.addSubview(loginButton)
        loginStatus.frame = CGRect(x: 18, y: 259, width: 400, height: 20)
        loginStatus.textColor = LEStyle.secondary
        loginStatus.font = .systemFont(ofSize: 12)
        page.addSubview(loginStatus)
        button("打开系统登录项…", x: 18, y: 221, width: 145, parent: page,
               action: #selector(openLoginSettings))
        let separator = NSView(frame: CGRect(x: 18, y: 194, width: 404, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = LEStyle.border.cgColor
        page.addSubview(separator)
        label("菜单栏图标", x: 18, y: 164, width: 220, parent: page)
        iconStatus.frame = CGRect(x: 18, y: 133, width: 400, height: 21)
        iconStatus.textColor = LEStyle.secondary
        iconStatus.font = .systemFont(ofSize: 12)
        iconStatus.lineBreakMode = .byTruncatingMiddle
        page.addSubview(iconStatus)
        let previewTile = NSView(frame: CGRect(x: 332, y: 80, width: 78, height: 78))
        previewTile.wantsLayer = true
        previewTile.layer?.cornerRadius = 12
        previewTile.layer?.borderWidth = 0.8
        previewTile.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.55).cgColor
        previewTile.layer?.backgroundColor = LEStyle.canvas.withAlphaComponent(0.46).cgColor
        page.addSubview(previewTile)
        iconPreview.frame = CGRect(x: 12, y: 11, width: 54, height: 54)
        iconPreview.imageScaling = .scaleProportionallyUpOrDown
        iconPreview.contentTintColor = .white
        iconPreview.setAccessibilityLabel("当前菜单栏图标预览")
        previewTile.addSubview(iconPreview)
        button("导入 SVG…", x: 18, y: 87, width: 111, parent: page,
               action: #selector(importMenuIcon))
        button("恢复默认", x: 137, y: 87, width: 100, parent: page,
               action: #selector(restoreMenuIcon))
        addCommit("应用", key: "general", to: page, action: #selector(applyGeneral))
    }

    private func buildMousePage(_ page: NSView) {
        label("鼠标", x: 18, y: 345, width: 250, size: 17, parent: page)
        mouseRuntimeStatus.frame = CGRect(x: 18, y: 316, width: 405, height: 20)
        mouseRuntimeStatus.font = .systemFont(ofSize: 12, weight: .medium)
        page.addSubview(mouseRuntimeStatus)
        label("指针灵敏度", x: 18, y: 282, width: 100, parent: page)
        pointerSpeedSlider.frame = CGRect(x: 122, y: 277, width: 177, height: 25)
        pointerSpeedSlider.minValue = 0
        pointerSpeedSlider.maxValue = Double(MouseTrackingSpeed.steps.count - 1)
        pointerSpeedSlider.numberOfTickMarks = MouseTrackingSpeed.steps.count
        pointerSpeedSlider.allowsTickMarkValuesOnly = true
        pointerSpeedSlider.target = self
        pointerSpeedSlider.action = #selector(pointerSpeedChanged)
        pointerSpeedSlider.setAccessibilityLabel("鼠标指针灵敏度")
        page.addSubview(pointerSpeedSlider)
        pointerSpeedValue.frame = CGRect(x: 302, y: 281, width: 52, height: 19)
        pointerSpeedValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pointerSpeedValue.textColor = LEStyle.text
        page.addSubview(pointerSpeedValue)
        mouseToggle("垂直滚轮反向", key: "vertical", y: 234, parent: page)
        mouseToggle("水平滚轮反向", key: "horizontal", y: 196, parent: page)
        label("滚轮倍率", x: 18, y: 164.5, width: 150, parent: page, centered: true)
        mouseSpeedField.frame = CGRect(x: 320, y: 160, width: 100, height: 29)
        mouseSpeedField.font = .systemFont(ofSize: 12)
        mouseSpeedField.backgroundColor = LEStyle.elevated
        mouseSpeedField.textColor = LEStyle.text
        mouseSpeedField.delegate = self
        page.addSubview(mouseSpeedField)
        mouseToggle("保留触控板/手势滚动", key: "discrete", y: 122, parent: page)
        mouseToggle("侧键 3/4 → 后退/前进", key: "side", y: 84, parent: page)
        label("部分高精度滚轮会被识别为手势。关闭手势保留后，触控板也会受影响。", x: 18, y: 51,
              width: 405, parent: page, color: LEStyle.secondary)
        mouseRetry = button("重新启用", x: 18, y: 19, width: 100, parent: page, action: #selector(retryMouse))
        addCommit("应用", key: "mouse", to: page, action: #selector(applyMouseSettings))
    }

    @objc private func retryMouse() {
        do { try onMouseRetry?(); refreshMouseRuntimeState() }
        catch { report(error.localizedDescription) }
    }

    private func syncPointerSpeedSlider() {
        let current = MouseTrackingSpeed.current() ?? MouseTrackingSpeed.saved ?? 2
        pointerSpeedSlider.doubleValue = Double(MouseTrackingSpeed.nearestStep(to: current))
        updatePointerSpeedValue()
    }

    private var pointerStep: Int {
        max(0, min(MouseTrackingSpeed.steps.count - 1, Int(pointerSpeedSlider.doubleValue.rounded())))
    }

    private func updatePointerSpeedValue() {
        pointerSpeedValue.stringValue = String(MouseTrackingSpeed.steps[pointerStep])
    }

    @objc private func pointerSpeedChanged() { updatePointerSpeedValue(); updateCommitStates() }

    private func mouseToggle(_ title: String, key: String, y: CGFloat, parent: NSView) {
        label(title, x: 18, y: y + 7, width: 270, parent: parent)
        let item = button("", x: 320, y: y, width: 100, parent: parent,
                          action: #selector(toggleMouseOption(_:)))
        item.identifier = NSUserInterfaceItemIdentifier(key)
        mouseButtons[key] = item
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                       size: CGFloat = 12, parent: NSView, color: NSColor = LEStyle.text, centered: Bool = false) {
        let field = centered ? SingleLineInputField.rowLabel(text) : NSTextField(labelWithString: text)
        field.frame = CGRect(x: x, y: y, width: width, height: size + 8)
        field.font = .systemFont(ofSize: size, weight: size >= 17 ? .semibold : .medium)
        field.textColor = color
        parent.addSubview(field)
    }

    @discardableResult
    private func button(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat,
                        parent: NSView, action: Selector) -> NSButton {
        let item = PointingButton(title: title, target: self, action: action)
        item.frame = CGRect(x: x, y: y, width: width, height: 29)
        style(item, action: action)
        parent.addSubview(item)
        return item
    }

    private func addCommit(_ title: String, key: String, to page: NSView, action: Selector) {
        let item = button(title, x: 349, y: 19, width: 72, parent: page, action: action)
        commits[key] = item
        CutsSettingsStyle.commit(item, dirty: false)
    }

    private func fieldText(_ field: NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }

    private func updateCommitStates() {
        let captureChanged = directory.standardizedFileURL.path != ImageSaveSettings.directory.standardizedFileURL.path
            || fieldText(prefixField) != ImageSaveSettings.prefix || format != ImageSaveSettings.format || naming != ImageSaveSettings.naming
        CutsSettingsStyle.commit(commits["capture"], dirty: captureChanged)
        CutsSettingsStyle.commit(commits["clipboard"], dirty: holdEnabled != savedHoldEnabled
                               || Int(fieldText(holdDelayField)) != savedHoldDelay)
        CutsSettingsStyle.commit(commits["mouse"], dirty: mouseSettings != savedMouse || pointerStep != savedPointerStep
                               || Double(fieldText(mouseSpeedField)) != savedMouse.speed)
        CutsSettingsStyle.commit(commits["general"], dirty: loginDraft != savedLogin || iconDraft != savedIcon)
        CutsSettingsStyle.commit(commits["logs"], dirty: logsEnabled != CutsLog.enabled || logLevel != CutsLog.level)
    }

    private func style(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        CutsSettingsStyle.control(button)
    }

    private func choice(_ title: String, key: String, x: CGFloat, y: CGFloat, parent: NSView) {
        let item = button(title, x: x, y: y, width: 98, parent: parent,
                          action: #selector(choiceClicked(_:)))
        item.identifier = NSUserInterfaceItemIdentifier(key)
        choices[key] = item
    }

    private func selectPage(_ name: String) {
        if name != "快捷键" { shortcutPage?.endRecording() }
        if name != "默认" { annotationPage?.dismissPicker() }
        let previous = Self.pageNames.firstIndex(of: selectedPage)
        let next = Self.pageNames.firstIndex(of: name)
        let changed = selectedPage != name
        selectedPage = name
        for (key, page) in pages { page.isHidden = key != name }
        for (key, button) in navigation {
            CutsSettingsStyle.navigation(button, selected: key == name)
        }
        if name == "日志" { refreshLogControls() }
        if changed, let page = pages[name], let previous, let next {
            CutsMotion.appear(page, .page, from: CGPoint(x: 0, y: next > previous ? -7 : 7))
        }
    }

    private func buildLoggingPage(_ page: NSView) {
        label("诊断日志", x: 18, y: 345, width: 250, size: 17, parent: page)
        label("记录 Cuts 内操作", x: 18, y: 295, width: 240, parent: page)
        logToggle = button("", x: 324, y: 287, width: 97, parent: page, action: #selector(toggleLogging))
        label("日志级别", x: 18, y: 244, width: 170, parent: page)
        for level in CutsLog.Level.allCases {
            let item = button(level.title, x: 18 + CGFloat(level.rawValue) * 101, y: 200,
                              width: 94, parent: page, action: #selector(chooseLogLevel(_:)))
            item.tag = level.rawValue
            logLevelButtons[level] = item
        }
        label("调试级额外记录菜单与逐帧拼接诊断。", x: 18, y: 159,
              width: 403, parent: page, color: LEStyle.secondary)
        label("只存于本机，不含截图内容、剪贴板或键盘输入。", x: 18, y: 128,
              width: 403, parent: page, color: LEStyle.secondary)
        label("最多保留 3 个日志文件，每个约 1 MB。", x: 18, y: 102,
              width: 403, parent: page, color: LEStyle.secondary)
        button("打开目录…", x: 18, y: 47, width: 110, parent: page, action: #selector(openLogDirectory))
        button("导出诊断…", x: 135, y: 47, width: 110, parent: page, action: #selector(exportLogs))
        button("清除日志…", x: 252, y: 47, width: 110, parent: page, action: #selector(clearLogs))
        addCommit("保存", key: "logs", to: page, action: #selector(saveLogSettings))
        refreshLogControls()
    }

    private func refreshLogControls() {
        let enabled = logsEnabled
        logToggle?.title = enabled ? "已开启" : "已关闭"
        CutsSettingsStyle.control(logToggle, selected: enabled)
        for (level, item) in logLevelButtons {
            item.isEnabled = enabled
            CutsSettingsStyle.control(item, selected: enabled && logLevel == level)
        }
        updateCommitStates()
    }

    @objc private func toggleLogging() {
        logsEnabled.toggle()
        refreshLogControls()
    }

    @objc private func chooseLogLevel(_ sender: NSButton) {
        guard let level = CutsLog.Level(rawValue: sender.tag) else { return }
        logLevel = level
        refreshLogControls()
    }

    @objc private func saveLogSettings() {
        CutsLog.level = logLevel
        CutsLog.enabled = logsEnabled
        CutsLog.write(.info, "settings", "logging level=\(logLevel.tag)")
        refreshLogControls()
        ActionFeedback.show("日志设置已保存", success: true)
    }

    @objc private func openLogDirectory() {
        do {
            try FileManager.default.createDirectory(at: CutsLog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CutsLog.directory)
        } catch { report("无法打开日志目录。") }
    }

    @objc private func exportLogs() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.plainText]
        save.nameFieldStringValue = "Cuts-诊断.txt"
        save.message = "只导出时间、级别、功能和错误代码。"
        save.beginSheetModal(for: panel) { [weak self, weak save] response in
            guard response == .OK, let url = save?.url else { return }
            Task {
                do { try await CutsLog.exportDiagnosticSummary(to: url); ActionFeedback.show("已导出诊断", success: true) }
                catch { self?.report("无法导出诊断：\(error.localizedDescription)") }
            }
        }
    }

    @objc private func clearLogs() {
        let alert = NSAlert()
        alert.messageText = "清除 Cuts 的诊断日志？"
        alert.informativeText = "不会清除剪贴板历史或更改日志设置。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除日志").hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            Task {
                do { try await CutsLog.clear(); ActionFeedback.show("已清除日志", success: true) }
                catch { self?.report("无法清除日志：\(error.localizedDescription)") }
            }
        }
    }

    private func updateChoices() {
        directoryLabel.stringValue = directory.path
        directoryLabel.toolTip = directory.path
        for (key, item) in choices {
            let active = key == format.rawValue || key == naming.rawValue
            CutsSettingsStyle.control(item, selected: active)
        }
        updateFilenamePreview()
        updateCommitStates()
    }

    private func updateFilenamePreview() {
        filenamePreview.stringValue = ImageSaveSettings.previewFilename(in: directory,
            prefix: fieldText(prefixField), format: format, naming: naming)
        filenamePreview.toolTip = filenamePreview.stringValue
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === prefixField { updateFilenamePreview() }
        updateCommitStates()
    }

    private func updateMouseControls() {
        let values = ["vertical": mouseSettings.reverseVertical,
                      "horizontal": mouseSettings.reverseHorizontal,
                      "discrete": mouseSettings.onlyDiscreteWheels,
                      "side": mouseSettings.sideButtonsNavigate]
        for (key, button) in mouseButtons {
            let active = values[key] ?? false
            button.title = active ? "已开启" : "已关闭"
            CutsSettingsStyle.control(button, selected: active)
        }
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Cuts 设置"
        alert.informativeText = message
        alert.beginSheetModal(for: panel)
    }

    @objc private func changePage(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { selectPage(name) }
    }

    @objc private func choiceClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        if let value = ImageSaveSettings.Format(rawValue: raw) { format = value }
        if let value = ImageSaveSettings.Naming(rawValue: raw) { naming = value }
        updateChoices()
        CutsMotion.accent(in: sender)
    }

    @objc private func chooseDirectory() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = directory
        chooser.beginSheetModal(for: panel) { [weak self] result in
            guard result == .OK, let url = chooser.url else { return }
            self?.directory = url
            self?.updateChoices()
        }
    }

    @objc private func saveScreenshotSettings() {
        let prefix = fieldText(prefixField)
        panel.makeFirstResponder(nil)
        ImageSaveSettings.configure(directory: directory, prefix: prefix,
                                    format: format, naming: naming)
        prefixField.stringValue = ImageSaveSettings.prefix
        updateFilenamePreview()
        updateCommitStates()
        ActionFeedback.show("截图保存设置已更新", success: true)
    }

    @objc private func toggleHold() {
        holdEnabled.toggle()
        refreshRuntimeState()
    }

    @objc private func applyHoldDelay() {
        guard let value = Int(fieldText(holdDelayField)), (250...2000).contains(value) else {
            report("请输入 250–2000 之间的毫秒数。")
            return
        }
        do {
            try onHoldChange?(holdEnabled, value)
            holdMilliseconds = value
            savedHoldEnabled = holdEnabled
            savedHoldDelay = value
            refreshRuntimeState()
            ActionFeedback.show("剪贴板设置已应用", success: true)
        } catch { report("无法应用剪贴板设置：\(error.localizedDescription)") }
    }

    @objc private func toggleLoginLaunch() {
        loginDraft.toggle()
        refreshGeneral()
        updateCommitStates()
    }

    @objc private func applyGeneral() {
        do {
            if loginDraft != savedLogin {
                _ = try LoginLaunchSettings.setEnabled(loginDraft)
                savedLogin = loginDraft
            }
            if iconDraft != savedIcon {
                try MenuBarIconSettings.save(iconDraft)
                savedIcon = iconDraft
                onIconChange?()
            }
            refreshRuntimeState()
            ActionFeedback.show("通用设置已应用", success: true)
        } catch {
            refreshRuntimeState()
            report("无法应用通用设置：\(error.localizedDescription)")
        }
    }

    @objc private func openLoginSettings() { LoginLaunchSettings.openSystemSettings() }

    @objc private func importMenuIcon() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = false
        if let svg = UTType(filenameExtension: "svg") { chooser.allowedContentTypes = [svg] }
        chooser.beginSheetModal(for: panel) { [weak self] result in
            guard let self, result == .OK, let url = chooser.url else { return }
            do {
                self.iconDraft = try MenuBarIconSettings.readSVG(from: url)
                self.refreshGeneral()
                self.updateCommitStates()
            } catch { self.report(error.localizedDescription) }
        }
    }

    @objc private func restoreMenuIcon() {
        iconDraft = .standard
        refreshGeneral()
        updateCommitStates()
    }

    @objc private func toggleMouseOption(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "vertical": mouseSettings.reverseVertical.toggle()
        case "horizontal": mouseSettings.reverseHorizontal.toggle()
        case "discrete": mouseSettings.onlyDiscreteWheels.toggle()
        case "side": mouseSettings.sideButtonsNavigate.toggle()
        default: return
        }
        updateMouseControls()
        updateCommitStates()
    }

    @objc private func applyMouseSettings() {
        guard let speed = Double(fieldText(mouseSpeedField)), (0.5...3).contains(speed) else {
            report("滚动倍率请输入 0.5–3.0 之间的数字。")
            return
        }
        var requested = mouseSettings
        requested.speed = speed
        do {
            if requested != savedMouse {
                try onMouseChange?(requested)
                mouseSettings = requested
                savedMouse = requested
                mouseMonitorActive = requested.needsMonitor
            }
            if pointerStep != savedPointerStep {
                try MouseTrackingSpeed.apply(MouseTrackingSpeed.steps[pointerStep])
                savedPointerStep = pointerStep
            }
            refreshRuntimeState()
            ActionFeedback.show("鼠标设置已应用", success: true)
        } catch {
            refreshRuntimeState()
            report("无法应用鼠标设置：\(error.localizedDescription)")
        }
    }
}
