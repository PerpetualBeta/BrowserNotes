import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    let engine = BrowserNotesEngine()
    let updateChecker = JorvikUpdateChecker(repoName: "BrowserNotes")

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
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        JorvikMenuBarPill.apply(to: statusItem.button!)
        updateChecker.checkOnSchedule()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil
        )

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

    @objc private func appearanceChanged() {
        if let button = statusItem.button { JorvikMenuBarPill.refresh(on: button) }
    }

    func refreshPill() {
        if let button = statusItem.button { JorvikMenuBarPill.apply(to: button) }
    }

    private func updateIcon() {
        if let image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Browser Notes") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
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
        let built = JorvikMenuBuilder.buildMenu(
            appName: "Browser Notes",
            aboutAction: #selector(openAbout), settingsAction: #selector(openSettings),
            target: self, actions: actions
        )
        menu.removeAllItems()
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }

    @objc private func toggleEnabled() { engine.isEnabled.toggle(); updateIcon() }
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
