import AppKit
import ApplicationServices

// MARK: - Module-level state

private var _markerTap: CFMachPort?
var _isEnabled: Bool = true
private var _onAction: ((MarkerAction) -> Void)?
private var _notesBrowserKeyCode: UInt16 = 4   // H
private var _notesBrowserModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
private var _addNoteKeyCode: UInt16 = 45        // N
private var _addNoteModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

enum MarkerAction {
    case showNotesBrowser(pid: pid_t)
    case addNote(bundleID: String, pid: pid_t)
}

// MARK: - CGEvent tap callback

private func markerCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = _markerTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }

    guard _isEnabled, type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        .intersection([.command, .control, .option, .shift])

    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let bundleID = frontApp.bundleIdentifier,
          browserBundleIDs.contains(bundleID)
    else {
        return Unmanaged.passRetained(event)
    }

    // Notes Browser hotkey
    let nbMods = _notesBrowserModifiers.intersection([.command, .control, .option, .shift])
    if keyCode == _notesBrowserKeyCode && modifiers.contains(nbMods) {
        let pid = frontApp.processIdentifier
        DispatchQueue.main.async { _onAction?(.showNotesBrowser(pid: pid)) }
        return nil
    }

    // Add Note hotkey
    let anMods = _addNoteModifiers.intersection([.command, .control, .option, .shift])
    if keyCode == _addNoteKeyCode && modifiers.contains(anMods) {
        let pid = frontApp.processIdentifier
        let bid = bundleID
        DispatchQueue.main.async { _onAction?(.addNote(bundleID: bid, pid: pid)) }
        return nil
    }

    return Unmanaged.passRetained(event)
}

// MARK: - BrowserNotesEngine

@MainActor
@Observable
final class BrowserNotesEngine {
    var isActive: Bool = false
    var permissionGranted: Bool = false
    var isEnabled: Bool = true {
        didSet {
            _isEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: "browserNotesEnabled")
        }
    }

    private var eventTap: CFMachPort?
    private var permissionTimer: Timer?
    private let notesBrowserHUD = NotesBrowserHUD()
    private let addNoteHUD = AddNoteHUD()
    private let pageNotesHUD = PageNotesHUD()
    private var urlPollTimer: Timer?
    private var lastKnownURL: String = ""
    private var pageNotesDismissedForURL: String = ""

    func updateNotesBrowserHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        _notesBrowserKeyCode = keyCode
        _notesBrowserModifiers = modifiers
        republishHotkeys()
    }

    func updateAddNoteHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        _addNoteKeyCode = keyCode
        _addNoteModifiers = modifiers
        republishHotkeys()
    }

    /// Publish current bindings to the JorvikKit registry. Both are browser-only.
    private func republishHotkeys() {
        JorvikHotkeyRegistry.publish([
            JorvikHotkey(actionTitle: "Open Notes Browser",
                         keyCode: _notesBrowserKeyCode,
                         modifiers: _notesBrowserModifiers,
                         activeContext: .browser),
            JorvikHotkey(actionTitle: "Add Note for Page",
                         keyCode: _addNoteKeyCode,
                         modifiers: _addNoteModifiers,
                         activeContext: .browser),
        ])
    }

    func start() {
        guard !isActive else { return }

        isEnabled = UserDefaults.standard.object(forKey: "browserNotesEnabled") != nil
            ? UserDefaults.standard.bool(forKey: "browserNotesEnabled")
            : true
        _isEnabled = isEnabled

        if UserDefaults.standard.object(forKey: "notesBrowserKeyCode") != nil {
            _notesBrowserKeyCode = UInt16(UserDefaults.standard.integer(forKey: "notesBrowserKeyCode"))
            _notesBrowserModifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "notesBrowserModifiers")))
        }
        if UserDefaults.standard.object(forKey: "addNoteKeyCode") != nil {
            _addNoteKeyCode = UInt16(UserDefaults.standard.integer(forKey: "addNoteKeyCode"))
            _addNoteModifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "addNoteModifiers")))
        }

        republishHotkeys()

        NoteStore.shared.open()

        addNoteHUD.onNoteSaved = { [weak self] in self?.refreshPageNotesHUD() }
        addNoteHUD.onNoteEdited = { [weak self] in self?.refreshPageNotesHUD() }
        notesBrowserHUD.onNoteDeleted = { [weak self] in self?.refreshPageNotesHUD() }
        pageNotesHUD.onEditNote = { [weak self] note in
            guard let self, let frontApp = NSWorkspace.shared.frontmostApplication else { return }
            self.addNoteHUD.showForEdit(note: note, browserPID: frontApp.processIdentifier)
        }

        _onAction = { action in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch action {
                case .showNotesBrowser(let pid):
                    self.notesBrowserHUD.show(browserPID: pid)
                case .addNote(let bundleID, let pid):
                    self.showAddNote(bundleID: bundleID, pid: pid)
                }
            }
        }

        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        permissionGranted = trusted

        if trusted {
            if tryCreateEventTap() {
                isActive = true
                startURLPolling()
            }
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.permissionGranted = true
                        if self.tryCreateEventTap() {
                            self.isActive = true
                            self.startURLPolling()
                        }
                    }
                }
            }
        }
    }

    func stop() {
        isActive = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        urlPollTimer?.invalidate()
        urlPollTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTap = nil
        _markerTap = nil
    }

    // MARK: - Refresh page notes HUD

    private func refreshPageNotesHUD() {
        let normURL = lastKnownURL
        let notes = NoteStore.shared.notesForURL(normURL)
        if notes.isEmpty {
            pageNotesHUD.dismiss()
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            pageNotesDismissedForURL = ""
            pageNotesHUD.show(notes: notes, url: normURL, browserPID: frontApp.processIdentifier) { [weak self] in
                self?.pageNotesDismissedForURL = normURL
            }
        }
    }

    // MARK: - Add Note

    private func showAddNote(bundleID: String, pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = AccessibilityReader.getCurrentURL(pid: pid) ?? ""
            DispatchQueue.main.async {
                self?.addNoteHUD.show(url: url, browserPID: pid)
            }
        }
    }

    // MARK: - URL polling for page notes HUD

    private func startURLPolling() {
        urlPollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pollCurrentURL()
            }
        }
    }

    private func pollCurrentURL() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let isBrowser = bundleID.map { browserBundleIDs.contains($0) } ?? false
        let isSelf = bundleID == Bundle.main.bundleIdentifier

        guard isBrowser, let frontApp else {
            // Don't dismiss when our own app is frontmost (user interacting with HUD)
            if !isSelf, pageNotesHUD.isVisible {
                pageNotesHUD.dismiss()
                pageNotesDismissedForURL = ""
            }
            return
        }

        let pid = frontApp.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rawText = AccessibilityReader.getRawAddressBarText(pid: pid)
            let parsedURL = AccessibilityReader.getCurrentURL(pid: pid)

            let normURL = parsedURL.map { NoteStore.shared.normaliseURL($0) } ?? rawText ?? ""
            let notes = parsedURL.map { NoteStore.shared.notesForURL(NoteStore.shared.normaliseURL($0)) } ?? []

            DispatchQueue.main.async {
                guard let self else { return }
                let urlChanged = normURL != self.lastKnownURL

                if urlChanged {
                    if self.pageNotesHUD.isVisible { self.pageNotesHUD.dismiss() }
                    self.pageNotesDismissedForURL = ""
                    self.lastKnownURL = normURL
                }

                if notes.isEmpty {
                    if self.pageNotesHUD.isVisible { self.pageNotesHUD.dismiss() }
                    return
                }

                if urlChanged || (!self.pageNotesHUD.isVisible && self.pageNotesDismissedForURL != normURL) {
                    self.pageNotesHUD.show(notes: notes, url: normURL, browserPID: pid) { [weak self] in
                        self?.pageNotesDismissedForURL = normURL
                    }
                }
            }
        }
    }

    // MARK: - CGEvent tap

    private func tryCreateEventTap() -> Bool {
        if eventTap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: markerCallback,
            userInfo: nil
        ) else { return false }

        eventTap = tap
        _markerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}
