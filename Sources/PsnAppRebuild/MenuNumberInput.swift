import AppKit

@MainActor
enum NumberEditingShortcuts {
    static func label() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "点击已有序号选中，可直接拖动\n⌘ + 左键：加 1   ⌥ + 左键：减 1\n选中后：↑ 加 1   ↓ 减 1")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = LEStyle.secondary
        label.frame = CGRect(x: 0, y: 0, width: 226, height: 46)
        return label
    }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 52))
        let label = label()
        label.frame.origin = CGPoint(x: 7, y: 2)
        container.addSubview(label)
        item.view = container
        return item
    }
}

@MainActor
final class MenuNumberInput: NSView {
    private let field = SingleLineInputField()
    private let current: () -> Int
    private let onApply: (Int) -> Void

    static func item(_ title: String, icon: String, current: @escaping () -> Int,
                     onApply: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = MenuIcon.symbol(icon, description: title)
        let menu = NSMenu()
        let input = NSMenuItem()
        input.view = MenuNumberInput(title: title, current: current, onApply: onApply)
        menu.addItem(input)
        item.submenu = menu
        return item
    }

    private init(title: String, current: @escaping () -> Int, onApply: @escaping (Int) -> Void) {
        self.current = current
        self.onApply = onApply
        super.init(frame: CGRect(x: 0, y: 0, width: 192, height: 62))
        let label = NSTextField(labelWithString: title)
        label.frame = CGRect(x: 7, y: 40, width: 174, height: 16)
        label.textColor = LEStyle.secondary
        label.font = .systemFont(ofSize: 11)
        addSubview(label)
        field.frame = CGRect(x: 7, y: 7, width: 117, height: 27)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "1–9999"
        field.setAccessibilityLabel(title)
        field.focusRingType = .none
        field.target = self
        field.action = #selector(apply)
        addSubview(field)
        let button = PointingButton(title: "应用", target: self, action: #selector(apply))
        LEStyle.icon(button)
        button.frame = CGRect(x: 131, y: 7, width: 54, height: 27)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { field.stringValue = String(current()) }
    }

    @objc private func apply() {
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...9999).contains(value) else {
            ActionFeedback.show("序号请输入 1–9999 的整数")
            return
        }
        field.stringValue = String(value)
        onApply(value)
    }

    func applyForTest(_ value: Int) {
        field.stringValue = String(value)
        apply()
    }
}
