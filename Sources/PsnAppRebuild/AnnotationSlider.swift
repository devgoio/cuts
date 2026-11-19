import AppKit

/// Numeric controls with optional live samples. Dragging previews; releasing
/// commits one edit so a drag remains a single undo step.
@MainActor
final class AnnotationSlider: NSView {
    struct Scale {
        let range: ClosedRange<CGFloat>
        let step: CGFloat
        let unit: String

        static let strokeWidth = Scale(range: 1...64, step: 1, unit: " px")
        static let eraserWidth = Scale(range: 1...128, step: 1, unit: " px")
        static let fontSize = Scale(range: 12...96, step: 1, unit: " px")
        static let magnification = Scale(range: 1.5...6, step: 0.1, unit: "×")
        static func diameter(maximum: CGFloat) -> Scale {
            Scale(range: min(24, maximum)...maximum, step: 1, unit: " px")
        }

        func snap(_ value: CGFloat) -> CGFloat {
            let ticks = ((value - range.lowerBound) / step).rounded()
            return min(range.upperBound, max(range.lowerBound, range.lowerBound + ticks * step))
        }

        func label(for value: CGFloat) -> String {
            let precision = step < 1 ? 1 : 0
            return Double(value).formatted(.number.grouping(.never).precision(.fractionLength(0...precision))) + unit
        }
    }

    enum Sample {
        case line(() -> NSColor), text(() -> NSColor), number(color: () -> NSColor, filled: () -> Bool), eraser
    }

    private final class SampleView: NSView {
        let sample: Sample
        var value: CGFloat { didSet { needsDisplay = true } }

        init(sample: Sample, value: CGFloat) {
            self.sample = sample
            self.value = value
            super.init(frame: CGRect(x: 7, y: 6, width: 220, height: 34))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            LEStyle.canvas.withAlphaComponent(0.34).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            switch sample {
            case .line(let color):
                let stroke = NSBezierPath()
                stroke.move(to: CGPoint(x: 20, y: center.y))
                stroke.line(to: CGPoint(x: bounds.maxX - 20, y: center.y))
                stroke.lineCapStyle = .round
                stroke.lineWidth = max(1, value * 0.44)
                color().setStroke()
                stroke.stroke()
            case .text(let color):
                drawText("Aa 文字", at: center, size: value * 0.27, color: color())
            case .number(let color, let filled):
                let diameter = value * 0.31
                let ink = color()
                let background = filled()
                if background {
                    ink.setFill()
                    NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                width: diameter, height: diameter)).fill()
                }
                drawText("1", at: center, size: diameter * 0.56, color: background ? .white : ink)
            case .eraser:
                let diameter = max(2, value * 0.24)
                let circle = NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                         width: diameter, height: diameter))
                LEStyle.primary.withAlphaComponent(0.4).setFill()
                circle.fill()
                LEStyle.text.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
        }

        private func drawText(_ text: NSString, at center: CGPoint, size: CGFloat, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(1, size), weight: .semibold), .foregroundColor: color
            ]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2),
                      withAttributes: attributes)
        }
    }

    static func menuItem(title: String, current: CGFloat, scale: Scale,
                         sample: Sample? = nil,
                         onPreview: ((CGFloat?) -> Void)? = nil,
                         onCommit: @escaping (CGFloat) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = AnnotationSlider(title: title, current: current, scale: scale, sample: sample,
                                    onPreview: onPreview, onCommit: onCommit)
        return item
    }

    static func inMenu(_ menu: NSMenu, title: String?) -> AnnotationSlider? {
        menu.items.lazy
            .filter { title == nil || $0.title == title }
            .compactMap { $0.view as? AnnotationSlider }.first
    }

    private final class Slider: NSSlider {
        var onRelease: (() -> Void)?
        var step: Double = 1
        private(set) var dragging = false
        func stopDragging() { dragging = false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            dragging = true
            window?.makeFirstResponder(self)
            update(with: event)
        }
        override func mouseDragged(with event: NSEvent) {
            if dragging { update(with: event) }
        }
        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            update(with: event)
            dragging = false
            onRelease?()
        }
        override func keyDown(with event: NSEvent) {
            guard isEnabled else { return }
            switch event.keyCode {
            case 123, 125: doubleValue -= step
            case 124, 126: doubleValue += step
            default: super.keyDown(with: event); return
            }
            sendAction(action, to: target)
        }

        func fraction(at x: CGFloat) -> CGFloat {
            min(1, max(0, (x - 8) / max(1, bounds.width - 16)))
        }

        private func update(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            doubleValue = minValue + Double(fraction(at: x)) * (maxValue - minValue)
            sendAction(action, to: target)
        }
    }

    private let slider = Slider()
    private let value = NSTextField(labelWithString: "")
    private let scale: Scale
    private let onCommit: (CGFloat) -> Void
    private let onPreview: ((CGFloat?) -> Void)?
    private var previewing = false
    private var committed: CGFloat
    private var sampleView: SampleView?

    init(title: String, current: CGFloat, scale: Scale, sample: Sample? = nil, width: CGFloat = 234,
         onPreview: ((CGFloat?) -> Void)? = nil,
         onCommit: @escaping (CGFloat) -> Void) {
        self.scale = scale
        self.onCommit = onCommit
        self.onPreview = onPreview
        self.committed = scale.snap(current)
        let bottom: CGFloat = sample == nil ? 0 : 38
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 55 + bottom))
        if let sample {
            let view = SampleView(sample: sample, value: committed)
            view.frame.size.width = width - 14
            sampleView = view
            addSubview(view)
        }
        let label = NSTextField(labelWithString: title)
        label.frame = CGRect(x: 7, y: 34 + bottom, width: width - 14, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = LEStyle.secondary
        addSubview(label)

        slider.frame = CGRect(x: 7, y: 9 + bottom, width: width - 81, height: 23)
        slider.minValue = Double(scale.range.lowerBound)
        slider.maxValue = Double(max(scale.range.upperBound, scale.range.lowerBound + scale.step))
        slider.isEnabled = scale.range.lowerBound < scale.range.upperBound
        slider.step = Double(scale.step)
        slider.doubleValue = Double(committed)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(title)
        slider.onRelease = { [weak self] in self?.changed() }
        addSubview(slider)

        value.frame = CGRect(x: width - 68, y: 10 + bottom, width: 61, height: 20)
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = LEStyle.text
        value.stringValue = scale.label(for: committed)
        addSubview(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() {
        let current = scale.snap(CGFloat(slider.doubleValue))
        slider.doubleValue = Double(current)
        value.stringValue = scale.label(for: current)
        sampleView?.value = current
        if slider.dragging {
            if let onPreview { previewing = true; onPreview(current) }
            return
        }
        clearPreview()
        guard current != committed else { return }
        committed = current
        onCommit(current)
    }

    func cancelPreview() {
        slider.stopDragging()
        slider.doubleValue = Double(committed)
        value.stringValue = scale.label(for: committed)
        sampleView?.value = committed
        clearPreview()
    }

    func refreshSample() { sampleView?.needsDisplay = true }

    private func clearPreview() {
        guard previewing else { return }
        previewing = false
        onPreview?(nil)
    }

    func changeForTest(to desired: CGFloat) -> Bool {
        guard window?.isVisible == true, slider.isEnabled, let action = slider.action else { return false }
        slider.doubleValue = Double(desired)
        guard NSApp.sendAction(action, to: slider.target, from: slider) else { return false }
        return abs(committed - desired) < 0.001 && value.stringValue == scale.label(for: desired)
    }

    func dragForTest(whileDragging: ((CGFloat) -> Bool)? = nil) -> CGFloat? {
        scrollToVisible(bounds)
        guard slider.isEnabled, let window, let content = window.contentView else { return nil }
        let track = slider.convert(slider.bounds, to: nil)
        let events = [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated().compactMap {
            index, type -> NSEvent? in
            let offset = track.width * (index == 0 ? 0.2 : 0.8)
            let point = CGPoint(x: track.minX + offset, y: track.midY)
            guard content.hitTest(point) === slider else { return nil }
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: 0.02 * Double(index), windowNumber: window.windowNumber,
                                      context: nil, eventNumber: index + 1, clickCount: 1,
                                      pressure: index < 2 ? 1 : 0)
        }
        guard events.count == 3 else { return nil }
        let before = committed
        let expected = scale.snap(scale.range.lowerBound
            + slider.fraction(at: track.width * 0.8) * (scale.range.upperBound - scale.range.lowerBound))
        NSApp.sendEvent(events[0])
        NSApp.sendEvent(events[1])
        let live = committed == before && value.stringValue == scale.label(for: expected)
            && (sampleView.map { $0.value == expected } ?? true)
            && (whileDragging?(expected) ?? true)
        NSApp.sendEvent(events[2])
        return live && committed == expected ? committed : nil
    }
}
