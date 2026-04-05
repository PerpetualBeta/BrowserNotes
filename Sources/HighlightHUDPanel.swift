import AppKit
import ApplicationServices

/// Floating HUD that lists all saved notes for browsing, filtering, and navigation.
@MainActor
final class NotesBrowserHUD: NSObject, HUDKeyPanelDelegate {

    private var panel: NSPanel?
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var searchField: NSTextField!
    private var countLabel: NSTextField!

    private var allNotes: [SavedNote] = []
    private var filteredNotes: [SavedNote] = []

    /// Called after a note is deleted — engine uses this to refresh page notes HUD
    var onNoteDeleted: (() -> Void)?
    private var selectedIndex: Int = 0
    private var clickMonitor: Any?

    private let panelWidth: CGFloat = 560
    private let panelHeight: CGFloat = 420
    private let rowHeight: CGFloat = 36

    var isVisible: Bool { panel?.isVisible ?? false }

    private var browserPID: pid_t = 0

    func show(browserPID: pid_t) {
        self.browserPID = browserPID
        allNotes = NoteStore.shared.allNotes()
        filteredNotes = allNotes
        selectedIndex = allNotes.isEmpty ? -1 : 0

        if panel == nil { createPanel() }

        searchField.stringValue = ""
        updateFilter()
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            if !p.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.dismiss() }
            }
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func deleteSelected() {
        guard selectedIndex >= 0, selectedIndex < filteredNotes.count else { return }
        NoteStore.shared.delete(id: filteredNotes[selectedIndex].id)
        allNotes = NoteStore.shared.allNotes()
        updateFilter()
        onNoteDeleted?()
    }

    private func createPanel() {
        let p = HUDKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.hudDelegate = self

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        searchField = NSTextField(frame: NSRect(x: 16, y: panelHeight - 52, width: panelWidth - 32, height: 28))
        searchField.placeholderString = "Filter notes..."
        searchField.font = .systemFont(ofSize: 14)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchAction)

        let sep = NSBox(frame: NSRect(x: 16, y: panelHeight - 58, width: panelWidth - 32, height: 1))
        sep.boxType = .separator

        countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 16, y: 8, width: panelWidth - 32, height: 16)
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = panelWidth - 16

        tableView = NSTableView(frame: .zero)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(activateSelected)
        tableView.target = self

        scrollView = NSScrollView(frame: NSRect(x: 8, y: 28, width: panelWidth - 16, height: panelHeight - 90))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        bg.addSubview(searchField)
        bg.addSubview(sep)
        bg.addSubview(scrollView)
        bg.addSubview(countLabel)

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
                let y = screen.frame.height - pos.y - size.height / 2 - panelHeight / 2
                panel?.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - panelWidth / 2,
                y: screen.visibleFrame.midY - panelHeight / 2
            ))
        }
    }

    private func updateFilter() {
        let query = searchField?.stringValue.lowercased() ?? ""
        filteredNotes = query.isEmpty ? allNotes : allNotes.filter {
            $0.note.lowercased().contains(query) ||
            $0.url.lowercased().contains(query) ||
            $0.hashtags.contains(where: { $0.lowercased().contains(query) })
        }
        selectedIndex = filteredNotes.isEmpty ? -1 : 0
        tableView?.reloadData()
        if selectedIndex >= 0 {
            tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView?.scrollRowToVisible(selectedIndex)
        }
        let total = allNotes.count
        countLabel?.stringValue = query.isEmpty ? "\(total) notes" : "\(filteredNotes.count) of \(total) notes"
    }

    func moveSelectionUp() {
        guard !filteredNotes.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    func moveSelectionDown() {
        guard !filteredNotes.isEmpty else { return }
        selectedIndex = min(filteredNotes.count - 1, selectedIndex + 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    @objc func activateSelected() {
        guard selectedIndex >= 0, selectedIndex < filteredNotes.count else { return }
        let note = filteredNotes[selectedIndex]
        dismiss()

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            navigateBrowserTab(bundleID: bundleID, url: note.url)
        }
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue,
              let row = Int(idStr),
              row >= 0, row < filteredNotes.count
        else { return }
        NoteStore.shared.delete(id: filteredNotes[row].id)
        allNotes = NoteStore.shared.allNotes()
        updateFilter()
        onNoteDeleted?()
    }

    @objc private func searchAction() { activateSelected() }

    // MARK: - Relative time

    private func relativeTime(_ dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let date = f.date(from: dateStr) else { return dateStr }
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        if s < 604800 { return "\(Int(s / 86400))d ago" }
        return "\(Int(s / 604800))w ago"
    }

    private func shortenURL(_ url: String) -> String {
        var short = url.replacingOccurrences(of: "https://", with: "")
                       .replacingOccurrences(of: "http://", with: "")
        if short.hasSuffix("/") { short = String(short.dropLast()) }
        if short.count > 50 { short = String(short.prefix(47)) + "..." }
        return short
    }
}

// MARK: - NSTextFieldDelegate

extension NotesBrowserHUD: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelectionUp(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelectionDown(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { activateSelected(); return true }
        return false
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension NotesBrowserHUD: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filteredNotes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredNotes.count else { return nil }
        let note = filteredNotes[row]

        let cellID = NSUserInterfaceItemIdentifier("NoteBrowserCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? panelWidth - 16, height: rowHeight))
            cell.identifier = cellID

            let noteField = NSTextField(labelWithString: "")
            noteField.tag = 1
            noteField.font = .systemFont(ofSize: 13)
            noteField.textColor = .labelColor
            noteField.lineBreakMode = .byTruncatingTail
            noteField.translatesAutoresizingMaskIntoConstraints = false

            let urlField = NSTextField(labelWithString: "")
            urlField.tag = 2
            urlField.font = .systemFont(ofSize: 10)
            urlField.textColor = .tertiaryLabelColor
            urlField.lineBreakMode = .byTruncatingMiddle
            urlField.translatesAutoresizingMaskIntoConstraints = false

            let deleteBtn = NSButton(frame: .zero)
            deleteBtn.tag = 99
            deleteBtn.bezelStyle = .inline
            deleteBtn.isBordered = false
            deleteBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            deleteBtn.contentTintColor = .tertiaryLabelColor
            deleteBtn.imageScaling = .scaleProportionallyDown
            deleteBtn.target = self
            deleteBtn.action = #selector(deleteButtonClicked(_:))
            deleteBtn.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(noteField)
            cell.addSubview(urlField)
            cell.addSubview(deleteBtn)

            NSLayoutConstraint.activate([
                deleteBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                deleteBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                deleteBtn.widthAnchor.constraint(equalToConstant: 20),
                deleteBtn.heightAnchor.constraint(equalToConstant: 20),

                noteField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                noteField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
                noteField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),

                urlField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                urlField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
                urlField.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 0),
            ])
        }

        if let nf = cell.viewWithTag(1) as? NSTextField {
            nf.stringValue = note.note
        }
        if let uf = cell.viewWithTag(2) as? NSTextField {
            uf.stringValue = "\(shortenURL(note.url))  —  \(relativeTime(note.createdAt))"
        }
        if let db = cell.viewWithTag(99) as? NSButton {
            db.identifier = NSUserInterfaceItemIdentifier("\(row)")
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }
}
