import AppKit

struct BrushChoice: Equatable {
    var width: CGFloat = 4
    var color: NSColor = .systemRed
}

@MainActor
enum BrushMenu {
    static func make(target: NSObject, width: CGFloat, color: NSColor,
                     colorAction: Selector, sampleColor: @escaping () -> NSColor,
                     onPreview: @escaping (CGFloat?) -> Void, onWidth: @escaping (CGFloat) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(AnnotationSlider.menuItem(title: "涂抹粗细", current: width, scale: .strokeWidth,
                                              sample: .line(sampleColor), onPreview: onPreview, onCommit: onWidth))
        let tint = NSMenuItem(title: "颜色", action: colorAction, keyEquivalent: "")
        tint.target = target
        tint.image = MenuIcon.swatch(color)
        menu.addItem(tint)
        return menu
    }
}
