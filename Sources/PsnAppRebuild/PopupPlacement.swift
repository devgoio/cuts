import AppKit

struct PopupAnchor {
    let point: CGPoint
    let leadingX: CGFloat
    let avoid: CGRect?
    let visibleFrame: CGRect

    enum Side { case left, right }
    private let margin: CGFloat = 8
    private let gap: CGFloat = 5

    static func anchored(to point: CGPoint, leadingX: CGFloat? = nil,
                         avoid: CGRect? = nil, fallbackScreen: NSScreen? = nil) -> Self {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? fallbackScreen ?? NSScreen.main
        return Self(point: point, leadingX: leadingX ?? point.x, avoid: avoid,
                    visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func frame(for requested: CGSize, keepFullHeight: Bool = false) -> CGRect {
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let boundary = avoid ?? CGRect(origin: point, size: .zero)
        let below = boundary.minY - gap - usable.minY
        let above = usable.maxY - boundary.maxY - gap
        let useAbove = below < requested.height && above > below
        let capacity = max(44, useAbove ? above : below)
        let height = min(requested.height, usable.height, keepFullHeight ? usable.height : capacity)
        let width = min(requested.width, usable.width)
        let y = useAbove ? boundary.maxY + gap : boundary.minY - gap - height
        return CGRect(x: clamp(leadingX, min: usable.minX, max: usable.maxX - width),
                      y: clamp(y, min: usable.minY, max: usable.maxY - height),
                      width: width, height: height)
    }

    func submenu(for requested: CGSize, parent: CGRect, row: CGRect, preferred: Side?) -> (CGRect, Side) {
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(requested.width, usable.width)
        let height = min(requested.height, usable.height)
        let left = parent.minX - gap - usable.minX
        let right = usable.maxX - parent.maxX - gap
        let direction = preferred ?? .right
        let side: Side
        if (direction == .right ? right : left) >= width { side = direction }
        else if (direction == .right ? left : right) >= width { side = direction == .right ? .left : .right }
        else { side = right >= left ? .right : .left }
        let x = side == .right ? parent.maxX + gap : parent.minX - gap - width
        return (CGRect(x: clamp(x, min: usable.minX, max: usable.maxX - width),
                       y: clamp(row.maxY - height, min: usable.minY, max: usable.maxY - height),
                       width: width, height: height), side)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }

    static func verify() -> Bool {
        let screen = CGRect(x: -1280, y: -100, width: 1280, height: 840)
        let toolbar = CGRect(x: -430, y: -50, width: 380, height: 46)
        let anchor = Self(point: CGPoint(x: -60, y: -20), leadingX: -72, avoid: toolbar, visibleFrame: screen)
        let root = anchor.frame(for: CGSize(width: 220, height: 160))
        let row = CGRect(x: root.minX + 6, y: root.maxY - 110, width: 208, height: 32)
        let (child, side) = anchor.submenu(for: CGSize(width: 230, height: 300), parent: root, row: row, preferred: nil)
        let (nested, direction) = anchor.submenu(for: CGSize(width: 180, height: 95), parent: child, row: child, preferred: side)
        let topToolbar = CGRect(x: -1200, y: 660, width: 500, height: 45)
        let top = Self(point: CGPoint(x: -1000, y: 682), leadingX: -1014, avoid: topToolbar, visibleFrame: screen)
            .frame(for: CGSize(width: 220, height: 160))
        return screen.contains(root) && !root.intersects(toolbar) && root.minY > toolbar.maxY
            && screen.contains(child) && !child.intersects(root) && side == .left
            && screen.contains(nested) && direction == .left && nested.maxX < child.minX
            && top.maxY < topToolbar.minY && abs(top.minX - (-1014)) < 0.1
    }
}
