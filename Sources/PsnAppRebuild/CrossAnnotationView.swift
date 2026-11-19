import AppKit

/// Each non-active display paints the same annotation canvas. A click moves
/// the real editor (including its text input) here; it never duplicates edits.
final class CrossAnnotationView: NSView {
    let selection: CGRect
    var isMirroring = true { didSet { needsDisplay = true } }
    var paint: ((CGRect) -> Void)?
    var receive: ((NSEvent) -> Void)?

    init(frame: CGRect, selection: CGRect) {
        self.selection = selection
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        selection.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { receive?(event) }
    override func mouseDragged(with event: NSEvent) { receive?(event) }
    override func mouseUp(with event: NSEvent) { receive?(event) }
    override func rightMouseDown(with event: NSEvent) { receive?(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard isMirroring else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        paint?(selection)
        let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
