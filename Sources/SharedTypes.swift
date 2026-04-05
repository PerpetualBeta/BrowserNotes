import AppKit
import ApplicationServices

/// Bundle IDs of known web browsers
let browserBundleIDs: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
    "company.thebrowser.Browser",       // Arc
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "com.kagi.kagimacOS",               // Orion
    "org.chromium.Chromium",
    "com.nickvision.nicegram",
    "app.zen-browser.zen",              // Zen Browser
]

/// AX roles that indicate the focused element is a text input
private let textInputRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
]

/// Uses the Accessibility API to check if the currently focused UI element is a text input
func isTextFieldFocused(pid: pid_t) -> Bool {
    let axApp = AXUIElementCreateApplication(pid)

    var focusedValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedValue)
    guard result == .success else { return true }

    let element = focusedValue as! AXUIElement
    var roleValue: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)

    if let role = roleValue as? String {
        if textInputRoles.contains(role) { return true }
        if role == "AXWebArea" || role == "AXGroup" {
            var focusedChild: CFTypeRef?
            let childResult = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedChild)
            if childResult == .success {
                let child = focusedChild as! AXUIElement
                var childRole: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRole)
                if let cr = childRole as? String, textInputRoles.contains(cr) { return true }
            }
        }
    }

    var subroleValue: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
    if let subrole = subroleValue as? String {
        if subrole.contains("Text") || subrole.contains("Search") { return true }
    }

    return false
}

// MARK: - Browser Navigation via AppleScript

private let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.canary",
    "com.microsoft.edgemac", "com.brave.Browser",
    "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser", "org.chromium.Chromium",
    "app.zen-browser.zen",
]

private let safariBundleIDs: Set<String> = [
    "com.apple.Safari", "com.apple.SafariTechnologyPreview",
]

/// Navigates the current tab of the given browser to a URL via osascript
func navigateBrowserTab(bundleID: String, url: String) {
    let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

    let script: String
    if safariBundleIDs.contains(bundleID) {
        script = "tell application id \"\(bundleID)\" to set URL of document 1 to \"\(escaped)\""
    } else if chromiumBundleIDs.contains(bundleID) {
        script = "tell application id \"\(bundleID)\" to set URL of active tab of front window to \"\(escaped)\""
    } else {
        script = "tell application id \"\(bundleID)\" to open location \"\(escaped)\""
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

// MARK: - HUD Panel

@MainActor
protocol HUDKeyPanelDelegate: AnyObject {
    func moveSelectionUp()
    func moveSelectionDown()
    func activateSelected()
    func deleteSelected()
    func dismiss()
}

/// NSPanel subclass that can become key without activating the app
final class HUDKeyPanel: NSPanel {
    weak var hudDelegate: (any HUDKeyPanelDelegate)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let hasCmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 126: hudDelegate?.moveSelectionUp()
        case 125: hudDelegate?.moveSelectionDown()
        case 36:  hudDelegate?.activateSelected()
        case 51 where hasCmd: hudDelegate?.deleteSelected()  // Cmd+Backspace
        case 53:  hudDelegate?.dismiss()
        default:  super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        hudDelegate?.dismiss()
    }
}

/// Simple NSView subclass for colour dot identification in table cells
final class ColourDotView: NSView {}
