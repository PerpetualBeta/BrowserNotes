import AppKit
import ApplicationServices

/// Reads browser URL via the Accessibility API — no JS injection required.
enum AccessibilityReader {

    /// Reads the current URL from the browser's address bar via AX tree traversal
    static func getCurrentURL(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success else {
            return nil
        }
        let result = findURLBar(windowVal as! AXUIElement)
        return result
    }

    /// Returns the raw text from the address bar, even if it doesn't look like a URL
    static func getRawAddressBarText(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success else {
            return nil
        }
        return findAddressBarText(windowVal as! AXUIElement)
    }

    private static func findAddressBarText(_ element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 12 { return nil }

        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String ?? ""

        if role == "AXTextField" || role == "AXComboBox" {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
            if let val = valRef as? String, !val.isEmpty {
                return val
            }
        }

        var childrenVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
        guard let children = childrenVal as? [AXUIElement] else { return nil }
        for child in children {
            if let text = findAddressBarText(child, depth: depth + 1) { return text }
        }
        return nil
    }

    // MARK: - AX tree traversal

    private static func findURLBar(_ element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 12 { return nil }

        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String ?? ""

        if role == "AXTextField" || role == "AXComboBox" {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
            let val = valRef as? String ?? ""

            let isURL = (val.contains(".") && (val.hasPrefix("http") || val.hasPrefix("www") || val.contains("/")))
                || val.contains("://")
                || val.hasPrefix("localhost")

            if isURL {
                if val.hasPrefix("http") || val.contains("://") {
                    return val
                } else if val.hasPrefix("localhost") {
                    return "http://" + val
                } else {
                    return "https://" + val
                }
            }
        }

        var childrenVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
        guard let children = childrenVal as? [AXUIElement] else { return nil }
        for child in children {
            if let url = findURLBar(child, depth: depth + 1) { return url }
        }
        return nil
    }
}
