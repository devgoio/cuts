import AppKit
import Carbon
import ApplicationServices
import ImageIO

enum CutsVersion {
    static let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    static let label = "版本 \(value)"
}

@MainActor
final class RebuildApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var hotKeys: [EventHotKeyRef] = []
    private var coordinator: CaptureFlow?
    private var queuedCapture: (purpose: CaptureFlow.Purpose, expires: TimeInterval)?
    private var archive: ClipboardArchive?
    private var monitor: ClipboardMonitor?
    private var clipboardPanel: ClipboardPanel?
    private var pendingHistoryPaste: UUID?
    private var openingHistoryImage = false
    private var previousApp: NSRunningApplication?
    private var shortcutHoldMonitor: ShortcutHoldMonitor?
    private var recordingShortcut = false
    private var shortcuts = ShortcutPreferences.saved
    private var shortcutConflicts: [String] = []
    private var holdInactive = false
    private var mouseMonitor: MouseEventMonitor?
    private var settingsPanel: SettingsPanel?
    private let holdEnabledKey = "cuts.commandVHoldEnabled"
    private let holdMillisecondsKey = "cuts.commandVHoldMilliseconds"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CutsLog.write(.info, "app", "started version=\(CutsVersion.value)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIconSettings.image()
        item.button?.setAccessibilityLabel("Cuts 菜单")
        statusItem = item
        let archive = ClipboardArchive()
        archive.onThumbnail = { [weak self] id in self?.clipboardPanel?.refreshThumbnail(id) }
        let monitor = ClipboardMonitor(archive: archive)
        monitor.onChange = { [weak self] in self?.clipboardPanel?.refresh() }
        monitor.start()
        self.archive = archive
        self.monitor = monitor
        installShortcutHandler()
        let startupConflicts = registerPressedShortcuts(shortcuts)
        do {
            try configureHoldBindings(for: shortcuts, pasteEnabled: commandVHoldEnabled,
                                      pasteMilliseconds: commandVHoldMilliseconds)
            if commandVHoldEnabled { CutsLog.write(.info, "shortcuts", "clipboard hold active milliseconds=\(commandVHoldMilliseconds)") }
            updateStatusMenu(conflicts: startupConflicts)
        } catch {
            CutsLog.failure("shortcuts", "start hold bindings", error)
            updateStatusMenu(conflicts: startupConflicts, holdInactive: true)
        }
        let mouseSettings = MouseSettings.saved
        if mouseSettings.needsMonitor {
            do { try configureMouse(mouseSettings) }
            catch { ActionFeedback.show("鼠标设置未运行，请检查 Cuts 的辅助功能权限") }
        }
        MouseTrackingSpeed.reapplySaved()
    }

    static func verifyStatusMenu() -> Bool {
        let app = RebuildApp()
        let entries = app.makeStatusMenu(clipboardMilliseconds: 300).items.filter { !$0.isSeparatorItem }
        let imagesVisible: Bool
        if #available(macOS 27.0, *) {
            imagesVisible = entries.allSatisfy { $0.preferredImageVisibility == .visible }
        } else {
            imagesVisible = true
        }
        return entries.count == 5
            && imagesVisible
            && entries.first?.title == "\u{2002}剪贴板历史  ⌘V·300"
            && entries[2].title == "\u{2002}滚动长截图"
            && app.makeStatusMenu(clipboardMilliseconds: nil).items.first?.title == "\u{2002}剪贴板历史"
            && entries.allSatisfy { item in
                item.image?.size == MenuIcon.size && item.title.hasPrefix("\u{2002}") && item.target === app
                    && item.action.map { app.responds(to: $0) } == true
            }
            && !entries.contains(where: { $0.title.contains("录制") || $0.title.contains("关于") })
    }

    private func makeStatusMenu(clipboardMilliseconds: Int?) -> NSMenu {
        let menu = NSMenu()
        let clipboardSuffix = clipboardMilliseconds.map { "  " + ShortcutPreferences.clipboardShortcutLabel(milliseconds: $0) } ?? ""
        menu.addItem(makeStatusItem("剪贴板历史\(clipboardSuffix)", symbol: "doc.on.clipboard", action: #selector(showClipboard)))
        menu.addItem(makeStatusItem("区域截图  \(shortcuts[.capture].display)", symbol: "camera.viewfinder", action: #selector(startCapture)))
        menu.addItem(makeStatusItem("滚动长截图", symbol: "rectangle.stack", action: #selector(startLongCapture)))
        menu.addItem(.separator())
        menu.addItem(makeStatusItem("设置…", symbol: "gearshape", action: #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(makeStatusItem("退出 Cuts", symbol: "power", action: #selector(quit)))
        return menu
    }

    private func makeStatusItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: "\u{2002}\(title)", action: action, keyEquivalent: "")
        entry.target = self
        entry.image = MenuIcon.symbol(symbol, description: title)
        if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }
        return entry
    }

    private var commandVHoldEnabled: Bool {
        UserDefaults.standard.object(forKey: holdEnabledKey) as? Bool ?? true
    }

    private var commandVHoldMilliseconds: Int {
        let saved = UserDefaults.standard.integer(forKey: holdMillisecondsKey)
        return (250...2000).contains(saved) ? saved : ShortcutPreferences.defaultClipboardHoldMilliseconds
    }

    private func configureHoldBindings(for preferences: ShortcutPreferences, pasteEnabled: Bool,
                                       pasteMilliseconds: Int) throws {
        var bindings = preferences.bindings.filter(\.hold)
        if pasteEnabled {
            bindings.append(ShortcutPreferences.clipboardHold(milliseconds: pasteMilliseconds))
        }
        if bindings.isEmpty {
            shortcutHoldMonitor?.stop()
            shortcutHoldMonitor = nil
            return
        }
        if let shortcutHoldMonitor {
            shortcutHoldMonitor.replaceBindings(bindings)
            return
        }
        let hold = ShortcutHoldMonitor(bindings: bindings)
        hold.shouldIntercept = { [weak self] action in
            guard let self, !self.recordingShortcut else { return false }
            // A capture hotkey can start while the previous overlay is closing.
            // Only check for an existing capture when the hold actually fires.
            return action != .clipboard || !NSApp.isActive || self.clipboardPanel == nil
        }
        hold.onLongPress = { [weak self] action in
            switch action {
            case .capture: self?.beginCapture(.screenshot, waitForClosingCapture: true)
            case .clipboard: self?.showClipboard()
            case .legacyLongCapture: break
            }
        }
        hold.onStoppedUnexpectedly = { [weak self] in
            guard let self else { return }
            self.shortcutHoldMonitor = nil
            self.updateStatusMenu(conflicts: self.shortcutConflicts, holdInactive: true)
            ActionFeedback.show("长按快捷键已停止，普通按键功能不受影响")
        }
        try hold.start()
        shortcutHoldMonitor = hold
    }

    private func configureCommandVHold(enabled: Bool, milliseconds: Int) throws {
        try configureHoldBindings(for: shortcuts, pasteEnabled: enabled, pasteMilliseconds: milliseconds)
        UserDefaults.standard.set(milliseconds, forKey: holdMillisecondsKey)
        UserDefaults.standard.set(enabled, forKey: holdEnabledKey)
        updateStatusMenu(conflicts: shortcutConflicts, holdInactive: false)
    }

    private func configureShortcuts(_ requested: ShortcutPreferences) throws {
        try requested.validate()
        let conflicts = registerPressedShortcuts(requested)
        if !conflicts.isEmpty {
            updateStatusMenu(conflicts: registerPressedShortcuts(shortcuts))
            throw ShortcutPreferences.failure("无法注册 \(conflicts.joined(separator: "、"))，可能被系统或其他应用占用。")
        }
        do {
            try configureHoldBindings(for: requested, pasteEnabled: commandVHoldEnabled,
                                      pasteMilliseconds: commandVHoldMilliseconds)
        } catch {
            updateStatusMenu(conflicts: registerPressedShortcuts(shortcuts))
            throw error
        }
        shortcuts = requested
        shortcuts.store()
        updateStatusMenu(conflicts: [], holdInactive: false)
        CutsLog.write(.info, "shortcuts", "bindings updated")
    }

    private func updateStatusMenu(conflicts: [String], holdInactive: Bool? = nil) {
        shortcutConflicts = conflicts
        if let holdInactive { self.holdInactive = holdInactive }
        let menu = makeStatusMenu(clipboardMilliseconds: commandVHoldEnabled && !self.holdInactive ? commandVHoldMilliseconds : nil)
        if !conflicts.isEmpty {
            let warning = NSMenuItem(title: "快捷键冲突：\(conflicts.joined(separator: "、"))", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.insertItem(warning, at: 0)
        }
        if self.holdInactive {
            menu.insertItem(makeStatusItem("重新启用长按快捷键", symbol: "arrow.clockwise",
                                           action: #selector(retryHoldShortcuts)), at: 0)
        }
        statusMenu = menu
        statusItem?.menu = menu
    }

    private func configureMouse(_ settings: MouseSettings) throws {
        if !settings.needsMonitor {
            mouseMonitor?.stop()
            mouseMonitor = nil
            settingsPanel?.lastScrollResult = nil
            settings.save()
            CutsLog.write(.info, "mouse", "enhancement inactive")
            return
        }
        if let mouseMonitor {
            mouseMonitor.settings = settings
        } else {
            let mouseMonitor = MouseEventMonitor(settings: settings)
            mouseMonitor.onStoppedUnexpectedly = { [weak self] in
                self?.mouseMonitor = nil
                self?.settingsPanel?.mouseMonitorActive = false
                self?.settingsPanel?.lastScrollResult = nil
                self?.settingsPanel?.refreshRuntimeState()
                CutsLog.write(.warning, "mouse", "event tap stopped")
                ActionFeedback.show("鼠标增强已停止，系统鼠标功能不受影响")
            }
            mouseMonitor.onScrollResult = { [weak self] result in
                self?.settingsPanel?.lastScrollResult = result
                self?.settingsPanel?.refreshMouseRuntimeState()
            }
            do { try mouseMonitor.start() }
            catch {
                CutsLog.write(.warning, "mouse", "event tap could not start: \(error.localizedDescription)")
                throw error
            }
            self.mouseMonitor = mouseMonitor
        }
        settingsPanel?.lastScrollResult = mouseMonitor?.lastScroll
        settings.save()
        CutsLog.write(.info, "mouse", "event tap active vertical=\(settings.reverseVertical) horizontal=\(settings.reverseHorizontal) preserveGestures=\(settings.onlyDiscreteWheels)")
    }

    @objc private func showSettings() {
        CutsLog.write(.info, "settings", "opened")
        if settingsPanel == nil {
            let settings = SettingsPanel()
            settings.onHoldChange = { [weak self] enabled, milliseconds in
                try self?.configureCommandVHold(enabled: enabled, milliseconds: milliseconds)
            }
            settings.onShortcutsChange = { [weak self] preferences in try self?.configureShortcuts(preferences) }
            settings.onShortcutRecordingChange = { [weak self] recording in
                guard let self else { return }
                self.recordingShortcut = recording
                if recording { self.unregisterPressedShortcuts() }
                else { self.updateStatusMenu(conflicts: self.registerPressedShortcuts(self.shortcuts)) }
            }
            settings.onIconChange = { [weak self] in
                self?.statusItem?.button?.image = MenuBarIconSettings.image()
            }
            settings.onMouseChange = { [weak self] value in
                try self?.configureMouse(value)
            }
            settings.onMouseRetry = { [weak self] in try self?.configureMouse(.saved) }
            settings.holdEnabled = commandVHoldEnabled
            settings.shortcutPreferences = shortcuts
            settings.holdMilliseconds = commandVHoldMilliseconds
            settingsPanel = settings
        }
        settingsPanel?.mouseMonitorActive = mouseMonitor != nil
        settingsPanel?.lastScrollResult = mouseMonitor?.lastScroll
        settingsPanel?.show()
    }

    @objc private func retryHoldShortcuts() {
        do {
            try configureHoldBindings(for: shortcuts, pasteEnabled: commandVHoldEnabled,
                                      pasteMilliseconds: commandVHoldMilliseconds)
            updateStatusMenu(conflicts: shortcutConflicts, holdInactive: false)
        } catch { ActionFeedback.show(error.localizedDescription) }
    }

    @objc private func showClipboard() {
        guard let archive else { return }
        monitor?.captureLatest()
        pendingHistoryPaste = nil
        CutsLog.write(.info, "clipboard", "history opened")
        if clipboardPanel == nil {
            previousApp = NSWorkspace.shared.frontmostApplication
            let panel = ClipboardPanel(archive: archive)
            panel.onPaste = { [weak self] record in self?.paste(record) }
            panel.onEditImage = { [weak self] record in self?.editClipboardImage(record) }
            panel.onClose = { [weak self] in self?.clipboardPanel = nil }
            clipboardPanel = panel
        }
        clipboardPanel?.show()
    }

    private func editClipboardImage(_ record: ClipboardRecord) {
        guard !openingHistoryImage, let host = clipboardPanel, let source = archive?.previewSource(for: record) else { return }
        openingHistoryImage = true
        Task { [weak self, weak host] in
            let result = await Task.detached(priority: .userInitiated) { Result { try ClipboardImageReader.decode(source) } }.value
            guard let self else { return }
            self.openingHistoryImage = false
            guard let host, self.clipboardPanel === host else { return }
            switch result {
            case .success(let image):
                host.close()
                CutsLog.write(.info, "clipboard", "opened history image for annotation")
                CaptureEditor.presentClipboardImage(image)
            case .failure(let error):
                CutsLog.failure("clipboard", "decode history image", error)
                ActionFeedback.show(error.localizedDescription)
            }
        }
    }

    private func paste(_ record: ClipboardRecord) {
        guard let archive else { return }
        pendingHistoryPaste = nil
        let target = previousApp
        let pasteboard = NSPasteboard.general
        guard archive.restore(record, to: pasteboard) else {
            CutsLog.write(.warning, "clipboard", "could not restore history item")
            let alert = NSAlert()
            alert.messageText = "无法粘贴这条记录"
            alert.informativeText = record.kind == .files ? "原文件可能已经移动或删除。" : "剪贴板内容已不可读取。"
            alert.runModal()
            return
        }
        let changeCount = pasteboard.changeCount
        monitor?.noteOwnWrite(changeCount)
        CutsLog.write(.info, "clipboard", "history item restored")
        clipboardPanel?.close()
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        _ = target.activate(options: [])
        guard AXIsProcessTrusted() else {
            CutsLog.write(.warning, "clipboard", "automatic paste skipped: accessibility permission")
            let alert = NSAlert()
            alert.messageText = "已复制到剪贴板"
            alert.informativeText = "按 ⌘V 即可粘贴。自动粘贴需要在“系统设置 → 隐私与安全 → \(AccessibilityPermission.paneName)”中允许 Cuts；如果列表里没有 Cuts，请点“添加”并选择 Cuts.app。"
            alert.addButton(withTitle: "打开\(AccessibilityPermission.paneName)")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
            }
            return
        }
        let delivery = HistoryPasteDelivery(target: target.processIdentifier, changeCount: changeCount)
        pendingHistoryPaste = delivery.id
        waitForTargetAndPaste(delivery, target: target, remaining: 12)
    }

    private func waitForTargetAndPaste(_ delivery: HistoryPasteDelivery, target: NSRunningApplication, remaining: Int) {
        switch delivery.decision(active: pendingHistoryPaste, changeCount: NSPasteboard.general.changeCount,
                                 foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                 targetAlive: !target.isTerminated, remaining: remaining) {
        case .superseded: return
        case .send:
            pendingHistoryPaste = nil
            ShortcutHoldMonitor.postUninterceptedPaste(to: delivery.target)
            CutsLog.write(.debug, "clipboard", "requested targeted paste in original app")
        case .clipboardChanged:
            pendingHistoryPaste = nil
            CutsLog.write(.info, "clipboard", "automatic paste skipped: clipboard changed")
            ActionFeedback.show("剪贴板已变化，未自动粘贴")
        case .targetUnavailable:
            pendingHistoryPaste = nil
            CutsLog.write(.warning, "clipboard", "automatic paste skipped: original app unavailable")
            ActionFeedback.show("已复制，请切回目标应用后按 ⌘V")
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForTargetAndPaste(delivery, target: target, remaining: remaining - 1)
            }
        }
    }

    @objc private func startCapture() {
        beginCapture(.screenshot)
    }

    @objc private func startLongCapture() {
        beginCapture(.longScreenshot)
    }

    private func beginCapture(_ purpose: CaptureFlow.Purpose, waitForClosingCapture: Bool = false) {
        guard coordinator == nil else {
            if waitForClosingCapture {
                queuedCapture = (purpose, ProcessInfo.processInfo.systemUptime + 0.45)
                CutsLog.write(.debug, "capture", "hold awaiting previous capture closure")
            } else {
                CutsLog.write(.debug, "capture", "invocation ignored: another capture is active")
            }
            return
        }
        let flow = CaptureFlow(purpose: purpose)
        coordinator = flow
        flow.onFinish = { [weak self, weak flow] in
            guard let self, let flow, self.coordinator === flow else { return }
            self.coordinator = nil
            let queued = self.queuedCapture
            self.queuedCapture = nil
            if let queued, queued.expires >= ProcessInfo.processInfo.systemUptime {
                DispatchQueue.main.async { [weak self] in
                    self?.beginCapture(queued.purpose)
                }
            }
        }
        Task { await flow.start() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func installShortcutHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr else { return result }
            guard hotKeyID.signature == 0x50534E32,
                  hotKeyID.id == ShortcutPreferences.Action.capture.rawValue else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in
                (NSApp.delegate as? RebuildApp)?.startCapture()
            }
            return noErr
        }, 1, &type, nil, nil)
    }

    private func unregisterPressedShortcuts() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func registerPressedShortcuts(_ preferences: ShortcutPreferences) -> [String] {
        unregisterPressedShortcuts()
        var unavailable: [String] = []
        for binding in preferences.bindings where !binding.hold {
            var ref: EventHotKeyRef?
            let key = EventHotKeyID(signature: 0x50534E32, id: binding.action.rawValue)
            if RegisterEventHotKey(UInt32(binding.chord.keyCode), binding.chord.carbonFlags, key,
                                   GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { hotKeys.append(ref) }
            else { unavailable.append(binding.chord.display) }
        }
        if !unavailable.isEmpty {
            CutsLog.write(.warning, "app", "hotkey registration conflicts=\(unavailable.count)")
        }
        return unavailable
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutHoldMonitor?.stop()
        mouseMonitor?.stop()
        unregisterPressedShortcuts()
    }

}

@main
struct RebuildMain {
    @MainActor private static var retainedDelegate: RebuildApp?

    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--rebind-installed-login-item") {
            guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Cuts.app" else { Foundation.exit(1) }
            do {
                let status = try LoginLaunchSettings.rebindAfterInstallation()
                print("LOGIN ITEM STATUS \(status)")
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Could not rebind the Cuts login item: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            let menuPassed = RebuildApp.verifyStatusMenu()
            let editorPassed = CaptureEditor.verifyOffscreen()
            let numberPassed = CaptureEditor.verifyNumberEditing()
            let textPositionPassed = CaptureEditor.verifyTextPosition()
            let textStylePassed = CaptureEditor.verifyTextStyleRanges()
            let magnifierPassed = CaptureEditor.verifyMagnifierEditing()
            let pinPlacementPassed = CaptureEditor.verifyPinnedPlacement()
            let pinBrushPassed = CaptureEditor.verifyPinnedBrushMenu()
            let lineAndDeletePassed = CaptureEditor.verifyLinePreviewAndDelete()
            let colorPickingPassed = CaptureFlow.verifyColorPicking()
            let arrowHandoffPassed = CaptureFlow.verifyArrowHandoff()
            let crossEditorPassed = CaptureEditor.verifyCrossDisplayEdits()
            let localEraserPassed = CaptureEditor.verifyLocalizedEraser()
            let selectionPassed = CaptureFlow.verifySelectionInteraction()
                && HoverHintButton.verifyOffscreen()
            let crossSelectionPassed = CaptureFlow.verifyCrossDisplaySelection()
            let displaysPassed = CaptureFlow.verifyMultiDisplay()
            let maskPassed = CaptureShape.verifyMask()
            let stitchPassed = VerticalStitcher.verifySynthetic() && LongCaptureRunner.verifyRegionMapping()
            let archivePassed = ClipboardArchive.verifyTemporaryArchive()
            let holdPassed = ShortcutHoldMonitor.verifyEngine() && ShortcutPreferences.verify() && HistoryPasteDelivery.verify()
            let savePassed = ImageSaveSettings.verifySynthetic()
            let popupPassed = CutsPopup.verifyOffscreen()
            let motionPassed = CutsMotion.verify()
            let mousePassed = MouseSettings.verify() && MouseEventMonitor.verifySynthetic()
                && MouseTrackingSpeed.verify()
            let settingsPassed = SettingsPanel.verifyOffscreen()
            let loggingPassed = CutsLog.verifyTemporaryLog()
            Task { @MainActor in
                // Give the UI fixture its own foreground identity even when the
                // regular Cuts menu-bar process is already running.
                NSApp.setActivationPolicy(.regular)
                let panelPassed = await ClipboardPanel.verifyOffscreen()
                print("menu=\(menuPassed) selection=\(selectionPassed) crossSelection=\(crossSelectionPassed) displays=\(displaysPassed) mask=\(maskPassed) stitch=\(stitchPassed) editor=\(editorPassed) textPosition=\(textPositionPassed) textStyles=\(textStylePassed) magnifier=\(magnifierPassed) pinPlacement=\(pinPlacementPassed) pinBrush=\(pinBrushPassed) arrowHandoff=\(arrowHandoffPassed) archive=\(archivePassed) panel=\(panelPassed) hold=\(holdPassed) save=\(savePassed) popup=\(popupPassed) mouse=\(mousePassed) settings=\(settingsPassed) logging=\(loggingPassed)")
                print("crossDisplayEditor=\(crossEditorPassed) localEraser=\(localEraserPassed) numberEditing=\(numberPassed)")
                print("linePreviewAndDelete=\(lineAndDeletePassed) colorPicking=\(colorPickingPassed) motion=\(motionPassed)")
                let passed = menuPassed && selectionPassed && crossSelectionPassed && displaysPassed && maskPassed && stitchPassed && editorPassed && numberPassed && textPositionPassed && textStylePassed && magnifierPassed && pinPlacementPassed && pinBrushPassed && lineAndDeletePassed && colorPickingPassed && arrowHandoffPassed && crossEditorPassed && localEraserPassed && archivePassed && panelPassed && holdPassed && savePassed && popupPassed && mousePassed && settingsPassed && loggingPassed && motionPassed
                print(passed ? "REBUILD SELF-TEST PASS" : "REBUILD SELF-TEST FAIL")
                Foundation.exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--verify-live-save-panel") {
            app.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                FileHandle.standardError.write(Data("LIVE SAVE PANEL CHECK TIMED OUT\n".utf8))
                Foundation.exit(1)
            }
            Task { @MainActor in
                let passed = await ScreenshotSaveDialog.verifyLivePanel()
                print(passed ? "LIVE SAVE PANEL CHECK PASS" : "LIVE SAVE PANEL CHECK FAIL")
                Foundation.exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--verify-live-displays") {
            Task { @MainActor in
                let passed = await CaptureFlow.verifyLiveDisplays()
                print(passed ? "LIVE DISPLAY CHECK PASS" : "LIVE DISPLAY CHECK FAIL")
                Foundation.exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--verify-live-long-capture") {
            Task { @MainActor in
                let passed = await LongCaptureRunner.verifyLiveFixture()
                print(passed ? "LIVE LONG CAPTURE CHECK PASS" : "LIVE LONG CAPTURE CHECK FAIL")
                Foundation.exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--verify-live-overlays") {
            Task { @MainActor in
                let passed = await CaptureFlow.verifyLiveOverlayPlacement()
                print(passed ? "LIVE OVERLAY CHECK PASS" : "LIVE OVERLAY CHECK FAIL")
                Foundation.exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CaptureEditor.writeToolbarPreview(to: url)
            print(passed ? "UI PREVIEW WRITTEN" : "UI PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-color-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CaptureEditor.writeColorPickerPreview(to: url)
            print(passed ? "COLOR PREVIEW WRITTEN" : "COLOR PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-text-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let passed = CaptureEditor.verifyTextPosition(previewDirectory: directory)
            print(passed ? "TEXT PREVIEW WRITTEN" : "TEXT POSITION CHECK FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-text-style-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CaptureEditor.verifyTextStyleRanges(previewURL: url)
            print(passed ? "TEXT STYLE PREVIEW WRITTEN" : "TEXT STYLE CHECK FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-ocr-image"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("OCR IMAGE READ FAILED")
                Foundation.exit(1)
            }
            OCRTextRecognition.recognize(image) { result in
                switch result {
                case .success(let document):
                    let valid = !document.glyphs.isEmpty && document.glyphs.allSatisfy {
                        CGRect(x: 0, y: 0, width: 1, height: 1).intersects($0.box)
                    }
                    let invalid = document.glyphs.filter {
                        !CGRect(x: 0, y: 0, width: 1, height: 1).intersects($0.box)
                    }
                    print("ocr-glyphs=\(document.glyphs.count) positions-valid=\(valid) invalid=\(invalid.count) examples=\(invalid.prefix(3).map(\.box))")
                    Foundation.exit(valid ? 0 : 1)
                case .failure(let error):
                    print("OCR FAILED: \(error.localizedDescription)")
                    Foundation.exit(1)
                }
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-arrow-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CaptureEditor.writeArrowPreview(to: url)
            print(passed ? "ARROW PREVIEW WRITTEN" : "ARROW PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-app-icon"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = AppIcon.render(to: url)
            print(passed ? "APP ICON WRITTEN" : "APP ICON FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-iconset"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let passed = AppIcon.renderIconSet(to: url)
            print(passed ? "ICONSET WRITTEN" : "ICONSET FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-popup-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CommandLine.arguments.contains("--show-text-menu")
                ? CaptureEditor.writeTextMenuPreview(to: url) : CutsPopup.writePreview(to: url)
            print(passed ? "POPUP PREVIEW WRITTEN" : "POPUP PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-panel-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = ClipboardPanel.writePreview(to: url)
            print(passed ? "PANEL PREVIEW WRITTEN" : "PANEL PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings-preview"),
           CommandLine.arguments.indices.contains(index + 2) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            let passed = SettingsPanel.writePreview(to: url, page: CommandLine.arguments[index + 1],
                                                    dirty: CommandLine.arguments.contains("--show-settings-dirty"),
                                                    editing: CommandLine.arguments.contains("--show-input-focus"))
            print(passed ? "SETTINGS PREVIEW WRITTEN" : "SETTINGS PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-selection-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let passed = CaptureFlow.writeSelectionPreview(to: url,
                                                            showingMenu: CommandLine.arguments.contains("--show-shape-menu"))
            print(passed ? "SELECTION PREVIEW WRITTEN" : "SELECTION PREVIEW FAILED")
            Foundation.exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--idle-benchmark") {
            app.setActivationPolicy(.accessory)
            let monitor = ClipboardMonitor(archive: ClipboardArchive())
            monitor.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                var usage = rusage()
                _ = getrusage(RUSAGE_SELF, &usage)
                let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                print("IDLE BENCHMARK maxRSS=\(Double(usage.ru_maxrss) / 1_048_576) MiB cpu=\(cpu) s / 8 s")
                Foundation.exit(0)
            }
            app.run()
            return
        }
        let delegate = RebuildApp()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
