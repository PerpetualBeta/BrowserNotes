import AppKit
import ApplicationServices

/// Reads browser URL via the Accessibility API — no JS injection required.
enum AccessibilityReader {

    /// AX messages to an unresponsive app block for 6 seconds each by default;
    /// a stalled browser must not wedge a traversal for minutes.
    private static let axMessagingTimeout: Float = 0.5

    /// Reads the current URL from the browser's address bar via AX tree traversal
    static func getCurrentURL(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
        var windowVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success else {
            return nil
        }
        let result = findURLBar(windowVal as! AXUIElement)
        return result
    }

    /// Window-title suffixes browsers append after the page title
    private static let browserSuffixNames: Set<String> = [
        "Safari", "Safari Technology Preview",
        "Google Chrome", "Google Chrome Canary", "Chromium",
        "Microsoft Edge", "Brave", "Opera", "Vivaldi", "Arc", "Orion",
        "Zen Browser", "SigmaOS",
        "Mozilla Firefox", "Firefox Developer Edition", "Firefox Nightly",
        "Mozilla Firefox Private Browsing", "Private Browsing",
        "Waterfox", "LibreWolf", "Mullvad Browser", "Tor Browser",
    ]

    private static let titleSeparators = [" \u{2014} ", " \u{2013} ", " - "]  // em dash, en dash, hyphen

    /// Titles browsers give pages that have no real title
    private static let placeholderTitles: Set<String> = [
        "new tab", "untitled", "start page", "about:blank",
    ]

    /// Reads the focused window's title — in every mainstream browser this is the
    /// page title, sometimes suffixed with the browser's own name. Returns nil
    /// when a usable page title can't be reliably extracted.
    static func getPageTitle(pid: pid_t, browserName: String?, url: String) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
        var windowVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success else {
            return nil
        }
        var titleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(windowVal as! AXUIElement, kAXTitleAttribute as CFString, &titleVal)
        guard let raw = titleVal as? String else { return nil }

        var suffixes = browserSuffixNames
        if let browserName, !browserName.isEmpty { suffixes.insert(browserName) }

        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for sep in titleSeparators {
                for name in suffixes where title.hasSuffix(sep + name) {
                    title = String(title.dropLast(sep.count + name.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    stripped = true
                }
            }
        }

        guard !title.isEmpty, !placeholderTitles.contains(title.lowercased()) else { return nil }

        // Some browsers title an untitled page with its URL — not a page title
        let bareURL = url.replacingOccurrences(of: "https://", with: "")
                         .replacingOccurrences(of: "http://", with: "")
        if title.caseInsensitiveCompare(url) == .orderedSame { return nil }
        if !bareURL.isEmpty, title.caseInsensitiveCompare(bareURL) == .orderedSame { return nil }

        return title
    }

    /// Returns the raw text from the address bar, even if it doesn't look like a URL
    static func getRawAddressBarText(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
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

        // The address bar is browser chrome — never inside the page itself.
        // Descending into AXWebArea crawls the whole web page's AX tree:
        // thousands of IPC round-trips on a heavy page.
        if role == "AXWebArea" { return nil }

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

        // The address bar is browser chrome — never inside the page itself.
        // Descending into AXWebArea crawls the whole web page's AX tree:
        // thousands of IPC round-trips on a heavy page.
        if role == "AXWebArea" { return nil }

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
