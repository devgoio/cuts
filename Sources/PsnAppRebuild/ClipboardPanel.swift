import AppKit
import ImageIO

@MainActor
final class ClipboardPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var onPaste: ((ClipboardRecord) -> Void)?
    var onEditImage: ((ClipboardRecord) -> Void)?
    var onClose: (() -> Void)?

    private let archive: ClipboardArchive
    private let panel: ClipboardHistoryWindow
    private let defaults: UserDefaults
    private static let sizeKey = "ClipboardHistory.contentSize"
    private static let initialSize = CGSize(width: 520, height: 450)
    private static let minimumSize = CGSize(width: 400, height: 300)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let search = ClipboardSearchField()
    private let searchSurface = ClipboardSearchSurface()
    private let clearSearch = PointingButton()
    private let countLabel = NSTextField(labelWithString: "")
    private var filtered: [ClipboardRecord] = []
    private enum Tab: Int, CaseIterable {
        case history, favorites
        var title: String { self == .history ? "历史" : "收藏" }
    }
    private var tab = Tab.history
    private var tabButtons: [Tab: NSButton] = [:]
    private let imagePreview = ClipboardImagePreview()
    fileprivate enum RowAction { case edit, favorite, delete }
    private enum PointerHit: Equatable {
        case tab(Tab)
        case row(UUID, RowAction)
    }
    private var pressedAction: PointerHit?

    static func writePreview(to url: URL) -> Bool {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("psn-panel-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let archive = ClipboardArchive(directory: path)
        archive.addText("产品追溯标签 · 复制的文字内容")
        archive.addFiles(["/tmp/报表.xlsx", "/tmp/截图.png"])
        archive.addText("LabelEditor 标签编辑与打印")
        if let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(LEStyle.selected.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            context.setFillColor(LEStyle.color(0x4096FF).cgColor)
            context.fill(CGRect(x: 380, y: 60, width: 180, height: 280))
            if let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                archive.addImage(data, type: NSPasteboard.PasteboardType.png.rawValue)
            }
        }
        if let first = archive.records.first { archive.toggleFavorite(first) }
        let preview = ClipboardPanel(archive: archive)
        preview.updateSearchAppearance(isEditing: true)
        preview.panel.displayIfNeeded()
        guard let content = preview.panel.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func verifyOffscreen() async -> Bool {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("psn-panel-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let suite = "com.psn.Cuts.clipboard-size-test." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = ClipboardArchive(directory: path)
        archive.addText("hello panel")
        archive.addText("another item")
        let panel = ClipboardPanel(archive: archive, defaults: defaults)
        guard panel.filtered.count == 2, panel.table.numberOfRows == 2,
              panel.panel.titleVisibility == .hidden,
              panel.panel.contentView?.subviews.compactMap({ $0 as? NSTextField })
                .contains(where: { $0.stringValue == "剪贴板历史" }) == false,
              panel.search.focusRingType == .none, panel.tab == .history,
              panel.tabButtons.count == 2 else { return false }
        panel.moveSelection(1)
        guard panel.table.selectedRow == 1 else { return false }
        panel.moveSelection(-1)
        guard panel.table.selectedRow == 0 else { return false }
        panel.search.stringValue = "hello"
        panel.applyFilter()
        guard panel.filtered.count == 1, let found = panel.filtered.first, found.text == "hello panel" else { return false }
        panel.toggleFavorite(found)
        panel.tabButtons[.favorites]?.performClick(nil)
        guard panel.tab == .favorites, panel.filtered.map(\.id) == [found.id] else { return false }
        panel.toggleFavorite(found)
        guard panel.filtered.isEmpty && archive.records.count == 2 else { return false }
        guard let bitmap = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = bitmap.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let imageRecord = archive.addImage(data, type: NSPasteboard.PasteboardType.png.rawValue) else { return false }
        panel.show()
        defer { panel.close() }
        guard panel.panel.styleMask.contains(.resizable),
              panel.panel.contentView?.bounds.size == initialSize else { return false }
        let expanded = CGSize(width: 630, height: 520)
        let oldSearch = panel.searchSurface.frame
        let oldList = panel.scroll.frame
        panel.panel.setContentSize(expanded)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel.panel)
        panel.refresh()
        guard panel.panel.contentView?.bounds.size == expanded,
              panel.searchSurface.frame.width - oldSearch.width == 110,
              panel.scroll.frame.width - oldList.width == 110,
              panel.scroll.frame.height - oldList.height == 70,
              panel.restoredSize(fitting: CGRect(x: 0, y: 0, width: 470, height: 370)).width == 470 else {
            print("clipboard resize layout or storage failed")
            return false
        }
        panel.panel.displayIfNeeded()
        // Let AppKit deliver its initial tracking and key-window notifications
        // before simulating a pointer entry into the thumbnail.
        try? await Task.sleep(for: .milliseconds(120))
        guard panel.tab == .history, panel.search.currentEditor() != nil,
              let firstRow = panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ClipboardRowView,
              firstRow.window === panel.panel else {
            print("clipboard fixture did not open the history tab with initial search focus")
            return false
        }
        firstRow.hoverImageForTest(true)
        let deadline = Date().addingTimeInterval(1.5)
        while !panel.imagePreview.isVisible && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard panel.imagePreview.isVisible, panel.panel.isKeyWindow else {
            print("clipboard thumbnail preview: visible=\(panel.imagePreview.isVisible) hostVisible=\(panel.panel.isVisible) hostKey=\(panel.panel.isKeyWindow) pending=\(panel.imagePreview.hasPendingPreview)")
            return false
        }
        firstRow.hoverImageForTest(false)
        guard !panel.imagePreview.isVisible else { return false }
        var imageToEdit: ClipboardRecord?
        panel.onEditImage = { imageToEdit = $0 }
        guard firstRow.clickEditForTest(), imageToEdit?.id == imageRecord.id,
              archive.originalImage(for: imageRecord)?.width == 320 else {
            print("clipboard pencil click failed")
            return false
        }
        guard firstRow.clickFavoriteForTest(), archive.isFavorite(imageRecord) else {
            print("clipboard star click failed")
            return false
        }
        guard let historyRow = panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ClipboardRowView,
              historyRow.clickDeleteForTest(), !panel.filtered.contains(where: { $0.id == imageRecord.id }),
              archive.isFavorite(imageRecord), archive.originalImage(for: imageRecord)?.width == 320 else {
            print("clipboard history delete did not preserve the favorite")
            return false
        }
        guard let favorites = panel.tabButtons[.favorites],
              clickControlForTest(favorites), panel.tab == .favorites,
              panel.filtered.map(\.id) == [imageRecord.id],
              let favoriteRow = panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ClipboardRowView,
              !favoriteRow.clickDeleteForTest() else {
            print("clipboard favorites tab click failed")
            return false
        }
        panel.close()
        let reopened = ClipboardPanel(archive: archive, defaults: defaults)
        reopened.show()
        defer { reopened.close() }
        return reopened.panel.contentView?.bounds.size == expanded && reopened.tab == .history
    }

    fileprivate static func clickControlForTest(_ button: NSButton) -> Bool {
        guard let window = button.window, !button.isHidden else { return false }
        let rect = button.convert(button.bounds, to: nil)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                 clickCount: 1, pressure: 1) else { return false }
            NSApp.sendEvent(event)
        }
        return true
    }

    init(archive: ClipboardArchive, defaults: UserDefaults = .standard) {
        self.archive = archive
        self.defaults = defaults
        panel = ClipboardHistoryWindow(contentRect: CGRect(origin: .zero, size: Self.initialSize),
                                       styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        super.init()
        setup()
        refresh()
    }

    func show() {
        tab = .history
        updateTabs()
        search.stringValue = ""
        applyFilter()
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? panel.frame
        let size = restoredSize(fitting: visible)
        if panel.contentView?.bounds.size != size { panel.setContentSize(size) }
        let origin = CGPoint(x: max(visible.minX, min(visible.maxX - panel.frame.width, mouse.x - panel.frame.width / 2)),
                             y: max(visible.minY, min(visible.maxY - panel.frame.height, mouse.y - panel.frame.height + 60)))
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        updateSearchAppearance()
        if let content = panel.contentView { CutsMotion.appear(content, .window, from: CGPoint(x: 0, y: -7)) }
    }

    func close() { panel.close() }
    func windowWillClose(_ notification: Notification) { imagePreview.hide(); onClose?() }
    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { panel.close() }
    }

    func windowWillStartLiveResize(_ notification: Notification) { imagePreview.hide() }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = panel.contentView?.bounds.size else { return }
        defaults.set([Double(size.width), Double(size.height)], forKey: Self.sizeKey)
    }

    private func restoredSize(fitting visible: CGRect) -> CGSize {
        let saved = defaults.array(forKey: Self.sizeKey) as? [Double]
        let preferred: CGSize
        if let saved, saved.count == 2, saved.allSatisfy({ $0.isFinite && $0 > 0 }) {
            preferred = CGSize(width: saved[0], height: saved[1])
        } else {
            preferred = Self.initialSize
        }
        let maxContent = panel.contentRect(forFrameRect: visible).size
        return CGSize(width: min(max(preferred.width, Self.minimumSize.width), maxContent.width),
                      height: min(max(preferred.height, Self.minimumSize.height), maxContent.height))
    }

    func refresh() { applyFilter(preservingSelection: true) }

    private func setup() {
        panel.title = "剪贴板历史"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentMinSize = Self.minimumSize
        panel.onPointerEvent = { [weak self] in self?.routePointerAction($0) == true }
        panel.onImageShortcut = { [weak self] in self?.imageShortcut(edit: $0) == true }
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.8
        content.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.52).cgColor
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur, positioned: .below, relativeTo: nil)
        let tint = NSView(frame: content.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = LEStyle.container.withAlphaComponent(0.50).cgColor
        content.addSubview(tint, positioned: .above, relativeTo: blur)

        var tabX: CGFloat = 20
        for tab in Tab.allCases {
            let button = PointingButton(title: tab.title, target: self, action: #selector(changeTab(_:)))
            let width: CGFloat = 75
            button.frame = CGRect(x: tabX, y: 363, width: width, height: 34)
            button.autoresizingMask = [.minYMargin]
            button.tag = tab.rawValue
            button.font = .systemFont(ofSize: 12, weight: .medium)
            LEStyle.icon(button)
            content.addSubview(button)
            tabButtons[tab] = button
            tabX += width + 9
        }
        updateTabs()

        searchSurface.frame = CGRect(x: tabX, y: 363, width: 500 - tabX, height: 34)
        searchSurface.autoresizingMask = [.width, .minYMargin]
        LEStyle.surface(searchSurface, radius: 8)
        searchSurface.onClick = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.search)
            self.updateSearchAppearance()
        }
        content.addSubview(searchSurface)
        let searchIcon = NSImageView(frame: CGRect(x: 11, y: 10, width: 14, height: 14))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = LEStyle.secondary
        searchSurface.addSubview(searchIcon)
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 13, weight: .regular)
        search.textColor = LEStyle.text
        search.cell?.usesSingleLineMode = true
        search.placeholderAttributedString = NSAttributedString(string: "搜索文字或文件名",
                                                                  attributes: [.foregroundColor: LEStyle.secondary])
        search.setAccessibilityLabel("搜索文字或文件名")
        search.frame = CGRect(x: 33, y: 7, width: searchSurface.bounds.width - 69, height: 20)
        search.autoresizingMask = [.width]
        search.delegate = self
        search.onNavigate = { [weak self] offset in self?.moveSelection(offset) }
        search.onConfirm = { [weak self] in self?.pasteSelected() }
        search.onCancel = { [weak self] in self?.close() }
        searchSurface.addSubview(search)
        clearSearch.target = self
        clearSearch.action = #selector(clearQuery)
        clearSearch.frame = CGRect(x: searchSurface.bounds.maxX - 29, y: 5, width: 24, height: 24)
        clearSearch.autoresizingMask = [.minXMargin]
        clearSearch.image = MenuIcon.symbol("xmark.circle.fill", description: "清空搜索")
        clearSearch.imagePosition = .imageOnly
        clearSearch.setAccessibilityLabel("清空搜索")
        LEStyle.icon(clearSearch)
        searchSurface.addSubview(clearSearch)
        updateSearchAppearance()

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = LEStyle.secondary
        countLabel.frame = CGRect(x: 22, y: 340, width: 320, height: 18)
        countLabel.autoresizingMask = [.minYMargin]
        content.addSubview(countLabel)

        scroll.frame = CGRect(x: 20, y: 60, width: 480, height: 278)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        LEStyle.frostedSurface(scroll)
        scroll.drawsBackground = false
        table.headerView = nil
        table.rowHeight = 52
        table.intercellSpacing = CGSize(width: 0, height: 1)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = scroll.contentSize.width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.doubleAction = #selector(pasteSelected)
        scroll.documentView = table
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: "双击条目，或选中后点击“粘贴”")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = LEStyle.secondary
        hint.frame = CGRect(x: 21, y: 22, width: 320, height: 20)
        hint.autoresizingMask = [.width]
        hint.lineBreakMode = .byTruncatingTail
        content.addSubview(hint)
        let paste = PointingButton(title: "粘贴", target: self, action: #selector(pasteSelected))
        paste.appearance = NSAppearance(named: .darkAqua)
        paste.isBordered = false
        paste.wantsLayer = true
        paste.layer?.backgroundColor = LEStyle.primary.cgColor
        paste.layer?.cornerRadius = 7
        paste.attributedTitle = NSAttributedString(string: "粘贴", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ])
        paste.keyEquivalent = "\r"
        paste.frame = CGRect(x: 418, y: 17, width: 80, height: 28)
        paste.autoresizingMask = [.minXMargin]
        content.addSubview(paste)
    }

    private func updateTabs() {
        for (value, button) in tabButtons {
            LEStyle.applySelection(button, active: value == tab)
            button.setAccessibilityValue(value == tab ? "已选中" : "未选中")
        }
    }

    @objc private func changeTab(_ sender: NSButton) {
        if let selected = Tab(rawValue: sender.tag) { selectTab(selected) }
    }

    private func selectTab(_ selected: Tab) {
        guard tab != selected else { return }
        let direction: CGFloat = selected.rawValue > tab.rawValue ? 6 : -6
        tab = selected
        updateTabs()
        applyFilter()
        CutsMotion.appear(scroll, .page, from: CGPoint(x: direction, y: 0))
    }

    private func toggleFavorite(_ record: ClipboardRecord) {
        guard archive.toggleFavorite(record) else { ActionFeedback.show("未能更新收藏"); return }
        let nowFavorite = archive.isFavorite(record)
        applyFilter(preservingSelection: true, animateRemovalOf: tab == .favorites && !nowFavorite ? record.id : nil)
        if let index = filtered.firstIndex(where: { $0.id == record.id }),
           let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ClipboardRowView {
            cell.acknowledgeFavorite(active: nowFavorite)
        }
    }

    private func deleteHistory(_ record: ClipboardRecord) {
        guard tab == .history else { return }
        guard archive.delete(record) else { ActionFeedback.show("未能删除历史记录"); return }
        CutsLog.write(.info, "clipboard", "removed history record")
        applyFilter(preservingSelection: true, animateRemovalOf: record.id)
    }

    private func routePointerAction(_ event: NSEvent) -> Bool {
        func hit() -> PointerHit? {
            let location = event.locationInWindow
            if let tab = tabButtons.first(where: { $0.value.bounds.contains($0.value.convert(location, from: nil)) })?.key {
                return .tab(tab)
            }
            let point = table.convert(location, from: nil)
            guard table.visibleRect.contains(point) else { return nil }
            let index = table.row(at: point)
            guard filtered.indices.contains(index),
                  let row = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ClipboardRowView,
                  let action = row.action(at: event.locationInWindow) else { return nil }
            return .row(filtered[index].id, action)
        }
        switch event.type {
        case .leftMouseDown:
            pressedAction = hit()
            return pressedAction != nil
        case .leftMouseDragged:
            return pressedAction != nil
        case .leftMouseUp:
            guard let pressed = pressedAction else { return false }
            pressedAction = nil
            guard pressed == hit() else { return true }
            switch pressed {
            case .tab(let selected): selectTab(selected)
            case .row(let id, let action):
                guard let record = filtered.first(where: { $0.id == id }) else { return true }
                switch action {
                case .edit: onEditImage?(record)
                case .favorite: toggleFavorite(record)
                case .delete: deleteHistory(record)
                }
            }
            return true
        default: return false
        }
    }

    @objc private func clearQuery() {
        search.stringValue = ""
        if let editor = search.currentEditor() { editor.string = "" }
        applyFilter()
        panel.makeFirstResponder(search)
        updateSearchAppearance()
    }

    private func updateSearchAppearance(isEditing: Bool? = nil) {
        let focused = isEditing ?? (search.currentEditor() != nil)
        searchSurface.layer?.borderWidth = focused ? 1 : 0.7
        searchSurface.layer?.borderColor = (focused ? LEStyle.color(0x5986AC) : LEStyle.border).cgColor
        CutsMotion.background(focused ? LEStyle.color(0x1A2537) : LEStyle.color(0x141C2B), on: searchSurface.layer)
        clearSearch.isHidden = (search.currentEditor()?.string ?? search.stringValue).isEmpty
    }

    func controlTextDidBeginEditing(_ notification: Notification) { updateSearchAppearance(isEditing: true) }
    func controlTextDidEndEditing(_ notification: Notification) { updateSearchAppearance(isEditing: false) }
    func controlTextDidChange(_ notification: Notification) { applyFilter(); updateSearchAppearance() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): pasteSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let current = max(0, table.selectedRow)
        let next = min(filtered.count - 1, max(0, current + offset))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func applyFilter(preservingSelection: Bool = false, animateRemovalOf removed: UUID? = nil) {
        imagePreview.hide()
        let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        let oldItems = removed == nil ? [] : filtered.map(\.id)
        let query = (search.currentEditor()?.string ?? search.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        let records = tab == .history ? archive.records : archive.favorites
        filtered = query.isEmpty ? records : records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.text?.localizedCaseInsensitiveContains(query) == true
                || $0.filePaths?.contains(where: { $0.localizedCaseInsensitiveContains(query) }) == true
        }
        countLabel.stringValue = tab == .history ? "\(filtered.count) 条记录 · 文字、图片、文件"
            : "\(filtered.count) 条收藏 · 最多 \(ClipboardArchive.maxFavorites) 条"
        if CutsMotion.enabled, panel.isVisible, let removed, let index = oldItems.firstIndex(of: removed),
           oldItems.filter({ $0 != removed }) == filtered.map(\.id), table.numberOfRows == oldItems.count {
            table.removeRows(at: IndexSet(integer: index), withAnimation: .effectFade)
        } else {
            table.reloadData()
        }
        if !filtered.isEmpty {
            let index = preservingSelection ? (filtered.firstIndex(where: { $0.id == selected }) ?? 0) : 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func refreshThumbnail(_ id: UUID) {
        guard panel.isVisible, let row = filtered.firstIndex(where: { $0.id == id }), table.numberOfColumns > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func imageShortcut(edit: Bool) -> Bool {
        let row = table.selectedRow
        guard filtered.indices.contains(row), let source = archive.previewSource(for: filtered[row]) else { return false }
        if edit { onEditImage?(filtered[row]); return true }
        if imagePreview.isVisible { imagePreview.hide(); return true }
        table.scrollRowToVisible(row)
        if let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) {
            imagePreview.show(source: source, from: view, host: panel)
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LERowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let record = filtered[row]
        let id = NSUserInterfaceItemIdentifier("clipboard-entry")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClipboardRowView ?? ClipboardRowView()
        cell.identifier = id
        cell.configure(record, archive: archive, canDelete: tab == .history,
                       onFavorite: { [weak self] in self?.toggleFavorite(record) },
                       onEdit: { [weak self] in self?.onEditImage?(record) },
                       onDelete: { [weak self] in self?.deleteHistory(record) },
                       onImageHover: { [weak self] icon, entered in
            guard let self else { return }
            if entered, let source = self.archive.previewSource(for: record) {
                self.imagePreview.show(source: source, from: icon, host: self.panel)
            } else if !entered {
                self.imagePreview.hide(from: icon)
            }
        })
        return cell
    }

    @objc private func pasteSelected() {
        let index = table.selectedRow
        guard filtered.indices.contains(index) else { NSSound.beep(); return }
        onPaste?(filtered[index])
    }
}

private final class ClipboardHistoryWindow: NSPanel {
    var onPointerEvent: ((NSEvent) -> Bool)?
    var onImageShortcut: ((Bool) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .option,
           [36, 49, 76].contains(event.keyCode), onImageShortcut?(event.keyCode != 49) == true { return }
        if onPointerEvent?(event) != true { super.sendEvent(event) }
    }
    override func cancelOperation(_ sender: Any?) { close() }
}

private final class ClipboardSearchSurface: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class ClipboardSearchField: NSTextField {
    var onNavigate: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onNavigate?(1)
        case 126: onNavigate?(-1)
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

private final class LERowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        LEStyle.selected.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

private final class ClipboardRowView: NSTableCellView {
    private let icon = ClipboardThumbnail()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let favorite = PointingButton()
    private let edit = PointingButton()
    private let delete = PointingButton()
    private var onFavorite: (() -> Void)?
    private var onEdit: (() -> Void)?
    private var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.frame = CGRect(x: 12, y: 8, width: 36, height: 36)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = LEStyle.text
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = CGRect(x: 59, y: 26, width: 342, height: 20)
        addSubview(titleField)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = LEStyle.secondary
        subtitle.frame = CGRect(x: 59, y: 8, width: 342, height: 16)
        addSubview(subtitle)
        favorite.frame = CGRect(x: 433, y: 13, width: 28, height: 26)
        favorite.target = self
        favorite.action = #selector(toggleFavorite)
        favorite.imagePosition = .imageOnly
        LEStyle.icon(favorite)
        addSubview(favorite)
        edit.frame = CGRect(x: 400, y: 13, width: 28, height: 26)
        edit.target = self
        edit.action = #selector(editImage)
        edit.image = MenuIcon.symbol("square.and.pencil", description: "标注图片")
        edit.imagePosition = .imageOnly
        edit.toolTip = "标注图片"
        edit.setAccessibilityLabel("标注图片")
        LEStyle.icon(edit)
        edit.contentTintColor = LEStyle.secondary
        addSubview(edit)
        delete.frame = CGRect(x: 0, y: 13, width: 28, height: 26)
        delete.target = self
        delete.action = #selector(deleteHistory)
        delete.image = MenuIcon.symbol("trash", description: "删除历史记录")
        delete.imagePosition = .imageOnly
        delete.toolTip = "删除历史记录"
        delete.setAccessibilityLabel("删除历史记录")
        LEStyle.icon(delete)
        delete.contentTintColor = LEStyle.danger
        addSubview(delete)
        layoutContents()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        delete.frame.origin.x = max(0, bounds.width - 39)
        favorite.frame.origin.x = max(0, delete.frame.minX - (delete.isHidden ? 0 : 33))
        edit.frame.origin.x = max(0, favorite.frame.minX - 33)
        let textWidth = max(0, (edit.isHidden ? favorite : edit).frame.minX - titleField.frame.minX - 8)
        titleField.frame.size.width = textWidth
        subtitle.frame.size.width = textWidth
    }

    @objc private func toggleFavorite() { onFavorite?() }
    @objc private func editImage() { onEdit?() }
    @objc private func deleteHistory() { onDelete?() }
    func action(at point: CGPoint) -> ClipboardPanel.RowAction? {
        if !edit.isHidden && edit.bounds.contains(edit.convert(point, from: nil)) { return .edit }
        if favorite.bounds.contains(favorite.convert(point, from: nil)) { return .favorite }
        if !delete.isHidden && delete.bounds.contains(delete.convert(point, from: nil)) { return .delete }
        return nil
    }

    func clickEditForTest() -> Bool { ClipboardPanel.clickControlForTest(edit) }
    func clickFavoriteForTest() -> Bool { ClipboardPanel.clickControlForTest(favorite) }
    func clickDeleteForTest() -> Bool { ClipboardPanel.clickControlForTest(delete) }
    func hoverImageForTest(_ entered: Bool) { icon.onHover?(icon, entered) }

    func acknowledgeFavorite(active: Bool) {
        CutsMotion.accent(in: favorite, color: active ? LEStyle.color(0xFAAD14) : LEStyle.secondary, radius: 5)
    }

    func configure(_ record: ClipboardRecord, archive: ClipboardArchive, canDelete: Bool,
                   onFavorite: @escaping () -> Void, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void,
                   onImageHover: @escaping (NSView, Bool) -> Void) {
        icon.onHover?(icon, false)
        icon.onHover = record.kind == .image ? onImageHover : nil
        self.onFavorite = onFavorite
        self.onEdit = record.kind == .image ? onEdit : nil
        self.onDelete = canDelete ? onDelete : nil
        edit.isHidden = record.kind != .image
        delete.isHidden = !canDelete
        layoutContents()
        let saved = archive.isFavorite(record)
        let title = saved ? "取消收藏" : "收藏"
        favorite.image = MenuIcon.symbol(saved ? "star.fill" : "star", description: title)
        favorite.contentTintColor = saved ? LEStyle.color(0xFAAD14) : LEStyle.secondary
        favorite.toolTip = title
        favorite.setAccessibilityLabel(title)
        titleField.stringValue = record.title.isEmpty ? "（空白）" : record.title
        let type: String
        switch record.kind {
        case .text:
            type = "文字"
            icon.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: type)
        case .image:
            type = "图片"
            icon.image = NSImage(contentsOf: archive.thumbnailURL(for: record))
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: type)
        case .files:
            type = "文件"
            if let path = record.filePaths?.first, FileManager.default.fileExists(atPath: path) {
                icon.image = NSWorkspace.shared.icon(forFile: path)
            } else {
                icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: type)
            }
        }
        subtitle.stringValue = "\(type) · \(record.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private final class ClipboardThumbnail: NSImageView {
    var onHover: ((NSView, Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { onHover?(self, false) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onHover?(self, false) }
        super.viewWillMove(toWindow: newWindow)
    }
}

@MainActor
private final class ClipboardImagePreview {
    private var preview: NSPanel?
    private var pending: Task<Void, Never>?
    private weak var anchorView: NSView?
    var isVisible: Bool { preview?.isVisible == true }
    var hasPendingPreview: Bool { pending != nil }

    func show(source: URL, from view: NSView, host: NSWindow) {
        hide()
        anchorView = view
        pending = Task { [weak self, weak view, weak host] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { Self.decode(source) }.value
            guard !Task.isCancelled, let self, let view, let host, let image,
                  host.isKeyWindow, view.window === host else { return }
            self.present(image, from: view, host: host)
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        try? ClipboardImageReader.decode(url, maximumSide: 880)
    }

    private func present(_ image: CGImage, from view: NSView, host: NSWindow) {
        let size = CGSize(width: image.width, height: image.height)
        let limit = CGSize(width: 440, height: 320)
        let scale = min(limit.width / size.width, limit.height / size.height)
        let contentSize = CGSize(width: size.width * scale + 16, height: size.height * scale + 16)
        let thumbnail = host.convertToScreen(view.convert(view.bounds, to: nil))
        let point = CGPoint(x: thumbnail.midX, y: thumbnail.midY)
        let anchor = PopupAnchor.anchored(to: point, avoid: host.frame, fallbackScreen: host.screen)
        let target = anchor.submenu(for: contentSize, parent: host.frame, row: thumbnail, preferred: .right).0
        let vertical = anchor.frame(for: contentSize, keepFullHeight: true)
        let frame = target.intersects(host.frame) && !vertical.intersects(host.frame) ? vertical : target
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: host.level.rawValue + 1)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        LEStyle.surface(content)
        let imageView = NSImageView(frame: content.bounds.insetBy(dx: 8, dy: 8))
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)
        panel.contentView = content
        preview = panel
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        CutsMotion.appear(content, .popup, from: CutsMotion.direction(from: point, toward: frame))
    }

    func hide(from view: NSView? = nil) {
        if let view, anchorView !== view { return }
        pending?.cancel()
        pending = nil
        anchorView = nil
        if let preview {
            preview.parent?.removeChildWindow(preview)
            preview.orderOut(nil)
            self.preview = nil
        }
    }
}
