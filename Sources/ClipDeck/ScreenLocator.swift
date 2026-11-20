import AppKit
import ApplicationServices

@MainActor
enum ScreenLocator {
    /// Prefer the focused window's screen; the mouse is only a fallback.
    static func screen(for application: NSRunningApplication?) -> NSScreen? {
        if let pid = application?.processIdentifier,
           AXIsProcessTrusted(),
           let rect = focusedWindowFrame(pid: pid) {
            let screens = NSScreen.screens
            let chosen = screens.max { intersectionArea($0.frame, rect) < intersectionArea($1.frame, rect) }
            if let chosen, intersectionArea(chosen.frame, rect) > 0 { return chosen }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func appKitPoint(fromQuartz point: CGPoint) -> NSPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: point.x, y: primaryTop - point.y)
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func focusedWindowFrame(pid: pid_t) -> NSRect? {
        let app = AXUIElementCreateApplication(pid)
        // A hung source app must not block the menu bar or keyboard for seconds.
        AXUIElementSetMessagingTimeout(app, 0.08)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        // Messaging timeouts belong to each AX element; the application's
        // timeout is not inherited by the returned window object.
        AXUIElementSetMessagingTimeout(window, 0.08)
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size) else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: position.x, y: primaryTop - position.y - size.height, width: size.width, height: size.height)
    }
}
