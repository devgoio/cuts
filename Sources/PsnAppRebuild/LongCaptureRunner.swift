import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum LongCaptureFailure: LocalizedError {
    case missingDisplay
    case missingTarget
    case targetNotForeground

    var errorDescription: String? {
        switch self {
        case .missingDisplay: "找不到所选显示器"
        case .missingTarget: "选区中心没有可采集的应用窗口，请把选区框在要滚动的页面内"
        case .targetNotForeground: "无法切回目标应用，未开始滚动采集"
        }
    }
}

/// Own the strip buffers and matching work away from AppKit's event loop.
private actor LongCaptureStitchWorker {
    private var accumulator: VerticalStitcher.Accumulator?
    func start(with image: CGImage) { accumulator = .init(first: image) }
    func offer(_ frame: CGImage) -> VerticalStitcher.Accumulator.Update {
        accumulator?.offer(frame) ?? .unmatched
    }
    func preview(fitting size: CGSize) -> (CGImage, CGSize)? {
        guard let accumulator, let image = accumulator.thumbnail(fitting: size) else { return nil }
        return (image, accumulator.pixelSize)
    }
    var pixelSize: CGSize { accumulator?.pixelSize ?? .zero }
    var frameCount: Int { accumulator?.frameCount ?? 0 }
    func result() throws -> CGImage {
        guard let accumulator else { throw VerticalStitchError.inconsistentFrames }
        return try accumulator.result()
    }
}

@MainActor
final class LongCaptureRunner {
    struct Result {
        let image: CGImage
        let frameCount: Int
        let note: String?
    }

    private struct WindowTarget {
        let pid: pid_t
        let frame: CGRect
        var id: CGWindowID = 0
    }

    func capture(screen: NSScreen, region: CGRect) async throws -> Result? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LongCaptureFailure.missingDisplay
        }
        let clipped = region.intersection(screen.frame).integral
        guard clipped.width >= 24, clipped.height >= 24 else { throw LongCaptureFailure.missingDisplay }
        guard let target = Self.windowUnderSelection(clipped),
              let targetApp = NSRunningApplication(processIdentifier: target.pid),
              !targetApp.isTerminated else { throw LongCaptureFailure.missingTarget }
        let targetPID = target.pid
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            guard targetApp.activate(options: []) else { throw LongCaptureFailure.targetNotForeground }
        }
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              Self.windowUnderSelection(clipped)?.id == target.id else {
            throw LongCaptureFailure.targetNotForeground
        }
        let guide = LongCaptureGuide(region: clipped, visibleFrame: screen.visibleFrame,
                                     otherVisibleFrames: NSScreen.screens.filter { $0 != screen }.map(\.visibleFrame))
        guide.show()
        defer { guide.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw LongCaptureFailure.missingDisplay
        }
        guard let targetWindow = content.windows.first(where: { $0.windowID == target.id }) else {
            throw LongCaptureFailure.missingTarget
        }
        let filter = Self.captureFilter(display: display, target: targetWindow)
        let config = Self.configuration(screen: screen, region: clipped)
        guard Self.windowUnderSelection(clipped)?.id == target.id else { throw LongCaptureFailure.targetNotForeground }
        let first = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        CutsLog.write(.info, "longCapture", "started selection=\(first.width)x\(first.height) pixels")
        let worker = LongCaptureStitchWorker()
        await worker.start(with: first)
        var frameCount = 1
        var missedSince: TimeInterval?
        var lastAutomaticScroll: TimeInterval = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastProgress = startedAt
        var pausedByTarget = false
        var reachedLimit = false
        var captureFailureReported = false
        var reportedGap = false
        var needsThumbnail = false
        var lastThumbnail = startedAt
        if let preview = await worker.preview(fitting: guide.thumbnailBudget) { guide.updateThumbnail(preview) }
        guide.ready()
        while guide.decision == .waiting {
            try await Task.sleep(nanoseconds: pausedByTarget || reachedLimit ? 280_000_000 : 72_000_000)
            guard guide.decision == .waiting else { break }
            let now = ProcessInfo.processInfo.systemUptime
            if needsThumbnail, now - lastThumbnail >= 0.12 {
                if let preview = await worker.preview(fitting: guide.thumbnailBudget) { guide.updateThumbnail(preview) }
                lastThumbnail = now
                needsThumbnail = false
            }
            if reachedLimit { continue }
            guard Self.windowUnderSelection(clipped)?.id == target.id else {
                if !pausedByTarget {
                    pausedByTarget = true
                    guide.pauseAutomatic("已暂缓采集，回到目标窗口可继续")
                    CutsLog.write(.warning, "longCapture", "target temporarily unavailable")
                }
                continue
            }
            if pausedByTarget {
                pausedByTarget = false
                guide.update("已回到原窗口，可以继续滚动")
                CutsLog.write(.info, "longCapture", "target resumed")
            }
            if guide.automatic, now - lastAutomaticScroll >= 0.45,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                if guide.automaticStarted > 0, now - max(lastProgress, guide.automaticStarted) >= 2.8 {
                    guide.pauseAutomatic("已暂停自动滚动，采集仍在继续")
                    CutsLog.write(.info, "longCapture", "automatic wheel paused; session still open")
                } else {
                    postScroll(at: clipped, pixels: -Int32(max(12, min(70, clipped.height / 6))))
                    lastAutomaticScroll = now
                }
            }
            let frame: CGImage
            do {
                frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                if !captureFailureReported {
                    captureFailureReported = true
                    guide.update("暂时无法采帧，仍在尝试")
                    CutsLog.failure("longCapture", "capture frame", error)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            if captureFailureReported {
                captureFailureReported = false
                CutsLog.write(.info, "longCapture", "frame capture recovered")
            }
            guard guide.decision != .cancelled else { break }
            guard Self.windowUnderSelection(clipped)?.id == target.id else {
                continue
            }
            let update = await worker.offer(frame)
            guard guide.decision != .cancelled else { break }
            switch update {
            case .unchanged:
                if reportedGap {
                    reportedGap = false
                    guide.update("已回到已采集区域，可继续滚动")
                    CutsLog.write(.info, "longCapture", "returned to captured area")
                }
                missedSince = nil
            case .appended:
                frameCount += 1
                missedSince = nil
                if reportedGap {
                    reportedGap = false
                    CutsLog.write(.info, "longCapture", "overlap recovered")
                }
                lastProgress = now
                needsThumbnail = true
                guide.update("已接上 \(frameCount) 帧", animated: false)
                CutsLog.write(.debug, "longCapture", "accepted frame=\(frameCount)")
            case .unmatched:
                if missedSince == nil {
                    missedSince = now
                    CutsLog.write(.debug, "longCapture", "no overlap with either end; frames=\(frameCount)")
                }
                if !reportedGap, now - (missedSince ?? now) >= 0.6 {
                    reportedGap = true
                    CutsLog.write(.warning, "longCapture", "no overlap for 600ms; session still open")
                    guide.update("中间有空档，往回滚一点可接上")
                }
            case .limitReached:
                reachedLimit = true
                guide.pauseAutomatic("已达图像大小上限，请选择完成或取消")
                CutsLog.write(.warning, "longCapture", "output pixel limit; waiting for user")
            }
        }
        guard guide.decision != .cancelled else {
            CutsLog.write(.info, "longCapture", "cancelled by user")
            return nil
        }
        let note = frameCount == 1 ? "没有新增画面，已保留选区截图" : nil
        let image = try await worker.result()
        guard guide.decision != .cancelled else { return nil }
        let seconds = Int(ProcessInfo.processInfo.systemUptime - startedAt)
        CutsLog.write(.info, "longCapture",
                      "completed frames=\(frameCount) pixels=\(image.width)x\(image.height) seconds=\(seconds)")
        return Result(image: image, frameCount: frameCount, note: note)
    }

    static func sourceRect(region: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: region.minX - screenFrame.minX,
               y: screenFrame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    private static func captureFilter(display: SCDisplay, target: SCWindow) -> SCContentFilter {
        let filter = SCContentFilter(display: display, including: [target])
        filter.includeMenuBar = false
        return filter
    }

    private static func configuration(screen: NSScreen, region: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect(region: region, screenFrame: screen.frame)
        config.width = max(2, Int((region.width * screen.backingScaleFactor).rounded()))
        config.height = max(2, Int((region.height * screen.backingScaleFactor).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        return config
    }

    private static func target(at center: CGPoint, windows: [WindowTarget], ownPID: pid_t) -> WindowTarget? {
        windows.first(where: { $0.pid != ownPID && $0.frame.contains(center) })
    }

    private static func windowUnderSelection(_ region: CGRect) -> WindowTarget? {
        guard let mainTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.main?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates: [WindowTarget] = windows.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 24, rect.height >= 24 else { return nil }
            return WindowTarget(pid: pid, frame: rect, id: id)
        }
        let center = CGPoint(x: region.midX, y: mainTop - region.midY)
        return target(at: center, windows: candidates, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func verifyRegionMapping() -> Bool {
        let primary = sourceRect(region: CGRect(x: 100, y: 300, width: 420, height: 500),
                                 screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let second = sourceRect(region: CGRect(x: 1600, y: 200, width: 300, height: 400),
                                screenFrame: CGRect(x: 1440, y: -100, width: 1280, height: 1000))
        let candidates = [WindowTarget(pid: 1, frame: CGRect(x: -400, y: -500, width: 1200, height: 1600)),
                          WindowTarget(pid: 3, frame: CGRect(x: 300, y: 300, width: 500, height: 350)),
                          WindowTarget(pid: 2, frame: CGRect(x: -300, y: 50, width: 600, height: 450)),
                          WindowTarget(pid: 4, frame: CGRect(x: -300, y: 50, width: 600, height: 450))]
        return primary == CGRect(x: 100, y: 100, width: 420, height: 500)
            && second == CGRect(x: 160, y: 300, width: 300, height: 400)
            && target(at: CGPoint(x: -100, y: 200), windows: candidates, ownPID: 1)?.pid == 2
            && target(at: CGPoint(x: 450, y: 450), windows: candidates, ownPID: 1)?.pid == 3
            && target(at: CGPoint(x: 900, y: 200), windows: candidates, ownPID: 1) == nil
            && LongCaptureGuide.verifyControl()
    }

    static func verifyLiveFixture() async -> Bool {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            print("long-capture-fixture: screen recording permission or display unavailable")
            return false
        }
        let size = CGSize(width: 460, height: 312)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.center()
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = LongCaptureFixture(frame: CGRect(x: 0, y: 0, width: size.width, height: 2200))
        window.contentView = scroll
        window.orderFrontRegardless()
        let region = window.frame.insetBy(dx: 10, dy: 8)
        let guide = LongCaptureGuide(region: region, visibleFrame: screen.visibleFrame)
        guide.show()
        defer { guide.close(); window.close() }
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }),
                  let fixture = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                print("long-capture-fixture: synthetic window not listed")
                return false
            }
            // Include only the synthetic window. No user window is captured.
            let filter = captureFilter(display: display, target: fixture)
            let config = configuration(screen: screen, region: region)
            func frame(at y: CGFloat) async throws -> CGImage {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 120_000_000)
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            let first = try await frame(at: 52)
            let collector = LongCaptureStitchWorker()
            await collector.start(with: first)
            if let preview = await collector.preview(fitting: guide.thumbnailBudget) { guide.updateThumbnail(preview) }
            guide.ready()
            guard guide.previewMatches(await collector.pixelSize) else { return false }
            let offsets: [CGFloat] = [52, 430, 108, 108, 162, 108, 52, 0, 0]
            var updates: [VerticalStitcher.Accumulator.Update] = []
            for y in offsets {
                let update = await collector.offer(try await frame(at: y))
                if update == .appended, let preview = await collector.preview(fitting: guide.thumbnailBudget) {
                    guide.updateThumbnail(preview)
                }
                guard guide.previewMatches(await collector.pixelSize) else { return false }
                updates.append(update)
            }
            let output = try await collector.result()
            let expectedHeight = first.height + Int((162 * screen.backingScaleFactor).rounded())
            print("long-capture-fixture updates=\(updates) frames=\(await collector.frameCount) height=\(output.height) expected=\(expectedHeight)")
            return updates == [.unchanged, .unmatched, .appended, .unchanged, .appended, .unchanged,
                               .unchanged, .appended, .unchanged]
                && output.width == first.width && abs(output.height - expectedHeight) <= 3
        } catch {
            print("long-capture-fixture: \(error.localizedDescription)")
            return false
        }
    }

    private func postScroll(at region: CGRect, pixels: Int32) {
        let mainTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY ?? region.maxY
        let center = CGPoint(x: region.midX, y: mainTop - region.midY)
        let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                            units: .pixel, wheelCount: 1,
                            wheel1: pixels, wheel2: 0, wheel3: 0)
        event?.location = center
        event?.setIntegerValueField(.eventSourceUserData, value: MouseEventMonitor.marker)
        event?.post(tap: .cgSessionEventTap)
    }
}

private final class LongCaptureFixture: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        LEStyle.canvas.setFill()
        dirtyRect.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        for row in max(0, Int(dirtyRect.minY) / 32 - 1)...Int(dirtyRect.maxY) / 32 {
            let y = CGFloat(row * 32 + (row * 7) % 12 + 2)
            LEStyle.primary.setFill()
            CGRect(x: 25, y: y + 6, width: CGFloat(7 + ((row * 29) % 48)), height: 3).fill()
            ("ROW \(row) — Record \((row * 617 + 41) % 1_235) · " + String(repeating: "·", count: row % 13))
                .draw(at: CGPoint(x: 94 + CGFloat((row * 13) % 31), y: y),
                      withAttributes: [.font: font, .foregroundColor: LEStyle.text])
        }
    }
}

@MainActor
private final class LongCaptureGuide: NSObject {
    enum Decision { case waiting, finished, cancelled }
    private(set) var decision: Decision = .waiting
    private(set) var automatic = false
    private(set) var automaticStarted: TimeInterval = 0
    private let outline: NSPanel
    private let controls: NSPanel
    private let thumbnail: NSPanel
    private let thumbnailView = NSImageView()
    private let dimensions = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "正在准备固定采集区域…")
    private let autoButton = HoverHintButton()
    private let finishButton = HoverHintButton()

    init(region: CGRect, visibleFrame: CGRect, otherVisibleFrames: [CGRect] = []) {
        outline = Self.makePanel(frame: region)
        let barSize = CGSize(width: 432, height: 46)
        let x = max(visibleFrame.minX + 8, min(visibleFrame.maxX - barSize.width - 8, region.midX - barSize.width / 2))
        let lower = region.minY - barSize.height - 8
        let upper = region.maxY + 8
        let y = lower >= visibleFrame.minY + 8 ? lower
            : min(visibleFrame.maxY - barSize.height - 8, upper)
        let barFrame = CGRect(origin: CGPoint(x: x, y: y), size: barSize)
        controls = Self.makePanel(frame: barFrame)
        let previewFrame = Self.thumbnailFrame(region: region, visibleFrame: visibleFrame,
                                                otherVisibleFrames: otherVisibleFrames, controlsFrame: barFrame)
        thumbnail = Self.makePanel(frame: previewFrame)
        super.init()
        outline.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: region.size))
        view.wantsLayer = true
        view.layer?.borderColor = LEStyle.primary.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        outline.contentView = view

        let bar = NSView(frame: CGRect(origin: .zero, size: barSize))
        LEStyle.surface(bar, radius: 9)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = LEStyle.text
        label.frame = CGRect(x: 12, y: 14, width: 218, height: 18)
        label.lineBreakMode = .byTruncatingTail
        bar.addSubview(label)
        configure(autoButton, title: "自动滚动", x: 230, width: 69, action: #selector(toggleAutomatic))
        configure(finishButton, title: "完成", x: 305, width: 55, action: #selector(finish))
        finishButton.layer?.backgroundColor = LEStyle.primary.cgColor
        finishButton.isEnabled = false
        autoButton.isEnabled = false
        let cancel = HoverHintButton()
        configure(cancel, title: "取消", x: 366, width: 56, action: #selector(cancelCapture))
        for button in [autoButton, finishButton, cancel] { bar.addSubview(button) }
        controls.contentView = bar
        controls.hasShadow = true

        let preview = NSView(frame: CGRect(origin: .zero, size: previewFrame.size))
        LEStyle.surface(preview, radius: 9)
        let title = NSTextField(labelWithString: "实时预览")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = LEStyle.text
        title.frame = CGRect(x: 10, y: preview.bounds.height - 24, width: preview.bounds.width - 20, height: 15)
        preview.addSubview(title)
        thumbnailView.frame = CGRect(x: 8, y: 27, width: preview.bounds.width - 16, height: preview.bounds.height - 54)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.setAccessibilityLabel("已拼接的截图")
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.backgroundColor = LEStyle.canvas.cgColor
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        preview.addSubview(thumbnailView)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        dimensions.textColor = LEStyle.secondary
        dimensions.alignment = .center
        dimensions.frame = CGRect(x: 6, y: 7, width: preview.bounds.width - 12, height: 14)
        preview.addSubview(dimensions)
        thumbnail.contentView = preview
        thumbnail.ignoresMouseEvents = true
        thumbnail.hasShadow = true
    }

    private static func thumbnailFrame(region: CGRect, visibleFrame: CGRect,
                                       otherVisibleFrames: [CGRect], controlsFrame: CGRect) -> CGRect {
        let desired = CGSize(width: 148, height: 258)
        let visible = visibleFrame.insetBy(dx: 8, dy: 8)
        let capture = region.insetBy(dx: -8, dy: -8)
        func excluding(_ obstacle: CGRect, from area: CGRect) -> [CGRect] {
            let overlap = obstacle.intersection(area)
            guard !overlap.isEmpty, !overlap.isNull else { return [area] }
            return [
                CGRect(x: overlap.maxX, y: area.minY, width: area.maxX - overlap.maxX, height: area.height),
                CGRect(x: area.minX, y: area.minY, width: overlap.minX - area.minX, height: area.height),
                CGRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY),
                CGRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY)
            ].filter { !$0.isEmpty }
        }
        func place(_ area: CGRect) -> CGRect {
            let size = CGSize(width: min(desired.width, area.width), height: min(desired.height, area.height))
            let x = max(area.minX, min(region.maxX + 8, area.maxX - size.width))
            let y = max(area.minY, min(region.maxY - size.height, area.maxY - size.height))
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        let free = excluding(capture, from: visible).flatMap { excluding(controlsFrame.insetBy(dx: -6, dy: -6), from: $0) }
        if let full = free.first(where: { $0.width >= desired.width && $0.height >= desired.height }) {
            return place(full)
        }
        if let nearby = free.filter({ $0.width >= 108 && $0.height >= 146 }).max(by: {
            let lhs = place($0), rhs = place($1)
            return lhs.width * lhs.height < rhs.width * rhs.height
        }) { return place(nearby) }
        let nearestOther = otherVisibleFrames.min {
            hypot($0.midX - region.midX, $0.midY - region.midY) < hypot($1.midX - region.midX, $1.midY - region.midY)
        }
        if let nearestOther { return place(nearestOther.insetBy(dx: 8, dy: 8)) }
        // Full-screen capture with no spare screen: use a click-through corner.
        // ScreenCaptureKit's filter includes only the target window, not this panel.
        return place(excluding(controlsFrame.insetBy(dx: -6, dy: -6), from: visible)
            .first(where: { $0.width >= desired.width && $0.height >= desired.height }) ?? visible)
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func configure(_ button: NSButton, title: String, x: CGFloat, width: CGFloat, action: Selector) {
        button.frame = CGRect(x: x, y: 7, width: width, height: 32)
        button.title = title
        button.target = self
        button.action = action
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        LEStyle.icon(button)
    }

    func show() {
        outline.orderFrontRegardless()
        thumbnail.orderFrontRegardless()
        controls.orderFrontRegardless()
        if let bar = controls.contentView { CutsMotion.appear(bar, .popup, from: CGPoint(x: 0, y: -5)) }
        if let preview = thumbnail.contentView {
            let center = CGPoint(x: outline.frame.midX, y: outline.frame.midY)
            CutsMotion.appear(preview, .popup, from: CutsMotion.direction(from: center, toward: thumbnail.frame))
        }
    }

    var thumbnailBudget: CGSize {
        let bounds = thumbnailView.bounds.size
        // A fixed 2x budget is bounded even when the preview is moved to another display.
        return CGSize(width: bounds.width * 2, height: bounds.height * 2)
    }

    func updateThumbnail(_ preview: (CGImage, CGSize)) {
        let (image, size) = preview
        CutsMotion.replaceContents(in: thumbnailView) {
            thumbnailView.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        dimensions.stringValue = Self.pixelDimensions(size)
    }

    private static func pixelDimensions(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }

    func previewMatches(_ size: CGSize) -> Bool {
        guard thumbnail.isVisible, thumbnail.ignoresMouseEvents, let image = thumbnailView.image else { return false }
        return dimensions.stringValue == Self.pixelDimensions(size)
            && image.size.height <= thumbnailView.bounds.height * 2 && image.size.width <= thumbnailView.bounds.width * 2
    }

    func ready() {
        update("移入框内可上下滚动，点完成结束")
        finishButton.isEnabled = true
        autoButton.isEnabled = true
    }

    func update(_ text: String, animated: Bool = true) {
        guard text != label.stringValue else { return }
        if animated { CutsMotion.replaceContents(in: label) { label.stringValue = text } }
        else { label.stringValue = text }
    }

    func pauseAutomatic(_ message: String) {
        automatic = false
        autoButton.title = "自动滚动"
        update(message)
    }

    @objc private func toggleAutomatic() {
        if automatic {
            pauseAutomatic("已暂停自动滚动，可继续手动滚动")
            CutsLog.write(.info, "longCapture", "automatic wheel paused by user")
        } else if AXIsProcessTrusted() {
            automatic = true
            automaticStarted = ProcessInfo.processInfo.systemUptime
            autoButton.title = "暂停自动"
            update("正在自动滚动")
            CutsLog.write(.info, "longCapture", "automatic wheel enabled by user")
        } else {
            update("自动滚动需辅助功能权限；可手动滚动")
            CutsLog.write(.warning, "longCapture", "automatic wheel unavailable: accessibility permission")
        }
    }

    @objc private func finish() { decision = .finished }
    @objc private func cancelCapture() { decision = .cancelled }
    func close() { controls.close(); thumbnail.close(); outline.close() }

    static func verifyControl() -> Bool {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let region = CGRect(x: 100, y: 100, width: 300, height: 260)
        let guide = Self(region: region, visibleFrame: visible)
        defer { guide.close() }
        let roomy = thumbnailFrame(region: region, visibleFrame: visible, otherVisibleFrames: [],
                                   controlsFrame: guide.controls.frame)
        let other = CGRect(x: -1000, y: -200, width: 1000, height: 760)
        let full = thumbnailFrame(region: visible, visibleFrame: visible, otherVisibleFrames: [other],
                                  controlsFrame: guide.controls.frame)
        let fallback = thumbnailFrame(region: visible, visibleFrame: visible, otherVisibleFrames: [],
                                      controlsFrame: guide.controls.frame)
        guard visible.contains(roomy), !roomy.intersects(region), !roomy.intersects(guide.controls.frame),
              other.contains(full), visible.contains(fallback), !fallback.intersects(guide.controls.frame),
              guide.thumbnail.ignoresMouseEvents else { return false }
        guide.ready()
        guard !guide.automatic, guide.decision == .waiting else { return false }
        guide.pauseAutomatic("测试：暂停自动滚动")
        guard guide.decision == .waiting, guide.finishButton.isEnabled else { return false }
        guide.finishButton.performClick(nil)
        return guide.decision == .finished
    }
}
