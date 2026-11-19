import CoreFoundation
import Darwin
import Foundation

/// Applies macOS's mouse (not trackpad) tracking speed once, without a per-movement event tap.
enum MouseTrackingSpeed {
    enum Failure: LocalizedError {
        case unavailable
        case invalidValue
        case rejected(Int32)
        case notApplied

        var errorDescription: String? {
            switch self {
            case .unavailable: "当前系统无法读取或设置鼠标指针速度。"
        case .invalidValue: "指针灵敏度必须在 0.125–3.0 之间。"
            case .rejected(let code): "系统拒绝更改鼠标指针速度（\(code)）。"
            case .notApplied: "系统或其他鼠标工具覆盖了指针速度设置。"
            }
        }
    }

    private typealias Open = @convention(c) () -> UInt32
    private typealias Get = @convention(c) (UInt32, CFString, UnsafeMutablePointer<Double>) -> Int32
    private typealias Set = @convention(c) (UInt32, CFString, Double) -> Int32

    private struct Functions {
        let open: Open
        let get: Get
        let set: Set
    }

    private static let functions: Functions? = {
        guard let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let kit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let open = dlsym(services, "NXOpenEventStatus"),
              let get = dlsym(kit, "IOHIDGetAccelerationWithKey"),
              let set = dlsym(kit, "IOHIDSetAccelerationWithKey") else { return nil }
        return Functions(open: unsafeBitCast(open, to: Open.self),
                         get: unsafeBitCast(get, to: Get.self),
                         set: unsafeBitCast(set, to: Set.self))
    }()

    private static let savedKey = "cuts.mouse.pointerSpeed"
    static let steps: [Double] = [0.125, 0.5, 0.6875, 0.875, 1.0, 1.5, 2.0, 2.5, 3.0]
    private static let key = CFStringCreateWithCString(nil, "HIDMouseAcceleration",
                                                      CFStringBuiltInEncodings.UTF8.rawValue)!

    static var saved: Double? {
        guard let value = UserDefaults.standard.object(forKey: savedKey) as? Double,
              (0.125...3).contains(value) else { return nil }
        return value
    }

    static func current() -> Double? {
        guard let functions else { return nil }
        var value = 0.0
        let result = functions.get(functions.open(), key, &value)
        return result == 0 && value.isFinite ? value : nil
    }

    static func apply(_ value: Double, remember: Bool = true) throws {
        guard value.isFinite, (0.125...3).contains(value) else { throw Failure.invalidValue }
        guard let functions else { throw Failure.unavailable }
        let result = functions.set(functions.open(), key, value)
        guard result == 0 else { throw Failure.rejected(result) }
        guard let actual = current(), abs(actual - value) < 0.13 else { throw Failure.notApplied }
        if remember { UserDefaults.standard.set(value, forKey: savedKey) }
        CutsLog.write(.info, "mouse", "pointer tracking readback requested=\(value) observed=\(actual)")
    }

    static func reapplySaved() {
        guard let saved else { return }
        try? apply(saved, remember: false)
    }

    static func nearestStep(to value: Double) -> Int {
        steps.indices.min(by: { abs(steps[$0] - value) < abs(steps[$1] - value) }) ?? 0
    }

    static func verify() -> Bool {
        steps.first == 0.125 && steps.last == 3.0
            && nearestStep(to: 0.7) == 2 && nearestStep(to: 2.0) == 6
            && savedKey.hasPrefix("cuts.mouse.")
    }
}
