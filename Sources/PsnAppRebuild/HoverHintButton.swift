import AppKit

private final class PassThroughHintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PointingButton: NSButton {
    private var pointerArea: NSTrackingArea?
    private var hoverWash: CALayer?
    private var hovered = false
    private var pressed = false
    var showsHoverFeedback = true
    var usesSharedPointerTracking: Bool { true }

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled {
                window?.invalidateCursorRects(for: self)
                refreshPointerFeedback()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, !bounds.isEmpty { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea); self.pointerArea = nil }
        super.updateTrackingAreas()
        guard usesSharedPointerTracking else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
        refreshPointerFeedback()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshPointerFeedback()
        super.mouseExited(with: event)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        refreshPointerFeedback()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hovered = false
            pressed = false
            refreshPointerFeedback()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refreshPointerFeedback() {
        guard usesSharedPointerTracking, showsHoverFeedback else { return }
        let alpha: CGFloat = isEnabled ? (pressed ? 0.17 : hovered ? 0.085 : 0) : 0
        if hoverWash == nil, alpha > 0, let layer {
            let wash = CALayer()
            wash.frame = layer.bounds.insetBy(dx: 1, dy: 1)
            wash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            wash.cornerRadius = max(0, layer.cornerRadius - 1)
            wash.zPosition = 2
            layer.addSublayer(wash)
            hoverWash = wash
        }
        CutsMotion.background(alpha == 0 ? .clear : LEStyle.text.withAlphaComponent(alpha), on: hoverWash)
    }
}

/// A tooltip drawn inside the capture window, which also works at screen-saver window level.
final class HoverHintButton: PointingButton {
    private var hint: NSView?
    private var pendingMenu: DispatchWorkItem?
    var onMenuHover: (() -> Void)?
    private(set) var isSubmenuDot = false

    static func submenuDot(x: CGFloat, title: String, target: AnyObject, action: Selector) -> HoverHintButton {
        let dot = HoverHintButton(title: "", target: target, action: action)
        dot.frame = CGRect(x: x, y: 0, width: 28, height: 11)
        dot.isSubmenuDot = true
        dot.setAccessibilityLabel("展开\(title)")
        LEStyle.icon(dot)
        return dot
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func verifyOffscreen() -> Bool {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 220, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView!.bounds)
        window.contentView = root
        let button = HoverHintButton(frame: CGRect(x: 20, y: 20, width: 28, height: 28))
        button.toolTip = "复制图片"
        root.addSubview(button)
        button.showHint()
        guard root.subviews.count == 2, button.hint is PassThroughHintView else { return false }
        button.hideHint()
        return root.subviews.count == 1
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if !isSubmenuDot { showHint() }
        scheduleMenuOnHover()
    }

    override func mouseExited(with event: NSEvent) {
        cancelMenuOnHover()
        hideHint()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        cancelMenuOnHover()
        hideHint()
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelMenuOnHover(); hideHint() }
        super.viewWillMove(toWindow: newWindow)
    }

    func scheduleMenuOnHover(testing: Bool = false) {
        cancelMenuOnHover()
        guard onMenuHover != nil, isEnabled else { return }
        let request = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor,
                  testing || NSEvent.pressedMouseButtons == 0 else { return }
            self.cancelMenuOnHover()
            self.hideHint()
            self.onMenuHover?()
        }
        pendingMenu = request
        if testing { request.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + CutsMotion.menuHoverDelay, execute: request) }
    }

    private func cancelMenuOnHover() {
        pendingMenu?.cancel()
        pendingMenu = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSubmenuDot else { return }
        LEStyle.text.withAlphaComponent(isEnabled ? 0.7 : 0.3).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - 1.75, y: bounds.midY - 1.75,
                                    width: 3.5, height: 3.5)).fill()
    }

    private func showHint() {
        hideHint()
        guard isEnabled, let text = toolTip, !text.isEmpty,
              let root = window?.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = LEStyle.text
        label.sizeToFit()
        let width = min(root.bounds.width - 16, label.frame.width + 20)
        let bubble = PassThroughHintView(frame: CGRect(x: 0, y: 0, width: width, height: 26))
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 7
        bubble.layer?.backgroundColor = LEStyle.container.withAlphaComponent(0.93).cgColor
        bubble.layer?.borderWidth = 0.5
        bubble.layer?.borderColor = LEStyle.primary.withAlphaComponent(0.48).cgColor
        label.frame = CGRect(x: 10, y: 5, width: width - 20, height: 16)
        bubble.addSubview(label)
        let position = convert(bounds, to: root)
        let x = max(8, min(root.bounds.maxX - width - 8, position.midX - width / 2))
        let y = position.maxY + 6 + bubble.frame.height <= root.bounds.maxY - 8
            ? position.maxY + 6 : position.minY - bubble.frame.height - 6
        bubble.frame.origin = CGPoint(x: x, y: max(8, y))
        root.addSubview(bubble, positioned: .above, relativeTo: nil)
        hint = bubble
        CutsMotion.appear(bubble, .hint, from: CGPoint(x: 0, y: y > position.maxY ? -3 : 3))
    }

    private func hideHint() {
        hint?.removeFromSuperview()
        hint = nil
    }

}
