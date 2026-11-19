import AppKit
import QuartzCore

/// Transitions change only presentation layers. Hit targets, window placement
/// and focus are final as soon as the content is shown.
@MainActor
enum CutsMotion {
    private final class AccentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    static let menuHoverDelay = 0.16
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.18, 0.78, 0.27, 1)
    private static var retiring: [ObjectIdentifier: NSPanel] = [:]
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    enum Arrival: Equatable {
        case window, popup, page, pin, hint, feedback

        var duration: CFTimeInterval {
            switch self {
            case .window, .pin: 0.23
            case .popup, .feedback: 0.20
            case .page: 0.16
            case .hint: 0.12
            }
        }

        var opacity: Float {
            switch self {
            case .window, .pin, .feedback: 0.52
            case .popup, .hint: 0.60
            case .page: 0.76
            }
        }

        var scale: CGFloat {
            switch self {
            case .popup, .feedback: 0.975
            case .window: 0.99
            case .page, .pin, .hint: 1
            }
        }
    }

    static func appear(_ view: NSView, _ style: Arrival = .popup, from offset: CGPoint = .zero) {
        guard view.window?.isVisible == true else { return }
        guard enabled else {
            if let layer = view.layer { installArrival(on: layer, style, offset: offset, motionAllowed: false) }
            return
        }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        installArrival(on: layer, style, offset: offset, motionAllowed: true)
    }

    private static func installArrival(on layer: CALayer, _ style: Arrival, offset: CGPoint, motionAllowed: Bool) {
        guard motionAllowed else {
            layer.removeAnimation(forKey: "cuts.arrival.opacity")
            layer.removeAnimation(forKey: "cuts.arrival.transform")
            return
        }
        let presentation = layer.animation(forKey: "cuts.arrival.opacity") == nil ? nil : layer.presentation()
        let start = presentation?.transform ?? transform(offset: offset, scale: style.scale)
        layer.add(animation("opacity", from: presentation?.opacity ?? style.opacity, to: layer.opacity,
                            duration: style.duration), forKey: "cuts.arrival.opacity")
        layer.add(springTransform(from: start, to: layer.transform, duration: style.duration,
                                  bounce: style == .feedback ? 0.10 : 0),
                  forKey: "cuts.arrival.transform")
    }

    static func direction(from source: CGPoint, toward frame: CGRect, distance: CGFloat = 6) -> CGPoint {
        let dx = source.x - frame.midX, dy = source.y - frame.midY
        let length = hypot(dx, dy)
        guard length > 0 else { return .zero }
        return CGPoint(x: dx * distance / length, y: dy * distance / length)
    }

    /// Explicit dismissal may finish visually after logical close. It never
    /// receives input, and a new menu or capture can clear it immediately.
    static func retire(_ panel: NSPanel, toward offset: CGPoint) {
        guard enabled, panel.isVisible, let view = panel.contentView else { panel.orderOut(nil); return }
        view.wantsLayer = true
        guard let layer = view.layer else { panel.orderOut(nil); return }
        panel.ignoresMouseEvents = true
        let id = ObjectIdentifier(panel)
        let duration: CFTimeInterval = 0.12
        let start = layer.presentation()?.transform ?? layer.transform
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "cuts.arrival.transform")
        layer.removeAnimation(forKey: "cuts.arrival.opacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = transform(offset: offset, scale: 0.98)
        CATransaction.commit()
        layer.add(animation("opacity", from: opacity, to: 0, duration: duration), forKey: "cuts.departure.opacity")
        layer.add(animation("transform", from: NSValue(caTransform3D: start),
                            to: NSValue(caTransform3D: layer.transform), duration: duration), forKey: "cuts.departure.transform")
        retiring[id] = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            retiring.removeValue(forKey: id)?.orderOut(nil)
        }
    }

    static func clearRetiringPanels() {
        let old = Array(retiring.values)
        retiring.removeAll()
        old.forEach { $0.orderOut(nil) }
    }

    static func isRetiring(_ panel: NSPanel) -> Bool { retiring[ObjectIdentifier(panel)] === panel }

    static func replaceContents(in view: NSView, apply: () -> Void) {
        if enabled, view.window?.isVisible == true {
            view.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.13
            fade.timingFunction = easeOut
            view.layer?.add(fade, forKey: "cuts.replace")
        } else {
            view.layer?.removeAnimation(forKey: "cuts.replace")
        }
        apply()
    }

    static func accent(in view: NSView, rect: CGRect? = nil, ellipse: Bool = false,
                       color: NSColor = LEStyle.primary, radius: CGFloat = 7) {
        guard enabled, view.window?.isVisible == true else { return }
        let area = rect ?? view.bounds.insetBy(dx: 1, dy: 1)
        guard !area.isEmpty, area.intersects(view.bounds) else { return }
        let clipped = area.insetBy(dx: -2, dy: -2).intersection(view.bounds)
        clearAccent(in: view)
        let overlay = AccentView(frame: clipped)
        overlay.wantsLayer = true
        guard let host = overlay.layer else { return }
        host.masksToBounds = true
        let ring = CAShapeLayer()
        ring.frame = CGRect(origin: .zero, size: clipped.size)
        let x = area.minX - clipped.minX
        let y = view.isFlipped == host.isGeometryFlipped ? area.minY - clipped.minY : clipped.maxY - area.maxY
        let local = CGRect(x: x, y: y, width: area.width, height: area.height)
        ring.path = ellipse ? CGPath(ellipseIn: local, transform: nil)
            : CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        host.addSublayer(ring)
        ring.add(animation("opacity", from: 0.96, to: 0, duration: 0.29), forKey: "cuts.accent.fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak overlay] in overlay?.removeFromSuperview() }
    }

    static func clearAccent(in view: NSView) {
        view.subviews.filter { $0 is AccentView }.forEach { $0.removeFromSuperview() }
    }

    static func background(_ color: NSColor, on layer: CALayer?) {
        guard let layer else { return }
        let shouldAnimate = enabled
        if !shouldAnimate { layer.removeAnimation(forKey: "cuts.hover") }
        let target = color.cgColor
        if layer.backgroundColor == target { return }
        let start = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? NSColor.clear.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = target
        CATransaction.commit()
        if shouldAnimate {
            layer.add(animation("backgroundColor", from: start, to: target, duration: 0.12),
                      forKey: "cuts.hover")
        }
    }

    static func indicatorStroke(_ layer: CALayer, visible: Bool, animated: Bool) {
        let start = layer.presentation() ?? layer
        let original = start.transform
        let opacity = start.opacity
        let target = CATransform3DMakeScale(1, visible ? 1 : 0.1, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        layer.opacity = visible ? 1 : 0
        CATransaction.commit()
        if enabled && animated {
            layer.add(springTransform(from: original, to: target, duration: 0.16, bounce: 0),
                      forKey: "cuts.indicator.transform")
            layer.add(animation("opacity", from: opacity, to: layer.opacity, duration: 0.12),
                      forKey: "cuts.indicator.opacity")
        } else if !enabled {
            layer.removeAnimation(forKey: "cuts.indicator.transform")
            layer.removeAnimation(forKey: "cuts.indicator.opacity")
        }
    }

    private static func transform(offset: CGPoint, scale: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(offset.x, offset.y, 0), scale, scale, 1)
    }

    private static func springTransform(from: CATransform3D, to: CATransform3D,
                                        duration: CFTimeInterval, bounce: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: to)
        spring.duration = min(0.33, spring.settlingDuration)
        return spring
    }

    static func verify() -> Bool {
        let layer = CALayer()
        let offset = direction(from: CGPoint(x: 15, y: 20), toward: CGRect(x: 30, y: 0, width: 20, height: 40))
        guard offset == CGPoint(x: -6, y: 0) else { return false }
        installArrival(on: layer, .popup, offset: offset, motionAllowed: true)
        guard layer.animation(forKey: "cuts.arrival.transform") is CASpringAnimation,
              layer.opacity == 1, CATransform3DIsIdentity(layer.transform) else { return false }
        installArrival(on: layer, .popup, offset: offset, motionAllowed: false)
        return layer.animationKeys()?.isEmpty != false && layer.opacity == 1 && CATransform3DIsIdentity(layer.transform)
    }

    private static func animation(_ property: String, from: Any, to: Any,
                                  duration: CFTimeInterval) -> CABasicAnimation {
        let transition = CABasicAnimation(keyPath: property)
        transition.fromValue = from
        transition.toValue = to
        transition.duration = duration
        transition.timingFunction = easeOut
        return transition
    }
}
