import AppKit
import ApplicationServices
import CoreGraphics

// Called only while the capture overlay is visible. Accessibility hit testing is bounded
// by a short timeout; when unavailable, the containing application window is used.
enum WindowContourDetector {
    static func target(at local: CGPoint, screenFrame: CGRect, mainTop: CGFloat, useAccessibility: Bool) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return nil }
        let screenPoint = CGPoint(x: local.x + screenFrame.minX, y: local.y + screenFrame.minY)
        let quartzPoint = CGPoint(x: screenPoint.x, y: mainTop - screenPoint.y)
        for info in windows {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  pid != Int(ProcessInfo.processInfo.processIdentifier),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  windowBounds.contains(quartzPoint), windowBounds.width >= 16,
                  windowBounds.height >= 16 else { continue }
            let target = useAccessibility && AXIsProcessTrusted()
                ? accessibleElement(pid: pid_t(pid), point: quartzPoint, inside: windowBounds) ?? windowBounds
                : windowBounds
            let cocoa = CGRect(x: target.minX, y: mainTop - target.maxY,
                               width: target.width, height: target.height)
            let localRect = cocoa.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                .intersection(CGRect(origin: .zero, size: screenFrame.size))
            if localRect.width >= 16 && localRect.height >= 16 { return localRect }
        }
        return nil
    }

    private static func accessibleElement(pid: pid_t, point: CGPoint, inside window: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var current: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &current) == .success else { return nil }
        for _ in 0..<7 {
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, 0.05)
            if let rect = elementFrame(element), rect.contains(point),
               rect.width >= 16, rect.height >= 16,
               rect.width <= window.width, rect.height <= window.height,
               window.intersection(rect).width >= rect.width * 0.8,
               window.intersection(rect).height >= rect.height * 0.8 { return rect }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
