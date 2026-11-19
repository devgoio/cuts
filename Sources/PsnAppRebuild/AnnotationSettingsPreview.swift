import AppKit

enum AnnotationSettingsTab: String, CaseIterable {
    case region = "选区", pen = "涂抹", arrow = "箭头", shapes = "圈选"
    case text = "文字", number = "序号", lens = "放大", eraser = "擦除"
}

/// Draws sample marks with the same renderer as the capture editor. No screenshots
/// or clipboard content are used, and the preview cannot edit the actual canvas.
@MainActor
final class AnnotationSettingsPreview: NSView {
    private static let sourceSize = CGSize(width: 400, height: 280)
    private lazy var neutral = Self.makeScene(detailed: false).map(CaptureEditor.annotationSampleRenderer)
    private lazy var detailed = Self.makeScene(detailed: true).map(CaptureEditor.annotationSampleRenderer)
    private let summary = NSTextField(labelWithString: "")
    private(set) var tab = AnnotationSettingsTab.region
    private(set) var preset = AnnotationDefaults.baseline
    private var artwork: CGRect {
        let width = bounds.width - 20
        let height = width * Self.sourceSize.height / Self.sourceSize.width
        return CGRect(x: 10, y: 45 + (133 - height) / 2, width: width, height: height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("实时预览")
        let title = NSTextField(labelWithString: "实时预览")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = LEStyle.text
        title.frame = CGRect(x: 12, y: bounds.height - 30, width: bounds.width - 24, height: 17)
        title.setAccessibilityElement(false)
        addSubview(title)
        summary.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        summary.textColor = LEStyle.secondary
        summary.alignment = .center
        summary.lineBreakMode = .byTruncatingTail
        summary.frame = CGRect(x: 8, y: 16, width: bounds.width - 16, height: 18)
        summary.setAccessibilityElement(false)
        addSubview(summary)
        updateSummary()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(tab: AnnotationSettingsTab, preset: AnnotationDefaults) {
        guard self.tab != tab || self.preset != preset else { return }
        self.tab = tab
        self.preset = preset
        updateSummary()
        needsDisplay = true
    }

    private func updateSummary() {
        let width = AnnotationSlider.Scale.strokeWidth
        switch tab {
        case .region: summary.stringValue = preset.selection.title
        case .pen: summary.stringValue = width.label(for: preset.brush.width)
        case .arrow:
            let heads = preset.arrowHeads == .none ? "无箭头" : String(preset.arrowHeads.title.dropLast(2))
            let tip = String(preset.arrowTip.title.dropLast(2))
            summary.stringValue = [heads, preset.arrowHeads == .none ? nil : tip,
                                   width.label(for: preset.arrow.width)].compactMap { $0 }.joined(separator: " · ")
        case .shapes: summary.stringValue = preset.geometryTool.title + " · " + width.label(for: preset.geometry.width)
        case .text: summary.stringValue = AnnotationSlider.Scale.fontSize.label(for: preset.fontSize)
        case .number: summary.stringValue = preset.numberFilled ? "有背景" : "无背景"
        case .lens:
            let diameter = preset.lensDiameter.map { AnnotationSlider.Scale.diameter(maximum: 2048).label(for: $0) } ?? "自动直径"
            summary.stringValue = AnnotationSlider.Scale.magnification.label(for: preset.magnification) + " · " + diameter
        case .eraser: summary.stringValue = (preset.eraserMode ?? .whole).title
        }
        setAccessibilityValue(tab.rawValue + "，" + summary.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        LEStyle.container.withAlphaComponent(0.74).setFill()
        card.fill()
        LEStyle.border.setStroke()
        card.lineWidth = 1
        card.stroke()

        let area = artwork
        let clip = NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let render = tab == .lens || tab == .region ? detailed : neutral
        render?(marks(), area)
        if tab == .region { drawSelection(in: area) }
        if tab == .eraser, preset.eraserMode == .local {
            let diameter = (preset.eraserWidth ?? 20) * area.width / Self.sourceSize.width
            let ring = NSBezierPath(ovalIn: CGRect(x: area.midX - diameter / 2, y: area.minY + area.height * 0.65 - diameter / 2,
                                                 width: diameter, height: diameter))
            LEStyle.text.withAlphaComponent(0.85).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        LEStyle.border.setStroke()
        clip.lineWidth = 0.75
        clip.stroke()
    }

    private func marks() -> [Mark] {
        func points(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }
        let defaultColor = NSColor.systemRed
        switch tab {
        case .region:
            return []
        case .pen:
            let stroke = (0...40).map { index -> CGPoint in
                let t = CGFloat(index) / 40
                return CGPoint(x: 0.15 + 0.70 * t, y: 0.48 + 0.21 * sin(t * .pi * 2) + 0.12 * t)
            }
            return [Mark(tool: .pen, points: stroke, color: preset.brush.color, lineWidth: preset.brush.width)]
        case .arrow:
            return [Mark(tool: .arrow, points: points([(0.14, 0.5), (0.86, 0.5)]),
                         color: preset.arrow.color, lineWidth: preset.arrow.width,
                         arrowHeads: preset.arrowHeads, arrowTipStyle: preset.arrowTip)]
        case .shapes:
            let x: CGFloat = preset.geometryTool == .circle ? 0.29 : 0.20
            return [Mark(tool: preset.geometryTool, points: points([(x, 0.20), (1 - x, 0.80)]),
                         color: preset.geometry.color, lineWidth: preset.geometry.width)]
        case .text:
            let color = preset.textColor.map(AnnotationDefaults.makeColor) ?? defaultColor
            let style = AnnotationTextStyle(fontName: preset.font, fontSize: preset.fontSize, color: color,
                                            bold: preset.bold, italic: preset.italic)
            let sample = "Aa 字"
            let layout = AnnotationTextLayout()
            layout.storage.setAttributedString(AnnotationTextStyle.attributed(sample, base: style, runs: [], scale: 1))
            let width = layout.usedRect.width
            let height = layout.usedRect.height
            return [Mark(tool: .text, points: [CGPoint(x: (1 - width / Self.sourceSize.width) / 2,
                                                     y: (1 + height / Self.sourceSize.height) / 2)],
                         text: sample, color: color, fontName: preset.font, fontSize: preset.fontSize,
                         bold: preset.bold, italic: preset.italic)]
        case .number:
            let color = preset.numberColor.map(AnnotationDefaults.makeColor) ?? defaultColor
            return [Mark(tool: .number, points: points([(0.50, 0.50)]), text: String(preset.firstNumber),
                         color: color, fontSize: preset.numberSize, numberFilled: preset.numberFilled)]
        case .lens:
            // Compress the full range onto the small card so even large values
            // continue to grow without covering the entire sample image.
            let diameter = preset.lensDiameter.map { 51 * pow($0 / 24, 0.34) }
            return [Mark(tool: .magnifier, points: points([(0.50, 0.50)]), color: LEStyle.text, lineWidth: 3,
                         magnifierDiameter: diameter, magnification: preset.magnification)]
        case .eraser:
            let remaining = Mark(tool: .pen, points: points([(0.18, 0.30), (0.82, 0.30)]),
                                 color: LEStyle.color(0x72B8F2), lineWidth: 14)
            guard preset.eraserMode == .local else { return [remaining] }
            let erased = Mark(tool: .pen, points: points([(0.18, 0.65), (0.82, 0.65)]),
                              color: LEStyle.color(0x72B8F2), lineWidth: 14)
            let mask = Mark(tool: .eraser, points: points([(0.50, 0.60), (0.50, 0.70)]),
                            lineWidth: preset.eraserWidth ?? 20)
            return [remaining, erased, mask]
        }
    }

    private func drawSelection(in area: CGRect) {
        let height = area.height * 0.67
        let width = preset.selection == .circle ? height : area.width * 0.74
        let box = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        let cutout = preset.selection.path(in: box)
        let mask = NSBezierPath(rect: area)
        mask.windingRule = .evenOdd
        mask.append(cutout)
        LEStyle.canvas.withAlphaComponent(0.76).setFill()
        mask.fill()
        LEStyle.color(0x69B1FF).setStroke()
        cutout.lineWidth = 1.5
        cutout.stroke()
        for point in [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.midX, y: box.maxY),
                      CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)] {
            LEStyle.text.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        }
    }

    private static func makeScene(detailed: Bool) -> CGImage? {
        let rect = CGRect(origin: .zero, size: sourceSize)
        guard let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(LEStyle.color(0x131D2E).cgColor)
        ctx.fill(rect)
        let pitch = detailed ? 16 : 24
        ctx.setStrokeColor(LEStyle.color(0x273650).withAlphaComponent(detailed ? 0.95 : 0.65).cgColor)
        ctx.setLineWidth(1)
        for x in stride(from: pitch, to: Int(rect.width), by: pitch) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(x), y: rect.height))
        }
        for y in stride(from: pitch, to: Int(rect.height), by: pitch) {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: rect.width, y: CGFloat(y)))
        }
        ctx.strokePath()
        if detailed {
            let heights: [CGFloat] = [54, 76, 67, 91, 84, 115, 105, 128, 115, 141, 124, 154, 137]
            ctx.setFillColor(LEStyle.color(0x2F6B9A).withAlphaComponent(0.72).cgColor)
            for (i, height) in heights.enumerated() {
                ctx.fill(CGRect(x: 30 + CGFloat(i) * 27, y: 51, width: 13, height: height))
            }
            ctx.setStrokeColor(LEStyle.color(0x80C8FF).cgColor)
            ctx.setLineWidth(3)
            ctx.setLineJoin(.round)
            for (i, height) in heights.enumerated() {
                let point = CGPoint(x: 36 + CGFloat(i) * 27, y: 61 + height)
                if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
            }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    func samplePNG() -> Data? {
        guard let image = bitmapImageRepForCachingDisplay(in: artwork) else { return nil }
        cacheDisplay(in: artwork, to: image)
        return image.representation(using: .png, properties: [:])
    }
}
