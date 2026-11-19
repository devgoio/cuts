import Foundation

enum AccessibilityPermission {
    static var paneName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 27 && version.minorVersion < 3
            ? "设备控制和数据访问" : "无障碍"
    }

    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
