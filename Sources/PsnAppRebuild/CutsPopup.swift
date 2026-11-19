import AppKit

@MainActor
final class CutsPopup: NSObject {
    private final class PopupWindow: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class ActionProbe: NSObject {
        var calls = 0
        @objc func choose(_ item: NSMenuItem) { calls += 1 }
        @objc func chooseWithoutArgument() { calls += 1 }
    }

    private enum Spacing {
        static let card: CGFloat = 10
        static let vertical: CGFloat = 10
        static let leading: CGFloat = 9
        static let trailing: CGFloat = 12
        static let glyph: CGFloat = 16
        static let glyphGap: CGFloat = 8
        static let check: CGFloat = 16
        static let indicator: CGFloat = 9
        static let trailingGap: CGFloat = 6
    }

    private final class RowContent: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class RowButton: PointingButton {
        override var usesSharedPointerTracking: Bool { false }
        private var pressed = false
        private var hovered = false
        var keyboardHighlighted = false { didSet { refreshBackground() } }
        private let horizontalStroke = CALayer()
        private let verticalStroke = CALayer()
        private let content = RowContent()
        private let glyph = NSImageView()
        private let label = SingleLineInputField.rowLabel("")
        private let check = NSImageView()
        private var reservesIcon = false
        var hasSubmenu = false { didSet { needsLayout = true } }
        var expanded = false {
            didSet {
                refreshBackground()
                if hasSubmenu { CutsMotion.indicatorStroke(verticalStroke, visible: !expanded, animated: oldValue != expanded) }
            }
        }
        var onHover: ((RowButton, Bool) -> Void)?
        var indicator: String { hasSubmenu ? (expanded ? "−" : "+") : "" }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            pressed = true
            refreshBackground()
        }

        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            hovered = inside
            refreshBackground()
            // Do not enter NSButton's nested mouse-tracking loop in a
            // transient panel. One down/up pair sends exactly one action.
            if inside, isEnabled { sendAction(action, to: target) }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) {
            changeHover(true)
        }
        override func mouseExited(with event: NSEvent) {
            changeHover(false)
        }
        func changeHover(_ active: Bool) {
            hovered = active
            refreshBackground()
            onHover?(self, active)
        }
        private func refreshBackground() {
            let fill: NSColor = pressed ? LEStyle.primary.withAlphaComponent(0.6)
                : hovered || expanded || keyboardHighlighted ? LEStyle.selected : .clear
            CutsMotion.background(fill, on: layer)
        }

        func setContents(title: String, image: NSImage?, tone: NSColor, checked: Bool, reservesIcon: Bool) {
            if content.superview == nil {
                glyph.imageScaling = .scaleProportionallyDown
                label.lineBreakMode = .byTruncatingTail
                check.image = MenuIcon.symbol("checkmark", description: "已选中")
                check.imageScaling = .scaleProportionallyDown
                content.setAccessibilityElement(false)
                for view in [glyph, label, check] as [NSView] {
                    view.setAccessibilityElement(false)
                    content.addSubview(view)
                }
                addSubview(content)
            }
            self.reservesIcon = reservesIcon
            glyph.image = image
            glyph.contentTintColor = tone
            glyph.alphaValue = isEnabled || image?.isTemplate == true ? 1 : 0.42
            glyph.isHidden = image == nil
            label.font = font
            label.stringValue = title
            label.textColor = tone
            check.contentTintColor = tone
            check.isHidden = !checked
            setAccessibilityLabel(title)
            setAccessibilityValue(checked ? "已选中" : nil)
            needsLayout = true
        }

        func contentIsInset() -> Bool {
            layoutSubtreeIfNeeded()
            guard !glyph.isHidden,
                  glyph.frame.minX == Spacing.leading,
                  label.frame.minX - glyph.frame.maxX == Spacing.glyphGap else { return false }
            // Test against the actual row, not just the mouse target at the label.
            return content.hitTest(CGPoint(x: glyph.frame.midX, y: glyph.frame.midY)) == nil
        }

        func checkIsVisible() -> Bool {
            layoutSubtreeIfNeeded()
            let indicatorLeft = bounds.maxX - Spacing.trailing - (hasSubmenu ? Spacing.indicator : 0)
            return !check.isHidden && check.image != nil && check.frame.width == Spacing.check
                && bounds.contains(check.frame) && label.frame.maxX + Spacing.trailingGap <= check.frame.minX
                && check.frame.maxX + (hasSubmenu ? Spacing.trailingGap : 0) <= indicatorLeft
        }

        override func layout() {
            super.layout()
            if content.superview != nil {
                content.frame = bounds
                let x = Spacing.leading + (reservesIcon ? Spacing.glyph + Spacing.glyphGap : 0)
                let indicatorWidth = hasSubmenu ? Spacing.indicator + Spacing.trailingGap : 0
                let checkRight = bounds.maxX - Spacing.trailing - indicatorWidth
                let right = checkRight - (check.isHidden ? 0 : Spacing.check + Spacing.trailingGap)
                glyph.frame = CGRect(x: Spacing.leading, y: bounds.midY - Spacing.glyph / 2,
                                     width: Spacing.glyph, height: Spacing.glyph)
                label.frame = CGRect(x: x, y: bounds.midY - 9, width: max(0, right - x), height: 18)
                check.frame = CGRect(x: checkRight - Spacing.check, y: bounds.midY - Spacing.check / 2,
                                     width: Spacing.check, height: Spacing.check)
            }
            guard hasSubmenu, let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let center = CGPoint(x: bounds.maxX - Spacing.trailing - Spacing.indicator / 2, y: bounds.midY)
            for (stroke, size) in [(horizontalStroke, CGSize(width: Spacing.indicator, height: 1.5)),
                                   (verticalStroke, CGSize(width: 1.5, height: Spacing.indicator))] {
                stroke.position = center
                stroke.bounds = CGRect(origin: .zero, size: size)
                stroke.cornerRadius = 0.75
                stroke.backgroundColor = LEStyle.text.cgColor
                if stroke.superlayer == nil { layer.addSublayer(stroke) }
            }
            CATransaction.commit()
            CutsMotion.indicatorStroke(verticalStroke, visible: !expanded, animated: false)
        }
    }

    private let menu: NSMenu
    private var window: PopupWindow?
    private var rows: [NSMenuItem] = []
    private var child: CutsPopup?
    private weak var expandedRow: RowButton?
    private weak var pendingHoverRow: RowButton?
    private var pendingHover: DispatchWorkItem?
    private weak var parentPopup: CutsPopup?
    private var submenuRow: CGRect?
    private var placementSide: PopupAnchor.Side?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchor = CGPoint.zero
    private var anchorScreenPoint: CGPoint?
    private weak var parentWindow: NSWindow?
    private weak var triggerView: NSView?
    private var avoidanceRect: CGRect?
    private var closeButton: RowButton?
    private weak var keyboardRow: RowButton?
    private var colorPicker: AntColorPicker?
    var refreshedMenu: (() -> NSMenu?)?
    var onChoose: ((PopupAnchor) -> Void)?
    var isOpen: Bool { window?.isVisible == true }
    var screenFrame: CGRect? { window?.frame }
    var windowNumber: Int? { window?.windowNumber }
    func isAnchored(to view: NSView) -> Bool { isOpen && triggerView === view }

    func writePreview(over host: NSView, to url: URL) -> Bool {
        guard let panel = window, let content = panel.contentView,
              let hostWindow = host.window,
              let base = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let overlay = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: base)
        content.cacheDisplay(in: content.bounds, to: overlay)
        let hostRect = hostWindow.convertToScreen(host.convert(host.bounds, to: nil))
        let output = NSImage(size: host.bounds.size)
        output.lockFocus()
        base.draw(in: CGRect(origin: .zero, size: host.bounds.size))
        overlay.draw(in: panel.frame.offsetBy(dx: -hostRect.minX, dy: -hostRect.minY))
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func clickToolbarButtonForTest(_ button: NSButton) -> Bool {
        guard let window = button.window, window.isVisible, button.isEnabled else { return false }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let point = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        guard window.contentView?.hitTest(point) === button,
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                         timestamp: 0.02, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        return true
    }

    func clickRowLikeMouseForTest(title: String, releasingOutside: Bool = false) -> Bool {
        if child?.clickRowLikeMouseForTest(title: title, releasingOutside: releasingOutside) == true { return true }
        guard let index = rows.firstIndex(where: { $0.title == title }) else { return false }
        guard
              let panel = window,
              let effect = panel.contentView,
              let scroll = effect.subviews.compactMap({ $0 as? NSScrollView }).first,
              let row = scroll.documentView?.subviews.compactMap({ $0 as? RowButton })
                .first(where: { $0.tag == index }),
              row.window === panel else { return false }
        if !scroll.contentView.bounds.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) {
            row.scrollToVisible(row.bounds)
        }
        let rect = row.convert(row.bounds, to: nil)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard effect.hitTest(point) === row else { return false }
        if ProcessInfo.processInfo.environment["CUTS_POPUP_DEBUG"] == "1" {
            print("POPUP HIT \(title) point=\(point) row=\(row.frame) hit=\(String(describing: panel.contentView?.hitTest(point)))")
        }
        return clickForTest(point: point, in: panel, releasingOutside: releasingOutside)
    }

    private func clickForTest(point: CGPoint, in panel: NSWindow, releasingOutside: Bool = false) -> Bool {
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                           timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp,
                                         location: releasingOutside ? CGPoint(x: 1, y: point.y) : point,
                                         modifierFlags: [],
                                         timestamp: 0.02, windowNumber: panel.windowNumber, context: nil,
                                         eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        return true
    }

    private func clickCloseForTest() -> Bool {
        guard let window, let closeButton, let content = window.contentView else { return false }
        let frame = closeButton.convert(closeButton.bounds, to: nil)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return content.hitTest(point) === closeButton && clickForTest(point: point, in: window)
    }

    func changeSliderForTest(to value: CGFloat, title: String? = nil) -> Bool {
        child?.changeSliderForTest(to: value, title: title) == true
            || AnnotationSlider.inMenu(menu, title: title)?.changeForTest(to: value) == true
    }

    func dragSliderForTest(title: String? = nil, whileDragging: ((CGFloat) -> Bool)? = nil) -> CGFloat? {
        child?.dragSliderForTest(title: title, whileDragging: whileDragging)
            ?? AnnotationSlider.inMenu(menu, title: title)?.dragForTest(whileDragging: whileDragging)
    }

    func applyNumberForTest(_ number: Int) -> Bool {
        if let child { return child.applyNumberForTest(number) }
        guard let input = rows.compactMap({ $0.view as? MenuNumberInput }).first,
              input.window?.isVisible == true else { return false }
        input.applyForTest(number)
        return true
    }

    func selectedRowCheckForTest(title: String) -> Bool {
        if child?.selectedRowCheckForTest(title: title) == true { return true }
        guard let index = rows.firstIndex(where: { $0.title == title && $0.state == .on }),
              let scroll = window?.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let row = scroll.documentView?.subviews.compactMap({ $0 as? RowButton }).first(where: { $0.tag == index })
        else { return false }
        return row.checkIsVisible()
    }

    static func writePreview(to url: URL) -> Bool {
        let menu = NSMenu()
        let select = NSMenuItem(title: "选择 / 移动", action: nil, keyEquivalent: "")
        select.image = MenuIcon.tool(.select)
        menu.addItem(select)
        let shapes = NSMenuItem(title: "图形", action: nil, keyEquivalent: "")
        shapes.image = MenuIcon.tool(.rectangle)
        let children = NSMenu()
        for tool in [EditTool.rectangle, .circle, .ellipse] {
            let item = NSMenuItem(title: tool.title, action: nil, keyEquivalent: "")
            item.image = MenuIcon.tool(tool)
            if tool == .circle { item.state = .on }
            children.addItem(item)
        }
        shapes.submenu = children
        menu.addItem(shapes)
        for tool in [EditTool.text, .mosaic] {
            let item = NSMenuItem(title: tool.title, action: nil, keyEquivalent: "")
            item.image = MenuIcon.tool(tool)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "复制图片", action: nil, keyEquivalent: "")
        copy.image = MenuIcon.symbol("doc.on.doc", description: "复制图片")
        menu.addItem(copy)
        return writePreview(to: url, menu: menu, opening: shapes)
    }

    static func writePreview(to url: URL, menu: NSMenu, opening item: NSMenuItem) -> Bool {
        guard let children = item.submenu, let index = menu.items.firstIndex(where: { $0 === item }) else { return false }
        let popup = CutsPopup(menu: menu)
        popup.anchor = CGPoint(x: 300, y: 600)
        popup.render()
        defer { popup.close() }
        guard let rootWindow = popup.window,
              let scroll = rootWindow.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let row = scroll.documentView?.subviews.compactMap({ $0 as? RowButton }).first(where: { $0.tag == index })
        else { return false }
        popup.showSubmenu(children, from: row)
        guard let childWindow = popup.child?.window else { return false }
        let union = rootWindow.frame.union(childWindow.frame)
        let preview = NSImage(size: union.size)
        preview.lockFocus()
        for panel in [rootWindow, childWindow] {
            guard let content = panel.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                preview.unlockFocus()
                return false
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(bitmap)
            image.draw(in: CGRect(x: panel.frame.minX - union.minX,
                                  y: panel.frame.minY - union.minY,
                                  width: content.bounds.width, height: content.bounds.height))
        }
        preview.unlockFocus()
        guard let tiff = preview.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func verifyOffscreen() -> Bool {
        let menu = NSMenu()
        let parent = NSMenuItem(title: "图形", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "矩形", action: nil, keyEquivalent: ""))
        parent.submenu = submenu
        menu.addItem(parent)
        let popup = CutsPopup(menu: menu)
        guard popup.visibleRows().count == 1, PopupAnchor.verify() else { return false }
        let probe = ActionProbe()
        let action = NSMenuItem(title: "圆形", action: #selector(ActionProbe.choose(_:)), keyEquivalent: "")
        action.target = probe
        let interactive = CutsPopup(menu: NSMenu())
        let choices = NSMenu()
        let formats = NSMenu()
        formats.addItem(action)
        let nested = NSMenuItem(title: "形状样式", action: nil, keyEquivalent: "")
        nested.submenu = formats
        choices.addItem(nested)
        let group = NSMenuItem(title: "图形", action: nil, keyEquivalent: "")
        group.image = MenuIcon.tool(.rectangle)
        group.state = .on
        group.submenu = choices
        interactive.menu.addItem(group)
        interactive.anchor = CGPoint(x: 300, y: 600)
        interactive.render()
        defer { interactive.close() }
        guard let panel = interactive.window,
              !panel.styleMask.contains(.nonactivatingPanel),
              let effect = panel.contentView,
              let scroll = effect.subviews.compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView,
              let row = document.subviews.compactMap({ $0 as? RowButton }).first,
              row.window === panel,
              row.frame.minX == Spacing.card, document.bounds.maxX - row.frame.maxX == Spacing.card,
              document.bounds.maxY - row.frame.maxY >= Spacing.vertical,
              row.contentIsInset(), row.checkIsVisible() else { return false }
        let iconPoint = row.convert(CGPoint(x: Spacing.leading + Spacing.glyph / 2, y: row.bounds.midY), to: nil)
        guard effect.hitTest(iconPoint) === row else { return false }
        let rootHeight = panel.frame.height
        guard row.indicator == "+" else { return false }
        interactive.rowHovered(row, active: true)
        interactive.rowHovered(row, active: false)
        guard interactive.child == nil, row.indicator == "+" else { return false }
        interactive.rowHovered(row, active: true, testing: true)
        row.changeHover(false)
        guard interactive.window === panel,
              interactive.visibleRows().count == 1,
              interactive.window?.frame.height == rootHeight,
              row.indicator == "−",
              interactive.child?.window?.isVisible == true,
              interactive.child?.visibleRows().map(\.0.title) == ["形状样式"] else { return false }
        guard interactive.clickRowLikeMouseForTest(title: "形状样式"),
              interactive.clickRowLikeMouseForTest(title: "圆形", releasingOutside: true),
              probe.calls == 0, interactive.isOpen,
              interactive.clickRowLikeMouseForTest(title: "圆形"), probe.calls == 1,
              let middle = interactive.child, let leaf = middle.child, let foldingPanel = leaf.window,
              leaf.isOpen, middle.isOpen, interactive.isOpen,
              leaf.clickCloseForTest(), !leaf.isOpen, middle.isOpen, interactive.isOpen else { return false }
        if CutsMotion.enabled {
            guard foldingPanel.ignoresMouseEvents, CutsMotion.isRetiring(foldingPanel) else {
                print("popup fold: ignoresMouse=\(foldingPanel.ignoresMouseEvents) retiring=\(CutsMotion.isRetiring(foldingPanel))")
                return false
            }
        } else if foldingPanel.isVisible { return false }
        func escape(_ popup: CutsPopup) -> Bool {
            guard let number = popup.windowNumber,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: number, context: nil,
                                               characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                               isARepeat: false, keyCode: 53) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        // Reopen immediately while the old panel is still animating; the
        // parent's live row must accept the click without waiting for a frame.
        guard interactive.clickRowLikeMouseForTest(title: "形状样式"), let reopened = middle.child,
              escape(reopened), !reopened.isOpen, middle.isOpen, interactive.isOpen,
              escape(middle), !middle.isOpen, interactive.isOpen, row.indicator == "+",
              interactive.clickRowLikeMouseForTest(title: "图形"),
              interactive.clickRowLikeMouseForTest(title: "形状样式"),
              let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               eventNumber: 1, clickCount: 1, pressure: 1) else {
            print("popup fold: could not reopen or dismiss using ESC immediately")
            return false
        }
        NSApp.sendEvent(outside)
        guard !interactive.isOpen, interactive.child == nil else { return false }
        let noArgument = NSMenuItem(title: "设置…", action: #selector(ActionProbe.chooseWithoutArgument), keyEquivalent: "")
        noArgument.target = probe
        let direct = CutsPopup(menu: NSMenu())
        direct.menu.addItem(noArgument)
        direct.anchor = CGPoint(x: 300, y: 600)
        direct.render()
        defer { direct.close() }
        return direct.clickRowLikeMouseForTest(title: "设置…") && probe.calls == 2
    }

    init(menu: NSMenu) { self.menu = menu }

    func show(from view: NSView, avoiding toolbar: NSView? = nil) {
        guard let host = view.window else { return }
        let rect = host.convertToScreen(view.convert(view.bounds, to: nil))
        parentWindow = host
        triggerView = view
        anchor = CGPoint(x: rect.minX, y: rect.midY)
        anchorScreenPoint = CGPoint(x: rect.midX, y: rect.midY)
        avoidanceRect = toolbar.map { host.convertToScreen($0.convert($0.bounds, to: nil)) } ?? rect
        render()
    }

    func show(at event: NSEvent, in view: NSView) {
        guard let host = view.window else { return }
        parentWindow = host
        anchor = host.convertPoint(toScreen: event.locationInWindow)
        render()
    }

    func close(restoringFocus: Bool = true, animated: Bool = false) {
        cancelPendingHover()
        guard let panel = window else { return }
        rows.compactMap { $0.view as? AnnotationSlider }.forEach { $0.cancelPreview() }
        closeChild()
        colorPicker?.dismiss(restoringFocus: false)
        colorPicker = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        panel.parent?.removeChildWindow(panel)
        window = nil
        closeButton = nil
        if animated, parentWindow?.isVisible == true {
            CutsMotion.retire(panel, toward: entranceOffset(for: panel.frame))
        } else {
            panel.orderOut(nil)
        }
        if restoringFocus && parentWindow?.isVisible == true {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func containsWindow(_ number: Int) -> Bool {
        number == window?.windowNumber || number == colorPicker?.windowNumber || child?.containsWindow(number) == true
    }

    private var rootPopup: CutsPopup { parentPopup?.rootPopup ?? self }
    private var deepestPopup: CutsPopup { child?.deepestPopup ?? self }

    func makeColorPicker(color: NSColor) -> AntColorPicker? {
        let leaf = deepestPopup
        guard let host = leaf.window, leaf.isOpen else { return nil }
        leaf.colorPicker?.dismiss(restoringFocus: false)
        let picker = AntColorPicker(color: color, anchor: layoutAnchor, host: host,
                                    menuFrame: host.frame)
        leaf.colorPicker = picker
        return picker
    }

    func refreshMarks() {
        guard let updated = refreshedMenu?() else { return }
        syncMarks(from: updated)
    }

    private func syncMarks(from updated: NSMenu) {
        rows.compactMap { $0.view as? AnnotationSlider }.forEach { $0.refreshSample() }
        if child == nil, colorPicker?.isVisible != true, sliderRowsChanged(menu, updated) {
            cancelPendingHover()
            rows.compactMap { $0.view as? AnnotationSlider }.forEach { $0.cancelPreview() }
            transferItems(from: updated, to: menu)
            render()
            return
        }
        let document = window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView
        for (index, item) in rows.enumerated() where item.view == nil && !item.isSeparatorItem {
            guard let update = updated.items.first(where: { $0.title == item.title }) else { continue }
            let newlySelected = item.state != .on && update.state == .on
            item.state = update.state
            item.image = update.image
            item.isEnabled = update.isEnabled
            if let row = document?.subviews.compactMap({ $0 as? RowButton }).first(where: { $0.tag == index }) {
                updateLabel(row, for: item)
                if newlySelected { CutsMotion.accent(in: row) }
                if expandedRow === row, let submenu = update.submenu { child?.syncMarks(from: submenu) }
            }
            // Unopened levels are rendered from this model on demand.
            if let submenu = item.submenu, let fresh = update.submenu, expandedRow?.tag != index {
                syncUnopenedMarks(submenu, from: fresh)
            }
        }
    }

    private func syncUnopenedMarks(_ menu: NSMenu, from updated: NSMenu) {
        if sliderRowsChanged(menu, updated) {
            transferItems(from: updated, to: menu)
            return
        }
        for item in menu.items where item.view == nil && !item.isSeparatorItem {
            guard let fresh = updated.items.first(where: { $0.title == item.title }) else { continue }
            item.state = fresh.state
            item.image = fresh.image
            item.isEnabled = fresh.isEnabled
            if let submenu = item.submenu, let update = fresh.submenu { syncUnopenedMarks(submenu, from: update) }
        }
    }

    private func sliderRowsChanged(_ current: NSMenu, _ updated: NSMenu) -> Bool {
        func sliderTitles(_ menu: NSMenu) -> [String] {
            menu.items.filter { $0.view is AnnotationSlider }.map(\.title)
        }
        return sliderTitles(current) != sliderTitles(updated)
    }

    private func transferItems(from source: NSMenu, to destination: NSMenu) {
        let items = source.items
        source.removeAllItems()
        destination.removeAllItems()
        items.forEach(destination.addItem)
    }

    @objc private func closeLayer() {
        var layer: CutsPopup? = self
        while let current = layer {
            current.cancelPendingHover()
            layer = current.child
        }
        let leaf = deepestPopup
        if let picker = leaf.colorPicker, picker.isVisible {
            picker.dismiss(animated: true)
            leaf.colorPicker = nil
        } else if let parent = leaf.parentPopup {
            parent.closeChild(animated: true)
            parent.window?.makeKeyAndOrderFront(nil)
        } else {
            close(animated: true)
        }
    }

    private func updateLabel(_ button: RowButton, for item: NSMenuItem) {
        button.isEnabled = item.isEnabled
        let attributed = item.attributedTitle
        let color = attributed.flatMap {
            $0.length > 0 ? $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        } ?? LEStyle.text
        button.setContents(title: item.title, image: item.image,
                           tone: item.isEnabled ? color : color.withAlphaComponent(0.42),
                           checked: item.state == .on, reservesIcon: rows.contains { $0.image != nil })
    }
    private var layoutAnchor: PopupAnchor {
        PopupAnchor.anchored(to: anchorScreenPoint ?? anchor, leadingX: anchor.x,
                             avoid: avoidanceRect, fallbackScreen: parentWindow?.screen)
    }

    private func visibleRows() -> [(NSMenuItem, Int)] {
        menu.items.map { ($0, 0) }
    }

    private func entranceOffset(for frame: CGRect) -> CGPoint {
        if let placementSide { return CGPoint(x: placementSide == .right ? -7 : 7, y: 0) }
        return CutsMotion.direction(from: anchorScreenPoint ?? anchor, toward: frame)
    }

    private func render() {
        let entering = window == nil
        let items = visibleRows()
        rows = items.map(\.0)
        let widest = items.filter { !$0.0.isSeparatorItem }.map {
            ($0.0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        }.max() ?? 0
        let customWidth = items.compactMap { $0.0.view?.frame.width }.max() ?? 0
        let inset = Spacing.card
        let iconColumn = rows.contains { $0.image != nil } ? Spacing.glyph + Spacing.glyphGap : 0
        let rowExtras = Spacing.leading + Spacing.trailing + iconColumn +
            Spacing.check + Spacing.indicator + Spacing.trailingGap * 2
        let proposedWidth: CGFloat = min(320, max(196, widest + rowExtras + inset * 2, customWidth + inset * 2))
        let naturalHeight = items.reduce(Spacing.vertical * 2) { total, entry in
            total + (entry.0.isSeparatorItem ? 11 : entry.0.view?.frame.height ?? 32)
        }
        let footerHeight: CGFloat = 38
        let proposedSize = CGSize(width: proposedWidth, height: naturalHeight + footerHeight)
        let layout = layoutAnchor
        let panelFrame: CGRect
        if let submenuRow, let parentWindow {
            (panelFrame, placementSide) = layout.submenu(for: proposedSize, parent: parentWindow.frame,
                                                       row: submenuRow, preferred: parentPopup?.placementSide)
        } else {
            panelFrame = layout.frame(for: proposedSize)
        }
        let width = panelFrame.width, height = panelFrame.height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let panel = window ?? PopupWindow(contentRect: frame,
                                           styleMask: [.borderless],
                                           backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue,
                                                   (parentWindow?.level.rawValue ?? 0) + 1))
        if let parentWindow {
            panel.collectionBehavior = parentWindow.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.backgroundColor = LEStyle.elevated.withAlphaComponent(0.18).cgColor
        effect.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.58).cgColor
        effect.layer?.borderWidth = 0.8
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let tint = NSView(frame: effect.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = LEStyle.elevated.withAlphaComponent(0.40).cgColor
        effect.addSubview(tint)

        let scroll = NSScrollView(frame: CGRect(x: 0, y: footerHeight, width: width, height: height - footerHeight))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = naturalHeight > height - footerHeight
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let documentWidth = scroll.contentSize.width
        let document = NSView(frame: CGRect(x: 0, y: 0, width: documentWidth, height: naturalHeight))
        var y = naturalHeight - Spacing.vertical
        for (index, (item, depth)) in items.enumerated() {
            if item.isSeparatorItem {
                y -= 8
                let rule = NSBox(frame: CGRect(x: inset, y: y, width: max(0, documentWidth - 2 * inset), height: 1))
                rule.boxType = .separator
                document.addSubview(rule)
                y -= 3
                continue
            }
            if let custom = item.view {
                y -= custom.frame.height
                let slot = NSView(frame: CGRect(origin: CGPoint(x: inset, y: y), size: custom.frame.size))
                // NSMenuItem normalizes its view origin; the slot owns positioning.
                custom.setFrameOrigin(.zero)
                slot.addSubview(custom)
                document.addSubview(slot)
                continue
            }
            y -= 32
            let button = RowButton(title: "", target: self, action: #selector(rowClicked(_:)))
            button.tag = index
            button.frame = CGRect(x: inset + CGFloat(depth) * 12, y: y + 1,
                                  width: max(0, documentWidth - inset * 2 - CGFloat(depth) * 12), height: 29)
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            updateLabel(button, for: item)
            button.hasSubmenu = item.submenu != nil
            button.onHover = { [weak self] row, active in self?.rowHovered(row, active: active) }
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            if !item.isEnabled { button.isEnabled = false }
            document.addSubview(button)
        }
        scroll.documentView = document
        effect.addSubview(scroll)
        let divider = NSBox(frame: CGRect(x: inset + 4, y: footerHeight - 1,
                                         width: width - (inset + 4) * 2, height: 1))
        divider.boxType = .separator
        effect.addSubview(divider)
        let close = RowButton(title: "关闭", target: self, action: #selector(closeLayerFromButton))
        close.frame = CGRect(x: width - inset - 54, y: 7, width: 54, height: 24)
        LEStyle.icon(close)
        close.font = .systemFont(ofSize: 12, weight: .medium)
        effect.addSubview(close)
        closeButton = close
        panel.contentView = effect
        panel.setFrame(panelFrame, display: true)
        CutsLog.write(.debug, "menu", {
            let screenIndex = NSScreen.screens.firstIndex { $0.visibleFrame == layout.visibleFrame } ?? -1
            let side = placementSide.map { $0 == .left ? "left" : "right" } ?? "root"
            return "open rows=\(rows.count) size=\(Int(width))x\(Int(height)) screenIndex=\(screenIndex) placement=\(side)"
        }())
        if window == nil && parentPopup == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        if !event.isARepeat { self.closeLayer() }
                        return nil
                    }
                    return self.handleMenuKey(event) ? nil : event
                }
                if !self.containsWindow(event.windowNumber) {
                    self.close(restoringFocus: false)
                    CutsMotion.clearRetiringPanels()
                }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.close(restoringFocus: false)
                CutsMotion.clearRetiringPanels()
            }
        }
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        if let parentWindow, parentWindow.isVisible, panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, naturalHeight - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if entering {
            CutsMotion.clearRetiringPanels()
            // The window frame and keyboard focus never wait on the effect.
            CutsMotion.appear(effect, .popup, from: entranceOffset(for: panelFrame))
        }
    }

    @objc private func closeLayerFromButton() { rootPopup.closeLayer() }

    private func menuLayer(for windowNumber: Int) -> CutsPopup? {
        if window?.windowNumber == windowNumber { return self }
        return child?.menuLayer(for: windowNumber)
    }

    private func handleMenuKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let layer = menuLayer(for: event.windowNumber),
              !(layer.window?.firstResponder is NSTextView), !(layer.window?.firstResponder is NSSlider) else { return false }
        guard let scroll = layer.window?.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first else { return false }
        let buttons = scroll.documentView?.subviews.compactMap({ $0 as? RowButton })
            .filter(\.isEnabled).sorted { $0.tag < $1.tag } ?? []
        guard !buttons.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126:
            layer.cancelPendingHover()
            let down = event.keyCode == 125
            let index = layer.keyboardRow.flatMap { focused in buttons.firstIndex { $0 === focused } }
            let next = index.map { ($0 + buttons.count + (down ? 1 : -1)) % buttons.count } ?? (down ? 0 : buttons.count - 1)
            layer.keyboardRow?.keyboardHighlighted = false
            let button = buttons[next]
            layer.keyboardRow = button
            button.keyboardHighlighted = true
            layer.window?.makeFirstResponder(button)
            button.scrollToVisible(button.bounds)
            return true
        case 36, 49, 76, 124:
            guard !event.isARepeat, let focused = layer.keyboardRow, layer.rows.indices.contains(focused.tag),
                  event.keyCode != 124 || layer.rows[focused.tag].submenu != nil else { return false }
            layer.rowClicked(focused)
            return true
        case 123:
            guard layer.parentPopup != nil else { return false }
            closeLayer()
            return true
        default: return false
        }
    }

    @objc private func rowClicked(_ sender: RowButton) {
        if ProcessInfo.processInfo.environment["CUTS_POPUP_DEBUG"] == "1" { print("POPUP CLICK \(sender.tag)") }
        cancelPendingHover()
        guard rows.indices.contains(sender.tag) else { return }
        let item = rows[sender.tag]
        if let submenu = item.submenu {
            showSubmenu(submenu, from: sender)
            return
        }
        guard let action = item.action else { return }
        CutsLog.write(.debug, "menu", "action=\(NSStringFromSelector(action))")
        let target = item.target
        let root = rootPopup
        root.onChoose?(root.layoutAnchor)
        if !NSApp.sendAction(action, to: target, from: item) {
            CutsLog.write(.warning, "menu", "action not dispatched selector=\(NSStringFromSelector(action))")
            ActionFeedback.show("菜单操作未能执行")
        } else if root.isOpen {
            root.refreshMarks()
        }
    }

    private func rowHovered(_ row: RowButton, active: Bool, testing: Bool = false) {
        if !active {
            if pendingHoverRow === row { cancelPendingHover() }
            return
        }
        cancelPendingHover()
        guard row.isEnabled, expandedRow !== row, rows.indices.contains(row.tag),
              rows[row.tag].submenu != nil, rootPopup.deepestPopup.colorPicker?.isVisible != true else { return }
        let request = DispatchWorkItem { [weak self, weak row] in
            guard let self, let row, self.isOpen, self.pendingHoverRow === row,
                  testing || NSEvent.pressedMouseButtons == 0 else { return }
            self.cancelPendingHover()
            if let submenu = self.rows[row.tag].submenu { self.showSubmenu(submenu, from: row) }
        }
        pendingHoverRow = row
        pendingHover = request
        if testing { request.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + CutsMotion.menuHoverDelay, execute: request) }
    }

    private func cancelPendingHover() {
        pendingHover?.cancel()
        pendingHover = nil
        pendingHoverRow = nil
    }

    private func closeChild(animated: Bool = false) {
        child?.close(restoringFocus: false, animated: animated)
        child = nil
        expandedRow?.expanded = false
        expandedRow = nil
    }

    private func showSubmenu(_ submenu: NSMenu, from sender: RowButton) {
        if expandedRow === sender, child?.isOpen == true { return }
        closeChild()
        colorPicker?.dismiss(restoringFocus: false)
        colorPicker = nil
        guard let window else { return }
        let row = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        let popup = CutsPopup(menu: submenu)
        popup.parentPopup = self
        popup.parentWindow = window
        popup.anchor = CGPoint(x: window.frame.maxX + 4, y: row.maxY)
        popup.anchorScreenPoint = CGPoint(x: row.midX, y: row.midY)
        popup.submenuRow = row
        child = popup
        expandedRow = sender
        sender.expanded = true
        popup.render()
    }
}
