import CoreGraphics

@MainActor
enum ScreenCapturePermission {
    private static var requestedThisLaunch = false

    static func checkOrRequest() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard !requestedThisLaunch else { return false }
        requestedThisLaunch = true
        return CGRequestScreenCaptureAccess()
    }
}
