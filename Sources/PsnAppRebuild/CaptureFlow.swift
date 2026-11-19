import AppKit
import CoreGraphics
import ScreenCaptureKit

private enum SelectionAction: Equatable {
    case edit(EditTool)
    case brush(BrushChoice)
    case recognizeText
    case longCapture
    case copy
    case save
    case pin

    var diagnosticName: String {
        switch self {
        case .edit(let tool): "edit.\(tool.rawValue)"
        case .brush: "edit.pen"
        case .recognizeText: "ocr"
        case .longCapture: "longCapture"
        case .copy: "copy"
        case .save: "save"
        case .pin: "pin"
        }
    }
}

@MainActor
final class CaptureFlow {
    enum Purpose { case screenshot, longScreenshot }
    static func verifySelectionInteraction() -> Bool { SelectionView.verifyInteraction() }
    static func verifyColorPicking() -> Bool { SelectionView.verifyColorPicking() }
    static func verifyCrossDisplaySelection() -> Bool { SelectionView.verifyCrossDisplay() }
    static func verifyArrowHandoff() -> Bool {
        guard let bitmap = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        bitmap.setFillColor(LEStyle.canvas.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        guard let image = bitmap.makeImage() else { return false }
        let screens = NSScreen.screens.map { ($0.frame, image, Optional($0)) }
        guard let desktop = DesktopComposite.bounds(of: screens.map { $0.0 }) else { return false }
        var passes = true
        for (index, screen) in NSScreen.screens.enumerated() {
            let passed = verifyArrowHandoff(on: screen, screens: screens, desktop: desktop)
            print("arrow-handoff display=\(index) passed=\(passed)")
            passes = passes && passed
        }
        return passes
    }

    private static func verifyArrowHandoff(on screen: NSScreen, screens: [(CGRect, CGImage, NSScreen?)],
                                           desktop: CGRect) -> Bool {
        let frame = screen.frame
        let flow = CaptureFlow(defaults: .baseline)
        defer { flow.editor?.closeFixture(); flow.finish() }
        flow.presentSelection(screens, desktop: desktop)
        guard let overlay = flow.selectionWindows.first(where: { $0.frame == frame }),
              let view = overlay.contentView else { return false }
        overlay.makeKeyAndOrderFront(nil)
        func send(_ type: NSEvent.EventType, _ location: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: 0, windowNumber: overlay.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        func arrowButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "arrow" { return button }
            return view.subviews.lazy.compactMap { arrowButton(in: $0) }.first
        }
        guard send(.leftMouseDown, CGPoint(x: frame.width * 0.18, y: frame.height * 0.25)),
              send(.leftMouseDragged, CGPoint(x: frame.width * 0.67, y: frame.height * 0.68)),
              send(.leftMouseUp, CGPoint(x: frame.width * 0.67, y: frame.height * 0.68)),
              let button = arrowButton(in: view), CutsPopup.clickToolbarButtonForTest(button),
              let editor = flow.editor, overlay.isVisible == false,
              editor.verifyArrowHandoff(on: screen),
              !flow.finished else { return false }
        return true
    }
    static func writeSelectionPreview(to url: URL, showingMenu: Bool = false) -> Bool {
        SelectionView.writePreview(to: url, showingMenu: showingMenu)
    }
    static func verifyMultiDisplay() -> Bool { DesktopComposite.verifySynthetic() }
    static func verifyLiveDisplays() async -> Bool {
        do {
            let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var captures: [(CGRect, CGImage)] = []
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = available.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    print("unmatched-display=\(screen.localizedName)")
                    return false
                }
                let config = SCStreamConfiguration()
                config.width = max(2, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
                config.height = max(2, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
                config.showsCursor = false
                config.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: config)
                captures.append((screen.frame, image))
                print("captured-display=\(display.displayID) size=\(image.width)x\(image.height)")
            }
            guard let combined = DesktopComposite.combine(captures) else { return false }
            print("displays=\(captures.count) composite=\(combined.image.width)x\(combined.image.height)")
            return captures.count == NSScreen.screens.count
        } catch {
            print("live-display-check-error=\(error.localizedDescription)")
            return false
        }
    }
    static func verifyLiveOverlayPlacement() async -> Bool {
        let flow = CaptureFlow()
        await flow.start()
        defer { flow.finish() }
        try? await Task.sleep(nanoseconds: 240_000_000)
        let windows = flow.selectionWindows
        let systemWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var passed = windows.count == NSScreen.screens.count
        for screen in NSScreen.screens {
            let window = windows.first(where: { $0.frame == screen.frame })
            let listed = window.map { selected in
                systemWindows.contains(where: {
                    ( $0[kCGWindowNumber as String] as? NSNumber)?.intValue == selected.windowNumber
                })
            } ?? false
            print("overlay=\(screen.localizedName) frame=\(String(describing: window?.frame)) visible=\(window?.isVisible ?? false) listed=\(listed)")
            passed = passed && window?.isVisible == true && listed
        }
        let mouse = NSEvent.mouseLocation
        if let startingWindow = windows.first(where: { $0.frame.contains(mouse) }) {
            let startsAtMouse = NSApp.keyWindow === startingWindow
            print("mouse=\(mouse) activeOverlay=\(String(describing: NSApp.keyWindow?.frame)) startsAtMouse=\(startsAtMouse)")
            passed = passed && startsAtMouse
        } else {
            passed = false
        }
        return passed
    }
    var onFinish: (() -> Void)?
    private let purpose: Purpose
    private let annotationDefaults: AnnotationDefaults
    private var selectionWindows: [NSWindow] = []
    private var editor: CaptureEditor?
    private var finished = false
    private var copyingSelection = false

    init(purpose: Purpose = .screenshot, defaults: AnnotationDefaults = .saved) {
        self.purpose = purpose
        self.annotationDefaults = defaults
    }

    func start() async {
        CutsMotion.clearRetiringPanels()
        ActionFeedback.dismiss()
        CutsLog.write(.info, "capture", purpose == .longScreenshot ? "long selection opened" : "region selection opened")
        guard ScreenCapturePermission.checkOrRequest() else {
            CutsLog.write(.warning, "capture", "screen capture permission unavailable")
            fail("请在系统设置 → 隐私与安全性 → 屏幕录制中允许 Cuts。")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var prepared: [(NSScreen, CGImage)] = []
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    throw CaptureFailure.missingDisplay(screen.localizedName)
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = max(2, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
                config.height = max(2, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
                config.showsCursor = false
                config.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                prepared.append((screen, image))
            }
            guard !prepared.isEmpty else { throw CaptureFailure.noDisplay }
            if purpose == .longScreenshot {
                presentSelection(prepared.map { ($0.0.frame, $0.1, $0.0) })
            } else {
                guard let desktop = DesktopComposite.bounds(of: prepared.map { $0.0.frame }) else {
                    throw CaptureFailure.compositeFailed
                }
                presentSelection(prepared.map { ($0.0.frame, $0.1, $0.0) }, desktop: desktop)
            }
        } catch {
            CutsLog.failure("capture", "selection", error)
            fail("无法截取屏幕：\(error.localizedDescription)")
        }
    }

    private func presentSelection(_ screens: [(CGRect, CGImage, NSScreen?)],
                                  desktop: CGRect? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let shared = desktop.map {
            SelectionSession(desktopBounds: CGRect(origin: .zero, size: $0.size), defaults: annotationDefaults)
        }
        for (frame, image, screen) in screens {
            let window = CaptureWindow(contentRect: frame, styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
            window.setFrame(frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false
            window.isOpaque = true
            let offset = CGPoint(x: frame.minX - (desktop?.minX ?? frame.minX),
                                 y: frame.minY - (desktop?.minY ?? frame.minY))
            let view = SelectionView(frame: CGRect(origin: .zero, size: frame.size),
                                     snapshot: image, longCapture: purpose == .longScreenshot,
                                     session: shared, desktopOffset: offset)
            view.onCancel = { [weak self] in
                CutsLog.write(.info, "capture", "selection cancelled")
                self?.finish()
            }
            view.onPickColor = { [weak self] hex in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(hex, forType: .string) else {
                    CutsLog.write(.warning, "capture", "pixel color copy failed")
                    ActionFeedback.show("无法复制色值")
                    return
                }
                CutsLog.write(.info, "capture", "pixel color copied")
                self.finish()
                ActionFeedback.show("已复制 \(hex)", success: true)
            }
            view.onAction = { [weak self, weak window, weak view] rect, shape, action in
                guard let self, let window, let view else { return }
                CutsLog.write(.info, "capture",
                              "selected action=\(action.diagnosticName) shape=\(shape.rawValue) points=\(Int(rect.width))x\(Int(rect.height))")
                if self.purpose == .longScreenshot {
                    self.openLongCapture(selection: rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
                } else {
                    guard let desktop else { return }
                    self.perform(action, selection: rect, shape: shape,
                                 frame: desktop, window: window, displays: screens, defaults: view.draftDefaults)
                }
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            selectionWindows.append(window)
        }
        guard let current = selectionWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? selectionWindows.first else { return }
        if let view = current.contentView as? SelectionView { shared?.paletteOwner = view }
        focusSelection(current)
    }

    private func focusSelection(_ window: NSWindow, retries: Int = 3) {
        guard !finished, selectionWindows.contains(where: { $0 === window }), window.isVisible else { return }
        if let key = NSApp.keyWindow, selectionWindows.contains(where: { $0 === key }) { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let view = window.contentView { window.makeFirstResponder(view) }
        // Activation may finish after the first request, especially on a different
        // Space. Do not fight a display the user has already selected in the meantime.
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self, weak window] in
            if let window { self?.focusSelection(window, retries: retries - 1) }
        }
    }

    private func capturedImage(_ image: CGImage, selection: CGRect, shape: CaptureShape,
                               frame: CGRect) -> CGImage? {
        let scaleX = CGFloat(image.width) / max(1, frame.width)
        let scaleY = CGFloat(image.height) / max(1, frame.height)
        let pixels = CGRect(x: (selection.minX * scaleX).rounded(),
                            y: ((frame.height - selection.maxY) * scaleY).rounded(),
                            width: (selection.width * scaleX).rounded(),
                            height: (selection.height * scaleY).rounded())
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard let cropped = image.cropping(to: pixels), cropped.width > 0, cropped.height > 0 else {
            return nil
        }
        return shape.masked(cropped)
    }

    private func perform(_ action: SelectionAction, selection: CGRect,
                         shape: CaptureShape, frame: CGRect, window: NSWindow,
                         displays: [(CGRect, CGImage, NSScreen?)], defaults: AnnotationDefaults) {
        guard !copyingSelection else { return }
        let absoluteSelection = selection.offsetBy(dx: frame.minX, dy: frame.minY)
        if action == .longCapture {
            openLongCapture(selection: absoluteSelection)
            return
        }
        let foreground = displays.first { $0.0.contains(absoluteSelection) }
        let rendered: CGImage?
        if let foreground {
            rendered = capturedImage(foreground.1, selection: absoluteSelection.offsetBy(dx: -foreground.0.minX,
                                                                                           dy: -foreground.0.minY),
                                     shape: shape, frame: foreground.0)
        } else {
            rendered = DesktopComposite.combine(displays.map { ($0.0, $0.1) }, region: absoluteSelection)
                .flatMap { shape.masked($0.image) }
        }
        guard let result = rendered else {
            CutsLog.write(.error, "capture", "selection crop or shape mask failed")
            ActionFeedback.show("无法生成截图，请缩小或重新框选")
            return
        }
        let tiles: [CaptureEditor.ScreenTile] = foreground == nil
            ? displays.compactMap { frame, image, screen in
                guard let screen, frame.intersects(absoluteSelection) else { return nil }
                return CaptureEditor.ScreenTile(frame: frame, image: image, screen: screen)
            } : []
        let activeTile = tiles.first { $0.frame == window.frame } ?? tiles.first
        let background = (frame: foreground?.0 ?? activeTile?.frame ?? frame,
                          image: foreground?.1 ?? activeTile?.image ?? result,
                          screen: foreground?.2 ?? activeTile?.screen)
        switch action {
        case .edit(let tool):
            openEditor(result: result, background: background, selection: absoluteSelection,
                       shape: shape, initialTool: tool == .rectangle ? defaults.geometryTool : tool,
                       tiles: tiles, defaults: defaults)
        case .brush(let choice):
            openEditor(result: result, background: background, selection: absoluteSelection,
                       shape: shape, initialTool: .pen, brushChoice: choice, tiles: tiles, defaults: defaults)
        case .recognizeText:
            openEditor(result: result, background: background, selection: absoluteSelection,
                       shape: shape, initialTool: .select, tiles: tiles, defaults: defaults)
            editor?.beginTextRecognition()
        case .longCapture:
            break
        case .copy:
            copyingSelection = true
            Task { [self] in
                defer { copyingSelection = false }
                let data = await Task.detached(priority: .userInitiated) { try? ImageSaveSettings.encode(result, format: .png) }.value
                guard !finished else { return }
                guard let data else {
                    CutsLog.write(.error, "capture", "clipboard image encoding failed")
                    ActionFeedback.show("无法复制截图")
                    return
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setData(data, forType: .png) else {
                    CutsLog.write(.error, "capture", "clipboard image write failed")
                    ActionFeedback.show("无法写入剪贴板")
                    return
                }
                CutsLog.write(.info, "capture", "image copied")
                finish()
                ActionFeedback.show("已复制截图", success: true)
            }
        case .save:
            Task { [self] in
                let outcome = await ScreenshotSaveDialog.save(result, topic: "capture") {
                    for overlay in selectionWindows where overlay.isVisible { overlay.orderOut(nil) }
                }
                switch outcome {
                case .saved(let url):
                    finish()
                    ActionFeedback.show("已保存：\(url.lastPathComponent)", success: true)
                    return
                case .failed(let error):
                    NSApp.presentError(error)
                case .cancelled: break
                case .busy: return
                }
                if !finished {
                    NSApp.activate(ignoringOtherApps: true)
                    for overlay in selectionWindows where overlay !== window { overlay.orderFront(nil) }
                    window.makeKeyAndOrderFront(nil)
                }
            }
        case .pin:
            finish()
            CutsLog.write(.info, "pin", "created on selection points=\(Int(selection.width))x\(Int(selection.height))")
            CaptureEditor.presentPinned(image: result, selectionShape: shape, screenRect: absoluteSelection,
                                        defaults: defaults)
            ActionFeedback.show("已贴到桌面", success: true)
        }
    }

    private func openEditor(result: CGImage, background: (frame: CGRect, image: CGImage, screen: NSScreen?),
                            selection: CGRect, shape: CaptureShape, initialTool: EditTool,
                            brushChoice: BrushChoice? = nil, tiles: [CaptureEditor.ScreenTile] = [],
                            defaults: AnnotationDefaults) {
        closeSelectionWindows()
        let displayIndex = NSScreen.screens.firstIndex { $0.frame == background.screen?.frame }
        CutsLog.write(.info, "editor", "opened tool=\(initialTool.rawValue) display=\(displayIndex.map(String.init) ?? "unknown") tiles=\(max(1, tiles.count))")
        let editor = CaptureEditor(image: result, frozenScreen: background.image, frozenFrame: background.frame,
                                   selection: selection, selectionShape: shape, initialTool: initialTool,
                                   editingScreen: background.screen, defaults: defaults, screenTiles: tiles)
        if let brushChoice { editor.applyBrushChoice(brushChoice) }
        self.editor = editor
        editor.onClose = { [weak self] in self?.finish() }
        editor.onLongCapture = { [weak self] in
            self?.openLongCapture(selection: selection) ?? false
        }
        editor.present()
    }

    @discardableResult
    private func openLongCapture(selection absolute: CGRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(absolute) }) else {
            CutsLog.write(.warning, "longCapture", "selection crosses displays")
            ActionFeedback.show("长截图选区需完整位于同一块屏幕")
            return false
        }
        closeSelectionWindows()
        let originalEditor = editor
        originalEditor?.suspendForLongCapture()
        func restoreOriginal() {
            if let originalEditor { originalEditor.present() }
            else { finish() }
        }
        Task { [self] in
            do {
                guard let result = try await LongCaptureRunner().capture(screen: screen, region: absolute) else {
                    restoreOriginal()
                    return
                }
                // A valid single frame is still an editable capture, not an error.
                originalEditor?.closeAfterLongCapture()
                let editor = CaptureEditor(image: result.image, longDocument: true, defaults: annotationDefaults)
                self.editor = editor
                editor.onClose = { [weak self] in self?.finish() }
                editor.present()
                if let note = result.note { ActionFeedback.show(note) }
            } catch {
                CutsLog.failure("longCapture", "session", error)
                restoreOriginal()
                ActionFeedback.show("长截图：\(error.localizedDescription)")
            }
        }
        return true
    }

    private func fail(_ text: String) {
        finish()
        let alert = NSAlert()
        alert.messageText = "Cuts"
        alert.informativeText = text
        alert.runModal()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        closeSelectionWindows()
        editor = nil
        onFinish?()
    }

    private func closeSelectionWindows() {
        for window in selectionWindows {
            (window.contentView as? SelectionView)?.closePopup()
            window.orderOut(nil)
        }
        selectionWindows.removeAll()
    }
}

private enum CaptureFailure: LocalizedError {
    case noDisplay
    case missingDisplay(String)
    case compositeFailed
    var errorDescription: String? {
        switch self {
        case .noDisplay: "未找到可截取的显示器"
        case .missingDisplay(let name): "无法抓取显示器“\(name)”，已取消截图，避免只截到主屏幕。"
        case .compositeFailed: "无法合成多屏幕截图。"
        }
    }
}

private enum DesktopComposite {
    static func bounds(of frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    static func combine(_ allCaptures: [(CGRect, CGImage)], region: CGRect? = nil) -> (frame: CGRect, image: CGImage)? {
        let captures = region.map { target in allCaptures.filter { $0.0.intersects(target) } } ?? allCaptures
        guard let first = captures.first, let frame = region ?? bounds(of: captures.map(\.0)) else { return nil }
        if first.0 == frame, captures.count == 1 { return (first.0, first.1) }
        let scale = captures.map { CGFloat($0.1.width) / max(1, $0.0.width) }.max() ?? 1
        let width = Int((frame.width * scale).rounded())
        let height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              Double(width) * Double(height) <= 150_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (screen, image) in captures {
            let target = CGRect(x: (screen.minX - frame.minX) * scale,
                                y: (screen.minY - frame.minY) * scale,
                                width: screen.width * scale,
                                height: screen.height * scale)
            context.draw(image, in: target)
        }
        guard let image = context.makeImage() else { return nil }
        return (frame, image)
    }

    static func verifySynthetic() -> Bool {
        func image(_ color: NSColor) -> CGImage? {
            guard let context = CGContext(data: nil, width: 10, height: 10,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            return context.makeImage()
        }
        guard let red = image(.red), let blue = image(.blue),
              let composite = combine([(CGRect(x: -10, y: 0, width: 10, height: 10), red),
                                       (CGRect(x: 0, y: 0, width: 10, height: 10), blue)]),
              composite.frame == CGRect(x: -10, y: 0, width: 20, height: 10),
              composite.image.width == 20,
              let left = composite.image.cropping(to: CGRect(x: 2, y: 2, width: 1, height: 1)),
              let right = composite.image.cropping(to: CGRect(x: 12, y: 2, width: 1, height: 1)),
              let leftData = left.dataProvider?.data,
              let rightData = right.dataProvider?.data,
              let l = CFDataGetBytePtr(leftData), let r = CFDataGetBytePtr(rightData) else { return false }
        let region = CGRect(x: -2, y: 3, width: 4, height: 2)
        guard let partial = combine([(CGRect(x: -10, y: 0, width: 10, height: 10), red),
                                     (CGRect(x: 0, y: 0, width: 5, height: 5), blue),
                                     (CGRect(x: 100, y: 0, width: 1, height: 1), red)], region: region),
              partial.frame == region, partial.image.width == 8, partial.image.height == 4,
              let a = partial.image.cropping(to: CGRect(x: 0, y: 1, width: 1, height: 1))?.dataProvider?.data,
              let b = partial.image.cropping(to: CGRect(x: 7, y: 1, width: 1, height: 1))?.dataProvider?.data,
              let leftPixel = CFDataGetBytePtr(a), let rightPixel = CFDataGetBytePtr(b) else { return false }
        return l[0] > l[2] && r[2] > r[0] && leftPixel[0] > leftPixel[2] && rightPixel[2] > rightPixel[0]
    }
}

private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionSession {
    private struct WeakView { weak var value: SelectionView? }
    let desktopBounds: CGRect
    var selection: CGRect = .zero { didSet { refresh() } }
    var hoveredTarget: CGRect? { didSet { refresh() } }
    var shape: CaptureShape = .rectangle { didSet { refresh() } }
    var defaults: AnnotationDefaults
    var brush: BrushChoice { BrushChoice(width: defaults.brush.width, color: defaults.brush.color) }
    weak var paletteOwner: SelectionView? { didSet { refresh() } }
    private var views: [WeakView] = []

    init(desktopBounds: CGRect, defaults: AnnotationDefaults = .baseline) {
        self.desktopBounds = desktopBounds
        self.shape = defaults.selection
        self.defaults = defaults
    }

    func attach(_ view: SelectionView) { views.append(WeakView(value: view)) }

    func choosePaletteOwner(at point: CGPoint) {
        paletteOwner = views.compactMap(\.value).first(where: {
            CGRect(origin: $0.desktopOffset, size: $0.bounds.size).contains(point)
        }) ?? paletteOwner
    }

    @MainActor func acknowledgeSelection() {
        guard selection.width >= 8, selection.height >= 8 else { return }
        for view in views.compactMap(\.value) {
            let area = selection.offsetBy(dx: -view.desktopOffset.x, dy: -view.desktopOffset.y)
            CutsMotion.accent(in: view, rect: area, ellipse: shape != .rectangle, radius: 0)
        }
    }

    @MainActor func clearAcknowledgment() {
        views.compactMap(\.value).forEach { CutsMotion.clearAccent(in: $0) }
    }

    private func refresh() {
        views.removeAll { $0.value == nil }
        for view in views.compactMap(\.value) {
            view.updateShapeButton()
            view.updatePalette()
            view.needsDisplay = true
        }
    }
}

private final class SelectionView: NSView {
    private final class MenuAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
    private let snapshot: CGImage
    private let longCapture: Bool
    private let session: SelectionSession
    let desktopOffset: CGPoint
    private enum DragMode { case create, move, resize(Int) }
    private var dragMode: DragMode = .create
    private var startPoint: CGPoint?
    private var original: CGRect = .zero
    private var selection: CGRect {
        get { session.selection.offsetBy(dx: -desktopOffset.x, dy: -desktopOffset.y) }
        set { session.selection = newValue.offsetBy(dx: desktopOffset.x, dy: desktopOffset.y) }
    }
    private var hoveredTarget: CGRect? {
        get { session.hoveredTarget?.offsetBy(dx: -desktopOffset.x, dy: -desktopOffset.y) }
        set { session.hoveredTarget = newValue?.offsetBy(dx: desktopOffset.x, dy: desktopOffset.y) }
    }
    private var pressedTarget: CGRect?
    private var didDrag = false
    private var lastHoverTime = Date.distantPast
    private var detectingHover = false
    private var lastHoverPoint: CGPoint?
    private var hoverColor: String?
    private var shape: CaptureShape {
        get { session.shape }
        set { session.shape = newValue }
    }
    private let palette = NSView(frame: CGRect(x: 0, y: 0, width: 526, height: 46))
    private var shapeButton: NSButton?
    private var shapeExpandButton: NSButton?
    private var brushExpandButton: NSButton?
    private var optionDots: [EditTool: HoverHintButton] = [:]
    private var popup: CutsPopup?
    var draftDefaults: AnnotationDefaults { session.defaults }
    var onAction: ((CGRect, CaptureShape, SelectionAction) -> Void)?
    var onCancel: (() -> Void)?
    var onPickColor: ((String) -> Void)?

    static func writePreview(to url: URL, showingMenu: Bool = false) -> Bool {
        guard let context = CGContext(data: nil, width: 900, height: 560,
                                      bitsPerComponent: 8, bytesPerRow: 3600,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.container.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 560))
        context.setFillColor(LEStyle.elevated.cgColor)
        context.fill(CGRect(x: 95, y: 70, width: 690, height: 420))
        context.setFillColor(LEStyle.primary.cgColor)
        context.fill(CGRect(x: 95, y: 455, width: 690, height: 35))
        guard let image = context.makeImage() else { return false }
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 560),
                                 snapshot: image, longCapture: false)
        view.selection = CGRect(x: 165, y: 145, width: 510, height: 280)
        view.updatePalette()
        if showingMenu {
            let host = CaptureWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            host.level = .screenSaver
            host.contentView = view
            host.makeKeyAndOrderFront(nil)
            defer { view.closePopup(); host.orderOut(nil) }
            guard let button = view.shapeExpandButton, CutsPopup.clickToolbarButtonForTest(button) else { return false }
            return view.popup?.writePreview(over: view, to: url) == true
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    static func verifyInteraction() -> Bool {
        guard let context = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8,
                                      bytesPerRow: 3600, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                                 snapshot: image, longCapture: false)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown, CGPoint(x: 100, y: 100)),
              let drag = event(.leftMouseDragged, CGPoint(x: 300, y: 250)),
              let up = event(.leftMouseUp, CGPoint(x: 300, y: 250)),
              let resizeDown = event(.leftMouseDown, CGPoint(x: 300, y: 250)),
              let resizeDrag = event(.leftMouseDragged, CGPoint(x: 380, y: 280)),
              let resizeUp = event(.leftMouseUp, CGPoint(x: 380, y: 280)) else { return false }
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        guard view.selection == CGRect(x: 100, y: 100, width: 200, height: 150),
              !view.palette.isHidden else { return false }
        guard let clickDown = event(.leftMouseDown, CGPoint(x: 180, y: 160)),
              let clickUp = event(.leftMouseUp, CGPoint(x: 180, y: 160)) else { return false }
        view.mouseDown(with: clickDown)
        view.mouseUp(with: clickUp)
        guard view.selection == CGRect(x: 100, y: 100, width: 200, height: 150),
              !view.palette.isHidden else { return false }
        view.mouseDown(with: resizeDown)
        view.mouseDragged(with: resizeDrag)
        view.mouseUp(with: resizeUp)
        guard view.selection == CGRect(x: 100, y: 100, width: 280, height: 180),
              !view.palette.isHidden else { return false }
        var selectedAction: SelectionAction?
        var selectedShape: CaptureShape?
        guard let shapeButton = view.shapeExpandButton,
              let brushButton = view.brushExpandButton else { return false }
        let host = CaptureWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.level = .screenSaver
        host.contentView = view
        host.makeKeyAndOrderFront(nil)
        defer { view.closePopup(); host.orderOut(nil) }
        func chooseShape(_ shape: CaptureShape) -> Bool {
            let barFrame = view.palette.frame
            let menuAnchor = host.convertToScreen(view.palette.convert(view.palette.bounds, to: nil))
            return CutsPopup.clickToolbarButtonForTest(shapeButton)
                && view.palette.frame == barFrame
                && view.popup?.isOpen == true
                && view.popup?.windowNumber != host.windowNumber
                && view.popup?.screenFrame?.intersects(menuAnchor) == false
                && view.popup?.clickRowLikeMouseForTest(title: shape.title) == true
                && view.shape == shape
                && view.palette.frame.size == barFrame.size
                && view.popup?.isOpen == true
        }
        guard chooseShape(.circle), view.selection.width == view.selection.height,
              chooseShape(.ellipse), chooseShape(.rectangle), chooseShape(.circle) else { return false }
        view.onAction = { _, shape, action in selectedShape = shape; selectedAction = action }
        let barFrame = view.palette.frame
        guard CutsPopup.clickToolbarButtonForTest(brushButton),
              view.popup?.changeSliderForTest(to: 8) == true,
              view.popup?.isOpen == true, view.session.brush.width == 8, view.palette.frame == barFrame else { return false }
        let expected = ["pen", "arrow", "rectangle", "text", "magnifier", "number", "mosaic", "eraser", "undo", "redo",
                        "ocr", "long", "pin", "save", "copy", "deleteMark", "cancel"]
        let actual = Set(view.palette.subviews.compactMap { ($0 as? NSButton)?.identifier?.rawValue })
        let toolMenus: [EditTool] = [.pen, .arrow, .rectangle, .text, .magnifier, .number, .eraser]
        let firstToolbarDots = view.palette.subviews.compactMap { $0 as? HoverHintButton }.filter(\.isSubmenuDot)
        guard firstToolbarDots.count == toolMenus.count + 1,
              toolMenus.allSatisfy({ view.optionDots[$0]?.isHidden == false }),
              let eraserOptions = view.optionDots[.eraser], CutsPopup.clickToolbarButtonForTest(eraserOptions),
              view.popup?.changeSliderForTest(to: 22, title: "局部擦除粗细") == false,
              view.popup?.clickRowLikeMouseForTest(title: "局部擦除") == true,
              view.popup?.changeSliderForTest(to: 22, title: "局部擦除粗细") == true,
              view.popup?.clickRowLikeMouseForTest(title: "整体擦除") == true,
              view.popup?.isOpen == true,
              view.popup?.changeSliderForTest(to: 23, title: "局部擦除粗细") == false,
              view.draftDefaults.eraserWidth == 22,
              let arrowOptions = view.optionDots[.arrow], CutsPopup.clickToolbarButtonForTest(arrowOptions),
              view.toolOptions(.arrow).items.filter({ !$0.isSeparatorItem && $0.view == nil }).map(\.title)
                == ArrowHeads.allCases.map(\.title) + ArrowTipStyle.allCases.map(\.title) + ["颜色"],
              view.popup?.clickRowLikeMouseForTest(title: "双向箭头") == true,
              view.popup?.changeSliderForTest(to: 12, title: "箭头线宽") == true,
              view.draftDefaults.arrowHeads == .both, view.draftDefaults.arrow.width == 12, selectedAction == nil,
              expected.allSatisfy(actual.contains),
              let annotate = view.palette.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "arrow" }),
              let magnifier = view.palette.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "magnifier" }),
              let brush = view.palette.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "pen" }),
              let undo = view.palette.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "undo" }),
              !undo.isEnabled else { return false }
        brush.performClick(nil)
        guard selectedAction == .brush(BrushChoice(width: 8)) else { return false }
        annotate.performClick(nil)
        guard selectedAction == .edit(.arrow), selectedShape == .circle else { return false }
        magnifier.performClick(nil)
        guard selectedAction == .edit(.magnifier), selectedShape == .circle else { return false }
        guard let doubleDown = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 180, y: 170),
                                                 modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, eventNumber: 5, clickCount: 2, pressure: 1),
              let doubleUp = NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 180, y: 170),
                                               modifierFlags: [], timestamp: 0, windowNumber: 0,
                                               context: nil, eventNumber: 6, clickCount: 2, pressure: 1) else { return false }
        view.mouseDown(with: doubleDown)
        view.mouseUp(with: doubleUp)
        return selectedAction == .copy && view.palette.superview === view
    }

    static func verifyColorPicking() -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(LEStyle.color(0xF02672).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 48))
        context.setFillColor(LEStyle.color(0x187CE4).cgColor)
        context.fill(CGRect(x: 40, y: 24, width: 40, height: 24))
        guard let image = context.makeImage() else { return false }
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 24)
        let view = SelectionView(frame: bounds, snapshot: image, longCapture: false)
        let hit = CGPoint(x: 32, y: 19)
        var picked: [String] = []
        view.onPickColor = { picked.append($0) }
        view.hoveredTarget = CGRect(x: 22, y: 13, width: 17, height: 10)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, shift: Bool = false) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        guard CaptureColor.hex(in: image, at: CGPoint(x: 32, y: 6), bounds: bounds) == "#F02672",
              let down = event(.leftMouseDown, hit), let up = event(.leftMouseUp, hit),
              let shiftDown = event(.leftMouseDown, hit, shift: true),
              let shiftUp = event(.leftMouseUp, hit, shift: true) else { return false }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        guard picked == ["#187CE4"], view.selection.isEmpty else { return false }
        view.mouseDown(with: shiftDown)
        view.mouseUp(with: shiftUp)
        return picked == ["#187CE4"] && view.selection == view.hoveredTarget
    }

    static func verifyCrossDisplay() -> Bool {
        guard let context = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8,
                                      bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let session = SelectionSession(desktopBounds: CGRect(x: 0, y: 0, width: 400, height: 120))
        let left = SelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120),
                                 snapshot: image, longCapture: false, session: session)
        let right = SelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120),
                                  snapshot: image, longCapture: false, session: session,
                                  desktopOffset: CGPoint(x: 200, y: 0))
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown, CGPoint(x: 150, y: 25)),
              let drag = event(.leftMouseDragged, CGPoint(x: 260, y: 90)),
              let up = event(.leftMouseUp, CGPoint(x: 260, y: 90)),
              let resizeDown = event(.leftMouseDown, CGPoint(x: 60, y: 90)),
              let resizeDrag = event(.leftMouseDragged, CGPoint(x: 110, y: 100)),
              let resizeUp = event(.leftMouseUp, CGPoint(x: 110, y: 100)) else { return false }
        left.mouseDown(with: down)
        left.mouseDragged(with: drag)
        left.mouseUp(with: up)
        guard session.selection == CGRect(x: 150, y: 25, width: 110, height: 65),
              session.paletteOwner === right, left.palette.isHidden,
              !right.palette.isHidden else { return false }
        right.mouseDown(with: resizeDown)
        right.mouseDragged(with: resizeDrag)
        right.mouseUp(with: resizeUp)
        guard session.selection == CGRect(x: 150, y: 25, width: 160, height: 75) else { return false }
        var emitted = CGRect.zero
        right.onAction = { rect, _, _ in emitted = rect }
        right.finish(with: .copy)
        guard emitted == session.selection else { return false }

        let reverseSession = SelectionSession(desktopBounds: CGRect(x: 0, y: 0, width: 400, height: 120))
        let reverseLeft = SelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120),
                                        snapshot: image, longCapture: false, session: reverseSession)
        let reverseRight = SelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120),
                                         snapshot: image, longCapture: false, session: reverseSession,
                                         desktopOffset: CGPoint(x: 200, y: 0))
        reverseSession.paletteOwner = reverseRight
        guard let reverseDown = event(.leftMouseDown, CGPoint(x: 80, y: 90)),
              let reverseDrag = event(.leftMouseDragged, CGPoint(x: -50, y: 25)),
              let reverseUp = event(.leftMouseUp, CGPoint(x: -50, y: 25)) else { return false }
        reverseRight.mouseDown(with: reverseDown)
        reverseRight.mouseDragged(with: reverseDrag)
        reverseRight.mouseUp(with: reverseUp)
        return reverseSession.selection == CGRect(x: 150, y: 25, width: 130, height: 65)
            && reverseSession.paletteOwner === reverseLeft
            && !reverseLeft.palette.isHidden && reverseRight.palette.isHidden
    }

    init(frame: CGRect, snapshot: CGImage, longCapture: Bool,
         session: SelectionSession? = nil, desktopOffset: CGPoint = .zero) {
        self.snapshot = snapshot
        self.longCapture = longCapture
        self.session = session ?? SelectionSession(desktopBounds: CGRect(origin: .zero, size: frame.size))
        self.desktopOffset = desktopOffset
        super.init(frame: frame)
        setupPalette()
        self.session.attach(self)
        if self.session.paletteOwner == nil { self.session.paletteOwner = self }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        lastHoverPoint = local
        guard selection.width < 8, !detectingHover, !isHidden,
              Date().timeIntervalSince(lastHoverTime) >= 0.07,
              let win = window, let top = mainScreenTop else { return }
        let frame = win.frame
        let source = snapshot
        let localBounds = bounds
        let showsColor = !longCapture
        lastHoverTime = Date()
        detectingHover = true
        Task { [weak self, weak win] in
            let (hit, color) = await Task.detached(priority: .userInitiated) {
                (WindowContourDetector.target(at: local, screenFrame: frame, mainTop: top, useAccessibility: true),
                 showsColor ? CaptureColor.hex(in: source, at: local, bounds: localBounds) : nil)
            }.value
            guard let self else { return }
            self.detectingHover = false
            guard let win, win.isVisible, self.window === win, self.selection.width < 8,
                  let pointer = self.lastHoverPoint,
                  hypot(pointer.x - local.x, pointer.y - local.y) < 24 || hit?.contains(pointer) == true else { return }
            let result = hit?.intersection(self.bounds)
            if self.hoveredTarget != result { self.hoveredTarget = result }
            if self.hoverColor != color { self.hoverColor = color; self.needsDisplay = true }
        }
    }

    override func mouseExited(with event: NSEvent) {
        lastHoverPoint = nil
        hoverColor = nil
        needsDisplay = true
    }

    private var mainScreenTop: CGFloat? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.main?.frame.maxY
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: snapshot, size: bounds.size).draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        let visible = selection.width > 1 && selection.height > 1 ? selection : hoveredTarget
        if let visible, visible.width > 1, visible.height > 1 {
            shade.append(shape.path(in: visible))
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(visible == nil ? 0.48 : 0.62).setFill()
        shade.fill()
        if selection.width < 8 {
            let pick = hoverColor.map { "单击复制 \($0)" } ?? "单击取色"
            let tip = longCapture ? "长截图 · 单击选取窗口 · 拖动框选 · Esc 退出"
                : "\(pick) · 拖动截图 · ⇧ 单击选窗口 · Esc 退出"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: LEStyle.text
            ]
            let size = (tip as NSString).size(withAttributes: attributes)
            let bubble = CGRect(x: (bounds.midX - size.width / 2 - 14).rounded(),
                                y: bounds.maxY - 54, width: size.width + 28, height: 32)
            LEStyle.elevated.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 9, yRadius: 9).fill()
            LEStyle.border.setStroke()
            NSBezierPath(roundedRect: bubble, xRadius: 9, yRadius: 9).stroke()
            tip.draw(at: CGPoint(x: bubble.minX + 14, y: bubble.minY + 9), withAttributes: attributes)
        }
        if selection.width > 1 && selection.height > 1 {
            NSColor.controlAccentColor.setStroke()
            let line = shape.path(in: selection)
            line.lineWidth = 2
            line.stroke()
            if session.paletteOwner === self {
                let visiblePart = selection.intersection(bounds)
                let label = "\(Int(selection.width * (window?.backingScaleFactor ?? 1))) × \(Int(selection.height * (window?.backingScaleFactor ?? 1))) px"
                label.draw(at: CGPoint(x: max(5, visiblePart.minX + 5),
                                       y: min(bounds.maxY - 23, visiblePart.maxY + 6)),
                           withAttributes: [.foregroundColor: NSColor.white,
                                            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            }
            for handle in handles {
                let dot = NSBezierPath(ovalIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8))
                NSColor.white.setFill()
                dot.fill()
                NSColor.controlAccentColor.setStroke()
                dot.stroke()
            }
        } else if let hoveredTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
            let line = shape.path(in: hoveredTarget)
            line.lineWidth = 1.5
            line.stroke()
        }
    }

    private var handles: [CGPoint] {
        let r = selection
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func setupPalette() {
        LEStyle.frostedSurface(palette)
        palette.isHidden = true
        if longCapture {
            palette.frame.size = CGSize(width: 60, height: 46)
            let start = HoverHintButton(title: "", target: self, action: #selector(startLongCapture))
            start.showsHoverFeedback = true
            start.frame = CGRect(x: 9, y: 7, width: 42, height: 32)
            start.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "开始滚动长截图")
            start.imagePosition = .imageOnly
            start.toolTip = "开始滚动长截图"
            start.setAccessibilityLabel("开始滚动长截图")
            LEStyle.icon(start)
            start.layer?.backgroundColor = LEStyle.primary.cgColor
            palette.addSubview(start)
            addSubview(palette)
            return
        }
        let shapeControl = HoverHintButton(title: "", target: self, action: #selector(showShapeMenu(_:)))
        shapeControl.showsHoverFeedback = true
        shapeControl.imagePosition = .imageOnly
        shapeControl.frame = CGRect(x: 8, y: 7, width: 28, height: 32)
        LEStyle.icon(shapeControl)
        shapeButton = shapeControl
        updateShapeButton()
        palette.addSubview(shapeControl)
        let expand = HoverHintButton.submenuDot(x: 8, title: "选区形状", target: self,
                                               action: #selector(showShapeMenu(_:)))
        let hoverShape = { [weak self, weak expand] in
            guard let self, let expand, self.popup?.isAnchored(to: expand) != true else { return }
            self.showShapeMenu(expand)
        }
        shapeControl.onMenuHover = hoverShape
        expand.onMenuHover = hoverShape
        shapeExpandButton = expand
        palette.addSubview(expand)
        let entries = [("pen", "涂抹", "pencil.tip"), ("arrow", "箭头", "arrow.up.right"),
                       ("rectangle", "圈选", "rectangle"),
                       ("text", "文本", EditTool.text.symbol), ("magnifier", "放大镜", "magnifyingglass"),
                       ("number", "序号", "number.circle"),
                       ("mosaic", "马赛克", "square.grid.3x3.fill"), ("eraser", "橡皮擦", "eraser"),
                       ("undo", "撤回（标注后可用）", "arrow.uturn.backward"),
                       ("redo", "重做（标注后可用）", "arrow.uturn.forward"),
                       ("ocr", "提取文字", "text.viewfinder"),
                       ("long", "滚动长截图", "rectangle.stack"),
                       ("pin", "贴图", "pin"), ("save", "保存", "square.and.arrow.down"),
                       ("copy", "复制", "doc.on.doc"), ("deleteMark", "删除选中标注", "trash"),
                       ("cancel", "关闭", "xmark")]
        palette.frame.size.width = 48 + CGFloat(entries.count) * 32
        for (index, entry) in entries.enumerated() {
            let button = HoverHintButton(title: "", target: self, action: #selector(actionClicked(_:)))
            button.showsHoverFeedback = true
            button.identifier = NSUserInterfaceItemIdentifier(entry.0)
            let tool = EditTool(rawValue: entry.0)
            button.image = tool.flatMap(ToolIcon.image(for:)) ?? NSImage(systemSymbolName: entry.2, accessibilityDescription: entry.1)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            button.imagePosition = .imageOnly
            LEStyle.icon(button)
            button.toolTip = entry.1
            button.setAccessibilityLabel(entry.1)
            button.frame = CGRect(x: 40 + CGFloat(index) * 32,
                                  y: 7, width: 28, height: 32)
            if entry.0 == "undo" || entry.0 == "redo" { button.isEnabled = false }
            if entry.0 == "deleteMark" {
                button.contentTintColor = LEStyle.danger
                button.isEnabled = false
            }
            palette.addSubview(button)
            if let tool, [EditTool.pen, .arrow, .rectangle, .text, .magnifier, .number, .eraser].contains(tool) {
                let dot = HoverHintButton.submenuDot(x: button.frame.minX, title: "\(entry.1)设置", target: self,
                                                    action: #selector(showToolOptions(_:)))
                dot.identifier = NSUserInterfaceItemIdentifier("options.\(tool.rawValue)")
                let hoverOptions = { [weak self, weak dot] in
                    guard let self, let dot, self.popup?.isAnchored(to: dot) != true else { return }
                    self.showToolOptions(dot)
                }
                button.onMenuHover = hoverOptions
                dot.onMenuHover = hoverOptions
                palette.addSubview(dot)
                optionDots[tool] = dot
                if tool == .pen { brushExpandButton = dot }
            }
        }
        addSubview(palette)
    }

    @objc private func showShapeMenu(_ sender: NSButton) {
        showPopup(shapeMenu(), from: sender) { [weak self] in self?.shapeMenu() }
    }

    private func shapeMenu() -> NSMenu {
        let menu = NSMenu()
        for candidate in CaptureShape.allCases {
            let item = NSMenuItem(title: candidate.title, action: #selector(shapeOptionClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.image = MenuIcon.symbol(candidate.symbol, description: candidate.title)
            item.state = shape == candidate ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showToolOptions(_ sender: NSButton) {
        guard let tool = optionDots.first(where: { $0.value === sender })?.key else { return }
        showPopup(toolOptions(tool), from: sender) { [weak self] in self?.toolOptions(tool) }
    }

    private func toolOptions(_ tool: EditTool) -> NSMenu {
        let menu = NSMenu()
        let defaults = session.defaults
        func action(_ title: String, image: NSImage?, state: Bool = false, run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(runOption(_:)), keyEquivalent: "")
            item.target = self
            item.image = image
            item.state = state ? .on : .off
            item.representedObject = MenuAction(run)
            return item
        }
        func choice<Value: Equatable>(_ title: String, _ value: Value,
                                      _ path: WritableKeyPath<AnnotationDefaults, Value>,
                                      icon: String) {
            menu.addItem(action(title, image: MenuIcon.symbol(icon, description: title),
                                state: defaults[keyPath: path] == value) { [weak self] in
                self?.session.defaults[keyPath: path] = value
            })
        }
        func slider<Value>(_ title: String, _ path: WritableKeyPath<AnnotationDefaults, Value>,
                           _ scale: AnnotationSlider.Scale, current: CGFloat, sample: AnnotationSlider.Sample? = nil,
                           store: @escaping (CGFloat) -> Value) {
            menu.addItem(AnnotationSlider.menuItem(title: title, current: current, scale: scale, sample: sample) { [weak self] value in
                self?.session.defaults[keyPath: path] = store(value)
            })
        }
        func ink(_ path: KeyPath<AnnotationDefaults, UInt32?>) -> () -> NSColor {
            { [weak self] in self?.session.defaults[keyPath: path].map(AnnotationDefaults.makeColor) ?? .systemRed }
        }
        func color(_ path: WritableKeyPath<AnnotationDefaults, UInt32?>) {
            let color = defaults[keyPath: path].map(AnnotationDefaults.makeColor) ?? .systemRed
            menu.addItem(action("颜色", image: MenuIcon.swatch(color)) { [weak self] in
                guard let self, let picker = self.popup?.makeColorPicker(color:
                    self.session.defaults[keyPath: path].map(AnnotationDefaults.makeColor) ?? .systemRed) else { return }
                picker.onApply = { [weak self] color in
                    self?.session.defaults[keyPath: path] = AnnotationDefaults.storeColor(color)
                    self?.popup?.refreshMarks()
                }
                picker.show()
            })
        }
        switch tool {
        case .pen:
            slider("涂抹粗细", \.brush.width, .strokeWidth, current: defaults.brush.width, sample: .line(ink(\.brush.rgba))) { $0 }
            color(\.brush.rgba)
        case .arrow:
            slider("箭头线宽", \.arrow.width, .strokeWidth, current: defaults.arrow.width, sample: .line(ink(\.arrow.rgba))) { $0 }
            for (head, icon) in [(ArrowHeads.end, "arrow.right"), (.start, "arrow.left"),
                                 (.both, "arrow.left.arrow.right"), (.none, "line.diagonal")] {
                choice(head.title, head, \.arrowHeads, icon: icon)
            }
            menu.addItem(.separator())
            for tip in ArrowTipStyle.allCases {
                choice(tip.title, tip, \.arrowTip, icon: tip == .open ? "arrow.up.right" : "arrow.up.right.circle.fill")
            }
            color(\.arrow.rgba)
        case .rectangle:
            for shape in [EditTool.rectangle, .ellipse, .circle] {
                choice(shape.title, shape, \.geometryTool, icon: shape.symbol)
            }
            menu.addItem(.separator())
            color(\.geometry.rgba)
            slider("线条粗细", \.geometry.width, .strokeWidth, current: defaults.geometry.width, sample: .line(ink(\.geometry.rgba))) { $0 }
        case .text:
            color(\.textColor)
            let fonts = NSMenu()
            for (title, name) in AnnotationDefaults.fonts {
                fonts.addItem(action(title, image: MenuIcon.fontSample(name), state: defaults.font == name) { [weak self] in
                    self?.session.defaults.font = name
                })
            }
            let font = NSMenuItem(title: "字体", action: nil, keyEquivalent: "")
            font.image = MenuIcon.symbol("character", description: font.title)
            font.submenu = fonts
            menu.addItem(font)
            slider("字号", \.fontSize, .fontSize, current: defaults.fontSize, sample: .text(ink(\.textColor))) { $0 }
            for (title, icon, path) in [("加粗", "bold", \AnnotationDefaults.bold), ("倾斜", "italic", \AnnotationDefaults.italic)] {
                menu.addItem(action(title, image: MenuIcon.symbol(icon, description: title),
                                    state: defaults[keyPath: path]) { [weak self] in
                    self?.session.defaults[keyPath: path].toggle()
                })
            }
        case .number:
            menu.addItem(NumberEditingShortcuts.menuItem())
            choice("有背景", true, \.numberFilled, icon: "number.circle.fill")
            choice("无背景", false, \.numberFilled, icon: "number.circle")
            menu.addItem(MenuNumberInput.item("设置下一个数字…", icon: "number",
                                              current: { [weak self] in self?.session.defaults.firstNumber ?? 1 }) { [weak self] in
                self?.session.defaults.firstNumber = $0
            })
            slider("序号大小", \.numberSize, .fontSize, current: defaults.numberSize,
                   sample: .number(color: ink(\.numberColor), filled: { [weak self] in self?.session.defaults.numberFilled ?? true })) { $0 }
            color(\.numberColor)
        case .magnifier:
            let scale = max(CGFloat(snapshot.width) / max(1, bounds.width),
                            CGFloat(snapshot.height) / max(1, bounds.height))
            let maximum = max(1, min(session.selection.width, session.selection.height) * scale)
            slider("放大倍率", \.magnification, .magnification, current: defaults.magnification) { $0 }
            slider("放大镜直径", \.lensDiameter, .diameter(maximum: maximum),
                   current: defaults.lensDiameter ?? min(maximum, min(280, max(48, maximum * 0.2)))) { $0 }
        case .eraser:
            for mode in EraserMode.allCases {
                menu.addItem(action(mode.title, image: MenuIcon.symbol(mode == .whole ? "eraser.fill" : "eraser",
                                    description: mode.title), state: (defaults.eraserMode ?? .whole) == mode) { [weak self] in
                    self?.session.defaults.eraserMode = mode
                })
            }
            if defaults.eraserMode == .local {
                slider("局部擦除粗细", \.eraserWidth, .eraserWidth, current: defaults.eraserWidth ?? 20, sample: .eraser) { $0 }
            }
        default: break
        }
        return menu
    }

    @objc private func runOption(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private func showPopup(_ menu: NSMenu, from sender: NSButton, refresh: @escaping () -> NSMenu?) {
        popup?.close(restoringFocus: false)
        let menuWindow = CutsPopup(menu: menu)
        popup = menuWindow
        menuWindow.refreshedMenu = refresh
        menuWindow.show(from: sender, avoiding: palette)
    }

    fileprivate func closePopup() {
        popup?.close(restoringFocus: false)
    }

    @objc private func shapeOptionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = CaptureShape(rawValue: raw) else { return }
        let changed = shape != selected
        shape = selected
        CutsLog.write(.debug, "capture", "selection shape=\(shape.rawValue)")
        if shape == .circle, selection.width >= 8, selection.height >= 8 {
            let side = min(selection.width, selection.height)
            selection = CGRect(x: selection.midX - side / 2, y: selection.midY - side / 2,
                               width: side, height: side)
        }
        if changed { session.acknowledgeSelection() }
    }

    fileprivate func updateShapeButton() {
        shapeButton?.title = ""
        shapeButton?.image = NSImage(systemSymbolName: shape.symbol, accessibilityDescription: shape.title)
        shapeButton?.setAccessibilityLabel("截图形状：\(shape.title)")
        shapeButton?.toolTip = "当前选区：\(shape.title)"
    }

    fileprivate func updatePalette() {
        let wasHidden = palette.isHidden
        palette.isHidden = selection.width < 8 || selection.height < 8 || session.paletteOwner !== self
        if palette.isHidden { popup?.close(restoringFocus: false) }
        guard !palette.isHidden else { return }
        let x = max(8, min(bounds.maxX - palette.frame.width - 8, selection.maxX - palette.frame.width))
        let y = selection.minY >= palette.frame.height + 12 ? selection.minY - palette.frame.height - 6
            : min(bounds.maxY - palette.frame.height - 8, selection.maxY + 8)
        palette.frame.origin = CGPoint(x: x, y: y)
        if wasHidden { CutsMotion.appear(palette, .popup, from: CGPoint(x: 0, y: y < selection.minY ? 6 : -6)) }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let action: SelectionAction
        switch name {
        case "cancel": onCancel?(); return
        case "pen": action = .brush(session.brush)
        case "arrow": action = .edit(.arrow)
        case "rectangle": action = .edit(.rectangle)
        case "text": action = .edit(.text)
        case "magnifier": action = .edit(.magnifier)
        case "number": action = .edit(.number)
        case "mosaic": action = .edit(.mosaic)
        case "eraser": action = .edit(.eraser)
        case "ocr": action = .recognizeText
        case "long": action = .longCapture
        case "pin": action = .pin
        case "save": action = .save
        case "copy": action = .copy
        default: return
        }
        finish(with: action)
    }

    @objc private func startLongCapture() { finish(with: .longCapture) }

    private func finish(with action: SelectionAction) {
        guard selection.width >= 8, selection.height >= 8 else { return }
        popup?.close(restoringFocus: false)
        onAction?(session.selection, shape, action)
    }

    override func mouseDown(with event: NSEvent) {
        session.clearAcknowledgment()
        let point = convert(event.locationInWindow, from: nil)
        session.paletteOwner = self
        startPoint = point
        original = selection
        didDrag = false
        pressedTarget = nil
        if selection.width >= 8,
           let index = handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 11 }) {
            dragMode = .resize(index)
        } else if selection.contains(point) {
            dragMode = .move
        } else {
            dragMode = .create
            pressedTarget = hoveredTarget?.contains(point) == true ? hoveredTarget : nil
            if pressedTarget == nil, (longCapture || event.modifierFlags.contains(.shift)), let window, let top = mainScreenTop {
                pressedTarget = WindowContourDetector.target(at: point, screenFrame: window.frame,
                                                               mainTop: top, useAccessibility: false)
            }
            selection = .zero
            palette.isHidden = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let allowed = session.desktopBounds.offsetBy(dx: -desktopOffset.x, dy: -desktopOffset.y)
        let clamped = CGPoint(x: max(allowed.minX, min(allowed.maxX, point.x)),
                              y: max(allowed.minY, min(allowed.maxY, point.y)))
        didDrag = didDrag || hypot(clamped.x - startPoint.x, clamped.y - startPoint.y) >= 3
        switch dragMode {
        case .create:
            let width = abs(clamped.x - startPoint.x)
            let height = abs(clamped.y - startPoint.y)
            let side = min(width, height)
            let finalWidth = shape == .circle ? side : width
            let finalHeight = shape == .circle ? side : height
            selection = CGRect(x: clamped.x < startPoint.x ? startPoint.x - finalWidth : startPoint.x,
                               y: clamped.y < startPoint.y ? startPoint.y - finalHeight : startPoint.y,
                               width: finalWidth, height: finalHeight)
        case .move:
            selection.origin.x = max(allowed.minX, min(allowed.maxX - original.width,
                                                       original.minX + clamped.x - startPoint.x))
            selection.origin.y = max(allowed.minY, min(allowed.maxY - original.height,
                                                       original.minY + clamped.y - startPoint.y))
        case .resize(let index):
            var left = original.minX, right = original.maxX
            var bottom = original.minY, top = original.maxY
            if [0, 6, 7].contains(index) { left = min(right - 8, clamped.x) }
            if [2, 3, 4].contains(index) { right = max(left + 8, clamped.x) }
            if [0, 1, 2].contains(index) { bottom = min(top - 8, clamped.y) }
            if [4, 5, 6].contains(index) { top = max(bottom + 8, clamped.y) }
            selection = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            if shape == .circle {
                let side = min(selection.width, selection.height)
                selection = CGRect(x: selection.midX - side / 2, y: selection.midY - side / 2,
                                   width: side, height: side)
            }
        }
        updatePalette()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .create = dragMode, !didDrag {
            if !longCapture, (original.width < 8 || original.height < 8),
               !event.modifierFlags.contains(.shift), let onPickColor,
               let hex = CaptureColor.hex(in: snapshot, at: point, bounds: bounds) {
                pressedTarget = nil
                startPoint = nil
                onPickColor(hex)
                return
            }
            selection = pressedTarget ?? .zero
            if shape == .circle, selection.width >= 8, selection.height >= 8 {
                let side = min(selection.width, selection.height)
                selection = CGRect(x: selection.midX - side / 2, y: selection.midY - side / 2,
                                   width: side, height: side)
            }
        }
        pressedTarget = nil
        startPoint = nil
        session.choosePaletteOwner(at: CGPoint(x: point.x + desktopOffset.x,
                                               y: point.y + desktopOffset.y))
        updatePalette()
        needsDisplay = true
        if event.clickCount >= 2, selection.contains(convert(event.locationInWindow, from: nil)) {
            finish(with: .copy)
        } else if selection != original {
            session.acknowledgeSelection()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { finish(with: .copy) }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { finish(with: .copy) }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" { finish(with: .save) }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "t" { finish(with: .pin) }
        else { super.keyDown(with: event) }
    }
}
