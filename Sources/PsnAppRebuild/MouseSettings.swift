import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

struct MouseSettings: Equatable {
    var reverseVertical = false
    var reverseHorizontal = false
    var speed = 1.0
    var onlyDiscreteWheels = true
    var sideButtonsNavigate = false

    var needsMonitor: Bool {
        reverseVertical || reverseHorizontal || abs(speed - 1) > 0.001 || sideButtonsNavigate
    }

    static var saved: Self {
        let defaults = UserDefaults.standard
        let rawSpeed = defaults.object(forKey: "cuts.mouse.speed") as? Double ?? 1.0
        return Self(reverseVertical: defaults.bool(forKey: "cuts.mouse.reverseVertical"),
                    reverseHorizontal: defaults.bool(forKey: "cuts.mouse.reverseHorizontal"),
                    speed: min(3, max(0.5, rawSpeed)),
                    onlyDiscreteWheels: defaults.object(forKey: "cuts.mouse.onlyDiscreteWheels") as? Bool ?? true,
                    sideButtonsNavigate: defaults.bool(forKey: "cuts.mouse.sideButtonsNavigate"))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(reverseVertical, forKey: "cuts.mouse.reverseVertical")
        defaults.set(reverseHorizontal, forKey: "cuts.mouse.reverseHorizontal")
        defaults.set(speed, forKey: "cuts.mouse.speed")
        defaults.set(onlyDiscreteWheels, forKey: "cuts.mouse.onlyDiscreteWheels")
        defaults.set(sideButtonsNavigate, forKey: "cuts.mouse.sideButtonsNavigate")
    }

    static func verify() -> Bool {
        let defaults = Self()
        guard !defaults.needsMonitor else { return false }
        var changed = defaults
        changed.reverseVertical = true
        guard changed.needsMonitor else { return false }
        changed.reverseVertical = false
        changed.speed = 1.5
        return changed.needsMonitor && changed.speed >= 0.5 && changed.speed <= 3
    }
}

@MainActor
final class MouseEventMonitor {
    static func verifySynthetic() -> Bool {
        var config = MouseSettings()
        config.reverseVertical = true
        config.speed = 2
        let monitor = MouseEventMonitor(settings: config)
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0),
              monitor.process(type: .scrollWheel, event: wheel),
              wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -6,
              wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -4 else { return false }
        guard let continuous = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                       wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return false }
        continuous.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        continuous.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 1.25)
        continuous.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 7)
        // High-resolution wheels can be pixel-based without a gesture phase.
        guard monitor.process(type: .scrollWheel, event: continuous),
              continuous.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0,
              continuous.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -2.5,
              continuous.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -14 else { return false }
        guard let gesture = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                    wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) else { return false }
        gesture.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        gesture.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        guard monitor.process(type: .scrollWheel, event: gesture),
              gesture.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 5,
              monitor.lastScroll == .preservedGesture else { return false }
        config.onlyDiscreteWheels = false
        monitor.settings = config
        guard monitor.process(type: .scrollWheel, event: gesture),
              gesture.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -10,
              monitor.lastScroll == .modified else { return false }
        return true
    }

    enum StartFailure: LocalizedError {
        case accessDenied
        case eventTapUnavailable

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "请先在“隐私与安全 → \(AccessibilityPermission.paneName)”中允许 Cuts。"
            case .eventTapUnavailable:
                "系统无法启用鼠标事件处理，请确认其他鼠标工具没有占用相同功能。"
            }
        }
    }

    static let marker: Int64 = 0x435554534D4F5553
    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        guard let pointer else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<MouseEventMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return MainActor.assumeIsolated {
            monitor.process(type: type, event: event)
                ? Unmanaged.passUnretained(event) : nil
        }
    }

    enum ScrollResult: Equatable {
        case preservedGesture, modified
    }

    var settings: MouseSettings {
        didSet {
            guard settings != oldValue else { return }
            verticalRemainder = 0
            horizontalRemainder = 0
            lastScroll = nil
        }
    }
    private(set) var lastScroll: ScrollResult?
    var onScrollResult: ((ScrollResult) -> Void)?
    var onStoppedUnexpectedly: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var verticalRemainder = 0.0
    private var horizontalRemainder = 0.0

    init(settings: MouseSettings) { self.settings = settings }

    func start() throws {
        guard AXIsProcessTrusted() else { throw StartFailure.accessDenied }
        guard tap == nil else { return }
        let events: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp]
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        self.tap = nil
        self.source = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) { stop(); onStoppedUnexpectedly?() }
            }
            return true
        }
        if type == .tapDisabledByUserInput {
            stop()
            onStoppedUnexpectedly?()
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        if type == .scrollWheel {
            guard settings.reverseVertical || settings.reverseHorizontal || abs(settings.speed - 1) > 0.001 else {
                return true
            }
            let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0
                || event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0
                || event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) != 0
            let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0
                || event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0
                || event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2) != 0
            let affectsScroll = (vertical && settings.reverseVertical) || (horizontal && settings.reverseHorizontal)
                || ((vertical || horizontal) && abs(settings.speed - 1) > 0.001)
            let isGesture = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                && (event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
                    || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
            if settings.onlyDiscreteWheels && isGesture {
                if affectsScroll { record(.preservedGesture) }
                return true
            }
            modifyScroll(event, axis: 1, reverse: settings.reverseVertical,
                         remainder: &verticalRemainder)
            modifyScroll(event, axis: 2, reverse: settings.reverseHorizontal,
                         remainder: &horizontalRemainder)
            if affectsScroll { record(.modified) }
            return true
        }
        guard settings.sideButtonsNavigate else { return true }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return true }
        if type == .otherMouseDown {
            DispatchQueue.main.async { [weak self] in self?.postNavigate(back: button == 3) }
        }
        return false
    }

    private func record(_ result: ScrollResult) {
        guard lastScroll != result else { return }
        lastScroll = result
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastScroll == result, self.tap != nil else { return }
            CutsLog.write(.debug, "mouse", result == .modified ? "scroll transformed" : "gesture-style scroll preserved")
            self.onScrollResult?(result)
        }
    }

    private func modifyScroll(_ event: CGEvent, axis: Int, reverse: Bool,
                              remainder: inout Double) {
        let factor = settings.speed * (reverse ? -1.0 : 1.0)
        guard abs(factor - 1) > 0.001 else { return }
        let line: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let fixed: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let point: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let rawLine = Double(event.getIntegerValueField(line)) * factor + remainder
        let fixedValue = event.getDoubleValueField(fixed) * factor
        let pointValue = Double(event.getIntegerValueField(point)) * factor
        let lineValue = Int64(rawLine.rounded(.towardZero))
        remainder = rawLine - Double(lineValue)
        // Writing the line delta makes Quartz recalculate both other fields.
        // A high-resolution wheel can send pixels and fractions with zero lines.
        event.setIntegerValueField(line, value: lineValue)
        event.setDoubleValueField(fixed, value: fixedValue)
        event.setIntegerValueField(point, value: Int64(pointValue.rounded()))
    }

    private func postNavigate(back: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let key = CGKeyCode(back ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
