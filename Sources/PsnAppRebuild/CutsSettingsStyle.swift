import AppKit

/// Settings button states only. Surfaces and inputs keep the existing LE theme.
@MainActor
enum CutsSettingsStyle {
    private static let selectedBorder = LEStyle.primary.withAlphaComponent(0.78)
    private static let navigationSelection = LEStyle.selected.blended(withFraction: 0.20, of: LEStyle.elevated) ?? LEStyle.selected
    static let restingCommit = LEStyle.elevated.blended(withFraction: 0.40, of: LEStyle.secondary) ?? LEStyle.elevated
    private static let activeCommit = LEStyle.primary.blended(withFraction: 0.28, of: LEStyle.canvas) ?? LEStyle.primary

    static func control(_ button: NSButton?, selected: Bool = false) {
        guard let button else { return }
        CutsMotion.background(selected ? LEStyle.selected : LEStyle.elevated, on: button.layer)
        button.layer?.borderWidth = 0.75
        button.layer?.borderColor = (selected ? selectedBorder : LEStyle.border).cgColor
        button.contentTintColor = selected ? .white : LEStyle.text
    }

    static func navigation(_ button: NSButton, selected: Bool) {
        CutsMotion.background(selected ? navigationSelection : .clear, on: button.layer)
        button.layer?.borderColor = (selected ? selectedBorder : .clear).cgColor
        button.contentTintColor = selected ? .white : LEStyle.text
    }

    static func commit(_ button: NSButton?, dirty: Bool) {
        guard let button else { return }
        button.isEnabled = dirty
        CutsMotion.background(dirty ? activeCommit : restingCommit, on: button.layer)
        button.layer?.borderWidth = 0.75
        button.layer?.borderColor = (dirty ? selectedBorder : LEStyle.border).cgColor
        button.contentTintColor = dirty ? .white : LEStyle.secondary
    }
}
