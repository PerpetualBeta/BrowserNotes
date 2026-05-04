import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import Sparkle

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    let engine = BrowserNotesEngine()
    let updateChecker = JorvikUpdateChecker(repoName: "BrowserNotes")

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
        migrateLegacyPillColorKey()

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        // Sparkle handles update polling now. JorvikUpdateChecker instance
        // remains because JorvikSettingsView.showWindow still requires one
        // as a parameter, pending JorvikKit retirement (§11.5).
        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch
        // updateChecker.checkOnSchedule()  // disabled — Sparkle owns this now

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.start()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.updateIcon()
                if self.engine.isActive { timer.invalidate() }
            }
        }
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
        statusItem.button?.image = JorvikMenuBarPill.icon(
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
    @objc func checkForUpdates(_ sender: Any?) { sparkleUpdater.checkForUpdates(sender) }
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
        JorvikSettingsView.showWindow(appName: "Browser Notes", updateChecker: updateChecker) {
            BrowserNotesSettingsContent(delegate: delegate)
        }
    }
}

/// LSUIElement apps don't auto-activate when they present windows, so
/// Sparkle's update dialogs would appear behind whatever app is currently
/// key. This brings Browser Notes frontmost just before each modal.
final class BrowserNotesUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
