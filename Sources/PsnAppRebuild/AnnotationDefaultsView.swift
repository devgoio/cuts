import AppKit

@MainActor
final class AnnotationDefaultsView: NSView, NSTextFieldDelegate {
    private typealias Tab = AnnotationSettingsTab
    private final class ActionButton: PointingButton {
        var invoke: (() -> Void)?
        @objc func run() { invoke?() }
    }

    private let body = NSView(frame: CGRect(x: 18, y: 58, width: 404, height: 225))
    private let preview = AnnotationSettingsPreview(frame: CGRect(x: 219, y: 0, width: 185, height: 225))
    private let controlWidth: CGFloat = 205
    private var tabs: [Tab: ActionButton] = [:]
    private var tab = Tab.region
    private var saved = AnnotationDefaults.saved
    private var draft = AnnotationDefaults.saved { didSet { updateCommit() } }
    private var transientPreview: AnnotationDefaults?
    private var commitButton: NSButton?
    private var picker: AntColorPicker?
    private var firstNumberField: NSTextField?
    var showError: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        _ = label("标注默认设置", y: 347, parent: self, x: 18, size: 17)
        for (i, kind) in Tab.allCases.enumerated() {
            tabs[kind] = button(kind.rawValue, x: 18 + CGFloat(i) * 51, y: 304, width: 47, in: self) { [weak self] in
                guard let self, self.syncNumber() else { return }
                guard self.tab != kind else { return }
                self.dismissPicker()
                self.selectTab(kind, animated: true)
            }
        }
        addSubview(body)
        body.addSubview(preview)
        _ = button("恢复默认", x: 18, y: 19, width: 95, in: self) { [weak self] in
            guard let self else { return }
            self.dismissPicker()
            self.firstNumberField = nil
            self.draft = .baseline
            self.rebuild()
        }
        commitButton = button("保存", x: 350, y: 19, width: 72, in: self) { [weak self] in
            guard let self, self.syncNumber(), self.draft.isValid, self.draft != self.saved else { return }
            self.draft.store()
            self.saved = self.draft
            self.updateCommit()
            ActionFeedback.show("已保存，下次截图生效", success: true)
        }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        transientPreview = nil
        firstNumberField = nil
        saved = .saved
        draft = saved
        rebuild()
    }

    func dismissPicker() { picker?.dismiss(restoringFocus: false) }

    func selectPreviewTab(_ name: String, example: Bool) {
        guard let tab = Tab(rawValue: name) else { return }
        draft = .baseline
        if example {
            draft.arrowHeads = .both
            draft.arrowTip = .filled
            draft.arrow.width = 16
            draft.arrow.rgba = 0x69B1FFFF
            draft.lensDiameter = 320
            draft.magnification = 3.2
            draft.eraserMode = .local
            draft.eraserWidth = 42
            draft.firstNumber = 16
            draft.numberSize = 38
            draft.fontSize = 40
        }
        selectTab(tab, animated: false)
    }

    func verifyPreview() -> Bool {
        let persisted = AnnotationDefaults.saved
        saved = .baseline
        draft = .baseline
        for kind in Tab.allCases {
            selectTab(kind, animated: false)
            guard let before = preview.samplePNG(),
                  body.bounds.contains(preview.frame),
                  body.subviews.filter({ $0 !== preview }).allSatisfy({
                      body.bounds.contains($0.frame) && !$0.frame.intersects(preview.frame)
                  }) else {
                print("annotation preview layout/render failed: \(kind.rawValue)")
                return false
            }
            var changed = draft
            switch kind {
            case .region: changed.selection = .circle
            case .pen: changed.brush.width = 24
            case .arrow: changed.arrowHeads = .both; changed.arrowTip = .filled; changed.arrow.width = 20
            case .shapes: changed.geometryTool = .ellipse
            case .text: changed.fontSize = 42; changed.italic = true
            case .number: changed.firstNumber = 98; changed.numberFilled = false
            case .lens: changed.lensDiameter = 360; changed.magnification = 3.4
            case .eraser: changed.eraserMode = .local; changed.eraserWidth = 35
            }
            preview.update(tab: kind, preset: changed)
            guard let after = preview.samplePNG(), before != after else {
                print("annotation preview pixels did not change: \(kind.rawValue)")
                return false
            }
        }
        selectTab(.arrow, animated: false)
        guard let before = preview.samplePNG(),
              let slider = body.subviews.compactMap({ $0 as? AnnotationSlider }).first,
              let width = slider.dragForTest(whileDragging: { value in
                  self.draft.arrow.width == 4 && self.preview.preset.arrow.width == value
                      && self.preview.samplePNG().map { $0 != before } == true && self.commitButton?.isEnabled == false
              }),
              draft.arrow.width == width, preview.preset.arrow.width == width, commitButton?.isEnabled == true else {
            print("annotation settings mouse drag preview failed")
            return false
        }
        guard let color = body.subviews.compactMap({ $0 as? ActionButton }).first(where: { $0.title == "颜色…" }) else { return false }
        color.invoke?()
        guard let picker, picker.choosePresetForTest(0x1677FF, apply: false),
              preview.preset.arrow.rgba == 0x1677FFFF, draft.arrow.rgba == nil else {
            print("annotation settings live palette preview failed")
            return false
        }
        dismissPicker()
        guard preview.preset.arrow.rgba == nil else { return false }
        color.invoke?()
        guard picker !== self.picker, self.picker?.choosePresetForTest(0x4096FF) == true,
              preview.preset.arrow.rgba == 0x4096FFFF, draft.arrow.rgba == 0x4096FFFF,
              AnnotationDefaults.saved == persisted else { return false }
        selectTab(.number, animated: false)
        firstNumberField?.stringValue = "1234"
        updateCommit()
        guard preview.preset.firstNumber == 1234, draft.firstNumber == 1 else { return false }
        subviews.compactMap { $0 as? ActionButton }.first { $0.title == "恢复默认" }?.invoke?()
        return preview.preset == .baseline && commitButton?.isEnabled == false && AnnotationDefaults.saved == persisted
    }

    private func selectTab(_ kind: Tab, animated: Bool) {
        let from = Tab.allCases.firstIndex(of: tab) ?? 0
        let to = Tab.allCases.firstIndex(of: kind) ?? 0
        tab = kind
        rebuild()
        if animated { CutsMotion.appear(body, .page, from: CGPoint(x: to > from ? 6 : -6, y: 0)) }
    }

    private func rebuild() {
        transientPreview = nil
        firstNumberField = nil
        body.subviews.filter { $0 !== preview }.forEach { $0.removeFromSuperview() }
        for (kind, button) in tabs {
            CutsSettingsStyle.control(button, selected: tab == kind)
        }
        switch tab {
        case .region:
            options("选区形状", CaptureShape.allCases.map { (String($0.title.dropLast(2)), $0) }, selected: draft.selection, y: 164,
                    at: \.selection)
        case .pen:
            slider("涂抹粗细", scale: .strokeWidth, y: 157, at: \.brush.width)
            tint(draft.brush.rgba, y: 111, at: \.brush.rgba)
        case .arrow:
            options("方向", [("终点", .end), ("起点", .start), ("双向", .both), ("无", .none)],
                    selected: draft.arrowHeads, y: 164, at: \.arrowHeads)
            options("样式", [("线框", .open), ("实心", .filled)],
                    selected: draft.arrowTip, y: 108, at: \.arrowTip)
            slider("线宽", scale: .strokeWidth, y: 48, at: \.arrow.width)
            tint(draft.arrow.rgba, y: 10, at: \.arrow.rgba)
        case .shapes:
            options("圈选形状", AnnotationDefaults.geometryTools.map { ($0.title, $0) },
                    selected: draft.geometryTool, y: 164, at: \.geometryTool)
            slider("线宽", scale: .strokeWidth, y: 104, at: \.geometry.width)
            tint(draft.geometry.rgba, y: 64, at: \.geometry.rgba)
        case .text:
            options("字体", AnnotationDefaults.fonts.map { ($0.1 == "Helvetica Neue" ? "Helvetica" : $0.0, $0.1) },
                    selected: draft.font, y: 164, columns: 2, at: \.font)
            slider("字号", scale: .fontSize, y: 75, at: \.fontSize)
            toggle("加粗", enabled: draft.bold, x: 0, y: 42, at: \.bold)
            toggle("倾斜", enabled: draft.italic, x: 106, y: 42, at: \.italic)
            tint(draft.textColor, y: 7, at: \.textColor)
        case .number:
            options("序号背景", [("无背景", false), ("有背景", true)],
                    selected: draft.numberFilled, y: 164, at: \.numberFilled)
            _ = label("起始序号", y: 135, parent: body, centered: true)
            let field = SingleLineInputField()
            field.stringValue = String(draft.firstNumber)
            field.frame = CGRect(x: 106, y: 131, width: 99, height: 27)
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.setAccessibilityLabel("起始序号")
            field.delegate = self
            body.addSubview(field)
            firstNumberField = field
            slider("大小", scale: .fontSize, y: 76, at: \.numberSize)
            tint(draft.numberColor, y: 44, at: \.numberColor)
            HoverHintButton.guide(NumberEditingShortcuts.guide, in: body, x: controlWidth - 24, y: 46)
        case .lens:
            slider("放大倍率", scale: .magnification, y: 157, at: \.magnification)
            let hasDiameter = draft.lensDiameter != nil
            let button = button(hasDiameter ? "自动直径：关" : "自动直径：开", x: 0, y: 115, width: 112, in: body) { [weak self] in
                guard let self else { return }
                self.draft.lensDiameter = hasDiameter ? nil : 120
                self.rebuild()
            }
            CutsSettingsStyle.control(button, selected: !hasDiameter)
            if let diameter = draft.lensDiameter {
                slider("直径", scale: .diameter(maximum: 2048), y: 52, current: diameter, at: \.lensDiameter, convert: Optional.some)
            }
        case .eraser:
            options("擦除模式", EraserMode.allCases.map { ($0.title, Optional($0)) },
                    selected: draft.eraserMode ?? .whole, y: 164, at: \.eraserMode)
            if draft.eraserMode == .local {
                slider("局部擦除粗细", scale: .eraserWidth, y: 104, current: draft.eraserWidth ?? 20,
                       at: \.eraserWidth, convert: Optional.some)
            }
        }
        updateCommit()
    }

    func controlTextDidChange(_ notification: Notification) { updateCommit() }

    private func updateCommit() {
        var comparison = draft
        if let field = firstNumberField {
            let text = field.currentEditor()?.string ?? field.stringValue
            comparison.firstNumber = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        if transientPreview == nil {
            var appearance = comparison
            if !(1...9999).contains(appearance.firstNumber) { appearance.firstNumber = draft.firstNumber }
            preview.update(tab: tab, preset: appearance)
        }
        var previous = saved
        comparison.eraserMode = comparison.eraserMode ?? .whole
        previous.eraserMode = previous.eraserMode ?? .whole
        comparison.eraserWidth = comparison.eraserWidth ?? 20
        previous.eraserWidth = previous.eraserWidth ?? 20
        CutsSettingsStyle.commit(commitButton, dirty: comparison != previous)
    }

    private func updatePreview<T>(_ value: T?, at keyPath: WritableKeyPath<AnnotationDefaults, T>) {
        guard let value else {
            transientPreview = nil
            updateCommit()
            return
        }
        var appearance = preview.preset
        appearance[keyPath: keyPath] = value
        transientPreview = appearance
        preview.update(tab: tab, preset: appearance)
    }

    private func syncNumber() -> Bool {
        guard let field = firstNumberField else { return true }
        let text = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(text), (1...9999).contains(number) else {
            showError?("起始序号请输入 1–9999。")
            return false
        }
        draft.firstNumber = number
        return true
    }

    private func options<T: Equatable>(_ name: String, _ options: [(String, T)], selected: T,
                                       y: CGFloat, columns: Int? = nil, at keyPath: WritableKeyPath<AnnotationDefaults, T>) {
        _ = label(name, y: y + 31, parent: body)
        let columns = columns ?? options.count
        let gap: CGFloat = 5
        let width = (controlWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, option) in options.enumerated() {
            let x = CGFloat(index % columns) * (width + gap)
            let row = y - CGFloat(index / columns) * 33
            let item = button(option.0, x: x, y: row, width: width, in: body) { [weak self] in
                guard let self, self.syncNumber() else { return }
                guard self.draft[keyPath: keyPath] != option.1 else { return }
                self.draft[keyPath: keyPath] = option.1
                self.rebuild()
                if let selected = self.body.subviews.compactMap({ $0 as? NSButton }).first(where: {
                    $0.frame.minX == x && $0.frame.minY == row
                }) { CutsMotion.accent(in: selected) }
            }
            CutsSettingsStyle.control(item, selected: option.1 == selected)
        }
    }

    private func toggle(_ name: String, enabled: Bool, x: CGFloat, y: CGFloat,
                        at keyPath: WritableKeyPath<AnnotationDefaults, Bool>) {
        let item = button(name + (enabled ? "：开" : "：关"), x: x, y: y, width: 99, in: body) { [weak self] in
            self?.draft[keyPath: keyPath].toggle()
            self?.rebuild()
        }
        CutsSettingsStyle.control(item, selected: enabled)
    }

    private func slider(_ name: String, scale: AnnotationSlider.Scale, y: CGFloat,
                        at keyPath: WritableKeyPath<AnnotationDefaults, CGFloat>) {
        slider(name, scale: scale, y: y, current: draft[keyPath: keyPath], at: keyPath, convert: { $0 })
    }

    private func slider<T>(_ name: String, scale: AnnotationSlider.Scale, y: CGFloat, current: CGFloat,
                           at keyPath: WritableKeyPath<AnnotationDefaults, T>, convert: @escaping (CGFloat) -> T) {
        let item = AnnotationSlider(title: name, current: current, scale: scale, width: controlWidth,
                                    onPreview: { [weak self] in self?.updatePreview($0.map(convert), at: keyPath) }) { [weak self] in
            self?.draft[keyPath: keyPath] = convert($0)
        }
        item.frame.origin.y = y
        body.addSubview(item)
    }

    private func tint(_ rgba: UInt32?, y: CGFloat, at keyPath: WritableKeyPath<AnnotationDefaults, UInt32?>) {
        let color = rgba.map(AnnotationDefaults.makeColor) ?? .systemRed
        let item = button("颜色…", x: 0, y: y, width: 103, in: body) {}
        item.image = MenuIcon.swatch(color)
        item.imagePosition = .imageLeading
        item.invoke = { [weak self, weak item] in
            guard let self, let item, let window = self.window, self.syncNumber() else { return }
            self.dismissPicker()
            let rect = window.convertToScreen(item.convert(item.bounds, to: nil))
            let anchor = PopupAnchor.anchored(to: CGPoint(x: rect.midX, y: rect.midY), leadingX: rect.minX,
                                              avoid: rect, fallbackScreen: window.screen)
            let previewFrame = window.convertToScreen(self.preview.convert(self.preview.bounds, to: nil))
            let picker = AntColorPicker(color: color, anchor: anchor, host: window, keepVisible: previewFrame)
            picker.onPreview = { [weak self] color in
                guard let rgba = AnnotationDefaults.storeColor(color) else { return }
                self?.updatePreview(Optional<UInt32?>.some(rgba), at: keyPath)
            }
            picker.onApply = { [weak self] color in
                self?.draft[keyPath: keyPath] = AnnotationDefaults.storeColor(color)
                self?.rebuild()
            }
            picker.onClose = { [weak self] in
                self?.picker = nil
                self?.updatePreview(nil, at: keyPath)
            }
            self.picker = picker
            picker.show()
        }
    }

    @discardableResult
    private func label(_ text: String, y: CGFloat, parent: NSView, x: CGFloat = 0,
                       size: CGFloat = 12, centered: Bool = false) -> NSTextField {
        let view = centered ? SingleLineInputField.rowLabel(text) : NSTextField(labelWithString: text)
        view.frame = CGRect(x: x, y: y, width: (parent === body ? controlWidth : parent.bounds.width) - x, height: size + 7)
        view.font = .systemFont(ofSize: size, weight: .semibold)
        view.textColor = LEStyle.text
        parent.addSubview(view)
        return view
    }

    private func button(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, in view: NSView,
                        _ invoke: @escaping () -> Void) -> ActionButton {
        let item = ActionButton(title: title, target: nil, action: nil)
        item.target = item
        item.action = #selector(ActionButton.run)
        item.invoke = invoke
        item.frame = CGRect(x: x, y: y, width: width, height: 29)
        item.font = .systemFont(ofSize: 12, weight: .medium)
        LEStyle.icon(item)
        CutsSettingsStyle.control(item)
        view.addSubview(item)
        return item
    }
}
