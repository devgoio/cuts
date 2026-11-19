import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

private enum HoldSignal {
    case commandVDown
    case vUp
    case commandReleased
    case otherKeyDown
    case deadline(Int)
}

private struct HoldOutcome {
    var forward = true
    var replayPaste = false
    var openHistory = false
    var schedule: Int?
    var remaining: TimeInterval?
}

private struct CommandVHoldEngine {
    private struct Pending {
        let id: Int
        let start: TimeInterval
        var completed = false
        var opened = false
    }

    private var pending: Pending?
    private var nextID = 0
    var isPending: Bool { pending != nil }

    mutating func handle(_ signal: HoldSignal, at time: TimeInterval,
                         threshold: TimeInterval) -> HoldOutcome {
        var outcome = HoldOutcome()
        switch signal {
        case .commandVDown:
            outcome.forward = false
            guard pending == nil else { return outcome }
            nextID += 1
            pending = Pending(id: nextID, start: time)
            outcome.schedule = nextID
        case .vUp:
            guard let held = pending else { return outcome }
            outcome.forward = false
            if !held.completed && !held.opened {
                if time - held.start >= threshold { outcome.openHistory = true }
                else { outcome.replayPaste = true }
            }
            pending = nil
        case .commandReleased, .otherKeyDown:
            guard var held = pending, !held.completed, !held.opened else { return outcome }
            if time - held.start >= threshold {
                held.opened = true
                outcome.openHistory = true
            } else {
                held.completed = true
                outcome.replayPaste = true
            }
            pending = held
        case .deadline(let id):
            guard var held = pending, held.id == id,
                  !held.completed, !held.opened else { return outcome }
            let remaining = threshold - (time - held.start)
            if remaining > 0 {
                outcome.remaining = remaining
                return outcome
            }
            held.opened = true
            pending = held
            outcome.openHistory = true
        }
        return outcome
    }

    mutating func stop() -> Bool {
        defer { pending = nil }
        return pending.map { !$0.completed && !$0.opened } ?? false
    }

    static func verify() -> Bool {
        var quick = CommandVHoldEngine()
        let first = quick.handle(.commandVDown, at: 0, threshold: 0.6)
        guard !first.forward, first.schedule == 1,
              !quick.handle(.commandVDown, at: 0.04, threshold: 0.6).forward,
              !quick.handle(.deadline(1), at: 0.05, threshold: 0.6).openHistory else { return false }
        let released = quick.handle(.vUp, at: 0.12, threshold: 0.6)
        guard !released.forward, released.replayPaste, !released.openHistory,
              !quick.handle(.deadline(1), at: 0.7, threshold: 0.6).openHistory else { return false }

        var long = CommandVHoldEngine()
        let scheduled = long.handle(.commandVDown, at: 1, threshold: 0.6).schedule
        guard let scheduled,
              let early = long.handle(.deadline(scheduled), at: 1.59, threshold: 0.6).remaining,
              early > 0 && early < 0.02,
              long.handle(.deadline(scheduled), at: 1.61, threshold: 0.6).openHistory,
              !long.handle(.deadline(scheduled), at: 1.7, threshold: 0.6).openHistory else { return false }
        let longRelease = long.handle(.vUp, at: 1.8, threshold: 0.6)
        guard !longRelease.forward, !longRelease.replayPaste, !longRelease.openHistory else { return false }

        var interrupted = CommandVHoldEngine()
        _ = interrupted.handle(.commandVDown, at: 2, threshold: 0.6)
        guard interrupted.handle(.commandReleased, at: 2.1, threshold: 0.6).replayPaste,
              !interrupted.handle(.vUp, at: 2.3, threshold: 0.6).replayPaste else { return false }
        var stopped = CommandVHoldEngine()
        _ = stopped.handle(.commandVDown, at: 3, threshold: 0.6)
        guard stopped.stop(), !stopped.isPending else { return false }

        let clipboardThreshold = Double(ShortcutPreferences.defaultClipboardHoldMilliseconds) / 1000
        var clipboard = CommandVHoldEngine()
        _ = clipboard.handle(.commandVDown, at: 0, threshold: clipboardThreshold)
        guard clipboard.handle(.vUp, at: 0.29, threshold: clipboardThreshold).replayPaste,
              let id = clipboard.handle(.commandVDown, at: 1, threshold: clipboardThreshold).schedule,
              !clipboard.handle(.deadline(id), at: 1.29, threshold: clipboardThreshold).openHistory,
              clipboard.handle(.deadline(id), at: 1.31, threshold: clipboardThreshold).openHistory else { return false }
        return !clipboard.handle(.vUp, at: 1.32, threshold: clipboardThreshold).replayPaste
    }
}

@MainActor
final class ShortcutHoldMonitor {
    static func verifyEngine() -> Bool { CommandVHoldEngine.verify() }
    enum StartFailure: LocalizedError {
        case accessDenied
        case eventTapUnavailable

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "请先在“隐私与安全 → \(AccessibilityPermission.paneName)”中允许 Cuts。"
            case .eventTapUnavailable:
                "系统未允许 Cuts 处理长按快捷键，普通按键功能不受影响。"
            }
        }
    }

    private static let syntheticMarker: Int64 = 0x4355545350415354
    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        guard let pointer else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<ShortcutHoldMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return MainActor.assumeIsolated {
            monitor.process(type: type, event: event)
                ? Unmanaged.passUnretained(event) : nil
        }
    }

    var onLongPress: ((ShortcutPreferences.Action) -> Void)?
    var shouldIntercept: ((ShortcutPreferences.Action) -> Bool)?
    var onStoppedUnexpectedly: (() -> Void)?
    private var bindings: [ShortcutPreferences.Binding]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var engine = CommandVHoldEngine()
    private var pendingBinding: ShortcutPreferences.Binding?
    private var originalPID: pid_t?

    init(bindings: [ShortcutPreferences.Binding]) { self.bindings = bindings }

    func replaceBindings(_ bindings: [ShortcutPreferences.Binding]) {
        flushPending()
        self.bindings = bindings
    }

    func start() throws {
        guard AXIsProcessTrusted() else { throw StartFailure.accessDenied }
        guard tap == nil else { return }
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                         place: .headInsertEventTap,
                                         options: .defaultTap,
                                         eventsOfInterest: mask,
                                         callback: Self.callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw StartFailure.eventTapUnavailable
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            throw StartFailure.eventTapUnavailable
        }
    }

    func stop() {
        flushPending()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        self.source = nil
        self.tap = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return true }
        if type == .tapDisabledByTimeout {
            flushPending()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    stop()
                    onStoppedUnexpectedly?()
                }
            }
            return true
        }
        if type == .tapDisabledByUserInput {
            stop()
            onStoppedUnexpectedly?()
            return true
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime
        let signal: HoldSignal
        if let binding = pendingBinding {
            if type == .keyDown {
                signal = code == Int64(binding.chord.keyCode) ? .commandVDown : .otherKeyDown
            } else if type == .keyUp, code == Int64(binding.chord.keyCode) {
                signal = .vUp
            } else if type == .flagsChanged,
                      event.flags.intersection(ShortcutChord.relevant) != binding.chord.flags {
                signal = .commandReleased
            } else { return true }
        } else {
            guard type == .keyDown,
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let binding = bindings.first(where: { $0.chord.matches(code: code, flags: event.flags) }),
                  shouldIntercept?(binding.action) != false
            else { return true }
            pendingBinding = binding
            originalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            signal = .commandVDown
        }
        guard let binding = pendingBinding else { return true }
        let threshold = Double(binding.milliseconds) / 1000
        let outcome = engine.handle(signal, at: now, threshold: threshold)
        if let id = outcome.schedule {
            scheduleDeadline(id, threshold: threshold, delay: threshold, action: binding.action)
        }
        if outcome.replayPaste { Self.post(binding.chord, to: originalPID) }
        if outcome.openHistory {
            DispatchQueue.main.async { [weak self] in self?.fire(binding.action) }
        }
        if !engine.isPending { pendingBinding = nil; originalPID = nil }
        return outcome.forward
    }

    private func scheduleDeadline(_ id: Int, threshold: TimeInterval, delay: TimeInterval,
                                  action: ShortcutPreferences.Action) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, delay)) { [weak self] in
            guard let self else { return }
            let outcome = self.engine.handle(.deadline(id), at: ProcessInfo.processInfo.systemUptime, threshold: threshold)
            if let remainder = outcome.remaining {
                self.scheduleDeadline(id, threshold: threshold, delay: remainder, action: action)
            } else if outcome.openHistory { self.fire(action) }
        }
    }

    private func fire(_ action: ShortcutPreferences.Action) {
        CutsLog.write(.debug, "shortcuts", "long press activated action=\(action.rawValue)")
        onLongPress?(action)
    }

    private func flushPending() {
        if engine.stop(), let binding = pendingBinding { Self.post(binding.chord, to: originalPID) }
        pendingBinding = nil
        originalPID = nil
    }

    static func postUninterceptedPaste(to pid: pid_t) {
        post(.paste, to: pid)
    }

    private static func post(_ chord: ShortcutChord, to pid: pid_t?) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: chord.keyCode, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = chord.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            if let pid { event.postToPid(pid) }
            else { event.post(tap: .cgSessionEventTap) }
        }
    }
}
