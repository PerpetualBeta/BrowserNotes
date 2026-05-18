import AppKit

enum JorvikWindowHelper {
    /// Centres a window on the display that currently has the mouse cursor.
    static func centreOnActiveDisplay(_ window: NSWindow) {
        // Find the screen containing the mouse
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main

        guard let screen = activeScreen else {
            window.center()
            return
        }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Convert an Accessibility-API rectangle to an AppKit rectangle.
    ///
    /// AX coordinates have origin at the top-left of the **primary** display
    /// (the one with the menu bar) and y increases downward. AppKit
    /// coordinates have origin at the bottom-left of the primary display
    /// and y increases upward.
    ///
    /// Critically, the y-flip pivot is the *primary* screen's height — **not**
    /// `NSScreen.main`'s height. On Tahoe (macOS 26.x), `NSScreen.main`
    /// reports the menu-bar-bearing primary display rather than the
    /// keyboard-focused window's screen, but even on earlier macOS
    /// versions where it tracked focus, using `main` would be wrong when
    /// the focused window lives on a display whose height differs from
    /// the primary's. The primary's height is always the correct pivot.
    static func axRectToAppKit(_ axRect: CGRect) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: axRect.origin.x,
                      y: primaryH - axRect.origin.y - axRect.size.height,
                      width: axRect.size.width,
                      height: axRect.size.height)
    }

    /// Find the NSScreen whose `frame` contains the given AppKit point.
    /// Falls back to `NSScreen.main` and then the primary screen if no
    /// screen contains the point (e.g. coordinates briefly off-screen
    /// during a window move). Never returns nil — at least one screen
    /// is always attached.
    static func screenContaining(_ point: NSPoint) -> NSScreen {
        if let s = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    /// Query the focused window of `pid` via the Accessibility API and
    /// return its frame in AppKit coordinates. `nil` if AX is unavailable
    /// (permission denied, app not responding, no focused window).
    static func axFocusedWindowFrame(pid: pid_t) -> NSRect? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success,
              let window = windowVal
        else { return nil }

        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue)
        guard let pv = posValue, let sv = sizeValue else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)

        return axRectToAppKit(CGRect(origin: pos, size: size))
    }
}
