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
    private let rowHeightWithPills: CGFloat = 54

    var isVisible: Bool { panel?.isVisible ?? false }

    private var browserPID: pid_t = 0

    func show(browserPID: pid_t) {
        self.browserPID = browserPID
        allNotes = NoteStore.shared.allNotes()
        filteredNotes = allNotes
        selectedIndex = allNotes.isEmpty ? -1 : 0

        if panel == nil { createPanel() }

        // Size to 80% of the browser window each open, so the Notes
        // Browser scales with whatever the user's working in.
        panel?.setContentSize(targetSize(browserPID: browserPID))

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
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
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
        p.minSize = NSSize(width: 360, height: 240)

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        // Leading inset clears the traffic-light cluster — the panel
        // uses .fullSizeContentView, so they sit inside the contentView.
        // Top inset drops the field below the titlebar row — the panel
        // uses .fullSizeContentView so the traffic lights occupy the
        // top ~28px of the contentView. Leading inset matches the
        // favicon column below so the filter aligns with content.
        searchField = NSTextField(frame: NSRect(x: 16, y: panelHeight - 68, width: panelWidth - 32, height: 28))
        searchField.placeholderString = "Filter notes..."
        searchField.font = .systemFont(ofSize: 14)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchAction)
        searchField.autoresizingMask = [.width, .minYMargin]

        let sep = NSBox(frame: NSRect(x: 16, y: panelHeight - 74, width: panelWidth - 32, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]

        countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 16, y: 8, width: panelWidth - 32, height: 16)
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.autoresizingMask = [.width, .maxYMargin]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = panelWidth - 16

        tableView = NSTableView(frame: .zero)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(activateSelected)
        tableView.target = self

        scrollView = NSScrollView(frame: NSRect(x: 8, y: 28, width: panelWidth - 16, height: panelHeight - 106))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]

        bg.addSubview(searchField)
        bg.addSubview(sep)
        bg.addSubview(scrollView)
        bg.addSubview(countLabel)

        p.contentView = bg
        panel = p
    }

    private func targetSize(browserPID: pid_t) -> NSSize {
        if let browserFrame = JorvikWindowHelper.axFocusedWindowFrame(pid: browserPID) {
            return NSSize(
                width: max(360, browserFrame.width * 0.8),
                height: max(240, browserFrame.height * 0.8)
            )
        }
        let visible = JorvikWindowHelper.screenContaining(NSEvent.mouseLocation).visibleFrame
        return NSSize(
            width: max(360, visible.width * 0.8),
            height: max(240, visible.height * 0.8)
        )
    }

    private func positionPanel() {
        let current = panel?.frame.size ?? NSSize(width: panelWidth, height: panelHeight)

        if let browserFrame = JorvikWindowHelper.axFocusedWindowFrame(pid: browserPID) {
            // Centred on the browser window. AX-to-AppKit conversion via
            // the primary screen's height (handled in axFocusedWindowFrame)
            // means this works on any display, not just the primary.
            let x = browserFrame.midX - current.width / 2
            let y = browserFrame.midY - current.height / 2
            panel?.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        // Fallback: centre on the mouse-bearing screen.
        let fallbackScreen = JorvikWindowHelper.screenContaining(NSEvent.mouseLocation)
        panel?.setFrameOrigin(NSPoint(
            x: fallbackScreen.visibleFrame.midX - current.width / 2,
            y: fallbackScreen.visibleFrame.midY - current.height / 2
        ))
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = tableView.selectedRow
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredNotes.count else { return nil }
        let note = filteredNotes[row]
        let tags = note.hashtags
        let height = tags.isEmpty ? rowHeight : rowHeightWithPills

        // Variable per-row layout (favicon + optional pills) doesn't
        // recycle cleanly, so build a fresh cell each call. The dataset
        // is bounded (visible-rows-only) so the cost is negligible.
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? panelWidth - 16, height: height))

        let faviconView = NSImageView(frame: .zero)
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        faviconView.image = FaviconCache.placeholder
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        FaviconCache.shared.image(forURL: note.url) { [weak faviconView] image in
            if let image { faviconView?.image = image }
        }

        let noteField = NSTextField(labelWithString: note.note)
        noteField.font = .systemFont(ofSize: 13)
        noteField.textColor = .labelColor
        noteField.lineBreakMode = .byTruncatingTail
        noteField.translatesAutoresizingMaskIntoConstraints = false

        let urlField = NSTextField(labelWithString: "\(shortenURL(note.url))  —  \(relativeTime(note.createdAt))")
        urlField.font = .systemFont(ofSize: 10)
        urlField.textColor = .tertiaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = NSButton(frame: .zero)
        deleteBtn.bezelStyle = .inline
        deleteBtn.isBordered = false
        deleteBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteBtn.contentTintColor = .tertiaryLabelColor
        deleteBtn.imageScaling = .scaleProportionallyDown
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteButtonClicked(_:))
        deleteBtn.identifier = NSUserInterfaceItemIdentifier("\(row)")
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(faviconView)
        cell.addSubview(noteField)
        cell.addSubview(urlField)
        cell.addSubview(deleteBtn)

        var constraints: [NSLayoutConstraint] = [
            faviconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            faviconView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            deleteBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            deleteBtn.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            deleteBtn.widthAnchor.constraint(equalToConstant: 20),
            deleteBtn.heightAnchor.constraint(equalToConstant: 20),

            noteField.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 8),
            noteField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
            noteField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),

            urlField.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
            urlField.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 0),
        ]

        if !tags.isEmpty {
            let pillField = NSTextField(labelWithAttributedString: HashtagPill.attributedPills(for: tags, font: .systemFont(ofSize: 9)))
            pillField.lineBreakMode = .byTruncatingTail
            pillField.maximumNumberOfLines = 1
            pillField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(pillField)
            constraints.append(contentsOf: [
                pillField.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 8),
                pillField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
                pillField.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 2),
            ])
        }

        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < filteredNotes.count else { return rowHeight }
        return filteredNotes[row].hashtags.isEmpty ? rowHeight : rowHeightWithPills
    }
}
