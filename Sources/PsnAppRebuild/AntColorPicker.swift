import AppKit

@MainActor
final class AntColorPicker: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private final class PickerPanel: NSPanel {
        var cancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown && event.keyCode == 53 { cancel?() }
            else { super.sendEvent(event) }
        }
    }

    private static let groups: [(String, [UInt32])] = [
        ("primary", [0xE6F4FF, 0xBAE0FF, 0x91CAFF, 0x69B1FF, 0x4096FF, 0x1677FF, 0x0958D9, 0x003EB3, 0x002C8C, 0x001D66]),
        ("red", [0xFFF1F0, 0xFFCCC7, 0xFFA39E, 0xFF7875, 0xFF4D4F, 0xF5222D, 0xCF1322, 0xA8071A, 0x820014, 0x5C0011]),
        ("green", [0xF6FFED, 0xD9F7BE, 0xB7EB8F, 0x95DE64, 0x73D13D, 0x52C41A, 0x389E0D, 0x237804, 0x135200, 0x092B00]),
        ("cyan", [0xE6FFFB, 0xB5F5EC, 0x87E8DE, 0x5CDBD3, 0x36CFC9, 0x13C2C2, 0x08979C, 0x006D75, 0x00474F, 0x002329]),
        ("LE", [0x2F6B9A, 0x722ED1, 0xEB2F96, 0xFA8C16, 0xFAAD14, 0xFFFFFF, 0x000000]),
    ]

    private let panel: PickerPanel
    private weak var host: NSWindow?
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1
    private var alpha: CGFloat = 1
    private var isClosing = false
    private let isMenuLayer: Bool
    private let plane = AntColorGradient(kind: .saturation)
    private let rail = AntColorGradient(kind: .hue)
    private let swatch = NSView()
    private let field = SingleLineInputField()
    private var presets: [UInt32: NSButton] = [:]
    var onApply: ((NSColor) -> Void)?
    var onPreview: ((NSColor) -> Void)?
    var onClose: (() -> Void)?
    var frame: CGRect { panel.frame }
    var windowNumber: Int? { isVisible ? panel.windowNumber : nil }
    var isVisible: Bool { !isClosing && panel.isVisible }
    var previewView: NSView? { panel.contentView }

    init(color: NSColor, anchor: PopupAnchor, host: NSWindow, menuFrame: CGRect? = nil, keepVisible: CGRect? = nil) {
        self.host = host
        isMenuLayer = menuFrame != nil
        let size = CGSize(width: 500, height: 278)
        let verticalFrame = anchor.frame(for: size, keepFullHeight: true)
        let frame = menuFrame.map { menu in
            let side = anchor.submenu(for: size, parent: menu, row: menu, preferred: nil).0
            guard let avoid = anchor.avoid, avoid.intersects(side) else { return side }
            return CGRect(x: side.minX, y: verticalFrame.minY, width: side.width, height: side.height)
        } ?? keepVisible.map { preview in
            guard verticalFrame.intersects(preview) else { return verticalFrame }
            let beside = anchor.submenu(for: size, parent: preview, row: preview, preferred: .left).0
            let vertical = PopupAnchor(point: anchor.point, leadingX: anchor.leadingX,
                                       avoid: preview, visibleFrame: anchor.visibleFrame)
                .frame(for: size, keepFullHeight: true)
            func overlap(_ frame: CGRect) -> CGFloat {
                let overlap = frame.intersection(preview)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            return [beside, vertical, verticalFrame].min { overlap($0) < overlap($1) } ?? verticalFrame
        } ?? verticalFrame
        panel = PickerPanel(contentRect: frame,
                            styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, host.level.rawValue + 2))
        panel.collectionBehavior = host.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary])
        panel.cancel = { [weak self] in self?.dismiss() }
        panel.delegate = self
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        LEStyle.frostedSurface(content, radius: 12)
        panel.contentView = content
        label("预设颜色", frame: CGRect(x: 14, y: 250, width: 160, height: 18), in: content, title: true)
        label("自选颜色", frame: CGRect(x: 264, y: 250, width: 160, height: 18), in: content, title: true)
        let divider = NSView(frame: CGRect(x: 248, y: 54, width: 1, height: 201))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = LEStyle.border.cgColor
        content.addSubview(divider)
        for (index, group) in Self.groups.enumerated() {
            let y = CGFloat(221 - index * 40)
            label(group.0, frame: CGRect(x: 14, y: y, width: 110, height: 16), in: content)
            for (column, value) in group.1.enumerated() {
                let button = HoverHintButton(title: "", target: self, action: #selector(selectPreset(_:)))
                button.frame = CGRect(x: 14 + CGFloat(column) * 22, y: y - 22, width: 16, height: 16)
                button.tag = Int(value)
                button.toolTip = String(format: "#%06X", value)
                button.setAccessibilityLabel(button.toolTip)
                LEStyle.icon(button)
                button.layer?.cornerRadius = 3
                button.layer?.backgroundColor = LEStyle.color(value).cgColor
                button.layer?.borderWidth = 0.5
                button.layer?.borderColor = LEStyle.text.withAlphaComponent(0.26).cgColor
                presets[value] = button
                content.addSubview(button)
            }
        }
        plane.frame = CGRect(x: 264, y: 115, width: 222, height: 126)
        rail.frame = CGRect(x: 264, y: 91, width: 222, height: 13)
        plane.onChange = { [weak self] x, y in
            guard let self else { return }
            self.panel.makeFirstResponder(nil)
            self.saturation = x
            self.brightness = y
            self.refresh(writeHex: true)
        }
        rail.onChange = { [weak self] x, _ in
            guard let self else { return }
            self.panel.makeFirstResponder(nil)
            self.hue = x
            self.refresh(writeHex: true)
        }
        content.addSubview(plane)
        content.addSubview(rail)
        label("HEX", frame: CGRect(x: 264, y: 59.5, width: 30, height: 18), in: content, centered: true)
        field.frame = CGRect(x: 300, y: 55, width: 145, height: 27)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.layer?.borderWidth = 0.6
        field.placeholderString = "#RRGGBB"
        field.delegate = self
        field.target = self
        field.action = #selector(confirm)
        content.addSubview(field)
        swatch.frame = CGRect(x: 456, y: 56, width: 30, height: 25)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 5
        swatch.layer?.borderWidth = 0.6
        swatch.layer?.borderColor = LEStyle.text.withAlphaComponent(0.4).cgColor
        content.addSubview(swatch)
        let controls = isMenuLayer
            ? [("应用", CGFloat(362), CGFloat(60), #selector(confirm)),
               ("关闭", CGFloat(426), CGFloat(60), #selector(cancel))]
            : [("取消", CGFloat(362), CGFloat(60), #selector(cancel)),
               ("应用", CGFloat(426), CGFloat(60), #selector(confirm))]
        for (title, x, width, action) in controls {
            let button = HoverHintButton(title: title, target: self, action: action)
            button.frame = CGRect(x: x, y: 14, width: width, height: 29)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            LEStyle.icon(button)
            if action == #selector(confirm) { button.layer?.backgroundColor = LEStyle.primary.cgColor }
            content.addSubview(button)
        }
        load(color)
        refresh(writeHex: true)
    }

    func show() {
        CutsMotion.clearRetiringPanels()
        if let host, host.isVisible { host.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        if let content = panel.contentView {
            let offset = host.map {
                CutsMotion.direction(from: CGPoint(x: $0.frame.midX, y: $0.frame.midY), toward: panel.frame)
            } ?? .zero
            CutsMotion.appear(content, .popup, from: offset)
        }
    }

    func dismiss(restoringFocus: Bool = true, animated: Bool = false) {
        guard !isClosing else { return }
        isClosing = true
        panel.parent?.removeChildWindow(panel)
        if animated, let host, host.isVisible {
            let point = CGPoint(x: host.frame.midX, y: host.frame.midY)
            CutsMotion.retire(panel, toward: CutsMotion.direction(from: point, toward: panel.frame, distance: 4))
        } else { panel.orderOut(nil) }
        if restoringFocus, host?.isVisible == true { host?.makeKeyAndOrderFront(nil) }
        let closing = onClose
        onClose = nil
        closing?()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isMenuLayer { dismiss(restoringFocus: false) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let color = parsedColor() { load(color); refresh(writeHex: false) }
        else { field.layer?.borderColor = NSColor.systemRed.cgColor }
    }

    @objc private func selectPreset(_ sender: NSButton) {
        panel.makeFirstResponder(nil)
        load(LEStyle.color(UInt32(sender.tag)))
        field.stringValue = String(format: "#%06X", sender.tag)
        refresh(writeHex: false)
        CutsMotion.accent(in: sender, color: LEStyle.text, radius: 3)
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func confirm() {
        panel.makeFirstResponder(nil)
        guard let selected = parsedColor() else {
            field.layer?.borderColor = NSColor.systemRed.cgColor
            return
        }
        onApply?(selected)
        if isMenuLayer { CutsMotion.accent(in: swatch, color: LEStyle.text, radius: 5) }
        else { dismiss(animated: true) }
    }

    func choosePresetForTest(_ value: UInt32, apply: Bool = true) -> Bool {
        guard let button = presets[value], isVisible else { return false }
        guard CutsPopup.clickToolbarButtonForTest(button) else { return false }
        if apply { confirm() }
        return true
    }

    func applyHexForTest(_ hex: String) {
        field.stringValue = hex
        confirm()
    }

    private func label(_ text: String, frame: CGRect, in view: NSView, title: Bool = false, centered: Bool = false) {
        let label = centered ? SingleLineInputField.rowLabel(text) : NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: title ? 13 : 11, weight: .medium)
        label.textColor = title ? LEStyle.text : LEStyle.secondary
        view.addSubview(label)
    }

    private func load(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? LEStyle.primary
        hue = rgb.hueComponent
        saturation = rgb.saturationComponent
        brightness = rgb.brightnessComponent
        alpha = rgb.alphaComponent
    }

    private func refresh(writeHex: Bool) {
        let c = brightness * saturation
        let h = min(6, max(0, hue * 6))
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let components: (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 1: components = (x, c, 0)
        case 2: components = (0, c, x)
        case 3: components = (0, x, c)
        case 4: components = (x, 0, c)
        case 5: components = (c, 0, x)
        default: components = (c, x, 0)
        }
        let color = NSColor(srgbRed: components.0 + m, green: components.1 + m, blue: components.2 + m, alpha: alpha)
        swatch.layer?.backgroundColor = color.cgColor
        plane.hue = hue
        plane.position = CGPoint(x: saturation, y: brightness)
        rail.position = CGPoint(x: hue, y: 0.5)
        if writeHex {
            let rgb = color
            func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            field.stringValue = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                                       byte(rgb.blueComponent)) + (alpha < 1 ? String(format: "%02X", byte(alpha)) : "")
        }
        field.layer?.borderColor = LEStyle.border.cgColor
        let selected = parsedColor()?.usingColorSpace(.sRGB)
        for (hex, button) in presets {
            let active = selected == LEStyle.color(hex)
            button.layer?.borderWidth = active ? 1.8 : 0.5
            button.layer?.borderColor = LEStyle.text.withAlphaComponent(active ? 0.98 : 0.26).cgColor
        }
        if let selected { onPreview?(selected) }
    }

    private func parsedColor() -> NSColor? {
        var hex = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [6, 8].contains(hex.count),
              hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 8
        let rgb = rgba ? value >> 8 : value
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: rgba ? CGFloat(value & 255) / 255 : 1)
    }
}

private final class AntColorGradient: NSView {
    enum Kind { case saturation, hue }
    let kind: Kind
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var position = CGPoint.zero { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { update(with: event) }
    override func mouseDragged(with event: NSEvent) { update(with: event) }

    private func update(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onChange?(min(1, max(0, point.x / max(1, bounds.width))), min(1, max(0, point.y / max(1, bounds.height))))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
        if kind == .hue {
            let colors = (0...6).map { NSColor(calibratedHue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1) }
            NSGradient(colors: colors)?.draw(in: bounds, angle: 0)
        } else {
            let tint = NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)
            NSGradient(starting: .white, ending: tint)?.draw(in: bounds, angle: 0)
            NSGradient(starting: .black, ending: NSColor.black.withAlphaComponent(0))?.draw(in: bounds, angle: 90)
        }
        NSGraphicsContext.restoreGraphicsState()
        let center = CGPoint(x: 5 + position.x * max(0, bounds.width - 10),
                             y: 5 + position.y * max(0, bounds.height - 10))
        let marker = NSBezierPath(ovalIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        NSColor.black.withAlphaComponent(0.65).setStroke()
        marker.lineWidth = 3
        marker.stroke()
        NSColor.white.setStroke()
        marker.lineWidth = 1.5
        marker.stroke()
    }
}
