import AppKit

struct AnnotationTextStyle: Hashable {
    var fontName: String
    var fontSize: CGFloat
    var color: NSColor
    var bold: Bool
    var italic: Bool

    private static let attributeKey = NSAttributedString.Key("com.psn.Cuts.TextAnnotationStyle")

    static func stored(in attributes: [NSAttributedString.Key: Any]) -> Self? {
        attributes[attributeKey] as? Self
    }

    func attributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let size = max(1, fontSize * scale)
        let traits: NSFontTraitMask = bold ? .boldFontMask : []
        let systemFont = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let fonts = NSFontManager.shared
        var font = fontName == ".AppleSystemUIFont" ? systemFont
            : fonts.font(withFamily: fontName, traits: traits, weight: bold ? 9 : 5, size: size)
                ?? NSFont(name: fontName, size: size) ?? systemFont
        if bold { font = fonts.convert(font, toHaveTrait: .boldFontMask) }
        // Apply the same slant to the whole run, including fallback glyphs such
        // as Chinese characters that do not have an italic font face.
        return [.font: font, .foregroundColor: color,
                .obliqueness: italic ? 0.22 : 0, Self.attributeKey: self]
    }

    static func attributed(_ text: String, base: Self, runs: [AnnotationTextRun],
                           scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: base.attributes(scale: scale))
        let whole = NSRange(location: 0, length: result.length)
        for run in runs {
            let range = NSIntersectionRange(run.range, whole)
            if range.length > 0 { result.addAttributes(run.style.attributes(scale: scale), range: range) }
        }
        return result
    }
}

struct AnnotationTextRun: Equatable {
    let range: NSRange
    var style: AnnotationTextStyle
}

enum AnnotationTextChange {
    case font(String), size(CGFloat), color(NSColor), bold(Bool), italic(Bool)

    func applied(to style: AnnotationTextStyle) -> AnnotationTextStyle {
        var result = style
        switch self {
        case .font(let value): result.fontName = value
        case .size(let value): result.fontSize = value
        case .color(let value): result.color = value
        case .bold(let value): result.bold = value
        case .italic(let value): result.italic = value
        }
        return result
    }
}

/// The draft and the exported mark share one TextKit layout, anchored at the
/// upper-left of the first line (not at the bottom of a control's frame).
final class AnnotationTextLayout {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 1_000_000, height: 1_000_000))

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    var usedRect: CGRect {
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container)
    }

    func draw(at anchor: CGPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let glyphs = manager.glyphRange(for: container)
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: anchor.x, y: anchor.y)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class AnnotationTextView: NSTextView {
    var onConfirm: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private func confirmIfRequested(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command, event.keyCode == 36 || event.keyCode == 76,
              !hasMarkedText(), let onConfirm else { return false }
        onConfirm()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, confirmIfRequested(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !confirmIfRequested(event) { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onContextMenu { onContextMenu(event) }
        else { super.rightMouseDown(with: event) }
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

final class AnnotationTextInput: NSView, NSTextViewDelegate {
    let layoutEngine: AnnotationTextLayout
    private let editor: AnnotationTextView
    private let baseStyle: AnnotationTextStyle
    private var scale: CGFloat
    private let inset: CGFloat = 3
    private var originalPreviewRuns: [AnnotationTextRun]?
    var textView: NSTextView { editor }
    var string: String { editor.string }
    var onConfirm: (() -> Void)? { didSet { editor.onConfirm = onConfirm } }
    var onContextMenu: ((NSEvent) -> Void)? { didSet { editor.onContextMenu = onContextMenu } }
    var onChange: (() -> Void)?

    init(text: String, style: AnnotationTextStyle, runs: [AnnotationTextRun], scale: CGFloat) {
        let layout = AnnotationTextLayout()
        layoutEngine = layout
        baseStyle = style
        self.scale = scale
        editor = AnnotationTextView(frame: .zero, textContainer: layout.container)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 4

        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainerInset = .zero
        editor.drawsBackground = false
        editor.delegate = self
        editor.setAccessibilityLabel("输入文字标注")
        editor.setAccessibilityHelp("回车换行，Command 加回车确认")
        layoutEngine.storage.setAttributedString(AnnotationTextStyle.attributed(text, base: style, runs: runs, scale: scale))
        addSubview(editor)
        setTypingStyle(style)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selection: NSRange {
        let range = editor.selectedRange()
        if range.location == NSNotFound { return NSRange(location: 0, length: 0) }
        return NSIntersectionRange(range, NSRange(location: 0, length: layoutEngine.storage.length))
    }

    var currentStyle: AnnotationTextStyle {
        let range = selection
        if range.length > 0 { return style(at: range.location) }
        return AnnotationTextStyle.stored(in: editor.typingAttributes) ?? baseStyle
    }

    func style(at index: Int) -> AnnotationTextStyle {
        let storage = layoutEngine.storage
        guard index >= 0, index < storage.length else { return baseStyle }
        return AnnotationTextStyle.stored(in: storage.attributes(at: index, effectiveRange: nil)) ?? baseStyle
    }

    private func runs(in range: NSRange) -> [AnnotationTextRun] {
        guard range.length > 0 else { return [] }
        var runs: [AnnotationTextRun] = []
        layoutEngine.storage.enumerateAttributes(in: range) { attributes, region, _ in
            let style = AnnotationTextStyle.stored(in: attributes) ?? baseStyle
            if let previous = runs.last, previous.style == style, NSMaxRange(previous.range) == region.location {
                runs[runs.count - 1] = AnnotationTextRun(range: NSUnionRange(previous.range, region), style: style)
            } else {
                runs.append(AnnotationTextRun(range: region, style: style))
            }
        }
        return runs
    }

    var textRuns: [AnnotationTextRun] { runs(in: NSRange(location: 0, length: layoutEngine.storage.length)) }

    func hasStyle(_ property: KeyPath<AnnotationTextStyle, Bool>) -> Bool {
        let range = selection
        return range.length == 0 ? currentStyle[keyPath: property]
            : runs(in: range).allSatisfy { $0.style[keyPath: property] }
    }

    func apply(_ change: AnnotationTextChange) {
        let range = selection
        let typingStyle = change.applied(to: currentStyle)
        if range.length > 0 {
            // Keep attributes like paragraph direction, but only change the
            // style fields of the runs intersecting the selection.
            applyRuns(runs(in: range).map { AnnotationTextRun(range: $0.range, style: change.applied(to: $0.style)) })
        }
        setTypingStyle(typingStyle)
    }

    func previewFontSize(_ size: CGFloat?) {
        if let size {
            guard !editor.hasMarkedText() else { return }
            if originalPreviewRuns == nil { originalPreviewRuns = runs(in: selection) }
            guard let originalPreviewRuns, !originalPreviewRuns.isEmpty else { return }
            let change = AnnotationTextChange.size(size)
            applyRuns(originalPreviewRuns.map { .init(range: $0.range, style: change.applied(to: $0.style)) })
        } else if let originalPreviewRuns {
            self.originalPreviewRuns = nil
            applyRuns(originalPreviewRuns)
        }
    }

    func updateScale(_ next: CGFloat) {
        guard scale != next else { return }
        let typingStyle = currentStyle
        let runs = textRuns
        scale = next
        applyRuns(runs)
        setTypingStyle(typingStyle)
    }

    private func applyRuns(_ runs: [AnnotationTextRun]) {
        let storage = layoutEngine.storage
        storage.beginEditing()
        for run in runs { storage.addAttributes(run.style.attributes(scale: scale), range: run.range) }
        storage.endEditing()
    }

    private func setTypingStyle(_ style: AnnotationTextStyle) {
        editor.typingAttributes = style.attributes(scale: scale)
        editor.insertionPointColor = style.color
    }

    func place(at anchor: CGPoint, maxWidth: CGFloat) {
        let lineHeight = (editor.typingAttributes[.font] as? NSFont)
            .map(layoutEngine.manager.defaultLineHeight(for:)) ?? 16
        let used = layoutEngine.usedRect
        let caretBottom = layoutEngine.manager.extraLineFragmentTextContainer === layoutEngine.container
            ? layoutEngine.manager.extraLineFragmentRect.maxY : 0
        let width = max(1, min(maxWidth, max(104, ceil(used.maxX) + 12)))
        let height = max(1, ceil(max(lineHeight, used.maxY, caretBottom)) + 2)
        frame = CGRect(x: anchor.x - inset, y: anchor.y - height - inset,
                       width: width + inset * 2, height: height + inset * 2)
        editor.frame = CGRect(x: inset, y: inset, width: width, height: height)
    }

    func textDidChange(_ notification: Notification) { onChange?() }
}
