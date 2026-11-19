import AppKit
import CoreGraphics

enum EditTool: String, CaseIterable, Codable {
    case select, pen, arrow, polyline, curve, rectangle, ellipse, circle, text, magnifier, number, mosaic, eraser

    // A curve (and legacy polyline) describes an existing mark, not a draw mode.
    var isArrow: Bool { self == .arrow || self == .polyline || self == .curve }

    var title: String {
        switch self {
        case .select: "选择"
        case .pen: "涂抹"
        case .arrow, .polyline, .curve: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .circle: "圆形"
        case .text: "文字"
        case .magnifier: "放大镜"
        case .number: "序号"
        case .mosaic: "马赛克"
        case .eraser: "橡皮擦"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .arrow, .polyline, .curve: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .circle: "circle"
        case .text: "character"
        case .magnifier: "magnifyingglass"
        case .number: "number.circle"
        case .mosaic: "square.grid.3x3.fill"
        case .eraser: "eraser"
        }
    }
}

enum ArrowHeads: String, CaseIterable, Codable {
    case end, start, both, none

    var title: String {
        switch self {
        case .end: "终点箭头"
        case .start: "起点箭头"
        case .both: "双向箭头"
        case .none: "无箭头"
        }
    }

    var atStart: Bool { self == .start || self == .both }
    var atEnd: Bool { self == .end || self == .both }
}

enum ArrowTipStyle: String, CaseIterable, Codable {
    case open, filled
    var title: String { self == .open ? "线框箭头" : "实心箭头" }
}

struct Mark {
    var tool: EditTool
    var points: [CGPoint] // 0...1 in the source image, independent of pin-window size.
    var text: String = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontName: String = ".AppleSystemUIFont"
    var fontSize: CGFloat = 24
    var bold = false
    var italic = false
    var numberFilled = true
    var arrowHeads: ArrowHeads = .end
    var arrowTipStyle: ArrowTipStyle = .open
    var raster: CGImage?
    var magnifierDiameter: CGFloat?
    var magnification: CGFloat = 2
    var textRuns: [AnnotationTextRun] = []

    var textStyle: AnnotationTextStyle {
        get { AnnotationTextStyle(fontName: fontName, fontSize: fontSize, color: color, bold: bold, italic: italic) }
        set {
            fontName = newValue.fontName
            fontSize = newValue.fontSize
            color = newValue.color
            bold = newValue.bold
            italic = newValue.italic
        }
    }

    mutating func applyTextChange(_ change: AnnotationTextChange) {
        textStyle = change.applied(to: textStyle)
        for index in textRuns.indices { textRuns[index].style = change.applied(to: textRuns[index].style) }
    }
}

@MainActor
final class CaptureEditor: NSObject, NSWindowDelegate {
    struct ScreenTile {
        let frame: CGRect
        let image: CGImage
        let screen: NSScreen
    }

    private struct EditorTile {
        let window: NSWindow
        let frame: CGRect
        let background: FrozenEditorBackground
        let mirror: CrossAnnotationView
    }

    static func annotationSampleRenderer(for image: CGImage) -> ([Mark], CGRect) -> Void {
        let canvas = EditCanvas(image: image, marks: [])
        return { marks, rect in canvas.drawSample(marks, in: rect) }
    }

    var onClose: (() -> Void)?
    var onLongCapture: (() -> Bool)?
    private var window: NSWindow
    private var editorTiles: [EditorTile] = []
    private var closing = false
    private var copyingImage = false
    private var recognizingText = false
    private var acceptsOCRResult = false
    private let canvas: EditCanvas
    private let toolbar: NSView
    private let frozenFrame: CGRect?
    private let selection: CGRect?
    private let selectionShape: CaptureShape
    private let pinned: Bool
    private let pinnedFrame: CGRect?
    private let longDocument: Bool
    private var toolButtons: [EditTool: NSButton] = [:]
    private weak var deleteMarkButton: NSButton?
    private var expandButtons: [EditTool: NSButton] = [:]
    private var lastGeometryTool: EditTool = .rectangle
    private var popup: CutsPopup?
    private var palettePicker: AntColorPicker?
    private var actionAnchor: PopupAnchor?
    private var sessionLineStyles: [EditTool: (width: CGFloat, color: NSColor)]?
    private var activeLineGroup: EditTool?
    private let annotationDefaults: AnnotationDefaults?

    static func presentPinned(image: CGImage, selectionShape: CaptureShape,
                              marks: [Mark] = [], screenRect: CGRect? = nil, defaults: AnnotationDefaults = .saved) {
        let pin = CaptureEditor(image: image, selectionShape: selectionShape,
                                marks: marks, pinned: true, pinnedFrame: screenRect, defaults: defaults)
        StandaloneEditors.shared.retain(pin)
        pin.present()
    }

    static func presentClipboardImage(_ image: CGImage) {
        let editor = CaptureEditor(image: image, initialTool: .select, longDocument: true,
                                   documentTitle: "图片标注", defaults: .saved)
        StandaloneEditors.shared.retain(editor)
        editor.present()
    }

    static func verifyPinnedPlacement() -> Bool {
        let screen = NSScreen.screens.last?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let selection = CGRect(x: screen.minX + 86, y: screen.minY + 120, width: 83, height: 52)
        guard let ctx = CGContext(data: nil, width: 166, height: 104, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return false }
        let pin = CaptureEditor(image: image, pinned: true, pinnedFrame: selection)
        pin.present()
        defer { pin.window.close() }
        return pin.window.frame == selection && pin.canvas.bounds.size == selection.size
    }

    static func verifyCrossDisplayEdits() -> Bool {
        let screens = Array(NSScreen.screens.prefix(2))
        guard screens.count == 2 else {
            print("cross-display-editor fixture skipped: second display unavailable")
            return true
        }
        let a = CGPoint(x: screens[0].frame.midX, y: screens[0].frame.midY)
        let b = CGPoint(x: screens[1].frame.midX, y: screens[1].frame.midY)
        let selection = CGRect(x: min(a.x, b.x) - 80, y: min(a.y, b.y) - 80,
                               width: abs(a.x - b.x) + 160, height: abs(a.y - b.y) + 160)
        guard let context = CGContext(data: nil, width: max(8, Int(selection.width / 4)),
                                      height: max(8, Int(selection.height / 4)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let image = context.makeImage() else { return false }
        let snapshots = screens.map { ScreenTile(frame: $0.frame, image: image, screen: $0) }
        let editor = CaptureEditor(image: image, frozenScreen: image, frozenFrame: screens[0].frame,
                                   selection: selection, initialTool: .pen, editingScreen: screens[0],
                                   screenTiles: snapshots)
        editor.present()
        defer { editor.window.close() }
        guard editor.editorTiles.count == 2 else { return false }
        let primary = editor.editorTiles[0].window, secondary = editor.editorTiles[1].window
        func send(_ type: NSEvent.EventType, _ world: CGPoint, to target: NSWindow) -> Bool {
            let location = target.convertPoint(fromScreen: world)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: target.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        guard primary.isVisible, secondary.isVisible,
              send(.leftMouseDown, a, to: primary), send(.leftMouseDragged, b, to: primary),
              send(.leftMouseUp, b, to: primary), editor.canvas.marks.count == 1,
              let first = editor.canvas.marks.first, let start = first.points.first, let end = first.points.last,
              hypot(start.x - end.x, start.y - end.y) >= 0.35 else { return false }
        let secondStart = CGPoint(x: b.x, y: b.y + 28)
        let secondFinish = CGPoint(x: a.x, y: a.y + 28)
        editor.select(.arrow)
        guard send(.leftMouseDown, secondStart, to: secondary), editor.window === secondary,
              editor.toolbar.window === secondary,
              send(.leftMouseDragged, secondFinish, to: secondary),
              send(.leftMouseUp, secondFinish, to: secondary),
              editor.canvas.marks.count == 2, editor.canvas.marks.last?.tool == .arrow,
              editor.canvas.marks.first?.points == first.points else { return false }
        return editor.canvas.renderedImage()?.width == image.width
    }

    static func verifyLocalizedEraser() -> Bool {
        let size = CGSize(width: 128, height: 80)
        guard let screen = NSScreen.main,
              let context = CGContext(data: nil, width: 128, height: 80, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let base = context.makeImage() else { return false }
        let line = Mark(tool: .pen, points: [CGPoint(x: 0.08, y: 0.5), CGPoint(x: 0.92, y: 0.5)],
                        color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 12)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let editor = CaptureEditor(image: base, marks: [line], pinned: true, pinnedFrame: frame)
        editor.present()
        defer { editor.window.close() }
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                               timestamp: 0, windowNumber: editor.window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)
        }
        func selectMode(_ title: String) -> Bool {
            guard let right = event(.rightMouseDown, x: 44, y: 45) else { return false }
            NSApp.sendEvent(right)
            return editor.popup?.clickRowLikeMouseForTest(title: "橡皮擦") == true
                && editor.popup?.clickRowLikeMouseForTest(title: title) == true
        }
        func sample() -> [Bool]? {
            guard let result = editor.canvas.renderedImage() else { return nil }
            let pixels = NSBitmapImageRep(cgImage: result)
            return [28, 64, 100].map {
                (pixels.colorAt(x: $0, y: 40)?.usingColorSpace(.sRGB)?.greenComponent ?? 0) > 0.9
            }
        }
        guard sample() == [false, false, false], selectMode("局部擦除"),
              let down = event(.leftMouseDown, x: 64, y: 20),
              let drag = event(.leftMouseDragged, x: 64, y: 53),
              let up = event(.leftMouseUp, x: 64, y: 55) else { return false }
        for event in [down, drag, up] { NSApp.sendEvent(event) }
        guard sample() == [false, true, false], editor.canvas.marks.count == 2 else { return false }
        editor.canvas.undo()
        guard sample() == [false, false, false] else { return false }
        editor.canvas.redo()
        guard sample() == [false, true, false], selectMode("整体擦除"),
              let whole = event(.leftMouseDown, x: 28, y: 40) else { return false }
        NSApp.sendEvent(whole)
        return sample() == [true, true, true] && editor.canvas.marks.allSatisfy { $0.tool == .eraser }
    }

    static func writeToolbarPreview(to url: URL) -> Bool {
        guard let context = CGContext(data: nil, width: 900, height: 500,
                                      bitsPerComponent: 8, bytesPerRow: 3600,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.canvas.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 500))
        guard let image = context.makeImage() else { return false }
        let editor = CaptureEditor(image: image, longDocument: true)
        editor.window.displayIfNeeded()
        guard let rep = editor.toolbar.bitmapImageRepForCachingDisplay(in: editor.toolbar.bounds) else { return false }
        editor.toolbar.cacheDisplay(in: editor.toolbar.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func writeTextMenuPreview(to url: URL) -> Bool {
        guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let editor = CaptureEditor(image: image, pinned: true, defaults: .baseline)
        defer { editor.window.close() }
        editor.canvas.fontName = "PingFang SC"
        let menu = editor.textStyleMenu()
        guard let fonts = menu.items.first(where: { $0.title == "字体" }) else { return false }
        return CutsPopup.writePreview(to: url, menu: menu, opening: fonts)
    }

    static func writeColorPickerPreview(to url: URL) -> Bool {
        guard let context = CGContext(data: nil, width: 320, height: 180,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let editor = CaptureEditor(image: image, pinned: true)
        editor.showColorPanel()
        defer { editor.dismissCustomColor() }
        guard let content = editor.palettePicker?.previewView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    private static func returnKey(for window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
    }

    static func verifyTextPosition(previewDirectory: URL? = nil) -> Bool {
        let size = CGSize(width: 320, height: 160)
        guard let context = CGContext(data: nil, width: 320, height: 160,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.canvas.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return false }
        let pin = CaptureEditor(image: image, pinned: true)
        pin.window.setContentSize(size)
        pin.select(.text)
        pin.canvas.applyColor(.systemYellow)
        pin.canvas.applyFontName("Menlo")
        pin.canvas.applyFontSize(32)
        pin.window.makeKeyAndOrderFront(nil)
        defer { pin.window.orderOut(nil) }
        let anchor = CGPoint(x: 48, y: 112)
        func click(_ point: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                 timestamp: 0, windowNumber: pin.window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            pin.canvas.mouseDown(with: event)
            return true
        }
        func snapshot() -> NSBitmapImageRep? {
            let canvas = pin.canvas
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            return bitmap
        }
        func yellowPixels(_ bitmap: NSBitmapImageRep) -> CGRect {
            var pixels = CGRect.null
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.redComponent > 0.65, color.greenComponent > 0.55, color.blueComponent < 0.45
                    else { continue }
                    pixels = pixels.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            return pixels
        }
        func aligned(_ initial: CGRect, _ final: CGRect, tolerance: CGFloat = 1) -> Bool {
            !initial.isNull && !final.isNull
                && abs(initial.minX - final.minX) <= tolerance && abs(initial.minY - final.minY) <= tolerance
                && abs(initial.maxX - final.maxX) <= tolerance && abs(initial.maxY - final.maxY) <= tolerance
        }
        guard click(anchor), let draft = pin.canvas.textInput,
              let newline = returnKey(for: pin.window),
              let confirm = returnKey(for: pin.window, modifiers: .command) else { return false }
        let firstLine = "Cuts 文字"
        let secondLine = "第二行"
        let multiline = firstLine + "\n" + secondLine
        draft.textView.insertText(firstLine, replacementRange: NSRange(location: NSNotFound, length: 0))
        let firstLineFrame = draft.frame
        pin.window.sendEvent(newline)
        guard pin.canvas.textInput === draft, draft.string == firstLine + "\n",
              draft.frame.height > firstLineFrame.height, draft.frame.maxY == firstLineFrame.maxY,
              pin.canvas.marks.isEmpty else { return false }
        draft.textView.insertText(secondLine, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let before = snapshot() else { return false }
        pin.window.sendEvent(confirm)
        guard pin.canvas.textInput == nil, let after = snapshot(),
              pin.canvas.marks.last?.text == multiline,
              let output = pin.canvas.renderedImage() else { return false }
        let initial = yellowPixels(before)
        let confirmed = yellowPixels(after)
        let exported = yellowPixels(NSBitmapImageRep(cgImage: output))
        let backing = CGFloat(after.pixelsWide) / size.width
        let exportedInPreview = CGRect(x: exported.minX * backing, y: exported.minY * backing,
                                       width: exported.width * backing, height: exported.height * backing)
        guard click(CGPoint(x: anchor.x + 15, y: anchor.y - 54)),
              pin.canvas.textInput?.string == multiline, let reopened = snapshot() else { return false }
        if let previewDirectory {
            for (name, bitmap) in [("text-draft", before), ("text-confirmed", after)] {
                guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
                do { try data.write(to: previewDirectory.appendingPathComponent(name).appendingPathExtension("png"), options: .atomic) }
                catch { return false }
            }
        }
        return aligned(initial, confirmed) && aligned(confirmed, exportedInPreview, tolerance: backing)
            && aligned(initial, yellowPixels(reopened))
    }

    static func verifyTextStyleRanges(previewURL: URL? = nil) -> Bool {
        let size = CGSize(width: 420, height: 230)
        guard let context = CGContext(data: nil, width: 420, height: 230,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.canvas.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return false }
        let pin = CaptureEditor(image: image, pinned: true)
        pin.window.setContentSize(size)
        pin.window.makeKeyAndOrderFront(nil)
        defer { pin.window.orderOut(nil) }
        pin.select(.text)
        pin.canvas.applyColor(.systemYellow)
        pin.canvas.applyFontName("Menlo")
        pin.canvas.applyFontSize(24)
        let anchor = CGPoint(x: 56, y: 186)
        func click(_ location: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: pin.window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            pin.canvas.mouseDown(with: event)
            return true
        }
        guard click(anchor), let input = pin.canvas.textInput else { return false }
        let source = "中文示例\nEnglish\n不改样式"
        input.textView.insertText(source, replacementRange: NSRange(location: NSNotFound, length: 0))
        let chinese = (source as NSString).range(of: "中文示例")
        let latin = (source as NSString).range(of: "English")
        let plain = (source as NSString).range(of: "不改样式")
        let originalStyle = input.style(at: 0)
        let anchorUnit = CGPoint(x: anchor.x / size.width, y: anchor.y / size.height)
        func render() -> CGImage? {
            var mark = Mark(tool: .text, points: [anchorUnit], text: input.string)
            mark.textStyle = originalStyle
            mark.textRuns = input.textRuns
            return EditCanvas(image: image, marks: [mark]).renderedImage()
        }
        func pixels(_ image: CGImage?) -> Data? {
            guard let data = image?.dataProvider?.data else { return nil }
            return data as Data
        }
        guard let upright = pixels(render()) else { return false }
        input.textView.setSelectedRange(chinese)
        pin.canvas.toggleItalic()
        guard input.style(at: chinese.location).italic, !input.style(at: latin.location).italic,
              let slantedChinese = pixels(render()), slantedChinese != upright else {
            print("text-style-check: Chinese slant did not render")
            return false
        }
        input.textView.setSelectedRange(latin)
        pin.canvas.toggleItalic()
        guard input.style(at: latin.location).italic, input.style(at: plain.location) == originalStyle,
              let slantedLatin = pixels(render()), slantedLatin != slantedChinese else {
            print("text-style-check: Latin slant did not render")
            return false
        }
        pin.canvas.applyColor(.systemTeal)
        pin.canvas.applyFontName(".AppleSystemUIFont")
        pin.canvas.applyFontSize(44)
        pin.canvas.toggleBold()
        let styled = input.style(at: latin.location)
        guard input.textView.selectedRange() == latin, styled.color == .systemTeal,
              styled.fontSize == 44, styled.fontName == ".AppleSystemUIFont", styled.bold, styled.italic,
              input.style(at: plain.location) == originalStyle, input.style(at: chinese.location).color == .systemYellow
        else { return false }
        let beforeTyping = input.textRuns
        input.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        pin.canvas.applyColor(.systemGreen)
        guard input.textRuns == beforeTyping else { return false }
        input.textView.insertText(" +", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard input.style(at: source.utf16.count + 1).color == .systemGreen,
              input.style(at: plain.location) == originalStyle,
              let expected = pixels(render()), let confirm = returnKey(for: pin.window, modifiers: .command)
        else { return false }
        let savedRuns = input.textRuns
        pin.window.sendEvent(confirm)
        guard pin.canvas.marks.last?.textRuns == savedRuns, pin.canvas.textInput == nil,
              let output = pin.canvas.renderedImage(), pixels(output) == expected,
              click(CGPoint(x: anchor.x + 10, y: anchor.y - 10)),
              pin.canvas.textInput?.textRuns == savedRuns else { return false }
        if let previewURL {
            guard let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: previewURL, options: .atomic) } catch { return false }
        }
        return true
    }

    static func verifyMagnifierEditing() -> Bool {
        let size = CGSize(width: 320, height: 200)
        guard let context = CGContext(data: nil, width: 320, height: 200,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let pin = CaptureEditor(image: image, pinned: true)
        pin.window.setContentSize(size)
        pin.window.makeKeyAndOrderFront(nil)
        defer { pin.popup?.close(restoringFocus: false); pin.window.orderOut(nil) }
        pin.select(.magnifier)
        func drag(from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                     timestamp: 0, windowNumber: pin.window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                else { return false }
                pin.window.sendEvent(event)
            }
            return true
        }
        let start = CGPoint(x: 80, y: 78)
        let lens = CGPoint(x: 160, y: 105)
        func centered(_ mark: Mark, at position: CGPoint) -> Bool {
            guard let markCenter = mark.points.last else { return false }
            let sample = pin.canvas.magnifierSampleRect(mark)
            return mark.points.count == 1
                && abs(markCenter.x * size.width - position.x) < 0.01
                && abs(markCenter.y * size.height - position.y) < 0.01
                && abs(sample.midX - position.x) < 0.01
                && abs(sample.midY - (size.height - position.y)) < 0.01
        }
        guard drag(from: start, to: lens), pin.canvas.marks.count == 1,
              pin.canvas.selectedMarkTool == .magnifier,
              let original = pin.canvas.marks.last, centered(original, at: lens) else { return false }
        let originalCrop = pin.canvas.magnifierSampleRect(original)
        let handleOffset = originalCrop.width * original.magnification / (2 * sqrt(CGFloat(2)))
        guard drag(from: CGPoint(x: lens.x + handleOffset, y: lens.y + handleOffset),
                   to: CGPoint(x: lens.x + 38, y: lens.y + 38)),
              let resized = pin.canvas.marks.last,
              (resized.magnifierDiameter ?? 0) > originalCrop.width * original.magnification,
              centered(resized, at: lens), pin.canvas.marks.count == 1 else { return false }
        let movedLens = CGPoint(x: 187, y: 120)
        pin.select(.select)
        guard drag(from: lens, to: movedLens),
              let moved = pin.canvas.marks.last, centered(moved, at: movedLens) else { return false }
        let edge = CGPoint(x: 6, y: 195)
        guard drag(from: movedLens, to: edge), let movedToEdge = pin.canvas.marks.last,
              pin.canvas.marks.count == 1 else { return false }
        let region = CGRect(origin: .zero, size: size)
        let bubble = pin.canvas.lensInImage(movedToEdge)
        let clampedCenter = CGPoint(x: bubble.midX, y: bubble.midY)
        guard region.contains(bubble), region.contains(pin.canvas.magnifierSampleRect(movedToEdge)),
              abs(bubble.minX) < 0.01, abs(bubble.maxY - size.height) < 0.01,
              centered(movedToEdge, at: clampedCenter) else { return false }
        guard let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: clampedCenter,
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: pin.window.windowNumber, context: nil,
                                                   eventNumber: 2, clickCount: 1, pressure: 1)
        else { return false }
        pin.canvas.rightMouseDown(with: rightClick)
        func verifyLiveMagnification(_ value: CGFloat) -> Bool {
            pin.canvas.magnificationPreview == value && pin.canvas.marks.last?.magnification == 2
        }
        guard pin.popup?.clickRowLikeMouseForTest(title: "放大镜") == true,
              let factor = pin.popup?.dragSliderForTest(title: "放大倍率", whileDragging: verifyLiveMagnification),
              let zoomed = pin.canvas.marks.last, zoomed.magnification == factor,
              pin.canvas.magnificationPreview == nil,
              factor > 4 && factor < 6,
              centered(zoomed, at: clampedCenter),
              pin.canvas.magnifierSampleRect(zoomed).width < pin.canvas.magnifierSampleRect(movedToEdge).width,
              pin.canvas.renderedImage() != nil else {
            print("magnifier slider drag failed: factor=\(String(describing: pin.canvas.marks.last?.magnification))")
            return false
        }
        pin.canvas.undo()
        guard pin.canvas.marks.last?.magnification == 2 else { return false }
        pin.canvas.redo()
        pin.popup?.close()
        guard let selectLens = NSEvent.mouseEvent(with: .leftMouseDown, location: clampedCenter, modifierFlags: [],
                                                 timestamp: 0, windowNumber: pin.window.windowNumber, context: nil,
                                                 eventNumber: 3, clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: selectLens)
        guard pin.canvas.marks.last?.magnification == factor,
              pin.canvas.selectedMarkTool == .magnifier else { return false }
        pin.canvas.rightMouseDown(with: rightClick)
        guard pin.popup?.clickRowLikeMouseForTest(title: "放大镜") == true,
              pin.popup?.changeSliderForTest(to: 3.7, title: "放大倍率") == true,
              let beforeDiameter = pin.canvas.marks.last,
              abs(beforeDiameter.magnification - 3.7) < 0.001 else { return false }
        let liveDiameter = pin.popup?.dragSliderForTest(title: "放大镜直径") { expected in
            guard let index = pin.canvas.marks.indices.last else { return false }
            let committed = pin.canvas.marks[index]
            let preview = pin.canvas.markForPreview(committed, at: index)
            return committed.magnifierDiameter == beforeDiameter.magnifierDiameter
                && preview.magnifierDiameter == expected
                && pin.canvas.lensInImage(preview).width == expected
                && region.contains(pin.canvas.lensInImage(preview))
                && region.contains(pin.canvas.magnifierSampleRect(preview))
                && pin.canvas.magnifierSampleRect(preview).width != pin.canvas.magnifierSampleRect(committed).width
        }
        guard let diameter = liveDiameter, pin.canvas.lensDiameterPreview == nil,
              let enlarged = pin.canvas.marks.last, enlarged.magnifierDiameter == diameter,
              region.contains(pin.canvas.lensInImage(enlarged)),
              region.contains(pin.canvas.magnifierSampleRect(enlarged)) else {
            print("magnifier slider reselection failed: factor=\(String(describing: pin.canvas.marks.last?.magnification))")
            return false
        }
        pin.canvas.undo()
        return pin.canvas.marks.last?.magnifierDiameter == resized.magnifierDiameter
    }

    static func writeArrowPreview(to url: URL) -> Bool {
        guard let context = CGContext(data: nil, width: 800, height: 420, bitsPerComponent: 8,
                                      bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.container.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 420))
        guard let image = context.makeImage() else { return false }
        let marks = [
            Mark(tool: .arrow, points: [CGPoint(x: 0.12, y: 0.30), CGPoint(x: 0.5, y: 0.30), CGPoint(x: 0.88, y: 0.30)],
                 color: .systemRed, lineWidth: 5, arrowHeads: .end),
            Mark(tool: .curve, points: [CGPoint(x: 0.12, y: 0.56), CGPoint(x: 0.5, y: 0.78), CGPoint(x: 0.88, y: 0.56)],
                 color: .systemRed, lineWidth: 5, arrowHeads: .end)
        ]
        let view = EditCanvas(image: image, marks: marks)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 420)
        let previewWindow = NSWindow(contentRect: view.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
        previewWindow.contentView = view
        view.tool = .select
        guard let selectArrow = NSEvent.mouseEvent(with: .leftMouseDown,
                                                  location: CGPoint(x: 400, y: 420 * 0.78),
                                                  modifierFlags: [], timestamp: 0,
                                                  windowNumber: previewWindow.windowNumber, context: nil,
                                                  eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
        view.mouseDown(with: selectArrow)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func verifyPinnedBrushMenu() -> Bool {
        let size = CGSize(width: 320, height: 200)
        guard let screen = NSScreen.main,
              let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return false }
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let editor = CaptureEditor(image: image, pinned: true, pinnedFrame: frame)
        editor.present()
        defer {
            editor.dismissCustomColor()
            editor.popup?.close(restoringFocus: false)
            editor.window.orderOut(nil)
        }

        func send(_ type: NSEvent.EventType, _ location: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: editor.window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            NSApp.sendEvent(event)
            return true
        }
        func openBrush() -> Bool {
            send(.rightMouseDown, CGPoint(x: 160, y: 110))
                && editor.popup?.clickRowLikeMouseForTest(title: "涂抹") == true
        }
        func draw(at y: CGFloat) -> Bool {
            send(.leftMouseDown, CGPoint(x: 30, y: y))
                && send(.leftMouseDragged, CGPoint(x: 100, y: y))
                && send(.leftMouseUp, CGPoint(x: 100, y: y))
        }

        guard editor.canvas.tool == .select, openBrush(),
              editor.popup?.clickRowLikeMouseForTest(title: "开始涂抹") == true,
              editor.canvas.tool == .pen, editor.popup?.isOpen == true,
              openBrush(), let width = editor.popup?.dragSliderForTest(),
              editor.canvas.strokeWidth == CGFloat(width),
              editor.popup?.clickRowLikeMouseForTest(title: "颜色") == true,
              editor.palettePicker?.choosePresetForTest(0x1677FF) == true,
              draw(at: 40), editor.canvas.marks.count == 1,
              let first = editor.canvas.marks.last, first.tool == .pen,
              first.lineWidth == CGFloat(width), first.color == LEStyle.color(0x1677FF),
              openBrush(), editor.popup?.changeSliderForTest(to: 9) == true,
              draw(at: 80), editor.popup?.isOpen == false, editor.canvas.marks.count == 2,
              let second = editor.canvas.marks.last, second.tool == .pen,
              second.lineWidth == 9, second.color == first.color,
              editor.canvas.marks.first?.lineWidth == first.lineWidth else { return false }
        editor.select(.select)
        let onSecond = CGPoint(x: 60, y: 80)
        guard send(.leftMouseDown, onSecond), send(.leftMouseUp, onSecond),
              editor.canvas.selectedMarkTool == .pen, openBrush() else { return false }
        let previewed = editor.popup?.dragSliderForTest(title: "涂抹粗细") { width in
            editor.canvas.marks[1].lineWidth == 9
                && editor.canvas.markForPreview(editor.canvas.marks[1], at: 1).lineWidth == width
                && editor.canvas.markForPreview(editor.canvas.marks[0], at: 0).lineWidth == first.lineWidth
        }
        guard let previewed, editor.canvas.marks[1].lineWidth == previewed,
              editor.popup?.clickRowLikeMouseForTest(title: "删除选中标注") == true,
              editor.canvas.marks.count == 1, !editor.canvas.canDeleteSelectedMark,
              editor.window.isVisible, editor.toolbar.superview == nil else { return false }
        editor.canvas.undo()
        guard editor.canvas.marks.count == 2, editor.canvas.marks[1].lineWidth == previewed else { return false }
        editor.canvas.undo()
        return editor.canvas.marks.count == 2 && editor.canvas.marks[1].lineWidth == 9
    }

    static func verifyLinePreviewAndDelete() -> Bool {
        guard let screen = NSScreen.main,
              let context = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let frame = CGRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 40, width: 720, height: 440)
        let region = CGRect(x: 40, y: 85, width: 640, height: 320)
        let arrow = Mark(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.7), CGPoint(x: 0.34, y: 0.7)], lineWidth: 5)
        let shape = Mark(tool: .rectangle, points: [CGPoint(x: 0.52, y: 0.4), CGPoint(x: 0.82, y: 0.7)], lineWidth: 7)
        let editor = CaptureEditor(image: image, frozenScreen: image, frozenFrame: frame,
                                   selection: region.offsetBy(dx: frame.minX, dy: frame.minY),
                                   initialTool: .select, marks: [arrow, shape], editingScreen: screen)
        editor.present()
        defer { editor.window.close() }
        guard let delete = editor.deleteMarkButton, !delete.isEnabled, delete.contentTintColor == LEStyle.danger,
              let close = editor.toolbar.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.action == #selector(close) }),
              delete.frame.maxX < close.frame.minX, close.frame.minX - delete.frame.minX == 32 else { return false }
        func select(_ unit: CGPoint) -> Bool {
            let point = CGPoint(x: region.minX + unit.x * region.width, y: region.minY + unit.y * region.height)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: editor.window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                else { return false }
                NSApp.sendEvent(event)
            }
            return true
        }
        for (index, tool, point, title) in [
            (0, EditTool.arrow, CGPoint(x: 0.19, y: 0.7), "箭头线宽"),
            (1, EditTool.rectangle, CGPoint(x: 0.6, y: 0.55), "线条粗细")
        ] {
            guard select(point), editor.canvas.selectedMarkTool == tool, delete.isEnabled,
                  let toggle = editor.expandButtons[tool], CutsPopup.clickToolbarButtonForTest(toggle) else { return false }
            let stored = editor.canvas.marks[index].lineWidth
            let changed = editor.popup?.dragSliderForTest(title: title) { width in
                editor.canvas.marks[index].lineWidth == stored
                    && editor.canvas.markForPreview(editor.canvas.marks[index], at: index).lineWidth == width
            }
            guard let changed, editor.canvas.marks[index].lineWidth == changed, editor.canvas.selectedMarkTool == tool else { return false }
            editor.popup?.close()
        }
        guard CutsPopup.clickToolbarButtonForTest(delete), !delete.isEnabled, editor.window.isVisible,
              editor.canvas.marks.map(\.tool) == [.arrow] else { return false }
        editor.canvas.undo()
        guard editor.canvas.marks.map(\.tool) == [.arrow, .rectangle] else { return false }
        editor.canvas.redo()
        return !delete.isEnabled && editor.canvas.marks.map(\.tool) == [.arrow]
    }

    static func verifyNumberEditing() -> Bool {
        let size = CGSize(width: 400, height: 260)
        guard let context = CGContext(data: nil, width: 400, height: 260, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.canvas.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return false }
        let pin = CaptureEditor(image: image, pinned: true, defaults: .baseline)
        pin.window.setContentSize(size)
        pin.window.makeKeyAndOrderFront(nil)
        pin.select(.number)
        defer { pin.popup?.close(restoringFocus: false); pin.window.orderOut(nil) }
        let origin = CGPoint(x: 103, y: 105), destination = CGPoint(x: 158, y: 141)
        func send(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [],
                  count: Int = 1) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: pin.window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: count, pressure: 1)
            else { return false }
            NSApp.sendEvent(event)
            return true
        }
        func click(_ point: CGPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1) -> Bool {
            send(.leftMouseDown, at: point, flags: flags, count: count)
                && send(.leftMouseUp, at: point, flags: flags, count: count)
        }
        func arrow(_ code: UInt16) -> Bool {
            let character = code == 126 ? "\u{f700}" : "\u{f701}"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                               timestamp: 0, windowNumber: pin.window.windowNumber, context: nil,
                                               characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: code) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        let canvas = pin.canvas
        guard click(origin), canvas.marks.count == 1, canvas.selectedNumber == nil,
              click(origin), canvas.selectedNumber == 1,
              click(origin, count: 2), canvas.selectedNumber == 1,
              click(origin, flags: [.command]), canvas.selectedNumber == 2,
              click(origin, flags: [.option]), canvas.selectedNumber == 1,
              arrow(126), canvas.selectedNumber == 2, arrow(125), canvas.selectedNumber == 1,
              send(.leftMouseDown, at: origin), send(.leftMouseDragged, at: destination),
              send(.leftMouseUp, at: destination), canvas.tool == .number,
              canvas.selectedNumber == 1, canvas.marks.count == 1,
              let center = canvas.marks[0].points.last,
              abs(center.x * size.width - destination.x) < 0.01,
              abs(center.y * size.height - destination.y) < 0.01 else { return false }
        guard send(.rightMouseDown, at: destination),
              pin.popup?.clickRowLikeMouseForTest(title: "序号") == true,
              let priorExport = canvas.renderedImage()?.dataProvider?.data as Data? else { return false }
        let applied = pin.popup?.dragSliderForTest(title: "序号大小") { expected in
            canvas.markForPreview(canvas.marks[0], at: 0).fontSize == expected
                && canvas.marks[0].fontSize == 24
                && (canvas.renderedImage()?.dataProvider?.data as Data?) == priorExport
        }
        guard let applied, applied > 24, canvas.marks[0].fontSize == applied,
              (canvas.renderedImage()?.dataProvider?.data as Data?) != priorExport,
              pin.popup?.clickRowLikeMouseForTest(title: "无背景") == true,
              !canvas.marks[0].numberFilled, canvas.selectedNumber == 1 else { return false }
        pin.popup?.close()
        canvas.undo()
        guard canvas.marks[0].numberFilled, canvas.marks[0].fontSize == applied else { return false }
        canvas.undo()
        guard canvas.marks[0].fontSize == 24, canvas.marks[0].points.last == center else { return false }
        canvas.redo()
        guard canvas.marks[0].fontSize == applied else { return false }
        pin.select(.select)
        return click(destination, flags: [.command]) && canvas.selectedNumber == 2
            && click(destination, flags: [.option]) && canvas.selectedNumber == 1
    }

    static func verifyOffscreen() -> Bool {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { return false }
        let filled = Mark(tool: .arrow, points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.75, y: 0.5)],
                          color: .red, lineWidth: 8, arrowHeads: .end, arrowTipStyle: .filled)
        guard let raster = EditCanvas(image: image, marks: [filled]).renderedImage() else { return false }
        let arrowPixels = NSBitmapImageRep(cgImage: raster)
        guard let head = arrowPixels.colorAt(x: 41, y: 16)?.usingColorSpace(.sRGB), head.redComponent > 0.8,
              let beyond = arrowPixels.colorAt(x: 50, y: 16)?.usingColorSpace(.sRGB), beyond.redComponent < 0.25 else {
            print("filled arrow shaft protruded beyond the head")
            return false
        }
        guard let patterned = CGContext(data: nil, width: 96, height: 96,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        for y in stride(from: 0, to: 96, by: 2) {
            for x in stride(from: 0, to: 96, by: 2) {
                patterned.setFillColor(((x + y) / 2).isMultiple(of: 2)
                                       ? NSColor.white.cgColor : NSColor.black.cgColor)
                patterned.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        guard let patternedImage = patterned.makeImage() else { return false }
        let patternedEditor = CaptureEditor(image: patternedImage, pinned: true)
        patternedEditor.select(.mosaic)
        func patternedEvent(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: patternedEditor.window.windowNumber, context: nil,
                               eventNumber: number, clickCount: 1, pressure: 1)
        }
        guard let patternDown = patternedEvent(.leftMouseDown, CGPoint(x: 40, y: 40), 30),
              let patternDrag = patternedEvent(.leftMouseDragged, CGPoint(x: 190, y: 190), 31),
              let patternUp = patternedEvent(.leftMouseUp, CGPoint(x: 190, y: 190), 32) else { return false }
        patternedEditor.canvas.mouseDown(with: patternDown)
        patternedEditor.canvas.mouseDragged(with: patternDrag)
        guard patternedEditor.canvas.tool == .mosaic,
              patternedEditor.canvas.hasMosaicPreview,
              let preview = patternedEditor.canvas.bitmapImageRepForCachingDisplay(in: patternedEditor.canvas.bounds),
              let theme = LEStyle.primary.usingColorSpace(.sRGB) else { return false }
        patternedEditor.canvas.cacheDisplay(in: patternedEditor.canvas.bounds, to: preview)
        func hasThemeOutline(_ bitmap: NSBitmapImageRep) -> Bool {
            let edgeX = Int(40 * CGFloat(bitmap.pixelsWide) / patternedEditor.canvas.bounds.width)
            return (edgeX - 2...edgeX + 2).contains { x in
                guard x >= 0, x < bitmap.pixelsWide,
                      let pixel = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
                else { return false }
                return abs(pixel.redComponent - theme.redComponent) < 0.12
                    && abs(pixel.greenComponent - theme.greenComponent) < 0.12
                    && abs(pixel.blueComponent - theme.blueComponent) < 0.12
            }
        }
        guard hasThemeOutline(preview) else { return false }
        patternedEditor.canvas.mouseUp(with: patternUp)
        guard let mosaicRaster = patternedEditor.canvas.marks.last?.raster,
              mosaicRaster.width >= 2,
              let color = NSBitmapImageRep(cgImage: mosaicRaster).colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB),
              color.redComponent > 0.1, color.redComponent < 0.9,
              let mosaicOutput = patternedEditor.canvas.renderedImage(),
              !hasThemeOutline(NSBitmapImageRep(cgImage: mosaicOutput)) else { return false }
        let sample = Mark(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)])
        let arrowPin = CaptureEditor(image: image, marks: [sample], pinned: true)
        let bendStart = CGPoint(x: 120, y: 60)
        let bendEnd = CGPoint(x: 120, y: 86)
        guard let bendDown = NSEvent.mouseEvent(with: .leftMouseDown, location: bendStart,
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: arrowPin.window.windowNumber, context: nil,
                                               eventNumber: 1, clickCount: 1, pressure: 1),
              let bendDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: bendEnd,
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: arrowPin.window.windowNumber, context: nil,
                                               eventNumber: 2, clickCount: 1, pressure: 1),
              let bendUp = NSEvent.mouseEvent(with: .leftMouseUp, location: bendEnd,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: arrowPin.window.windowNumber, context: nil,
                                             eventNumber: 3, clickCount: 1, pressure: 1) else { return false }
        arrowPin.canvas.mouseDown(with: bendDown)
        arrowPin.canvas.mouseDragged(with: bendDrag)
        arrowPin.canvas.mouseUp(with: bendUp)
        guard arrowPin.canvas.marks[0].points.count == 3,
              arrowPin.canvas.marks[0].tool == .curve,
              arrowPin.canvas.marks[0].points[1].y > 0.5 else { return false }
        arrowPin.canvas.applyArrowHeads(.both)
        arrowPin.canvas.applyArrowTipStyle(.filled)
        guard arrowPin.canvas.marks[0].arrowHeads == .both,
              arrowPin.canvas.marks[0].arrowTipStyle == .filled,
              arrowPin.canvas.marks[0].tool == .curve,
              arrowPin.canvas.renderedImage() != nil else { return false }
        let legacy = Mark(tool: .polyline, points: [CGPoint(x: 0.1, y: 0.1),
                                                   CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.9, y: 0.1)])
        let legacyCanvas = EditCanvas(image: image, marks: [legacy])
        guard legacyCanvas.renderedImage() != nil, legacyCanvas.marks.first?.tool == .polyline,
              legacyCanvas.marks.first?.points == legacy.points else { return false }
        let drawnArrow = CaptureEditor(image: image, pinned: true)
        drawnArrow.select(.arrow)
        func arrowEvent(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: drawnArrow.window.windowNumber, context: nil,
                               eventNumber: number, clickCount: 1, pressure: 1)
        }
        guard let drawDown = arrowEvent(.leftMouseDown, CGPoint(x: 30, y: 25), 10),
              let drawDrag = arrowEvent(.leftMouseDragged, CGPoint(x: 190, y: 85), 11),
              let drawUp = arrowEvent(.leftMouseUp, CGPoint(x: 190, y: 85), 12) else { return false }
        drawnArrow.canvas.mouseDown(with: drawDown)
        drawnArrow.canvas.mouseDragged(with: drawDrag)
        drawnArrow.canvas.mouseUp(with: drawUp)
        guard drawnArrow.canvas.marks.count == 1,
              drawnArrow.canvas.marks[0].points.count == 3,
              drawnArrow.canvas.selectedArrowTool == .arrow else { return false }
        func dragArrowHandle(_ index: Int, to end: CGPoint, eventNumber: Int) -> Bool {
            let unit = drawnArrow.canvas.marks[0].points[index]
            let start = CGPoint(x: unit.x * drawnArrow.canvas.bounds.width,
                                y: unit.y * drawnArrow.canvas.bounds.height)
            guard let down = arrowEvent(.leftMouseDown, start, eventNumber),
                  let drag = arrowEvent(.leftMouseDragged, end, eventNumber + 1),
                  let up = arrowEvent(.leftMouseUp, end, eventNumber + 2) else { return false }
            drawnArrow.canvas.mouseDown(with: down)
            drawnArrow.canvas.mouseDragged(with: drag)
            drawnArrow.canvas.mouseUp(with: up)
            return true
        }
        guard dragArrowHandle(0, to: CGPoint(x: 45, y: 30), eventNumber: 13),
              drawnArrow.canvas.marks[0].points[0].x > 0.15,
              dragArrowHandle(2, to: CGPoint(x: 200, y: 75), eventNumber: 16),
              drawnArrow.canvas.marks[0].points[2].x > 0.8 else { return false }
        let straight = drawnArrow.canvas.marks[0].points
        guard straight[1] == CGPoint(x: (straight[0].x + straight[2].x) / 2,
                                     y: (straight[0].y + straight[2].y) / 2),
              dragArrowHandle(1, to: CGPoint(x: 110, y: 90), eventNumber: 19),
              drawnArrow.canvas.tool == .arrow,
              drawnArrow.canvas.marks[0].tool == .curve,
              drawnArrow.canvas.marks[0].points[1].y > 0.7 else { return false }
        drawnArrow.present()
        guard let arrowMenuEvent = arrowEvent(.rightMouseDown, CGPoint(x: 135, y: 60), 23) else { return false }
        NSApp.sendEvent(arrowMenuEvent)
        guard drawnArrow.popup?.clickRowLikeMouseForTest(title: "箭头") == true,
              let draggedArrowWidth = drawnArrow.popup?.dragSliderForTest(),
              drawnArrow.canvas.marks[0].lineWidth == CGFloat(draggedArrowWidth),
              drawnArrow.popup?.changeSliderForTest(to: 13) == true,
              drawnArrow.canvas.marks[0].lineWidth == 13,
              drawnArrow.canvas.selectedStrokeWidth == 13 else { return false }
        drawnArrow.popup?.close(restoringFocus: false)
        let center = CGPoint(x: straight[1].x * drawnArrow.canvas.bounds.width,
                             y: straight[1].y * drawnArrow.canvas.bounds.height)
        guard dragArrowHandle(1, to: CGPoint(x: center.x, y: center.y + 2), eventNumber: 24),
              drawnArrow.canvas.marks[0].tool == .arrow, drawnArrow.canvas.marks[0].points == straight else { return false }
        drawnArrow.canvas.undo()
        guard drawnArrow.canvas.marks[0].tool == .curve else { return false }
        drawnArrow.canvas.redo()
        guard drawnArrow.canvas.marks[0].tool == .arrow else { return false }
        drawnArrow.window.orderOut(nil)
        let pin = CaptureEditor(image: image, marks: [sample], pinned: true)
        guard pin.canvas.renderedImage()?.width == 64,
              pin.canvas.renderedImage()?.height == 32,
              pin.toolbar.superview == nil,
              pin.canvas.superview === pin.window.contentView,
              pin.canvas.tool == .select,
              pin.window.styleMask.contains(.borderless),
              !pin.window.styleMask.contains(.titled),
              pin.canvas.onRightClick != nil else { return false }
        let ocr = OCRDocument(glyphs: [
            OCRGlyph(text: "测", box: CGRect(x: 0.1, y: 0.3, width: 0.15, height: 0.4), line: 0),
            OCRGlyph(text: "试", box: CGRect(x: 0.3, y: 0.3, width: 0.15, height: 0.4), line: 0)
        ])
        guard ocr.selectedText(from: 0, through: 1) == "测试" else { return false }
        pin.canvas.setOCRDocument(ocr)
        let firstOCRPoint = CGPoint(x: pin.canvas.bounds.width * 0.17, y: pin.canvas.bounds.height * 0.5)
        let lastOCRPoint = CGPoint(x: pin.canvas.bounds.width * 0.37, y: pin.canvas.bounds.height * 0.5)
        guard let ocrDown = NSEvent.mouseEvent(with: .leftMouseDown, location: firstOCRPoint,
                                              modifierFlags: [], timestamp: 0,
                                              windowNumber: pin.window.windowNumber, context: nil,
                                              eventNumber: 1, clickCount: 1, pressure: 1),
              let ocrDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: lastOCRPoint,
                                              modifierFlags: [], timestamp: 0,
                                              windowNumber: pin.window.windowNumber, context: nil,
                                              eventNumber: 2, clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: ocrDown)
        pin.canvas.mouseDragged(with: ocrDrag)
        guard pin.canvas.hasSelectedOCRText else { return false }
        pin.select(.pen)
        guard !pin.canvas.ocrMode, !pin.canvas.hasSelectedOCRText else { return false }
        pin.select(.pen)
        let start = CGPoint(x: pin.canvas.frame.minX + 100, y: pin.canvas.frame.minY + 100)
        let end = CGPoint(x: start.x + 40, y: start.y + 30)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [],
                                           timestamp: 0, windowNumber: pin.window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [],
                                           timestamp: 0, windowNumber: pin.window.windowNumber,
                                           context: nil, eventNumber: 2, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [],
                                         timestamp: 0, windowNumber: pin.window.windowNumber,
                                         context: nil, eventNumber: 3, clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: down)
        pin.canvas.mouseDragged(with: drag)
        pin.canvas.mouseUp(with: up)
        guard pin.canvas.marks.count == 2 else { return false }
        pin.canvas.undo()
        guard pin.canvas.marks.count == 1 else { return false }
        pin.canvas.redo()
        guard pin.canvas.marks.count == 2 else { return false }
        pin.select(.number)
        pin.canvas.applyNumberSize(12)
        pin.canvas.mouseDown(with: down)
        guard pin.canvas.marks.count == 3, pin.canvas.marks.last?.text == "1" else { return false }
        pin.canvas.mouseDown(with: down)
        guard pin.canvas.marks.count == 3, pin.canvas.selectedNumber == 1 else { return false }
        guard let commandDown = NSEvent.mouseEvent(with: .leftMouseDown, location: start,
                                                    modifierFlags: [.command], timestamp: 0,
                                                    windowNumber: pin.window.windowNumber, context: nil,
                                                    eventNumber: 4, clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: commandDown)
        guard pin.canvas.marks.count == 3, pin.canvas.marks.last?.text == "2" else { return false }
        pin.canvas.undo()
        guard pin.canvas.marks.last?.text == "1" else { return false }
        pin.canvas.redo()
        guard pin.canvas.marks.last?.text == "2" else { return false }
        pin.canvas.numberFilled = false
        pin.canvas.setNextNumber(7)
        guard let secondNumberDown = NSEvent.mouseEvent(with: .leftMouseDown,
                                                        location: CGPoint(x: start.x + 50, y: start.y),
                                                        modifierFlags: [], timestamp: 0,
                                                        windowNumber: pin.window.windowNumber, context: nil,
                                                        eventNumber: 5, clickCount: 1, pressure: 1),
              let thirdNumberDown = NSEvent.mouseEvent(with: .leftMouseDown,
                                                       location: CGPoint(x: start.x + 105, y: start.y),
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: pin.window.windowNumber, context: nil,
                                                       eventNumber: 6, clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: secondNumberDown)
        guard pin.canvas.marks.count == 4, pin.canvas.marks.last?.text == "7",
              pin.canvas.marks.last?.numberFilled == false else { return false }
        pin.canvas.mouseDown(with: thirdNumberDown)
        guard pin.canvas.marks.count == 5, pin.canvas.marks.last?.text == "8" else { return false }
        pin.select(.eraser)
        pin.canvas.mouseDown(with: down)
        guard pin.canvas.marks.count == 4 else { return false }
        pin.select(.mosaic)
        pin.canvas.mouseDown(with: down)
        pin.canvas.mouseDragged(with: drag)
        pin.canvas.mouseUp(with: up)
        guard pin.canvas.marks.last?.raster != nil else { return false }
        let mosaicCount = pin.canvas.marks.count
        guard let clickUp = NSEvent.mouseEvent(with: .leftMouseUp, location: start,
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: pin.window.windowNumber,
                                               context: nil, eventNumber: 7,
                                               clickCount: 1, pressure: 1) else { return false }
        pin.canvas.mouseDown(with: down)
        pin.canvas.mouseUp(with: clickUp)
        guard pin.canvas.marks.count == mosaicCount + 1,
              let clickMosaic = pin.canvas.marks.last,
              clickMosaic.raster != nil,
              clickMosaic.points.count == 2,
              clickMosaic.points[0] != clickMosaic.points[1] else { return false }
        pin.canvas.undo()
        guard pin.canvas.marks.count == mosaicCount else { return false }
        pin.canvas.applyColor(.systemBlue)
        pin.select(.ellipse)
        pin.canvas.mouseDown(with: down)
        pin.canvas.mouseDragged(with: drag)
        pin.canvas.mouseUp(with: up)
        guard pin.canvas.marks.last?.tool == .ellipse,
              pin.canvas.marks.last?.color == .systemBlue,
              pin.canvas.renderedImage()?.width == 64 else { return false }
        pin.select(.text)
        pin.canvas.mouseDown(with: down)
        guard let input = pin.canvas.textInput,
              !input.textView.drawsBackground, input.layer?.borderWidth == 1 else { return false }
        input.textView.insertText("测试标注", replacementRange: NSRange(location: NSNotFound, length: 0))
        pin.select(.arrow)
        guard pin.canvas.marks.last?.tool == .text,
              pin.canvas.marks.last?.text == "测试标注",
              pin.canvas.textInput == nil else { return false }
        pin.select(.rectangle)
        guard pin.canvas.tool == .rectangle,
              pin.toolbar.superview == nil else { return false }
        pin.canvas.applyNumberFilled(true)
        func iconsAreConsistent(_ menu: NSMenu) -> Bool {
            menu.items.allSatisfy { item in
                item.isSeparatorItem || item.view != nil || (item.image?.size == MenuIcon.size
                    && (item.submenu.map(iconsAreConsistent) ?? true))
            }
        }
        guard iconsAreConsistent(pin.makePinnedMenu()) else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "箭头") == true else { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard pin.popup?.clickRowLikeMouseForTest(title: "画箭头") == true,
              pin.canvas.tool == .arrow else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "箭头") == true else { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard pin.popup?.clickRowLikeMouseForTest(title: "双向箭头") == true,
              pin.canvas.arrowHeads == .both else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "序号") == true else { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard pin.popup?.clickRowLikeMouseForTest(title: "无背景") == true,
              !pin.canvas.numberFilled, pin.canvas.tool == .number else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "圈选") == true else { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard pin.popup?.clickRowLikeMouseForTest(title: "圆形") == true,
              pin.canvas.tool == .circle else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "圈选") == true,
              pin.popup?.clickRowLikeMouseForTest(title: "颜色") == true,
              pin.palettePicker?.choosePresetForTest(0x1677FF) == true,
              pin.canvas.annotationColor == LEStyle.color(0x1677FF), pin.popup?.isOpen == true else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "圈选") == true,
              pin.popup?.clickRowLikeMouseForTest(title: "颜色") == true,
              let pinnedPicker = pin.palettePicker, pinnedPicker.isVisible else { return false }
        pinnedPicker.applyHexForTest("#AB32CD")
        guard pin.palettePicker?.isVisible == true,
              pin.canvas.annotationColor == LEStyle.color(0xAB32CD) else { return false }
        pin.showPopup(pin.makePinnedMenu(), from: pin.canvas)
        guard pin.popup?.clickRowLikeMouseForTest(title: "圈选") == true,
              pin.popup?.changeSliderForTest(to: 10, title: "线条粗细") == true,
              pin.canvas.strokeWidth == 10 else { return false }
        pin.popup?.close()
        if let screen = NSScreen.main {
            let rect = CGRect(x: screen.frame.minX + 20, y: screen.frame.minY + 20, width: 64, height: 32)
            let inline = CaptureEditor(image: image, frozenScreen: image, frozenFrame: screen.frame, selection: rect)
            let firstLevel = ["选择", "涂抹", "箭头", "圈选", "文字", "序号",
                              "马赛克", "橡皮擦", "撤回", "重做", "提取文字",
                              "滚动长截图", "复制图片", "关闭"]
            let controls = inline.toolbar.subviews.compactMap { $0 as? NSButton }
            guard inline.toolbar.frame.height == 46,
                  !inline.toolbar.subviews.contains(where: { $0 is NSBox }),
                  controls.allSatisfy({
                      if ($0 as? HoverHintButton)?.isSubmenuDot == true { return $0.frame.minY == 0 && $0.frame.height == 11 }
                      return $0.frame.minY == 7 && $0.frame.height == 32
                  }),
                  controls.compactMap({ $0 as? HoverHintButton }).filter(\.isSubmenuDot).count == 7,
                  firstLevel.allSatisfy({ title in
                      controls.contains(where: { $0.toolTip?.hasPrefix(title) == true })
                  }) else { return false }
            var longClicked = false
            inline.onLongCapture = { longClicked = true; return false }
            guard let longButton = controls.first(where: { $0.toolTip == "滚动长截图" }),
                  let penButton = inline.toolButtons[.pen] else { return false }
            longButton.performClick(nil)
            penButton.performClick(nil)
            guard longClicked, inline.canvas.tool == .pen else { return false }
            inline.select(.pen)
            inline.select(.arrow)
            guard let arrowButton = inline.expandButtons[.arrow] else { return false }
            inline.showArrowMenu(arrowButton)
            guard inline.popup?.changeSliderForTest(to: 13) == true,
                  inline.canvas.strokeWidth == 13,
                  inline.arrowMenu().items.filter({ !$0.isSeparatorItem && $0.view == nil }).map(\.title)
                    == ArrowHeads.allCases.map(\.title) + ArrowTipStyle.allCases.map(\.title) + ["颜色"],
                  inline.canvas.tool == .arrow else { return false }
            inline.select(.pen)
            guard let mainArrowButton = inline.toolButtons[.arrow] else { return false }
            mainArrowButton.performClick(nil)
            guard inline.canvas.tool == .arrow else { return false }
            inline.showArrowMenu(arrowButton)
            guard inline.popup?.clickRowLikeMouseForTest(title: "实心箭头") == true,
                  inline.canvas.arrowTipStyle == .filled else { return false }
            guard let numberExpandButton = inline.expandButtons[.number] else { return false }
            inline.showNumberMenu(numberExpandButton)
            guard inline.popup?.clickRowLikeMouseForTest(title: "无背景") == true,
                  !inline.canvas.numberFilled, inline.canvas.tool == .number else { return false }
            inline.showNumberMenu(numberExpandButton)
            guard inline.popup?.clickRowLikeMouseForTest(title: "设置下一个数字…") == true,
                  NSApp.modalWindow == nil,
                  inline.popup?.applyNumberForTest(17) == true,
                  inline.popup?.isOpen == true, inline.canvas.nextNumber == 17 else { return false }
            guard let geometryExpandButton = inline.expandButtons[.rectangle],
                  let brushExpandButton = inline.expandButtons[.pen],
                  let textStyleButton = inline.expandButtons[.text],
                  let textButton = inline.toolButtons[.text] else { return false }
            inline.window.makeKeyAndOrderFront(nil)
            defer { inline.popup?.close(restoringFocus: false); inline.window.orderOut(nil) }
            let toolbarFrame = inline.toolbar.frame
            let toolbarScreenFrame = inline.window.convertToScreen(inline.toolbar.convert(inline.toolbar.bounds, to: nil))
            guard CutsPopup.clickToolbarButtonForTest(brushExpandButton),
                  inline.popup?.screenFrame?.intersects(toolbarScreenFrame) == false,
                  inline.popup?.clickRowLikeMouseForTest(title: "颜色") == true,
                  inline.palettePicker?.frame.intersects(toolbarScreenFrame) == false,
                  inline.palettePicker?.choosePresetForTest(0x52C41A) == true,
                  inline.canvas.tool == .pen, inline.canvas.annotationColor == LEStyle.color(0x52C41A) else {
                print("brush-palette-check failed")
                return false
            }
            guard CutsPopup.clickToolbarButtonForTest(brushExpandButton),
                  let draggedWidth = inline.popup?.dragSliderForTest(),
                  inline.canvas.strokeWidth == CGFloat(draggedWidth),
                  inline.popup?.changeSliderForTest(to: 8) == true, inline.popup?.isOpen == true,
                  inline.canvas.strokeWidth == 8, inline.toolbar.frame == toolbarFrame else {
                print("brush-slider-check failed width=\(inline.canvas.strokeWidth)")
                return false
            }
            // Switching to another dropdown must work while the old menu is open.
            guard let previousPopup = inline.popup, previousPopup.isOpen else { return false }
            for choice in [EditTool.circle, .ellipse, .rectangle, .circle] {
                guard CutsPopup.clickToolbarButtonForTest(geometryExpandButton),
                      !previousPopup.isOpen,
                      inline.popup?.screenFrame?.intersects(toolbarScreenFrame) == false,
                      inline.popup?.clickRowLikeMouseForTest(title: choice.title) == true,
                      inline.canvas.tool == choice,
                      inline.lastGeometryTool == choice,
                      inline.geometryMenu().items.first(where: { $0.title == choice.title })?.state == .on,
                      inline.toolbar.frame == toolbarFrame else {
                    print("geometry-menu-check failed: \(choice.rawValue) active=\(inline.canvas.tool.rawValue)")
                    return false
                }
                func shapeEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: CGPoint(x: inline.canvas.frame.minX + x,
                                                                      y: inline.canvas.frame.minY + y),
                                       modifierFlags: [], timestamp: 0, windowNumber: inline.window.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                }
                guard let shapeDown = shapeEvent(.leftMouseDown, 8, 4),
                      let shapeDrag = shapeEvent(.leftMouseDragged, 40, 24),
                      let shapeUp = shapeEvent(.leftMouseUp, 40, 24) else { return false }
                let previousCount = inline.canvas.marks.count
                NSApp.sendEvent(shapeDown)
                NSApp.sendEvent(shapeDrag)
                NSApp.sendEvent(shapeUp)
                guard inline.canvas.marks.count == previousCount + 1,
                      inline.canvas.marks.last?.tool == choice else {
                    print("geometry-draw-check failed: \(choice.rawValue) key=\(inline.window.isKeyWindow) hitCanvas=\(inline.window.contentView?.hitTest(shapeDown.locationInWindow) === inline.canvas)")
                    return false
                }
            }
            let markCount = inline.canvas.marks.count
            guard CutsPopup.clickToolbarButtonForTest(geometryExpandButton),
                  inline.popup?.clickRowLikeMouseForTest(title: "颜色") == true,
                  inline.palettePicker?.choosePresetForTest(0x1677FF) == true,
                  inline.canvas.annotationColor == LEStyle.color(0x1677FF) else { return false }
            guard CutsPopup.clickToolbarButtonForTest(geometryExpandButton),
                  inline.popup?.changeSliderForTest(to: 10) == true,
                  inline.canvas.strokeWidth == 10 else { return false }
            inline.popup?.close()
            textButton.performClick(nil)
            let textPoint = CGPoint(x: inline.canvas.frame.minX + 30, y: inline.canvas.frame.midY)
            guard let textDown = NSEvent.mouseEvent(with: .leftMouseDown, location: textPoint, modifierFlags: [],
                                                    timestamp: 0, windowNumber: inline.window.windowNumber,
                                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            inline.canvas.mouseDown(with: textDown)
            guard let draft = inline.canvas.textInput else { return false }
            draft.textView.insertText("Cuts", replacementRange: NSRange(location: NSNotFound, length: 0))
            draft.textView.setSelectedRange(NSRange(location: 0, length: draft.string.utf16.count))

            func openTextStyle() -> Bool {
                CutsPopup.clickToolbarButtonForTest(textStyleButton)
                    && inline.popup?.screenFrame?.intersects(toolbarScreenFrame) == false
                    && inline.toolbar.frame == toolbarFrame
            }
            func chooseTextStyle(_ choice: String, under group: String? = nil) -> Bool {
                guard openTextStyle() else { return false }
                if let group, inline.popup?.clickRowLikeMouseForTest(title: group) != true { return false }
                return inline.popup?.clickRowLikeMouseForTest(title: choice) == true
            }
            guard chooseTextStyle("等宽", under: "字体"),
                  inline.canvas.fontName == "Menlo",
                  inline.popup?.selectedRowCheckForTest(title: "等宽") == true,
                  (draft.layoutEngine.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Menlo"
            else { return false }
            let displayScale = min(inline.canvas.frame.width / CGFloat(image.width),
                                   inline.canvas.frame.height / CGFloat(image.height))
            guard openTextStyle() else { return false }
            let initialSize = inline.canvas.fontSize
            let previewFontSize = inline.popup?.dragSliderForTest(title: "字号") { value in
                draft.style(at: 0).fontSize == value && inline.canvas.fontSize == initialSize
            }
            guard let draggedFontSize = previewFontSize,
                  inline.canvas.fontSize == draggedFontSize,
                  inline.popup?.changeSliderForTest(to: 32, title: "字号") == true,
                  inline.canvas.fontSize == 32,
                  let draftSize = (draft.layoutEngine.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
                  abs(draftSize - 32 * displayScale) < 0.01
            else { return false }
            guard chooseTextStyle("颜色"),
                  inline.palettePicker?.choosePresetForTest(0xFAAD14) == true,
                  draft.style(at: 0).color == LEStyle.color(0xFAAD14),
                  inline.canvas.textInput === draft, inline.canvas.marks.count == markCount else { return false }
            guard chooseTextStyle("加粗"), inline.canvas.textBold,
                  chooseTextStyle("倾斜"), inline.canvas.textItalic,
                  chooseTextStyle("颜色"),
                  let textPicker = inline.palettePicker else { return false }
            textPicker.applyHexForTest("#E68A41")
            inline.popup?.close()
            let customColor = NSColor(srgbRed: 230.0 / 255, green: 138.0 / 255, blue: 65.0 / 255, alpha: 1)
            guard inline.canvas.textInput === draft, draft.style(at: 0).color == customColor,
                  inline.window.firstResponder === draft.textView else { return false }
            guard let confirm = returnKey(for: inline.window, modifiers: .command) else { return false }
            inline.window.sendEvent(confirm)
            guard inline.canvas.textInput == nil, let mark = inline.canvas.marks.last,
                  mark.text == "Cuts", mark.fontName == "Menlo", mark.fontSize == 32,
                  mark.color == customColor, mark.bold, mark.italic else { return false }
            guard openTextStyle(), inline.popup?.changeSliderForTest(to: 48, title: "字号") == true,
                  inline.canvas.marks.last?.fontSize == 48 else { return false }
            return inline.toolbar.superview === inline.window.contentView
                && inline.canvas.superview === inline.window.contentView
                && inline.canvas.tool == .text
                && !inline.toolbar.isHidden
                && inline.toolbar.frame.minX >= 0
                && inline.toolbar.frame.maxX <= inline.window.contentView!.bounds.maxX
        }
        return true
    }

    init(image: CGImage, frozenScreen: CGImage? = nil, frozenFrame: CGRect? = nil,
         selection: CGRect? = nil, selectionShape: CaptureShape = .rectangle,
         initialTool: EditTool = .arrow, marks: [Mark] = [], pinned: Bool = false,
         longDocument: Bool = false, documentTitle: String = "滚动长截图 · 标注",
         pinnedFrame: CGRect? = nil, editingScreen: NSScreen? = nil,
         defaults: AnnotationDefaults? = nil, screenTiles: [ScreenTile] = []) {
        self.frozenFrame = frozenFrame
        self.selection = selection
        self.selectionShape = selectionShape
        self.pinned = pinned
        self.pinnedFrame = pinnedFrame
        self.longDocument = longDocument
        self.annotationDefaults = defaults
        canvas = EditCanvas(image: image, marks: marks)
        canvas.transparentOutsideImage = selectionShape != .rectangle
        canvas.dragsWindowOnEmptySelection = pinned
        toolbar = NSView(frame: CGRect(x: 0, y: 0, width: 598, height: 46))
        if longDocument {
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.contentMinSize = CGSize(width: 654, height: 340)
            window.title = documentTitle
        } else if pinned {
            let ratio = CGFloat(image.width) / max(1, CGFloat(image.height))
            let width: CGFloat = min(950, max(240, CGFloat(image.width) / 2))
            let height = width / ratio
            let initialFrame = pinnedFrame ?? CGRect(x: 0, y: 0, width: width, height: height)
            window = PinnedWindow(contentRect: initialFrame,
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = CGSize(width: min(120, initialFrame.width), height: min(80, initialFrame.height))
            window.level = .floating
            window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if selectionShape != .rectangle {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        } else {
            let frame = frozenFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            window = EditorWindow(contentRect: frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: editingScreen)
            window.setFrame(frame, display: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = true
            window.hasShadow = false
        }
        super.init()
        canvas.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.deleteMarkButton?.isEnabled = self.canvas.canDeleteSelectedMark
        }
        if let defaults {
            sessionLineStyles = defaults.localStyles.mapValues { ($0.width, $0.color) }
            lastGeometryTool = defaults.geometryTool
            canvas.configureDefaults(defaults)
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        if longDocument {
            setupLongContent()
        } else if pinned {
            setupPinnedContent()
        } else if let frozenFrame, let selection, screenTiles.count > 1 {
            setupEditorTiles(screenTiles, initialFrame: frozenFrame, selection: selection)
        } else if let frozenFrame, let selection, let frozenScreen {
            setupInlineContent(frame: frozenFrame, selection: selection, frozenScreen: frozenScreen)
        }
        if pinned {
            canvas.onRightClick = { [weak self] event in
                guard let self else { return }
                self.showPopup(self.makePinnedMenu(), at: event, in: self.canvas) { [weak self] in self?.makePinnedMenu() }
            }
            canvas.onZoom = { [weak self] event in self?.zoomPinned(with: event) }
        } else {
            setupToolbar()
            canvas.onRightClick = { [weak self] event in
                guard let self, self.canvas.hasSelectedOCRText else { return }
                let menu = NSMenu()
                menu.addItem(self.menuItem("复制选中文字", #selector(self.copyRecognizedText),
                                           image: MenuIcon.symbol("doc.on.doc", description: "复制选中文字")))
                self.showPopup(menu, at: event, in: self.canvas)
            }
        }
        select(pinned ? .select : initialTool)
    }

    func present() {
        if let pinnedFrame { window.setFrame(pinnedFrame, display: false) }
        else if pinned || longDocument { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        for tile in editorTiles where tile.window !== window { tile.window.orderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        if pinned {
            CutsMotion.appear(canvas, .pin)
            CutsMotion.accent(in: canvas, rect: canvas.bounds.insetBy(dx: 1, dy: 1),
                              ellipse: selectionShape != .rectangle, radius: 0)
        } else {
            CutsMotion.appear(toolbar, .popup, from: CGPoint(x: 0, y: 6))
        }
    }

    func verifyArrowHandoff(on screen: NSScreen) -> Bool {
        guard window.isVisible, window.frame == screen.frame, window.screen?.frame == screen.frame,
              canvas.tool == .arrow, let button = expandButtons[.arrow],
              let arrowIcon = toolButtons[.arrow] as? HoverHintButton else { return false }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            NSApp.sendEvent(event)
            return true
        }
        let outside = CGPoint(x: 16, y: canvas.frame.midY)
        guard window.contentView?.hitTest(outside) === window.contentView,
              CutsPopup.clickToolbarButtonForTest(button), popup?.isOpen == true,
              let popupFrame = popup?.screenFrame, screen.visibleFrame.contains(popupFrame),
              send(.leftMouseDown, outside), send(.leftMouseUp, outside),
              window.isVisible, popup?.isOpen == false else { return false }
        arrowIcon.scheduleMenuOnHover(testing: true)
        guard popup?.isAnchored(to: button) == true,
              popup?.clickRowLikeMouseForTest(title: "双向箭头") == true,
              window.isVisible, canvas.tool == .arrow, popup?.isOpen == true else { return false }
        let start = CGPoint(x: canvas.frame.minX + canvas.frame.width * 0.2, y: canvas.frame.midY)
        let end = CGPoint(x: canvas.frame.minX + canvas.frame.width * 0.8, y: canvas.frame.midY + 25)
        let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bend = CGPoint(x: center.x, y: center.y + 22)
        guard send(.leftMouseDown, start), send(.leftMouseDragged, end), send(.leftMouseUp, end),
              window.isVisible, canvas.marks.count == 1, canvas.marks.last?.tool == .arrow,
              canvas.marks.last?.arrowHeads == .both else { return false }
        return send(.leftMouseDown, center) && send(.leftMouseDragged, bend) && send(.leftMouseUp, bend)
            && canvas.tool == .arrow && canvas.marks.count == 1 && canvas.marks.last?.tool == .curve
    }

    func closeFixture() { window.close() }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        popup?.close(restoringFocus: false)
        dismissCustomColor()
        for tile in editorTiles where (notification.object as? NSWindow) !== tile.window {
            tile.window.delegate = nil
            tile.window.close()
        }
        editorTiles.removeAll()
        onClose?()
    }

    private func setupPinnedContent() {
        guard let content = window.contentView else { return }
        canvas.frame = content.bounds
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)
    }

    private func setupLongContent() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = LEStyle.canvas.cgColor
        let toolbarSpace = toolbar.frame.height + 6
        let scroll = NSScrollView(frame: CGRect(x: 0, y: toolbarSpace,
                                               width: content.bounds.width,
                                               height: content.bounds.height - toolbarSpace))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.backgroundColor = LEStyle.canvas
        let width = max(560, content.bounds.width)
        canvas.frame = CGRect(x: 0, y: 0, width: width,
                              height: max(100, width * CGFloat(canvas.image.height) / CGFloat(canvas.image.width)))
        scroll.documentView = canvas
        content.addSubview(scroll)
        toolbar.frame.origin = CGPoint(x: max(0, (content.bounds.width - toolbar.frame.width) / 2), y: 3)
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin]
        content.addSubview(toolbar)
    }

    private func setupInlineContent(frame: CGRect, selection: CGRect, frozenScreen: CGImage) {
        let host = FrozenEditorBackground(frame: CGRect(origin: .zero, size: frame.size), image: frozenScreen,
                                          selected: selection.offsetBy(dx: -frame.minX, dy: -frame.minY),
                                          shape: selectionShape)
        window.contentView = host
        canvas.frame = selection.offsetBy(dx: -frame.minX, dy: -frame.minY)
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 2
        canvas.layer?.borderColor = NSColor.controlAccentColor.cgColor
        host.addSubview(canvas)
        layoutInlineToolbar(in: host, over: canvas.frame)
    }

    private func layoutInlineToolbar(in host: NSView, over canvasRect: CGRect) {
        let local = canvasRect.intersection(host.bounds)
        let x = max(8, min(host.bounds.maxX - toolbar.frame.width - 8, local.maxX - toolbar.frame.width))
        let y = local.minY >= toolbar.frame.height + 12 ? local.minY - toolbar.frame.height - 6
            : min(host.bounds.maxY - toolbar.frame.height - 8, local.maxY + 8)
        toolbar.frame.origin = CGPoint(x: x, y: y)
        host.addSubview(toolbar)
    }

    private func setupEditorTiles(_ snapshots: [ScreenTile], initialFrame: CGRect, selection: CGRect) {
        for snapshot in snapshots {
            let tileWindow: NSWindow
            if snapshot.frame == initialFrame { tileWindow = window }
            else {
                tileWindow = EditorWindow(contentRect: snapshot.frame, styleMask: .borderless, backing: .buffered,
                                          defer: false, screen: snapshot.screen)
                tileWindow.setFrame(snapshot.frame, display: false)
                tileWindow.level = window.level
                tileWindow.collectionBehavior = window.collectionBehavior
                tileWindow.hasShadow = false
                tileWindow.isReleasedWhenClosed = false
                tileWindow.delegate = self
            }
            let local = selection.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
            let bounds = CGRect(origin: .zero, size: snapshot.frame.size)
            let background = FrozenEditorBackground(frame: bounds, image: snapshot.image,
                                                    selected: local, shape: selectionShape)
            let mirror = CrossAnnotationView(frame: bounds, selection: local)
            mirror.paint = { [weak canvas] rect in canvas?.drawMirror(in: rect) }
            mirror.receive = { [weak self, weak tileWindow] event in
                guard let self, let tileWindow else { return }
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    if self.window !== tileWindow { self.activateEditorTile(tileWindow) }
                    if event.type == .rightMouseDown { self.canvas.rightMouseDown(with: event) }
                    else { self.canvas.mouseDown(with: event) }
                case .leftMouseDragged: self.canvas.mouseDragged(with: event)
                case .leftMouseUp: self.canvas.mouseUp(with: event)
                default: break
                }
            }
            background.addSubview(mirror)
            tileWindow.contentView = background
            editorTiles.append(EditorTile(window: tileWindow, frame: snapshot.frame, background: background, mirror: mirror))
        }
        canvas.onArtworkChanged = { [weak self] in
            for tile in self?.editorTiles ?? [] where tile.mirror.isMirroring { tile.mirror.needsDisplay = true }
        }
        activateEditorTile(window, activating: false)
    }

    private func activateEditorTile(_ tileWindow: NSWindow, activating: Bool = true) {
        guard let tile = editorTiles.first(where: { $0.window === tileWindow }), let selection else { return }
        popup?.close(restoringFocus: false)
        dismissCustomColor()
        canvas.finishTextEditing()
        canvas.removeFromSuperview()
        toolbar.removeFromSuperview()
        window = tileWindow
        for editorTile in editorTiles { editorTile.mirror.isMirroring = editorTile.window !== tileWindow }
        canvas.frame = selection.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY)
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 2
        canvas.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tile.background.addSubview(canvas)
        layoutInlineToolbar(in: tile.background, over: canvas.frame)
        if activating { tileWindow.makeKeyAndOrderFront(nil); tileWindow.makeFirstResponder(canvas) }
    }

    private func setupToolbar() {
        LEStyle.frostedSurface(toolbar)
        let primaryTools: [EditTool] = [.select, .pen, .arrow, .rectangle, .text,
                                        .magnifier, .number, .mosaic, .eraser]
        var x: CGFloat = 8
        for tool in primaryTools {
            let hasChoices = tool == .rectangle
            let hasExpandButton = hasChoices || [.arrow, .pen, .text, .magnifier, .number, .eraser].contains(tool)
            let action = hasChoices ? #selector(groupToolClicked(_:)) : #selector(toolClicked(_:))
            let title = tool == .arrow ? "箭头类型" : tool == .rectangle ? "圈选" : tool.title
            let button = button(symbol: tool.symbol, tooltip: title, action: action)
            if let icon = ToolIcon.image(for: tool) { button.image = icon }
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.frame = CGRect(x: x, y: 7, width: 28, height: 32)
            toolbar.addSubview(button)
            toolButtons[tool] = button
            if hasExpandButton {
                let menuAction: Selector = switch tool {
                case .pen: #selector(showBrushMenu(_:))
                case .arrow: #selector(showArrowMenu(_:))
                case .rectangle: #selector(showGeometryMenu(_:))
                case .text: #selector(showTextStyleMenu(_:))
                case .magnifier: #selector(showMagnifierMenu(_:))
                case .eraser: #selector(showEraserMenu(_:))
                default: #selector(showNumberMenu(_:))
                }
                let expand = HoverHintButton.submenuDot(x: x, title: title, target: self, action: menuAction)
                let hover = { [weak self, weak expand] in
                    guard let self, let expand, self.popup?.isAnchored(to: expand) != true else { return }
                    NSApp.sendAction(menuAction, to: self, from: expand)
                }
                (button as? HoverHintButton)?.onMenuHover = hover
                expand.onMenuHover = hover
                toolbar.addSubview(expand)
                expandButtons[tool] = expand
            }
            x += 32
        }
        x += 6
        for (symbol, title, action) in [
            ("arrow.uturn.backward", "撤回", #selector(undo)),
            ("arrow.uturn.forward", "重做", #selector(redo)),
            ("text.viewfinder", "提取文字", #selector(extractText)),
            ("rectangle.stack", "滚动长截图", #selector(beginLongCapture)),
            ("pin", "贴图", #selector(pinImage)),
            ("square.and.arrow.down", "保存图片", #selector(saveImage)),
            ("doc.on.doc", "复制图片", #selector(copyImage)),
            ("trash", "删除选中标注", #selector(deleteSelectedMark)),
            ("xmark", "关闭", #selector(close))
        ] {
            let control = button(symbol: symbol, tooltip: title, action: action)
            control.frame = CGRect(x: x, y: 7, width: 28, height: 32)
            if title == "滚动长截图" { control.isEnabled = !longDocument && !pinned }
            if action == #selector(deleteSelectedMark) {
                control.contentTintColor = LEStyle.danger
                control.isEnabled = canvas.canDeleteSelectedMark
                control.identifier = NSUserInterfaceItemIdentifier("deleteMark")
                deleteMarkButton = control
            }
            toolbar.addSubview(control)
            x += 32
        }
    }

    @objc private func showColorPanel() {
        dismissCustomColor()
        let anchor = actionAnchor ?? PopupAnchor.anchored(to: CGPoint(x: window.frame.midX, y: window.frame.midY),
                                                          fallbackScreen: window.screen)
        let color = canvas.textInput?.currentStyle.color ?? canvas.annotationColor
        let picker = popup?.makeColorPicker(color: color) ?? AntColorPicker(color: color, anchor: anchor, host: window)
        picker.onApply = { [weak self] color in
            CutsLog.write(.debug, "editor", "annotation color applied")
            self?.canvas.applyColor(color)
            self?.popup?.refreshMarks()
        }
        picker.onClose = { [weak self] in
            self?.palettePicker = nil
            if self?.window.isKeyWindow == true { self?.canvas.restoreTextInputFocus() }
        }
        palettePicker = picker
        picker.show()
    }

    private func dismissCustomColor() {
        palettePicker?.dismiss(restoringFocus: false)
    }

    private func strokeWidthItem(arrow: Bool = false) -> NSMenuItem {
        let group: EditTool = arrow ? .arrow : .rectangle
        let width = groupWidth(group)
        return AnnotationSlider.menuItem(title: arrow ? "箭头线宽" : "线条粗细", current: width,
                                         scale: .strokeWidth,
                                         sample: .line { [weak self] in self?.groupColor(group) ?? LEStyle.text },
                                         onPreview: { [weak self] in self?.previewLineWidth($0, group: group) }) { [weak self] width in
            guard let self else { return }
            self.prepareStyle(for: group)
            self.canvas.applyWidth(width, adjustingSelection: self.canvas.selectedMarkTool.map(Self.toolGroup) == group)
            CutsLog.write(.debug, "editor", "\(arrow ? "arrow" : "annotation") width=\(Int(width))px")
        }
    }

    @objc private func showTextStyleMenu(_ sender: NSButton) {
        showPopup(textStyleMenu(), from: sender) { [weak self] in self?.textStyleMenu() }
    }

    private func textStyleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(colorItem(group: .text))
        menu.addItem(submenuItem("字体", icon: "character", menu: fontMenu()))
        menu.addItem(AnnotationSlider.menuItem(title: "字号", current: canvas.currentFontSize,
                                              scale: .fontSize,
                                              sample: .text { [weak self] in self?.groupColor(.text) ?? LEStyle.text },
                                              onPreview: { [weak self] in self?.canvas.previewFontSize($0) }) { [weak self] size in
            self?.prepareStyle(for: .text)
            self?.canvas.applyFontSize(size)
        })
        menu.addItem(.separator())
        let bold = menuItem("加粗", #selector(toggleBold), image: MenuIcon.symbol("bold", description: "加粗"))
        bold.state = canvas.currentTextBold ? .on : .off
        menu.addItem(bold)
        let italic = menuItem("倾斜", #selector(toggleItalic), image: MenuIcon.symbol("italic", description: "倾斜"))
        italic.state = canvas.currentTextItalic ? .on : .off
        menu.addItem(italic)
        return menu
    }

    private func fontMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, name) in AnnotationDefaults.fonts {
            let item = menuItem(title, #selector(fontPicked(_:)), image: MenuIcon.fontSample(name))
            item.representedObject = name
            item.state = (canvas.textInput?.currentStyle.fontName ?? canvas.fontName) == name ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func fontPicked(_ item: NSMenuItem) {
        if let name = item.representedObject as? String { prepareStyle(for: .text); canvas.applyFontName(name) }
    }

    @objc private func toggleBold() { prepareStyle(for: .text); canvas.toggleBold() }
    @objc private func toggleItalic() { prepareStyle(for: .text); canvas.toggleItalic() }

    private func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let control = HoverHintButton(title: "", target: self, action: action)
        control.showsHoverFeedback = true
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        if control.image == nil { control.title = String(tooltip.prefix(1)); control.imagePosition = .noImage }
        else { control.imagePosition = .imageOnly }
        control.toolTip = tooltip
        control.setAccessibilityLabel(tooltip)
        LEStyle.icon(control)
        return control
    }

    private func select(_ requested: EditTool) {
        acceptsOCRResult = false
        let tool = requested.isArrow ? .arrow : requested
        let previousTool = canvas.tool
        CutsLog.write(.debug, "editor", "selected tool=\(tool.rawValue)")
        canvas.finishTextEditing()
        canvas.ocrMode = false
        canvas.tool = tool
        if [.rectangle, .ellipse, .circle].contains(tool) { lastGeometryTool = tool }
        let group = Self.toolGroup(tool)
        if sessionLineStyles != nil, activeLineGroup != group {
            if let previous = activeLineGroup, sessionLineStyles?[previous] != nil {
                sessionLineStyles?[previous] = (canvas.strokeWidth, canvas.annotationColor)
            }
            if let style = sessionLineStyles?[group] {
                canvas.strokeWidth = style.width
                canvas.annotationColor = style.color
            }
            activeLineGroup = group
        }
        for (candidate, button) in toolButtons {
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            LEStyle.applySelection(button, active: candidate == group)
        }
        toolButtons[.rectangle]?.toolTip = "圈选：\(lastGeometryTool.title)"
        toolButtons[.rectangle]?.image = ToolIcon.image(for: lastGeometryTool)
            ?? NSImage(systemSymbolName: lastGeometryTool.symbol, accessibilityDescription: lastGeometryTool.title)
        if previousTool != tool, let button = toolButtons[group] { CutsMotion.accent(in: button) }
        window.makeFirstResponder(canvas)
    }

    private static func toolGroup(_ tool: EditTool) -> EditTool {
        switch tool {
        case .polyline, .curve: .arrow
        case .ellipse, .circle: .rectangle
        default: tool
        }
    }

    private func prepareStyle(for group: EditTool) {
        if canvas.selectedMarkTool.map(Self.toolGroup) == group || Self.toolGroup(canvas.tool) == group
            || (group == .text && canvas.textInput != nil) { return }
        select(group == .rectangle ? lastGeometryTool : group)
    }

    private func groupWidth(_ group: EditTool) -> CGFloat {
        if canvas.selectedMarkTool.map(Self.toolGroup) == group { return canvas.selectedStrokeWidth }
        if Self.toolGroup(canvas.tool) == group { return canvas.strokeWidth }
        return sessionLineStyles?[group]?.width ?? canvas.strokeWidth
    }

    private func previewLineWidth(_ width: CGFloat?, group: EditTool) {
        canvas.previewLineWidth(canvas.selectedMarkTool.map(Self.toolGroup) == group ? width : nil)
    }

    private func groupColor(_ group: EditTool) -> NSColor {
        if group == .text, let draft = canvas.textInput { return draft.currentStyle.color }
        if canvas.selectedMarkTool.map(Self.toolGroup) == group || Self.toolGroup(canvas.tool) == group {
            return canvas.annotationColor
        }
        return sessionLineStyles?[group]?.color ?? canvas.annotationColor
    }

    @objc private func groupToolClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let group = EditTool(rawValue: name) else { return }
        select(group == .rectangle ? lastGeometryTool : group)
    }

    @objc private func showArrowMenu(_ sender: NSButton) {
        showPopup(arrowMenu(), from: sender) { [weak self] in self?.arrowMenu() }
    }

    private func arrowMenu(includeStart: Bool = false) -> NSMenu {
        let menu = NSMenu()
        if includeStart {
            let start = toolItem(.arrow)
            start.title = "画箭头"
            start.state = .off
            menu.addItem(start)
            menu.addItem(.separator())
        }
        menu.addItem(strokeWidthItem(arrow: true))
        menu.addItem(.separator())
        for heads in ArrowHeads.allCases {
            let symbol: String
            switch heads {
            case .end: symbol = "arrow.right"
            case .start: symbol = "arrow.left"
            case .both: symbol = "arrow.left.arrow.right"
            case .none: symbol = "line.diagonal"
            }
            let item = menuItem(heads.title, #selector(arrowHeadsPicked(_:)),
                                image: MenuIcon.symbol(symbol, description: heads.title))
            item.representedObject = heads.rawValue
            item.state = canvas.currentArrowHeads == heads ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for style in ArrowTipStyle.allCases {
            let item = menuItem(style.title, #selector(arrowTipPicked(_:)),
                                image: MenuIcon.symbol(style == .open ? "arrow.up.right" : "arrow.up.right.circle.fill",
                                                       description: style.title))
            item.representedObject = style.rawValue
            item.state = canvas.currentArrowTipStyle == style ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(colorItem(group: .arrow))
        return menu
    }

    @objc private func showGeometryMenu(_ sender: NSButton) {
        showPopup(geometryMenu(), from: sender) { [weak self] in self?.geometryMenu() }
    }

    @objc private func showBrushMenu(_ sender: NSButton) {
        showPopup(brushMenu(), from: sender) { [weak self] in self?.brushMenu() }
    }

    private func brushMenu(includeStart: Bool = false) -> NSMenu {
        let menu = BrushMenu.make(target: self, width: groupWidth(.pen), color: groupColor(.pen),
                                  colorAction: #selector(showCustomBrushColor),
                                  sampleColor: { [weak self] in self?.groupColor(.pen) ?? LEStyle.text },
                                  onPreview: { [weak self] in self?.previewLineWidth($0, group: .pen) }) { [weak self] width in
            guard let self else { return }
            self.activateBrushForStyle()
            self.canvas.applyWidth(width, adjustingSelection: self.canvas.selectedMarkTool == .pen)
            CutsLog.write(.debug, "editor", "brush width=\(Int(width))px")
        }
        if includeStart {
            menu.insertItem(menuItem("开始涂抹", #selector(startPinnedBrush), image: MenuIcon.tool(.pen)), at: 0)
        }
        return menu
    }

    @objc private func startPinnedBrush() { select(.pen) }

    func applyBrushChoice(_ choice: BrushChoice) {
        activateBrushForStyle()
        canvas.applyWidth(choice.width)
        canvas.applyColor(choice.color)
    }

    private func activateBrushForStyle() {
        if canvas.tool != .pen && canvas.selectedMarkTool != .pen { select(.pen) }
    }

    @objc private func showCustomBrushColor() {
        activateBrushForStyle()
        showColorPanel()
    }

    @objc private func showNumberMenu(_ sender: NSButton) {
        showPopup(numberMenu(), from: sender) { [weak self] in self?.numberMenu() }
    }

    @objc private func showMagnifierMenu(_ sender: NSButton) {
        showPopup(magnifierMenu(), from: sender)
    }

    @objc private func showEraserMenu(_ sender: NSButton) {
        showPopup(eraserMenu(), from: sender) { [weak self] in self?.eraserMenu() }
    }

    private func eraserMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in EraserMode.allCases {
            let item = menuItem(mode.title, #selector(eraserModePicked(_:)),
                                image: MenuIcon.symbol(mode == .whole ? "eraser.fill" : "eraser", description: mode.title))
            item.representedObject = mode.rawValue
            item.state = canvas.eraserMode == mode ? .on : .off
            menu.addItem(item)
        }
        if canvas.eraserMode == .local {
            menu.addItem(AnnotationSlider.menuItem(title: "局部擦除粗细", current: canvas.eraserWidth,
                                                  scale: .eraserWidth, sample: .eraser) { [weak self] width in
                self?.canvas.eraserWidth = width
            })
        }
        return menu
    }

    @objc private func eraserModePicked(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let mode = EraserMode(rawValue: value) else { return }
        canvas.eraserMode = mode
        select(.eraser)
    }

    private func magnifierMenu(includeStart: Bool = false) -> NSMenu {
        let menu = NSMenu()
        if includeStart {
            let start = toolItem(.magnifier)
            start.title = "添加放大镜"
            menu.addItem(start)
        }
        menu.addItem(AnnotationSlider.menuItem(title: "放大倍率", current: canvas.currentMagnification,
                                              scale: .magnification, onPreview: { [weak self] value in
            self?.canvas.previewMagnification(value)
        }) { [weak self] zoom in
            self?.canvas.applyMagnification(zoom)
        })
        menu.addItem(AnnotationSlider.menuItem(title: "放大镜直径", current: canvas.currentLensDiameter,
                                              scale: .diameter(maximum: canvas.maximumLensDiameter),
                                              onPreview: { [weak self] value in
            self?.canvas.previewLensDiameter(value)
        }) { [weak self] diameter in
            self?.canvas.applyLensDiameter(diameter)
        })
        return menu
    }

    private func geometryMenu() -> NSMenu {
        let menu = NSMenu()
        for choice in [EditTool.rectangle, .ellipse, .circle] {
            let item = toolItem(choice)
            item.state = lastGeometryTool == choice ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(colorItem(group: .rectangle))
        menu.addItem(strokeWidthItem())
        return menu
    }

    private func showPopup(_ menu: NSMenu, from view: NSView, refresh: (() -> NSMenu?)? = nil) {
        dismissCustomColor()
        popup?.close(restoringFocus: false)
        let popup = CutsPopup(menu: menu)
        self.popup = popup
        popup.onChoose = { [weak self] in self?.actionAnchor = $0 }
        popup.refreshedMenu = refresh
        popup.show(from: view, avoiding: view.isDescendant(of: toolbar) ? toolbar : nil)
    }

    private func showPopup(_ menu: NSMenu, at event: NSEvent, in view: NSView, refresh: (() -> NSMenu?)? = nil) {
        dismissCustomColor()
        popup?.close(restoringFocus: false)
        let popup = CutsPopup(menu: menu)
        self.popup = popup
        popup.onChoose = { [weak self] in self?.actionAnchor = $0 }
        popup.refreshedMenu = refresh
        popup.show(at: event, in: view)
    }

    @objc private func toolMenuPicked(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String,
              let tool = EditTool(rawValue: name) else { return }
        select(tool)
    }

    @objc private func arrowHeadsPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let heads = ArrowHeads(rawValue: raw) else { return }
        canvas.applyArrowHeads(heads)
        if canvas.selectedArrowTool == nil { select(.arrow) }
    }

    @objc private func arrowTipPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let style = ArrowTipStyle(rawValue: raw) else { return }
        canvas.applyArrowTipStyle(style)
        if canvas.selectedArrowTool == nil { select(.arrow) }
    }

    @objc private func toolClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let tool = EditTool(rawValue: name) else { return }
        select(tool)
    }

    private func menuItem(_ title: String, _ action: Selector, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = image
        return item
    }

    private func submenuItem(_ title: String, icon: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = MenuIcon.symbol(icon, description: title)
        item.submenu = menu
        return item
    }

    private func colorItem(group: EditTool) -> NSMenuItem {
        let item = menuItem("颜色", #selector(showScopedColor(_:)), image: MenuIcon.swatch(groupColor(group)))
        item.representedObject = group.rawValue
        return item
    }

    @objc private func showScopedColor(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let group = EditTool(rawValue: value) else { return }
        prepareStyle(for: group)
        showColorPanel()
    }

    private func toolItem(_ tool: EditTool) -> NSMenuItem {
        let item = menuItem(tool.title, #selector(toolMenuPicked(_:)), image: MenuIcon.tool(tool))
        item.representedObject = tool.rawValue
        item.state = (canvas.selectedArrowTool ?? canvas.tool) == tool ? .on : .off
        return item
    }

    private func numberMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(toolItem(.number))
        menu.addItem(NumberEditingShortcuts.menuItem())
        menu.addItem(.separator())
        let filled = menuItem("有背景", #selector(numberStylePicked(_:)),
                              image: MenuIcon.symbol("number.circle.fill", description: "有背景"))
        filled.representedObject = true
        filled.state = canvas.currentNumberFilled ? .on : .off
        menu.addItem(filled)
        let plain = menuItem("无背景", #selector(numberStylePicked(_:)),
                             image: MenuIcon.symbol("number.circle", description: "无背景"))
        plain.representedObject = false
        plain.state = canvas.currentNumberFilled ? .off : .on
        menu.addItem(plain)
        menu.addItem(.separator())
        menu.addItem(MenuNumberInput.item("设置下一个数字…", icon: "number",
                                              current: { [weak self] in self?.canvas.nextNumber ?? 1 }) { [weak self] value in
            self?.canvas.setNextNumber(value)
            self?.select(.number)
        })
        if canvas.selectedNumber != nil {
            menu.addItem(MenuNumberInput.item("修改选中序号…", icon: "square.and.pencil",
                                                  current: { [weak self] in self?.canvas.selectedNumber ?? 1 }) { [weak self] value in
                self?.canvas.editSelectedNumber(value)
            })
        }
        menu.addItem(.separator())
        menu.addItem(AnnotationSlider.menuItem(title: "序号大小", current: canvas.currentNumberSize,
                                              scale: .fontSize,
                                              sample: .number(color: { [weak self] in self?.groupColor(.number) ?? LEStyle.text },
                                                              filled: { [weak self] in self?.canvas.currentNumberFilled ?? true }),
                                              onPreview: { [weak self] value in
            self?.canvas.previewNumberSize(value)
        }) { [weak self] size in
            self?.prepareStyle(for: .number)
            self?.canvas.applyNumberSize(size)
        })
        menu.addItem(colorItem(group: .number))
        return menu
    }

    @objc private func numberStylePicked(_ item: NSMenuItem) {
        guard let filled = item.representedObject as? Bool else { return }
        prepareStyle(for: .number)
        canvas.applyNumberFilled(filled)
    }

    private func makePinnedMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(toolItem(.select))
        let brush = toolItem(.pen)
        brush.action = nil
        brush.submenu = brushMenu(includeStart: true)
        menu.addItem(brush)
        let arrows = NSMenuItem(title: "箭头", action: nil, keyEquivalent: "")
        arrows.submenu = arrowMenu(includeStart: true)
        arrows.image = MenuIcon.tool(.arrow)
        menu.addItem(arrows)
        let geometry = submenuItem("圈选", icon: lastGeometryTool.symbol, menu: geometryMenu())
        geometry.image = MenuIcon.tool(lastGeometryTool)
        menu.addItem(geometry)
        menu.addItem(toolItem(.text))
        menu.addItem(submenuItem("文字样式", icon: "character.textbox", menu: textStyleMenu()))
        let magnifier = toolItem(.magnifier)
        magnifier.action = nil
        magnifier.submenu = magnifierMenu(includeStart: true)
        menu.addItem(magnifier)
        let number = NSMenuItem(title: "序号", action: nil, keyEquivalent: "")
        number.submenu = numberMenu()
        number.image = MenuIcon.tool(.number)
        menu.addItem(number)
        menu.addItem(toolItem(.mosaic))
        let eraser = toolItem(.eraser)
        eraser.action = nil
        eraser.submenu = eraserMenu()
        menu.addItem(eraser)
        menu.addItem(.separator())
        menu.addItem(menuItem("撤销", #selector(undo),
                              image: MenuIcon.symbol("arrow.uturn.backward", description: "撤销")))
        menu.addItem(menuItem("重做", #selector(redo),
                              image: MenuIcon.symbol("arrow.uturn.forward", description: "重做")))
        menu.addItem(menuItem("提取文字", #selector(extractText),
                              image: MenuIcon.symbol("text.viewfinder", description: "提取文字")))
        if canvas.hasSelectedOCRText {
            menu.addItem(menuItem("复制选中文字", #selector(copyRecognizedText),
                                  image: MenuIcon.symbol("doc.on.doc", description: "复制选中文字")))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("复制图片", #selector(copyImage),
                              image: MenuIcon.symbol("doc.on.doc", description: "复制图片")))
        menu.addItem(menuItem("保存图片…", #selector(saveImage),
                              image: MenuIcon.symbol("square.and.arrow.down", description: "保存图片")))
        menu.addItem(.separator())
        let delete = menuItem("删除选中标注", #selector(deleteSelectedMark),
                              image: MenuIcon.symbol("trash", description: "删除选中标注"))
        delete.attributedTitle = NSAttributedString(string: delete.title, attributes: [.foregroundColor: LEStyle.danger])
        delete.isEnabled = canvas.canDeleteSelectedMark
        menu.addItem(delete)
        menu.addItem(menuItem("关闭贴图", #selector(close),
                              image: MenuIcon.symbol("xmark", description: "关闭贴图")))
        return menu
    }

    private func zoomPinned(with event: NSEvent) {
        guard pinned, let screen = window.screen ?? NSScreen.main else { return }
        let old = window.frame
        let ratio = old.width / max(1, old.height)
        let multiplier = pow(1.08, -event.scrollingDeltaY)
        let width = min(screen.visibleFrame.width, max(120, old.width * multiplier))
        let height = width / ratio
        let point = event.locationInWindow
        let fractionX = point.x / max(1, old.width)
        let fractionY = point.y / max(1, old.height)
        let frame = CGRect(x: old.minX + point.x - fractionX * width,
                           y: old.minY + point.y - fractionY * height,
                           width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func deleteSelectedMark() { canvas.deleteSelectedMark() }
    @objc private func close() { window.close() }
    @objc private func beginLongCapture() {
        guard !pinned, !longDocument else { return }
        _ = onLongCapture?()
    }

    func suspendForLongCapture() {
        acceptsOCRResult = false
        canvas.finishTextEditing()
        popup?.close(restoringFocus: false)
        dismissCustomColor()
        for tile in editorTiles where tile.window !== window { tile.window.orderOut(nil) }
        window.orderOut(nil)
    }

    func closeAfterLongCapture() {
        onClose = nil
        window.close()
    }

    @objc private func extractText() {
        beginTextRecognition()
    }

    func beginTextRecognition() {
        guard !recognizingText else { return }
        guard let image = canvas.renderedImage() else {
            CutsLog.write(.error, "ocr", "could not render source image")
            return
        }
        CutsLog.write(.info, "ocr", "started")
        recognizingText = true
        acceptsOCRResult = true
        ActionFeedback.show("正在识别文字…")
        OCRTextRecognition.recognize(image) { [weak self] result in
            guard let self else { return }
            self.recognizingText = false
            guard self.acceptsOCRResult, self.window.isVisible else { return }
            self.acceptsOCRResult = false
            switch result {
            case .success(let document):
                guard !document.glyphs.isEmpty else {
                    CutsLog.write(.info, "ocr", "completed: no text detected")
                    ActionFeedback.show("未识别到文字")
                    return
                }
                CutsLog.write(.info, "ocr", "completed")
                self.select(.select)
                self.canvas.setOCRDocument(document)
                self.window.makeFirstResponder(self.canvas)
                ActionFeedback.show("可在图片原位拖选文字，按 ⌘C 复制")
            case .failure(let error):
                CutsLog.failure("ocr", "recognize image", error)
                ActionFeedback.show("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func copyRecognizedText() { canvas.copySelectedOCRText() }

    @objc private func copyImage() {
        guard !copyingImage, let image = canvas.renderedImage() else { return }
        copyingImage = true
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? ImageSaveSettings.encode(image, format: .png) }.value
            guard let self else { return }
            self.copyingImage = false
            guard !self.closing, self.window.isVisible else { return }
            guard let data else { ActionFeedback.show("无法复制截图"); return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(data, forType: .png) {
                CutsLog.write(.info, "editor", "image copied")
                if !self.pinned { self.window.close() }
                ActionFeedback.show("已复制截图", success: true)
            } else {
                CutsLog.write(.error, "editor", "clipboard image write failed")
                ActionFeedback.show("无法写入剪贴板")
            }
        }
    }

    @objc private func saveImage() {
        guard let image = canvas.renderedImage() else { return }
        Task { [self] in
            let outcome = await ScreenshotSaveDialog.save(image, topic: "editor") {
                popup?.close(restoringFocus: false)
                dismissCustomColor()
                for tile in editorTiles where tile.window !== window { tile.window.orderOut(nil) }
                window.orderOut(nil)
            }
            switch outcome {
            case .saved(let url): ActionFeedback.show("已保存：\(url.lastPathComponent)", success: true)
            case .failed(let error): NSApp.presentError(error)
            case .cancelled: break
            case .busy: return
            }
            NSApp.activate(ignoringOtherApps: true)
            for tile in editorTiles where tile.window !== window { tile.window.orderFront(nil) }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(canvas)
        }
    }

    @objc private func pinImage() {
        guard !pinned else { return }
        canvas.finishTextEditing()
        Self.presentPinned(image: canvas.image, selectionShape: selectionShape,
                           marks: canvas.marks, screenRect: selection, defaults: annotationDefaults ?? .saved)
        window.close()
    }
}

@MainActor
private final class StandaloneEditors {
    static let shared = StandaloneEditors()
    private var editors: [CaptureEditor] = []
    func retain(_ editor: CaptureEditor) {
        editors.append(editor)
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.editors.removeAll(where: { $0 === editor })
        }
    }
}

private final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

private final class PinnedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

private final class FrozenEditorBackground: NSView {
    private let image: CGImage
    private let selected: CGRect
    private let shape: CaptureShape

    init(frame: CGRect, image: CGImage, selected: CGRect, shape: CaptureShape) {
        self.image = image
        self.selected = selected
        self.shape = shape
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        shade.append(shape.path(in: selected))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.62).setFill()
        shade.fill()
    }
    // A dismissed/edge-clipped popup can send a click here. Never close an editing session on it.
    override func mouseDown(with event: NSEvent) {}
}

private final class EditCanvas: NSView {
    var onArtworkChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { onArtworkChanged?() }
        }
    }
    let image: CGImage
    private(set) var marks: [Mark]
    var tool: EditTool = .arrow {
        didSet {
            pending = nil
            selectedIndex = nil
            numberSizePreview = nil
            strokeWidthPreview = nil
            fontSizePreview = nil
            lensDiameterPreview = nil
            cancelNumberMotion()
            magnifierDrag = nil
            needsDisplay = true
        }
    }
    var annotationColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 4
    var fontName = ".AppleSystemUIFont"
    var fontSize: CGFloat = 24
    var textBold = false
    var textItalic = false
    var currentTextBold: Bool { textInput?.hasStyle(\.bold) ?? textBold }
    var currentTextItalic: Bool { textInput?.hasStyle(\.italic) ?? textItalic }
    var numberFilled = true
    var arrowHeads: ArrowHeads = .end
    var arrowTipStyle: ArrowTipStyle = .open
    var onRightClick: ((NSEvent) -> Void)?
    var onZoom: ((NSEvent) -> Void)?
    var transparentOutsideImage = false
    var dragsWindowOnEmptySelection = false
    private struct ArtworkHistory {
        static let byteLimit = 24 * 1024 * 1024
        static let stepLimit = 80
        private var entries: [(marks: [Mark], bytes: Int)] = []
        private var bytes = 0

        mutating func append(_ marks: [Mark]) {
            let cost = marks.reduce(0) { sum, mark in
                sum + 256 + mark.points.count * MemoryLayout<CGPoint>.stride + mark.text.utf8.count * 2
                    + mark.textRuns.count * 128 + (mark.raster.map { $0.bytesPerRow * $0.height } ?? 0)
            }
            if cost > Self.byteLimit { clear(); return }
            entries.append((marks, cost))
            bytes += cost
            while entries.count > Self.stepLimit || bytes > Self.byteLimit {
                bytes -= entries.removeFirst().bytes
            }
        }

        mutating func popLast() -> [Mark]? {
            guard let item = entries.popLast() else { return nil }
            bytes -= item.bytes
            return item.marks
        }

        mutating func clear() { entries.removeAll(); bytes = 0 }
    }
    private var undoStack = ArtworkHistory()
    private var redoStack = ArtworkHistory()
    private var pending: Mark?
    var hasMosaicPreview: Bool { pending?.tool == .mosaic && pending?.raster != nil }
    private var selectedIndex: Int? {
        didSet {
            guard oldValue != selectedIndex else { return }
            onSelectionChanged?()
            if let selectedIndex, marks.indices.contains(selectedIndex) {
                acknowledge(marks[selectedIndex])
            } else {
                CutsMotion.clearAccent(in: self)
            }
        }
    }
    private var selectedArrowHandle: Int?
    private enum MagnifierDrag { case move, resize }
    private var magnifierDrag: MagnifierDrag?
    private var defaultMagnification: CGFloat = 2
    private var preferredLensDiameter: CGFloat?
    private var lastPoint: CGPoint?
    private var dragUndoRecorded = false
    private(set) var textInput: AnnotationTextInput? { didSet { onSelectionChanged?() } }
    private var textAnchor: CGPoint?
    private var editingTextIndex: Int?
    private var nextNumberOverride: Int?
    private var firstNumber = 1
    private var numberSize: CGFloat = 24
    private var numberSizePreview: CGFloat?
    private var strokeWidthPreview: CGFloat?
    private var fontSizePreview: CGFloat?
    private struct NumberMotion {
        let index: Int
        let oldText: String
        let direction: CGFloat
        let start: TimeInterval
    }
    private var numberMotion: NumberMotion?
    private var numberMotionTimer: Timer?
    private static let numberMotionDuration = 0.15
    var eraserMode: EraserMode = .whole
    var eraserWidth: CGFloat = 20
    private var ocrDocument: OCRDocument?
    private var ocrAnchor: Int?
    private var ocrFocus: Int?
    var ocrMode = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    var hasSelectedOCRText: Bool { selectedOCRText != nil }

    private var selectedOCRText: String? {
        guard ocrMode, let ocrDocument, let ocrAnchor, let ocrFocus else { return nil }
        let text = ocrDocument.selectedText(from: ocrAnchor, through: ocrFocus)
        return text.isEmpty ? nil : text
    }

    func setOCRDocument(_ document: OCRDocument) {
        ocrDocument = document
        ocrAnchor = nil
        ocrFocus = nil
        ocrMode = true
    }

    @discardableResult
    func copySelectedOCRText() -> Bool {
        guard let text = selectedOCRText else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(text, forType: .string)
        ActionFeedback.show(copied ? "已复制选中文字" : "文字复制失败", success: copied)
        return copied
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard ocrMode, let ocrDocument else { return }
        for glyph in ocrDocument.glyphs {
            addCursorRect(ocrRect(glyph.box).insetBy(dx: -2, dy: -3), cursor: .iBeam)
        }
    }

    private func ocrRect(_ box: CGRect, in target: CGRect? = nil) -> CGRect {
        let rect = target ?? imageRect
        return CGRect(x: rect.minX + box.minX * rect.width,
                      y: rect.minY + box.minY * rect.height,
                      width: box.width * rect.width,
                      height: box.height * rect.height)
    }

    private func ocrIndex(at point: CGPoint, nearest: Bool = false) -> Int? {
        guard let ocrDocument else { return nil }
        if let exact = ocrDocument.glyphs.indices.first(where: {
            ocrRect(ocrDocument.glyphs[$0].box).insetBy(dx: -3, dy: -5).contains(point)
        }) { return exact }
        guard nearest else { return nil }
        return ocrDocument.glyphs.indices.min(by: { lhs, rhs in
            let a = ocrRect(ocrDocument.glyphs[lhs].box)
            let b = ocrRect(ocrDocument.glyphs[rhs].box)
            return hypot(a.midX - point.x, a.midY - point.y)
                < hypot(b.midX - point.x, b.midY - point.y)
        })
    }

    var selectedNumber: Int? {
        guard let selectedIndex, marks.indices.contains(selectedIndex),
              marks[selectedIndex].tool == .number else { return nil }
        return Int(marks[selectedIndex].text)
    }

    var currentNumberFilled: Bool {
        if let selectedIndex, selectedMarkTool == .number { return marks[selectedIndex].numberFilled }
        return numberFilled
    }

    var selectedMarkTool: EditTool? {
        guard let index = selectedIndex, marks.indices.contains(index) else { return nil }
        return marks[index].tool
    }

    private var deletableMarkIndex: Int? {
        let candidate = textInput == nil ? selectedIndex : editingTextIndex
        guard let candidate, marks.indices.contains(candidate), marks[candidate].tool != .eraser else { return nil }
        return candidate
    }

    var canDeleteSelectedMark: Bool { deletableMarkIndex != nil }

    func deleteSelectedMark() {
        guard let index = deletableMarkIndex else { return }
        let removed = marks[index]
        recordUndo()
        cancelNumberMotion()
        if let input = textInput {
            input.removeFromSuperview()
            textAnchor = nil
            editingTextIndex = nil
            textInput = nil
        }
        selectedIndex = nil
        selectedArrowHandle = nil
        magnifierDrag = nil
        lastPoint = nil
        pending = nil
        marks.remove(at: index)
        if window?.isKeyWindow == true { window?.makeFirstResponder(self) }
        onSelectionChanged?()
        needsDisplay = true
        acknowledge(removed, color: LEStyle.danger)
    }

    private func acknowledge(_ mark: Mark, color: NSColor = LEStyle.primary) {
        let area = imageRect
        if mark.tool.isArrow, let end = mark.points.last {
            let point = CGPoint(x: area.minX + end.x * area.width, y: area.minY + end.y * area.height)
            CutsMotion.accent(in: self, rect: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                              ellipse: true, color: color)
        } else if mark.tool != .eraser {
            let region = markBounds(mark, in: area).insetBy(dx: -4, dy: -4)
            CutsMotion.accent(in: self, rect: region, ellipse: mark.tool == .magnifier || mark.tool == .number,
                              color: color, radius: 4)
        }
    }

    var selectedArrowTool: EditTool? {
        guard let selectedIndex, marks.indices.contains(selectedIndex),
              marks[selectedIndex].tool.isArrow else { return nil }
        return marks[selectedIndex].tool
    }

    var currentMagnification: CGFloat {
        if let index = selectedIndex, selectedMarkTool == .magnifier { return marks[index].magnification }
        return defaultMagnification
    }

    private(set) var magnificationPreview: CGFloat?

    func previewMagnification(_ value: CGFloat?) {
        let next = selectedMarkTool == .magnifier ? value : nil
        guard next != magnificationPreview else { return }
        magnificationPreview = next
        needsDisplay = true
    }

    var currentLensDiameter: CGFloat {
        if let index = selectedIndex, selectedMarkTool == .magnifier {
            return marks[index].magnifierDiameter ?? defaultLensDiameter()
        }
        return preferredLensDiameter ?? defaultLensDiameter()
    }

    private(set) var lensDiameterPreview: CGFloat?

    func previewLensDiameter(_ value: CGFloat?) {
        let next = selectedMarkTool == .magnifier ? value : nil
        guard next != lensDiameterPreview else { return }
        lensDiameterPreview = next
        needsDisplay = true
    }

    func applyLensDiameter(_ diameter: CGFloat) {
        preferredLensDiameter = diameter
        if let index = selectedIndex, selectedMarkTool == .magnifier,
           (marks[index].magnifierDiameter ?? defaultLensDiameter()) != diameter {
            recordUndo()
            marks[index].magnifierDiameter = diameter
            needsDisplay = true
        }
    }

    var currentFontSize: CGFloat { textInput?.currentStyle.fontSize ?? fontSize }

    var currentNumberSize: CGFloat {
        if let index = selectedIndex, selectedMarkTool == .number { return marks[index].fontSize }
        return numberSize
    }

    func previewNumberSize(_ value: CGFloat?) {
        let next = selectedMarkTool == .number ? value : nil
        guard next != numberSizePreview else { return }
        numberSizePreview = next
        needsDisplay = true
    }

    func applyNumberSize(_ size: CGFloat) {
        numberSize = size
        if let index = selectedIndex, selectedMarkTool == .number, marks[index].fontSize != size {
            recordUndo()
            marks[index].fontSize = size
            needsDisplay = true
        }
    }

    func applyMagnification(_ factor: CGFloat) {
        defaultMagnification = factor
        if let index = selectedIndex, selectedMarkTool == .magnifier, marks[index].magnification != factor {
            recordUndo()
            marks[index].magnification = factor
            needsDisplay = true
        }
    }

    var selectedStrokeWidth: CGFloat {
        guard let selectedIndex, marks.indices.contains(selectedIndex) else { return strokeWidth }
        return marks[selectedIndex].lineWidth
    }

    var currentArrowHeads: ArrowHeads {
        guard let selectedIndex, marks.indices.contains(selectedIndex),
              marks[selectedIndex].tool.isArrow else { return arrowHeads }
        return marks[selectedIndex].arrowHeads
    }

    var currentArrowTipStyle: ArrowTipStyle {
        guard let selectedIndex, marks.indices.contains(selectedIndex),
              marks[selectedIndex].tool.isArrow else { return arrowTipStyle }
        return marks[selectedIndex].arrowTipStyle
    }

    var nextNumber: Int {
        nextNumberOverride ?? min(9999, max(firstNumber, (marks.filter { $0.tool == .number }
            .compactMap { Int($0.text) }.max() ?? 0) + 1))
    }

    func configureDefaults(_ defaults: AnnotationDefaults) {
        fontName = defaults.font
        fontSize = defaults.fontSize
        textBold = defaults.bold
        textItalic = defaults.italic
        numberFilled = defaults.numberFilled
        numberSize = defaults.numberSize
        firstNumber = defaults.firstNumber
        arrowHeads = defaults.arrowHeads
        arrowTipStyle = defaults.arrowTip
        defaultMagnification = defaults.magnification
        preferredLensDiameter = defaults.lensDiameter.map { min(maximumLensDiameter, $0) }
        eraserMode = defaults.eraserMode ?? .whole
        eraserWidth = defaults.eraserWidth ?? 20
    }

    init(image: CGImage, marks: [Mark]) {
        self.image = image
        self.marks = marks
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override func scrollWheel(with event: NSEvent) {
        if let onZoom { onZoom(event) } else { super.scrollWheel(with: event) }
    }

    private func newMark(_ tool: EditTool, points: [CGPoint], text: String = "") -> Mark {
        Mark(tool: tool, points: points, text: text, color: annotationColor,
             lineWidth: strokeWidth, fontName: fontName, fontSize: tool == .number ? numberSize : fontSize,
             bold: textBold, italic: textItalic, numberFilled: numberFilled,
             arrowHeads: arrowHeads, arrowTipStyle: arrowTipStyle,
             magnifierDiameter: tool == .magnifier ? preferredLensDiameter : nil,
             magnification: defaultMagnification)
    }

    func applyArrowHeads(_ heads: ArrowHeads) {
        arrowHeads = heads
        if let selectedIndex, marks.indices.contains(selectedIndex), selectedArrowTool != nil {
            recordUndo()
            marks[selectedIndex].arrowHeads = heads
            needsDisplay = true
        }
    }

    func applyArrowTipStyle(_ style: ArrowTipStyle) {
        arrowTipStyle = style
        if let selectedIndex, marks.indices.contains(selectedIndex), selectedArrowTool != nil {
            recordUndo()
            marks[selectedIndex].arrowTipStyle = style
            needsDisplay = true
        }
    }

    func setNextNumber(_ number: Int) { nextNumberOverride = number }

    func editSelectedNumber(_ number: Int) {
        guard let index = selectedIndex, let current = selectedNumber, (1...9999).contains(number),
              number != current else { return }
        recordUndo()
        marks[index].text = String(number)
        animateNumberChange(index: index, old: current, new: number)
        needsDisplay = true
    }

    private func animateNumberChange(index: Int, old: Int, new: Int) {
        guard CutsMotion.enabled, window?.isVisible == true else { return }
        numberMotion = NumberMotion(index: index, oldText: String(old), direction: new > old ? 1 : -1,
                                    start: ProcessInfo.processInfo.systemUptime)
        guard numberMotionTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let change = self.numberMotion else { timer.invalidate(); return }
                if ProcessInfo.processInfo.systemUptime - change.start >= Self.numberMotionDuration {
                    self.cancelNumberMotion()
                }
                if self.marks.indices.contains(change.index) {
                    self.setNeedsDisplay(self.markBounds(self.marks[change.index], in: self.imageRect).insetBy(dx: -8, dy: -8))
                    self.onArtworkChanged?()
                }
            }
        }
        numberMotionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelNumberMotion() {
        numberMotion = nil
        numberMotionTimer?.invalidate()
        numberMotionTimer = nil
    }

    private func adjustSelectedNumber(by step: Int, showLimit: Bool = true) {
        guard let current = selectedNumber else { return }
        let updated = current + step
        if (1...9999).contains(updated) { editSelectedNumber(updated) }
        else if showLimit { ActionFeedback.show(step < 0 ? "序号不能小于 1" : "序号不能大于 9999") }
    }

    private func selectNumber(_ index: Int, click event: NSEvent, at unit: CGPoint) {
        selectedIndex = index
        annotationColor = marks[index].color
        lastPoint = unit
        dragUndoRecorded = false
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command || modifiers == .option {
            lastPoint = nil
            adjustSelectedNumber(by: modifiers == .command ? 1 : -1)
        }
        needsDisplay = true
    }

    func applyNumberFilled(_ filled: Bool) {
        numberFilled = filled
        if let index = selectedIndex, selectedMarkTool == .number, marks[index].numberFilled != filled {
            recordUndo()
            marks[index].numberFilled = filled
            needsDisplay = true
        }
    }

    func applyColor(_ color: NSColor) {
        annotationColor = color
        if applyDuringTextEditing(.color(color)) { return }
        else if let index = selectedIndex, marks.indices.contains(index) {
            recordUndo()
            if marks[index].tool == .text { marks[index].applyTextChange(.color(color)) }
            else { marks[index].color = color }
            needsDisplay = true
        }
    }

    func previewLineWidth(_ width: CGFloat?) {
        guard width != strokeWidthPreview else { return }
        strokeWidthPreview = width
        needsDisplay = true
    }

    func applyWidth(_ width: CGFloat, adjustingSelection: Bool = true) {
        strokeWidth = width
        if adjustingSelection, let index = selectedIndex, marks.indices.contains(index), marks[index].lineWidth != width {
            recordUndo()
            marks[index].lineWidth = width
            needsDisplay = true
        }
    }

    func applyFontName(_ name: String) {
        fontName = name
        changeTextStyle(.font(name))
    }

    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        changeTextStyle(.size(size))
    }

    func previewFontSize(_ size: CGFloat?) {
        if let textInput {
            textInput.previewFontSize(size)
            positionTextInput()
            onArtworkChanged?()
        } else {
            let value = selectedMarkTool == .text ? size : nil
            guard fontSizePreview != value else { return }
            fontSizePreview = value
            needsDisplay = true
        }
    }

    func toggleBold() {
        textBold = !currentTextBold
        changeTextStyle(.bold(textBold))
    }

    func toggleItalic() {
        textItalic = !currentTextItalic
        changeTextStyle(.italic(textItalic))
    }

    private func changeTextStyle(_ change: AnnotationTextChange) {
        if applyDuringTextEditing(change) { return }
        guard let index = selectedIndex, selectedMarkTool == .text else { return }
        recordUndo()
        marks[index].applyTextChange(change)
        needsDisplay = true
    }

    private var imageRect: CGRect {
        fittedImageRect(in: bounds)
    }

    private func fittedImageRect(in frame: CGRect) -> CGRect {
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        let width = min(frame.width, frame.height * aspect)
        let height = width / aspect
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if !transparentOutsideImage {
            LEStyle.canvas.setFill()
            bounds.fill()
        }
        let rect = imageRect
        drawArtwork(in: rect, editing: true)
        drawOCRSelection(in: rect)
    }

    func drawMirror(in selectionFrame: CGRect) {
        let rect = fittedImageRect(in: selectionFrame)
        drawArtwork(in: rect, editing: true)
        if let textInput, let textAnchor {
            textInput.layoutEngine.draw(at: CGPoint(x: rect.minX + textAnchor.x * rect.width,
                                                     y: rect.minY + textAnchor.y * rect.height))
        }
        drawOCRSelection(in: rect)
    }

    private func drawOCRSelection(in target: CGRect) {
        if ocrMode, let ocrDocument {
            let selected = ocrAnchor.flatMap { anchor -> ClosedRange<Int>? in
                guard let ocrFocus else { return nil }
                return min(anchor, ocrFocus)...max(anchor, ocrFocus)
            }
            for (index, glyph) in ocrDocument.glyphs.enumerated() {
                let rect = ocrRect(glyph.box, in: target).insetBy(dx: -1, dy: -2)
                if selected?.contains(index) == true {
                    NSColor.controlAccentColor.withAlphaComponent(0.48).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }

    fileprivate func drawSample(_ sample: [Mark], in rect: CGRect) {
        marks = sample
        drawArtwork(in: rect, editing: false)
    }

    private func drawArtwork(in rect: CGRect, editing: Bool) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect)
        let draft = editing ? pending : nil
        func displayedMark(_ mark: Mark, at index: Int) -> Mark {
            editing ? markForPreview(mark, at: index) : mark
        }
        func motion(at index: Int) -> NumberMotion? {
            editing && numberMotion?.index == index ? numberMotion : nil
        }
        let hasEraseMask = draft?.tool == .eraser || marks.contains { $0.tool == .eraser }
        if hasEraseMask, let context = NSGraphicsContext.current?.cgContext {
            // Erasing in a separate layer reveals the base image, not transparency.
            context.saveGState()
            context.clip(to: rect)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for (index, mark) in marks.enumerated() where !editing || index != editingTextIndex {
                if mark.tool == .eraser { drawEraseMask(mark, in: rect, context: context) }
                else { draw(displayedMark(mark, at: index), in: rect, numberMotion: motion(at: index)) }
            }
            if let draft {
                if draft.tool == .eraser { drawEraseMask(draft, in: rect, context: context) }
                else { draw(draft, in: rect) }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            for (index, mark) in marks.enumerated() where !editing || index != editingTextIndex {
                draw(displayedMark(mark, at: index), in: rect, numberMotion: motion(at: index))
            }
            if let draft { draw(draft, in: rect) }
        }
        if let pending = draft {
            if pending.tool == .mosaic {
                let region = markBounds(pending, in: rect)
                if region.width > 0 && region.height > 0 {
                    let outline = NSBezierPath(rect: region)
                    outline.lineWidth = 1.5
                    LEStyle.primary.setStroke()
                    outline.stroke()
                }
            }
            if pending.tool == .eraser, let point = pending.points.last {
                let diameter = pending.lineWidth * textScale(in: rect)
                let ring = NSBezierPath(ovalIn: CGRect(x: rect.minX + point.x * rect.width - diameter / 2,
                                                      y: rect.minY + point.y * rect.height - diameter / 2,
                                                      width: diameter, height: diameter))
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 1
                ring.stroke()
            }
        }
        if editing, let selectedIndex, selectedIndex != editingTextIndex, marks.indices.contains(selectedIndex) {
            let selected = markForPreview(marks[selectedIndex], at: selectedIndex)
            if selected.tool == .magnifier {
                for point in magnifierHandles(in: magnifierBounds(selected, in: rect)) {
                    let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    NSColor.white.setFill()
                    handle.fill()
                    LEStyle.primary.setStroke()
                    handle.lineWidth = 1.5
                    handle.stroke()
                }
                return
            }
            if selected.tool.isArrow {
                guard selected.points.count >= 2 else { return }
                let mapped = selected.points.map {
                    CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
                }
                let first = mapped[0], last = mapped[mapped.count - 1]
                let middle = selected.tool == .arrow || mapped.count < 3
                    ? Self.midpoint(first, last) : mapped[1]
                for point in [first, middle, last] {
                    let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                    NSColor.white.setFill()
                    dot.fill()
                    NSColor.controlAccentColor.setStroke()
                    dot.stroke()
                }
                return
            }
            let region = markBounds(selected, in: rect).insetBy(dx: -5, dy: -5)
            let path = NSBezierPath(rect: region)
            path.setLineDash([4, 3], count: 2, phase: 0)
            (selected.tool == .mosaic ? LEStyle.primary : NSColor.controlAccentColor).setStroke()
            path.stroke()
        }
    }

    fileprivate func markForPreview(_ mark: Mark, at index: Int) -> Mark {
        guard index == selectedIndex else { return mark }
        var preview = mark
        if mark.tool == .magnifier {
            if let magnificationPreview { preview.magnification = magnificationPreview }
            if let lensDiameterPreview { preview.magnifierDiameter = lensDiameterPreview }
        }
        if mark.tool == .number, let numberSizePreview { preview.fontSize = numberSizePreview }
        if let strokeWidthPreview { preview.lineWidth = strokeWidthPreview }
        if mark.tool == .text, let fontSizePreview { preview.applyTextChange(.size(fontSizePreview)) }
        return preview
    }

    private func drawEraseMask(_ mark: Mark, in rect: CGRect, context: CGContext) {
        guard let origin = mark.points.first else { return }
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        let diameter = max(1, mark.lineWidth * textScale(in: rect))
        let start = map(origin)
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setAlpha(1)
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        if !mark.points.dropFirst().contains(where: { $0 != origin }) {
            context.fillEllipse(in: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2,
                                           width: diameter, height: diameter))
        } else {
            context.beginPath()
            context.move(to: start)
            for point in mark.points.dropFirst() { context.addLine(to: map(point)) }
            context.setLineWidth(diameter)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func draw(_ mark: Mark, in rect: CGRect, numberMotion: NumberMotion? = nil) {
        let points = mark.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        guard let first = points.first else { return }
        mark.color.setStroke()
        mark.color.setFill()
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let stroke = max(1, mark.lineWidth * scale)
        if mark.tool == .text {
            layoutText(mark, in: rect).draw(at: first)
            return
        }
        if mark.tool == .number {
            let badge = numberBadge(mark, centeredAt: first, in: rect)
            if mark.numberFilled { NSBezierPath(ovalIn: badge).fill() }
            let textColor = mark.numberFilled ? NSColor.white : mark.color
            func digits(_ text: String, opacity: CGFloat = 1, offset: CGFloat = 0) {
                let size = badge.width * min(0.55, 1.35 / CGFloat(max(1, text.count)))
                let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
                let textSize = (text as NSString).size(withAttributes: [.font: font])
                text.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2 + offset),
                          withAttributes: [.foregroundColor: opacity < 1 ? textColor.withAlphaComponent(textColor.alphaComponent * opacity) : textColor,
                                           .font: font])
            }
            if let numberMotion {
                let elapsed = ProcessInfo.processInfo.systemUptime - numberMotion.start
                let progress = CGFloat(max(0, min(1, elapsed / Self.numberMotionDuration)))
                let ease = 1 - pow(1 - progress, 2)
                let shift = min(8, badge.height * 0.16) * numberMotion.direction
                digits(numberMotion.oldText, opacity: 1 - ease, offset: shift * ease)
                digits(mark.text, opacity: ease, offset: -shift * (1 - ease))
            } else { digits(mark.text) }
            return
        }
        if mark.tool == .mosaic {
            guard let last = points.last else { return }
            let target = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                width: abs(last.x - first.x), height: abs(last.y - first.y))
            if let raster = mark.raster {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: raster, size: target.size).draw(in: target)
                NSGraphicsContext.restoreGraphicsState()
            }
            return
        }
        if mark.tool == .magnifier {
            drawMagnifier(mark, in: rect, stroke: stroke)
            return
        }
        if mark.tool == .eraser { return }
        if mark.tool.isArrow, points.count >= 2 {
            drawAdjustableArrow(mark, points: points, stroke: stroke)
            return
        }
        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if [.rectangle, .ellipse, .circle].contains(mark.tool), let last = points.last {
            var box = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                             width: abs(last.x - first.x), height: abs(last.y - first.y))
            if mark.tool == .circle {
                let side = min(box.width, box.height)
                box = CGRect(x: box.minX, y: box.minY, width: side, height: side)
            }
            if mark.tool == .rectangle { path.appendRect(box) }
            else { path.appendOval(in: box) }
        } else {
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        }
        path.stroke()
    }

    private func drawAdjustableArrow(_ mark: Mark, points: [CGPoint], stroke: CGFloat) {
        guard let start = points.first, let end = points.last else { return }
        let middle = points.count >= 3 ? points[1] : Self.midpoint(start, end)
        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Round shaft caps must end inside a filled head, not beyond its tip.
        func shaftPoint(_ tip: CGPoint, toward inward: CGPoint, hasHead: Bool) -> CGPoint {
            guard hasHead, mark.arrowTipStyle == .filled else { return tip }
            let dx = inward.x - tip.x, dy = inward.y - tip.y
            let distance = hypot(dx, dy)
            guard distance > 0 else { return tip }
            let ratio = min(0.43, max(stroke * 1.6, 3) / distance)
            return CGPoint(x: tip.x + dx * ratio, y: tip.y + dy * ratio)
        }
        let startTangent: CGPoint
        let endTangent: CGPoint
        switch mark.tool {
        case .polyline:
            startTangent = middle == start ? end : middle
            endTangent = middle == end ? start : middle
            path.move(to: shaftPoint(start, toward: startTangent, hasHead: mark.arrowHeads.atStart))
            if middle != start && middle != end { path.line(to: middle) }
            path.line(to: shaftPoint(end, toward: endTangent, hasHead: mark.arrowHeads.atEnd))
        case .curve:
            let control = CGPoint(x: 2 * middle.x - (start.x + end.x) / 2,
                                  y: 2 * middle.y - (start.y + end.y) / 2)
            let firstControl = CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                                       y: start.y + (control.y - start.y) * 2 / 3)
            let lastControl = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                      y: end.y + (control.y - end.y) * 2 / 3)
            startTangent = firstControl == start ? end : firstControl
            endTangent = lastControl == end ? start : lastControl
            path.move(to: shaftPoint(start, toward: startTangent, hasHead: mark.arrowHeads.atStart))
            path.curve(to: shaftPoint(end, toward: endTangent, hasHead: mark.arrowHeads.atEnd),
                       controlPoint1: firstControl, controlPoint2: lastControl)
        default:
            startTangent = end
            endTangent = start
            path.move(to: shaftPoint(start, toward: end, hasHead: mark.arrowHeads.atStart))
            path.line(to: shaftPoint(end, toward: start, hasHead: mark.arrowHeads.atEnd))
        }
        path.stroke()
        if mark.arrowHeads.atStart {
            drawArrowHead(from: startTangent, to: start, stroke: stroke, style: mark.arrowTipStyle)
        }
        if mark.arrowHeads.atEnd {
            drawArrowHead(from: endTangent, to: end, stroke: stroke, style: mark.arrowTipStyle)
        }
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, stroke: CGFloat,
                               style: ArrowTipStyle) {
        guard start != end else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(9, stroke * 4)
        let head = NSBezierPath()
        head.lineWidth = stroke
        head.lineCapStyle = .round
        head.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6),
                              y: end.y - length * sin(angle - .pi / 6)))
        head.line(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6),
                              y: end.y - length * sin(angle + .pi / 6)))
        if style == .filled { head.close(); head.fill() }
        else { head.stroke() }
    }

    var maximumLensDiameter: CGFloat { CGFloat(min(image.width, image.height)) }

    private func magnifierScale(in rect: CGRect) -> CGFloat {
        min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
    }

    private func defaultLensDiameter() -> CGFloat {
        min(maximumLensDiameter, min(280, max(48, maximumLensDiameter * 0.20)))
    }

    private func magnifierBounds(_ mark: Mark, in rect: CGRect) -> CGRect {
        let lens = lensInImage(mark)
        let scale = magnifierScale(in: rect)
        return CGRect(x: rect.minX + lens.minX * scale, y: rect.minY + lens.minY * scale,
                      width: lens.width * scale, height: lens.height * scale)
    }

    fileprivate func lensInImage(_ mark: Mark) -> CGRect {
        guard let anchor = mark.points.last else { return .zero }
        let diameter = min(maximumLensDiameter, mark.magnifierDiameter ?? defaultLensDiameter())
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return CGRect(x: max(0, min(width - diameter, anchor.x * width - diameter / 2)),
                      y: max(0, min(height - diameter, anchor.y * height - diameter / 2)),
                      width: diameter, height: diameter)
    }

    private func magnifierHandles(in bubble: CGRect) -> [CGPoint] {
        let offset = (bubble.width / 2) / sqrt(CGFloat(2))
        return [CGPoint(x: bubble.midX - offset, y: bubble.midY - offset),
                CGPoint(x: bubble.midX + offset, y: bubble.midY - offset),
                CGPoint(x: bubble.midX - offset, y: bubble.midY + offset),
                CGPoint(x: bubble.midX + offset, y: bubble.midY + offset)]
    }

    fileprivate func magnifierSampleRect(_ mark: Mark) -> CGRect {
        let lens = lensInImage(mark)
        guard !lens.isEmpty else { return .zero }
        let size = min(lens.width, max(1, lens.width / mark.magnification))
        return CGRect(x: lens.midX - size / 2, y: CGFloat(image.height) - lens.midY - size / 2,
                      width: size, height: size)
    }

    private func drawMagnifier(_ mark: Mark, in rect: CGRect, stroke: CGFloat) {
        let bubble = magnifierBounds(mark, in: rect)
        guard bubble.width > 0 else { return }
        let crop = magnifierSampleRect(mark)
        let visible = crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !visible.isNull, !visible.isEmpty, let sample = image.cropping(to: visible) else { return }
        let scale = bubble.width / crop.width
        // Cut off unavailable edge pixels rather than moving the sampled center.
        let destination = CGRect(x: bubble.minX + (visible.minX - crop.minX) * scale,
                                 y: bubble.maxY - (visible.maxY - crop.minY) * scale,
                                 width: visible.width * scale, height: visible.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: bubble).addClip()
        NSImage(cgImage: sample, size: destination.size).draw(in: destination)
        NSGraphicsContext.restoreGraphicsState()
        mark.color.setStroke()
        let rimWidth = min(stroke + 1, bubble.width / 5)
        let rim = NSBezierPath(ovalIn: bubble.insetBy(dx: rimWidth / 2, dy: rimWidth / 2))
        rim.lineWidth = rimWidth
        rim.stroke()
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    private func markBounds(_ mark: Mark, in rect: CGRect) -> CGRect {
        let points: [CGPoint]
        if mark.tool == .arrow, let first = mark.points.first, let last = mark.points.last {
            points = [first, last]
        } else { points = mark.points }
        let mapped = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        guard let first = mapped.first else { return .zero }
        if mark.tool == .text {
            let used = layoutText(mark, in: rect).usedRect
            return CGRect(x: first.x + used.minX, y: first.y - used.maxY, width: used.width, height: used.height)
        }
        if mark.tool == .number {
            return numberBadge(mark, centeredAt: first, in: rect)
        }
        if mark.tool == .magnifier { return magnifierBounds(mark, in: rect) }
        return mapped.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            result.union(CGRect(origin: point, size: .zero))
        }
    }

    private func numberBadge(_ mark: Mark, centeredAt center: CGPoint, in rect: CGRect) -> CGRect {
        let size = max(1, mark.fontSize * textScale(in: rect) * 1.5)
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        window?.makeFirstResponder(self)
        magnifierDrag = nil
        let point = convert(event.locationInWindow, from: nil)
        if ocrMode {
            if let index = ocrIndex(at: point) {
                if event.clickCount >= 2, let ocrDocument {
                    let line = ocrDocument.glyphs[index].line
                    ocrAnchor = ocrDocument.glyphs.firstIndex(where: { $0.line == line })
                    ocrFocus = ocrDocument.glyphs.lastIndex(where: { $0.line == line })
                } else {
                    ocrAnchor = index
                    ocrFocus = index
                }
            } else {
                ocrAnchor = nil
                ocrFocus = nil
            }
            needsDisplay = true
            return
        }
        guard imageRect.contains(point) else { return }
        let unit = normalized(point)
        if tool == .magnifier || tool == .select {
            if let index = selectedIndex, selectedMarkTool == .magnifier,
               magnifierHandles(in: magnifierBounds(marks[index], in: imageRect)).contains(where: {
                   hypot($0.x - point.x, $0.y - point.y) <= 9
               }) {
                beginMagnifierDrag(.resize, index: index, at: unit)
                return
            }
            if tool == .magnifier, let index = marks.indices.reversed().first(where: {
                marks[$0].tool == .magnifier &&
                    NSBezierPath(ovalIn: magnifierBounds(marks[$0], in: imageRect)).contains(point)
            }) {
                beginMagnifierDrag(.move, index: index, at: unit)
                return
            }
            if tool == .magnifier { selectedIndex = nil }
        }
        if tool == .arrow,
           let index = selectedIndex, marks.indices.contains(index),
           marks[index].tool.isArrow,
           let handle = arrowHandle(at: unit, in: marks[index]) {
            selectedArrowHandle = handle
            lastPoint = unit
            dragUndoRecorded = false
            return
        }
        if tool == .select {
            selectedArrowHandle = nil
            selectedIndex = marks.indices.reversed().first {
                marks[$0].tool != .eraser
                    && markBounds(marks[$0], in: imageRect).insetBy(dx: -10, dy: -10).contains(point)
            }
            if selectedIndex == nil, dragsWindowOnEmptySelection {
                window?.performDrag(with: event)
                return
            }
            lastPoint = unit
            dragUndoRecorded = false
            if let index = selectedIndex {
                let mark = marks[index]
                if mark.tool == .magnifier {
                    beginMagnifierDrag(.move, index: index, at: unit)
                    return
                }
                if mark.tool == .number {
                    selectNumber(index, click: event, at: unit)
                }
                if mark.tool.isArrow, mark.points.count >= 2 {
                    selectedArrowHandle = arrowHandle(at: unit, in: mark)
                    arrowHeads = mark.arrowHeads
                    arrowTipStyle = mark.arrowTipStyle
                }
                annotationColor = mark.color
                strokeWidth = mark.lineWidth
                fontName = mark.fontName
                fontSize = mark.fontSize
                textBold = mark.bold
                textItalic = mark.italic
                numberFilled = mark.numberFilled
                if event.clickCount >= 2, mark.tool == .text {
                    beginText(at: mark.points[0], editing: index)
                    return
                }
            }
            needsDisplay = true
            return
        }
        if tool == .eraser {
            if eraserMode == .local {
                guard marks.contains(where: { $0.tool != .eraser }) else { return }
                pending = Mark(tool: .eraser, points: [unit], lineWidth: eraserWidth)
                needsDisplay = true
            } else if let index = marks.indices.reversed().first(where: {
                marks[$0].tool != .eraser
                    && markBounds(marks[$0], in: imageRect).insetBy(dx: -10, dy: -10).contains(point)
            }) {
                recordUndo()
                marks.remove(at: index)
                needsDisplay = true
            }
            return
        }
        if tool == .number {
            if let index = marks.indices.reversed().first(where: {
                marks[$0].tool == .number
                    && markBounds(marks[$0], in: imageRect).insetBy(dx: -6, dy: -6).contains(point)
            }) {
                selectNumber(index, click: event, at: unit)
                return
            }
            guard event.clickCount == 1, event.modifierFlags.intersection([.command, .option]).isEmpty else { return }
            let next = nextNumber
            recordUndo()
            marks.append(newMark(.number, points: [unit], text: String(next)))
            selectedIndex = nil
            lastPoint = nil
            if nextNumberOverride != nil { nextNumberOverride = min(9999, next + 1) }
            needsDisplay = true
            return
        }
        if tool == .arrow {
            selectedIndex = nil
            pending = newMark(.arrow, points: [unit, unit, unit])
            needsDisplay = true
            return
        }
        if tool == .text {
            if let index = marks.indices.reversed().first(where: {
                marks[$0].tool == .text && markBounds(marks[$0], in: imageRect).contains(point)
            }) {
                let mark = marks[index]
                annotationColor = mark.color
                fontName = mark.fontName
                fontSize = mark.fontSize
                textBold = mark.bold
                textItalic = mark.italic
                beginText(at: mark.points[0], editing: index)
            } else {
                selectedIndex = nil
                beginText(at: unit)
            }
            return
        }
        pending = newMark(tool, points: [unit])
    }

    private func beginMagnifierDrag(_ drag: MagnifierDrag, index: Int, at point: CGPoint) {
        selectedIndex = index
        selectedArrowHandle = nil
        magnifierDrag = drag
        lastPoint = point
        dragUndoRecorded = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        CutsMotion.clearAccent(in: self)
        if ocrMode {
            if ocrAnchor != nil {
                ocrFocus = ocrIndex(at: convert(event.locationInWindow, from: nil), nearest: true)
                needsDisplay = true
            }
            return
        }
        let pointer = convert(event.locationInWindow, from: nil)
        let point = normalized(pointer)
        if let drag = magnifierDrag, let index = selectedIndex, selectedMarkTool == .magnifier,
           let lastPoint {
            var mark = marks[index]
            switch drag {
            case .resize:
                let bubble = magnifierBounds(mark, in: imageRect)
                let scale = magnifierScale(in: imageRect)
                guard scale > 0 else { return }
                let diameter = min(maximumLensDiameter, max(min(24, maximumLensDiameter),
                    2 * hypot(pointer.x - bubble.midX, pointer.y - bubble.midY) / scale))
                guard abs(diameter - (mark.magnifierDiameter ?? defaultLensDiameter())) > 0.01 else { return }
                mark.magnifierDiameter = diameter
            case .move:
                let center = lensInImage(mark)
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let rx = center.width / (2 * width), ry = center.height / (2 * height)
                let target = CGPoint(x: min(1 - rx, max(rx, center.midX / width + point.x - lastPoint.x)),
                                     y: min(1 - ry, max(ry, center.midY / height + point.y - lastPoint.y)))
                self.lastPoint = point
                guard target != mark.points.last else { return }
                mark.points = [target]
            }
            if !dragUndoRecorded { recordUndo(); dragUndoRecorded = true }
            marks[index] = mark
            needsDisplay = true
            return
        }
        if (tool == .select || (tool == .number && selectedMarkTool == .number) || tool == .arrow),
           let index = selectedIndex, let lastPoint {
            if let handle = selectedArrowHandle {
                let previous = marks[index]
                guard let end = previous.points.last, previous.points.count >= 2 else { return }
                var mark = previous
                if mark.points.count == 2 {
                    mark.points.insert(Self.midpoint(mark.points[0], end), at: 1)
                }
                let last = mark.points.count - 1
                if handle == 1 {
                    let center = Self.midpoint(mark.points[0], mark.points[last])
                    let isStraight = distanceInCanvas(point, center) <= 5
                    mark.points[1] = isStraight ? center : point
                    mark.tool = isStraight ? .arrow : .curve
                } else {
                    mark.points[handle == 0 ? 0 : last] = point
                    if mark.tool == .arrow {
                        mark.points[1] = Self.midpoint(mark.points[0], mark.points[last])
                    }
                }
                guard mark.tool != previous.tool || mark.points != previous.points else { return }
                if !dragUndoRecorded { recordUndo(); dragUndoRecorded = true }
                marks[index] = mark
                needsDisplay = true
                return
            }
            let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
            if abs(delta.x) + abs(delta.y) > 0 {
                if !dragUndoRecorded { recordUndo(); dragUndoRecorded = true }
                marks[index].points = marks[index].points.map {
                    CGPoint(x: min(1, max(0, $0.x + delta.x)), y: min(1, max(0, $0.y + delta.y)))
                }
                self.lastPoint = point
            }
        } else if var mark = pending {
            if mark.tool == .arrow, let start = mark.points.first {
                mark.points[1] = Self.midpoint(start, point)
                mark.points[2] = point
            } else if mark.tool == .magnifier { mark.points = [point] }
            else if mark.tool == .pen || mark.tool == .eraser { mark.points.append(point) }
            else if mark.points.count == 1 { mark.points.append(point) }
            else { mark.points[1] = point }
            if mark.tool == .circle, let first = mark.points.first, mark.points.count > 1 {
                let width = abs(point.x - first.x) * imageRect.width
                let height = abs(point.y - first.y) * imageRect.height
                let side = min(width, height)
                mark.points[1] = CGPoint(x: first.x + (point.x < first.x ? -side : side) / imageRect.width,
                                         y: first.y + (point.y < first.y ? -side : side) / imageRect.height)
            }
            if mark.tool == .mosaic { mark.raster = makeMosaicRaster(for: mark) }
            pending = mark
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if ocrMode { return }
        lastPoint = nil
        dragUndoRecorded = false
        selectedArrowHandle = nil
        magnifierDrag = nil
        guard var mark = pending else { return }
        if mark.tool == .magnifier { mark.points = [normalized(convert(event.locationInWindow, from: nil))] }
        else if mark.tool == .eraser { mark.points.append(normalized(convert(event.locationInWindow, from: nil))) }
        else if mark.points.count == 1 { mark.points.append(normalized(convert(event.locationInWindow, from: nil))) }
        if mark.tool == .mosaic, mark.points.count >= 2 {
            let first = mark.points[0], last = mark.points[1]
            if hypot((last.x - first.x) * imageRect.width,
                     (last.y - first.y) * imageRect.height) < 4 {
                let halfWidth = min(16, CGFloat(image.width) / 2) / CGFloat(image.width)
                let halfHeight = min(16, CGFloat(image.height) / 2) / CGFloat(image.height)
                mark.points = [CGPoint(x: max(0, first.x - halfWidth), y: max(0, first.y - halfHeight)),
                               CGPoint(x: min(1, first.x + halfWidth), y: min(1, first.y + halfHeight))]
            }
        }
        if mark.tool == .arrow {
            let first = mark.points[0], last = normalized(convert(event.locationInWindow, from: nil))
            pending = nil
            guard distanceInCanvas(first, last) >= 4 else { needsDisplay = true; return }
            mark.points = [first, Self.midpoint(first, last), last]
        }
        if mark.tool == .mosaic {
            guard let raster = makeMosaicRaster(for: mark) else {
                pending = nil
                needsDisplay = true
                return
            }
            mark.raster = raster
        }
        recordUndo()
        marks.append(mark)
        if mark.tool.isArrow || mark.tool == .magnifier {
            selectedIndex = marks.count - 1
        } else if mark.tool == .mosaic {
            acknowledge(mark)
        }
        pending = nil
        needsDisplay = true
    }

    private func arrowHandle(at unit: CGPoint, in mark: Mark) -> Int? {
        guard mark.points.count >= 2 else { return nil }
        let first = mark.points[0], last = mark.points[mark.points.count - 1]
        let middle = mark.tool == .arrow || mark.points.count < 3 ? Self.midpoint(first, last) : mark.points[1]
        let nearest = [first, middle, last].enumerated().map { (index: $0.offset, distance: distanceInCanvas(unit, $0.element)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= 12 else { return nil }
        return nearest.index
    }

    private func distanceInCanvas(_ first: CGPoint, _ last: CGPoint) -> CGFloat {
        hypot((last.x - first.x) * imageRect.width, (last.y - first.y) * imageRect.height)
    }

    private static func midpoint(_ first: CGPoint, _ last: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
    }

    private func makeMosaicRaster(for mark: Mark) -> CGImage? {
        guard mark.points.count >= 2 else { return nil }
        let first = mark.points[0], last = mark.points[1]
        let pixels = CGRect(x: min(first.x, last.x) * CGFloat(image.width),
                            y: (1 - max(first.y, last.y)) * CGFloat(image.height),
                            width: abs(last.x - first.x) * CGFloat(image.width),
                            height: abs(last.y - first.y) * CGFloat(image.height))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard pixels.width >= 2, pixels.height >= 2,
              let cropped = image.cropping(to: pixels) else { return nil }
        let width = max(1, cropped.width / 12)
        let height = max(1, cropped.height / 12)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    override func keyDown(with event: NSEvent) {
        if ocrMode, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c", copySelectedOCRText() {
            return
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
        } else if !ocrMode, selectedNumber != nil, event.keyCode == 126 || event.keyCode == 125,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
            adjustSelectedNumber(by: event.keyCode == 126 ? 1 : -1, showLimit: !event.isARepeat)
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedMark()
        } else { super.keyDown(with: event) }
    }

    private func textScale(in rect: CGRect) -> CGFloat {
        min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
    }

    private func layoutText(_ mark: Mark, in rect: CGRect) -> AnnotationTextLayout {
        let layout = AnnotationTextLayout()
        layout.storage.setAttributedString(AnnotationTextStyle.attributed(mark.text, base: mark.textStyle,
                                                                         runs: mark.textRuns, scale: textScale(in: rect)))
        return layout
    }

    private func beginText(at unit: CGPoint, editing index: Int? = nil) {
        textAnchor = unit
        editingTextIndex = index
        let mark = index.map { marks[$0] } ?? newMark(.text, points: [unit])
        let input = AnnotationTextInput(text: mark.text, style: mark.textStyle,
                                        runs: mark.textRuns, scale: textScale(in: imageRect))
        input.onChange = { [weak self] in
            self?.positionTextInput()
            self?.onArtworkChanged?()
        }
        input.onConfirm = { [weak self] in self?.finishTextEditing() }
        if dragsWindowOnEmptySelection {
            input.onContextMenu = { [weak self] event in self?.onRightClick?(event) }
        }
        textInput = input
        addSubview(input)
        positionTextInput()
        restoreTextInputFocus()
        CutsMotion.appear(input, .hint)
        input.textView.setSelectedRange(NSRange(location: mark.text.utf16.count, length: 0))
        needsDisplay = true
    }

    func restoreTextInputFocus() {
        if let input = textInput { window?.makeFirstResponder(input.textView) }
        else { window?.makeFirstResponder(self) }
    }

    private func applyDuringTextEditing(_ change: AnnotationTextChange) -> Bool {
        guard let input = textInput else { return false }
        input.apply(change)
        positionTextInput()
        if window?.isKeyWindow == true { restoreTextInputFocus() }
        return true
    }

    private func positionTextInput() {
        guard let input = textInput, let unit = textAnchor else { return }
        let rect = imageRect
        let point = CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        input.place(at: point, maxWidth: rect.maxX - point.x)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textInput?.updateScale(textScale(in: imageRect))
        positionTextInput()
    }

    func finishTextEditing() {
        guard let input = textInput, let unit = textAnchor else { return }
        input.textView.unmarkText()
        input.previewFontSize(nil)
        let text = input.string
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordUndo()
            var mark = newMark(.text, points: [unit], text: text)
            mark.textRuns = input.textRuns
            if let first = mark.textRuns.first { mark.textStyle = first.style }
            if let index = editingTextIndex, marks.indices.contains(index) {
                marks[index] = mark
                selectedIndex = index
            } else {
                marks.append(mark)
                selectedIndex = marks.count - 1
            }
        }
        textInput = nil
        textAnchor = nil
        input.removeFromSuperview()
        editingTextIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func undo() {
        finishTextEditing()
        guard let previous = undoStack.popLast() else { return }
        cancelNumberMotion()
        redoStack.append(marks)
        marks = previous
        selectedIndex = nil
        needsDisplay = true
        CutsMotion.accent(in: self, rect: imageRect.insetBy(dx: 1, dy: 1), radius: 3)
    }

    func redo() {
        finishTextEditing()
        guard let next = redoStack.popLast() else { return }
        cancelNumberMotion()
        undoStack.append(marks)
        marks = next
        selectedIndex = nil
        needsDisplay = true
        CutsMotion.accent(in: self, rect: imageRect.insetBy(dx: 1, dy: 1), radius: 3)
    }

    private func recordUndo() {
        undoStack.append(marks)
        redoStack.clear()
    }

    func renderedImage() -> CGImage? {
        finishTextEditing()
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let graphics = NSGraphicsContext(cgContext: context, flipped: false) as NSGraphicsContext? else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        drawArtwork(in: CGRect(x: 0, y: 0, width: image.width, height: image.height), editing: false)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
