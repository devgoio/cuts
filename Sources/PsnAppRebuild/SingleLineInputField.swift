import AppKit

/// Keeps the native bezel and the native field editor, but centers the line
/// inside the taller controls used in settings and menus.
@MainActor
final class SingleLineInputField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredInputCell.self }
        set { }
    }

    init(alignment: NSTextAlignment = .center) {
        super.init(frame: .zero)
        self.alignment = alignment
        cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func rowLabel(_ title: String) -> NSTextField {
        let label = SingleLineInputField(alignment: .left)
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.stringValue = title
        return label
    }

    func lineIsCentered() -> Bool {
        guard let cell = cell as? VerticallyCenteredInputCell else { return false }
        return abs(cell.drawingRect(forBounds: bounds).midY - bounds.midY) <= 0.5
    }

    func editorLineRect() -> CGRect? {
        guard let editor = currentEditor() as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let line = layout.usedRect(for: container)
        return convert(line.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y), from: editor)
    }

    static func verifyOffscreen() -> Bool {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 90),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let numeric = SingleLineInputField()
        let text = SingleLineInputField(alignment: .left)
        for (field, value, font, rect) in [
            (numeric, "300", NSFont.systemFont(ofSize: 12), CGRect(x: 30, y: 51, width: 88, height: 29)),
            (text, "文件名 Sample", NSFont.systemFont(ofSize: 13), CGRect(x: 30, y: 14, width: 220, height: 27))
        ] {
            field.frame = rect
            field.font = font
            field.stringValue = value
            window.contentView?.addSubview(field)
            guard field.lineIsCentered(), window.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView, editor.alignment == field.alignment,
                  let editingLine = field.editorLineRect(),
                  abs(editingLine.midY - field.bounds.midY) <= 1.5 else {
                print("input field centering: bounds=\(field.bounds) editorLine=\(String(describing: field.editorLineRect()))")
                return false
            }
            guard window.makeFirstResponder(nil), field.stringValue == value else { return false }
        }
        return numeric.alignment == .center && text.alignment == .left
    }
}

@MainActor
private final class VerticallyCenteredInputCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textRect = super.drawingRect(forBounds: rect)
        guard let font, textRect.height > 0 else { return textRect }
        let height = min(textRect.height, ceil(font.ascender - font.descender + font.leading))
        return NSRect(x: textRect.minX, y: rect.midY - height / 2, width: textRect.width, height: height)
    }
}
