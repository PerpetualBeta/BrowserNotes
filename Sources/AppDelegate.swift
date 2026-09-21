import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import Sparkle

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    let engine = BrowserNotesEngine()

    // @ObservationIgnored — @Observable's macro can't transform `lazy`,
    // and Sparkle's controller isn't observable state anyway.
    @ObservationIgnored let sparkleUserDriverDelegate = BrowserNotesUserDriverDelegate()
    @ObservationIgnored lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )

    var notesBrowserKeyCode: UInt16 = {
        let val = UserDefaults.standard.object(forKey: "notesBrowserKeyCode")
        return val != nil ? UInt16(UserDefaults.standard.integer(forKey: "notesBrowserKeyCode")) : 4  // H
    }() {
        didSet {
            UserDefaults.standard.set(Int(notesBrowserKeyCode), forKey: "notesBrowserKeyCode")
            engine.updateNotesBrowserHotkey(keyCode: notesBrowserKeyCode, modifiers: notesBrowserModifiers)
        }
    }

    var notesBrowserModifiers: NSEvent.ModifierFlags = {
        let val = UserDefaults.standard.object(forKey: "notesBrowserModifiers")
        if let raw = val as? UInt { return NSEvent.ModifierFlags(rawValue: raw) }
        return [.command, .control, .option, .shift]
    }() {
        didSet {
            UserDefaults.standard.set(notesBrowserModifiers.rawValue, forKey: "notesBrowserModifiers")
            engine.updateNotesBrowserHotkey(keyCode: notesBrowserKeyCode, modifiers: notesBrowserModifiers)
        }
    }

    var addNoteKeyCode: UInt16 = {
        let val = UserDefaults.standard.object(forKey: "addNoteKeyCode")
        return val != nil ? UInt16(UserDefaults.standard.integer(forKey: "addNoteKeyCode")) : 45  // N
    }() {
        didSet {
            UserDefaults.standard.set(Int(addNoteKeyCode), forKey: "addNoteKeyCode")
            engine.updateAddNoteHotkey(keyCode: addNoteKeyCode, modifiers: addNoteModifiers)
        }
    }

    var addNoteModifiers: NSEvent.ModifierFlags = {
        let val = UserDefaults.standard.object(forKey: "addNoteModifiers")
        if let raw = val as? UInt { return NSEvent.ModifierFlags(rawValue: raw) }
        return [.command, .control, .option, .shift]
    }() {
        didSet {
            UserDefaults.standard.set(addNoteModifiers.rawValue, forKey: "addNoteModifiers")
            engine.updateAddNoteHotkey(keyCode: addNoteKeyCode, modifiers: addNoteModifiers)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // There is no SwiftUI App to build a menu bar for us, so build one. It is
        // never drawn — an accessory app has no menu bar — but AppKit routes key
        // equivalents through it, which is what makes Command+Q quit and the
        // editing shortcuts work in the settings window's text fields.
        JorvikApplicationMenu.install()

        migrateLegacyPillColorKey()

        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch

        engine.start()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.updateIcon()
                if self.engine.isActive { timer.invalidate() }
            }
        }

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave the pre-rendered pill cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }

        // Create or remove the status item when the user toggles its
        // visibility in Settings.
        NotificationCenter.default.addObserver(
            forName: JorvikStatusItemVisibility.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyStatusItemVisibility() }
        }
    }

    private func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the item's menu-bar slot across launches (and let a user ⌘-drag stick).
        item.autosaveName = "BrowserNotesStatusItem"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { engine.stop() }

    // One-shot removal of the user-chosen pill colour key from the old design.
    // The new pill uses fixed grey/light colours; the key is dead weight.
    private func migrateLegacyPillColorKey() {
        let migrated = "didMigratePillColorV2"
        if UserDefaults.standard.bool(forKey: migrated) { return }
        UserDefaults.standard.removeObject(forKey: "menuBarPillColor")
        UserDefaults.standard.set(true, forKey: migrated)
    }

    func refreshPill() { updateIcon() }

    private func updateIcon() {
        statusItem?.button?.image = JorvikMenuBarPill.icon(
            symbolName: "highlighter",
            accessibilityDescription: "Browser Notes"
        )
    }

    func notesBrowserShortcutDisplayString() -> String {
        JorvikShortcutPanel.displayString(keyCode: notesBrowserKeyCode, modifiers: notesBrowserModifiers)
    }

    func addNoteShortcutDisplayString() -> String {
        JorvikShortcutPanel.displayString(keyCode: addNoteKeyCode, modifiers: addNoteModifiers)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()
        var actions: [JorvikMenuBuilder.ActionItem] = []
        actions.append(JorvikMenuBuilder.ActionItem(
            title: engine.isEnabled ? "Disable" : "Enable",
            action: #selector(toggleEnabled), target: self, keyEquivalent: ""
        ))
        actions.append(JorvikMenuBuilder.ActionItem(title: "-", action: #selector(noop), target: self))
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Export Notes\u{2026}", action: #selector(exportNotes), target: self, keyEquivalent: ""
        ))
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Import Notes\u{2026}", action: #selector(importNotes), target: self, keyEquivalent: ""
        ))
        actions.append(JorvikMenuBuilder.ActionItem(title: "-", action: #selector(noop), target: self))
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Check for Updates\u{2026}", action: #selector(checkForUpdates(_:)), target: self
        ))
        let built = JorvikMenuBuilder.buildMenu(
            appName: "Browser Notes",
            aboutAction: #selector(openAbout), settingsAction: #selector(openSettings),
            target: self, actions: actions
        )
        menu.removeAllItems()
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }

    @objc private func toggleEnabled() { engine.isEnabled.toggle(); updateIcon() }
    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }
    @objc private func noop() {}

    @objc private func exportNotes() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BrowserNotes-Export.xml"
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let xml = NoteStore.shared.exportXML()
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func importNotes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let xml = try String(contentsOf: url, encoding: .utf8)
            let count = NoteStore.shared.importXML(xml)
            let alert = NSAlert()
            alert.messageText = "Import Complete"
            alert.informativeText = "\(count) note\(count == 1 ? "" : "s") imported."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openAbout() {
        JorvikAboutView.showWindow(appName: "Browser Notes", repoName: "BrowserNotes", productPage: "utilities/browsernotes")
    }

    @objc private func openSettings() {
        let delegate = self
        JorvikSettingsView.showWindow(appName: "Browser Notes") {
            BrowserNotesSettingsContent(delegate: delegate)
        }
    }
}

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class BrowserNotesUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}
