import AppKit

enum EraserMode: String, CaseIterable, Codable {
    case whole, local
    var title: String { self == .whole ? "整体擦除" : "局部擦除" }
}

struct AnnotationDefaults: Codable, Equatable {
    struct Line: Codable, Equatable {
        var width: CGFloat = 4
        var rgba: UInt32?
        var color: NSColor { rgba.map(AnnotationDefaults.makeColor) ?? .systemRed }
    }

    var selection: CaptureShape = .rectangle
    var brush = Line()
    var arrow = Line()
    // Kept in the saved payload for older builds; new arrows always start straight.
    private var arrowTool: EditTool? = .arrow
    var arrowHeads: ArrowHeads = .end
    var arrowTip: ArrowTipStyle = .open
    var geometry = Line()
    var geometryTool: EditTool = .rectangle
    var textColor: UInt32?
    var font = ".AppleSystemUIFont"
    var fontSize: CGFloat = 24
    var bold = false
    var italic = false
    var numberColor: UInt32?
    var numberSize: CGFloat = 24
    var numberFilled = true
    var firstNumber = 1
    var magnification: CGFloat = 2
    var lensDiameter: CGFloat?
    var eraserMode: EraserMode?
    var eraserWidth: CGFloat?

    static let baseline = Self()
    private static let key = "cuts.annotationDefaults"
    static let fonts = [("系统字体", ".AppleSystemUIFont"), ("苹方", "PingFang SC"),
                        ("Helvetica Neue", "Helvetica Neue"), ("等宽", "Menlo")]
    static let geometryTools: [EditTool] = [.rectangle, .ellipse, .circle]

    static var saved: Self {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .baseline }
        return decodeSaved(data)
    }

    private static func decodeSaved(_ data: Data) -> Self {
        guard var decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.isValid else { return .baseline }
        decoded.arrowTool = .arrow
        return decoded
    }

    func store() {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    var isValid: Bool {
        Self.geometryTools.contains(geometryTool)
            && [brush.width, arrow.width, geometry.width].allSatisfy { (1...64).contains($0) }
            && (12...96).contains(fontSize) && (12...96).contains(numberSize)
            && Self.fonts.contains(where: { $0.1 == font })
            && (1...9999).contains(firstNumber) && (1.5...6).contains(magnification)
            && (lensDiameter.map { (24...2048).contains($0) } ?? true)
            && (eraserWidth.map { (1...128).contains($0) } ?? true)
    }

    static func makeColor(_ rgba: UInt32) -> NSColor {
        func component(_ offset: UInt32) -> CGFloat { CGFloat((rgba >> offset) & 255) / 255 }
        return NSColor(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }

    static func storeColor(_ color: NSColor) -> UInt32? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
        return (byte(rgb.redComponent) << 24) | (byte(rgb.greenComponent) << 16)
            | (byte(rgb.blueComponent) << 8) | byte(rgb.alphaComponent)
    }

    var localStyles: [EditTool: Line] {
        [.pen: brush, .arrow: arrow, .rectangle: geometry,
         .text: Line(rgba: textColor), .number: Line(rgba: numberColor)]
    }

    static func verify() -> Bool {
        var preset = baseline
        preset.selection = .ellipse
        preset.arrowTool = .curve
        preset.arrow.width = 17
        preset.arrow.rgba = storeColor(.magenta)
        preset.lensDiameter = 160
        preset.magnification = 3.6
        preset.firstNumber = 8
        guard preset.isValid, let data = try? JSONEncoder().encode(preset) else { return false }
        let result = decodeSaved(data)
        preset.arrowTool = .arrow
        return result == preset && result.localStyles[.arrow]?.width == 17
    }
}
