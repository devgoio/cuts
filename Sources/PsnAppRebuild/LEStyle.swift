import AppKit

// Native-AppKit mapping of the current LabelEditor darkTheme.js tokens.
// Keep AppKit/ScreenCaptureKit native; a WebView would add a browser process to an idle menu-bar app.
enum LEStyle {
    static let primary = color(0x2F6B9A)
    static let canvas = color(0x080C18)
    static let container = color(0x101729)
    static let elevated = color(0x151E33)
    static let border = color(0x27334F)
    static let text = color(0xEEF2FF)
    static let secondary = color(0x99A7C2)
    static let selected = color(0x1E3A56)
    static let danger = color(0xFF6262)

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func surface(_ view: NSView, radius: CGFloat = 10) {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = elevated.cgColor
        view.layer?.borderColor = border.cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
    }

    static func frostedSurface(_ view: NSView, radius: CGFloat = 10) {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = elevated.withAlphaComponent(0.12).cgColor
        view.layer?.borderColor = primary.withAlphaComponent(0.38).cgColor
        view.layer?.borderWidth = 0.7
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        let blur = NSVisualEffectView(frame: view.bounds)
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        view.addSubview(blur, positioned: .below, relativeTo: nil)
        let tint = NSView(frame: view.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = elevated.withAlphaComponent(0.24).cgColor
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint, positioned: .above, relativeTo: blur)
    }

    static func icon(_ button: NSButton) {
        button.appearance = NSAppearance(named: .darkAqua)
        button.isBordered = false
        button.contentTintColor = text
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
    }

    @MainActor static func applySelection(_ button: NSButton, active: Bool) {
        CutsMotion.background(active ? selected : .clear, on: button.layer)
        button.contentTintColor = active ? .white : text
    }

}
