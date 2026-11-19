import AppKit

@MainActor
enum ActionFeedback {
    private static var activePanel: NSPanel?

    static func dismiss() {
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    static func show(_ message: String, success: Bool = false) {
        dismiss()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = LEStyle.text
        label.sizeToFit()
        let symbolWidth: CGFloat = success ? 24 : 0
        let width = max(112, label.frame.width + 32 + symbolWidth)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 38),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let background = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 38))
        LEStyle.surface(background, radius: 9)
        let start = (width - label.frame.width - symbolWidth) / 2
        label.frame.origin = CGPoint(x: start + symbolWidth,
                                     y: (38 - label.frame.height) / 2)
        if success {
            let icon = NSImageView(frame: CGRect(x: start, y: 12, width: 15, height: 15))
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            icon.contentTintColor = LEStyle.text
            background.addSubview(icon)
        }
        background.addSubview(label)
        panel.contentView = background
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(CGPoint(x: max(visible.minX + 8,
                                          min(visible.maxX - width - 8, mouse.x - width / 2)),
                                     y: max(visible.minY + 8,
                                            min(visible.maxY - 46, mouse.y + 18))))
        panel.orderFrontRegardless()
        activePanel = panel
        CutsMotion.appear(background, .feedback, from: CGPoint(x: 0, y: -5))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            guard activePanel === panel else { return }
            activePanel = nil
            CutsMotion.retire(panel, toward: CGPoint(x: 0, y: -3))
        }
    }
}
