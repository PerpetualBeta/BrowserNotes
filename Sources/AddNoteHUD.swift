import AppKit
import ApplicationServices

/// HUD for adding a note to the current page. Vibrancy glass style, movable, resizable.
@MainActor
final class AddNoteHUD: NSObject {

    private var panel: HUDKeyPanel?
    private var noteTextView: NSTextView!
    private var noteScrollView: NSScrollView!
    private var urlLabel: NSTextField!
    private var hintLabel: NSTextField!

    private var currentURL: String = ""
    private var browserPID: pid_t = 0
    private var editingNoteID: Int64?

    /// Called after a note is saved — engine uses this to refresh the page notes HUD
    var onNoteSaved: (() -> Void)?
    var onNoteEdited: (() -> Void)?

    private let panelWidth: CGFloat = 440
    private let defaultHeight: CGFloat = 120
    private let chromeHeight: CGFloat = 105  // titlebar + URL + sep + hint + padding

    func show(url: String, browserPID: pid_t) {
        self.currentURL = url
        self.browserPID = browserPID
        self.editingNoteID = nil

        if panel == nil { createPanel() }

        let shortURL = url.replacingOccurrences(of: "https://", with: "")
                          .replacingOccurrences(of: "http://", with: "")
        urlLabel.stringValue = shortURL.count > 55 ? String(shortURL.prefix(52)) + "..." : shortURL
        noteTextView.string = ""
        hintLabel.stringValue = "Enter to save \u{00B7} Escape to cancel"

        sizeToFitContent()
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(noteTextView)
    }

    func showForEdit(note: SavedNote, browserPID: pid_t) {
        self.currentURL = note.url
        self.browserPID = browserPID
        self.editingNoteID = note.id

        if panel == nil { createPanel() }

        let shortURL = note.url.replacingOccurrences(of: "https://", with: "")
                               .replacingOccurrences(of: "http://", with: "")
        urlLabel.stringValue = shortURL.count > 55 ? String(shortURL.prefix(52)) + "..." : shortURL
        noteTextView.string = note.note
        hintLabel.stringValue = "Enter to save changes \u{00B7} Escape to cancel"

        sizeToFitContent()
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(noteTextView)
        noteTextView.selectAll(nil)
    }

    private func sizeToFitContent() {
        guard let panel else { return }

        // Use panel width minus padding to calculate text width, since the text view
        // may not be laid out yet
        let textWidth = panelWidth - 32 - 10  // scroll view insets + text container inset
        let layoutManager = noteTextView.layoutManager!
        let textContainer = noteTextView.textContainer!
        textContainer.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height + 8

        let minTextHeight: CGFloat = 24
        let neededHeight = chromeHeight + max(minTextHeight, textHeight)
        let height = min(max(neededHeight, defaultHeight), 400)

        var frame = panel.frame
        let delta = height - frame.size.height
        frame.origin.y -= delta
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func createPanel() {
        let p = HUDKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: 320, height: 100)
        p.hudDelegate = self

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: defaultHeight))
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        urlLabel = NSTextField(labelWithString: "")
        urlLabel.font = .systemFont(ofSize: 10)
        urlLabel.textColor = .tertiaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Multi-line text view for note editing
        noteScrollView = NSScrollView()
        noteScrollView.hasVerticalScroller = true
        noteScrollView.autohidesScrollers = true
        noteScrollView.drawsBackground = false
        noteScrollView.borderType = .noBorder
        noteScrollView.translatesAutoresizingMaskIntoConstraints = false

        noteTextView = NSTextView()
        noteTextView.font = .systemFont(ofSize: 14)
        noteTextView.textColor = .labelColor
        noteTextView.drawsBackground = false
        noteTextView.isRichText = false
        noteTextView.isAutomaticQuoteSubstitutionEnabled = false
        noteTextView.isAutomaticDashSubstitutionEnabled = false
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.textContainer?.widthTracksTextView = true
        noteTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        noteTextView.delegate = self

        noteScrollView.documentView = noteTextView

        hintLabel = NSTextField(labelWithString: "Enter to save \u{00B7} Escape to cancel")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(urlLabel)
        bg.addSubview(sep)
        bg.addSubview(noteScrollView)
        bg.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            urlLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 32),
            urlLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 80),
            urlLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),

            sep.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),

            noteScrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            noteScrollView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            noteScrollView.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            noteScrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])

        p.contentView = bg
        panel = p
    }

    private func positionPanel() {
        let axApp = AXUIElementCreateApplication(browserPID)
        var windowVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowVal) == .success,
           let screen = NSScreen.main {
            var pos = CGPoint.zero
            var size = CGSize.zero
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(windowVal as! AXUIElement, kAXPositionAttribute as CFString, &posValue)
            AXUIElementCopyAttributeValue(windowVal as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue)
            if let pv = posValue, let sv = sizeValue {
                AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sv as! AXValue, .cgSize, &size)
                let x = pos.x + size.width / 2 - panelWidth / 2
                let y = screen.frame.height - pos.y - size.height / 2 - defaultHeight / 2
                panel?.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - panelWidth / 2,
                y: screen.visibleFrame.midY - defaultHeight / 2
            ))
        }
    }

    @objc private func saveNote() {
        let note = noteTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }

        if let editID = editingNoteID {
            NoteStore.shared.update(id: editID, note: note)
            editingNoteID = nil
            dismiss()
            onNoteEdited?()
        } else {
            NoteStore.shared.save(url: NoteStore.shared.normaliseURL(currentURL), note: note)
            dismiss()
            onNoteSaved?()
        }
    }
}

// MARK: - NSTextViewDelegate (Enter to save, Escape to cancel)

extension AddNoteHUD: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            saveNote()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}

// MARK: - HUDKeyPanelDelegate

extension AddNoteHUD: HUDKeyPanelDelegate {
    func moveSelectionUp() {}
    func moveSelectionDown() {}
    func activateSelected() { saveNote() }
    func deleteSelected() {}
    func dismiss() {
        panel?.orderOut(nil)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == browserPID }) {
            app.activate()
        }
    }
}

/// Borderless window that can become key (needed for text input)
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
