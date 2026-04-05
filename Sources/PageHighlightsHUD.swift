import AppKit
import ApplicationServices

/// Persistent HUD that appears when navigating to a page with notes.
@MainActor
final class PageNotesHUD: NSObject {

    private var panel: NSPanel?
    private var stackView: NSStackView!
    private var scrollView: NSScrollView!
    private var titleLabel: NSTextField!

    private var notes: [SavedNote] = []
    private var onDismissed: (() -> Void)?
    var onEditNote: ((SavedNote) -> Void)?

    private let panelWidth: CGFloat = 420
    private let titleBarHeight: CGFloat = 28

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(notes: [SavedNote], url: String, browserPID: pid_t,
              onDismissed: (() -> Void)? = nil) {
        guard !notes.isEmpty else { return }
        self.notes = notes
        self.onDismissed = onDismissed

        if panel == nil { createPanel() }

        let shortURL = url.replacingOccurrences(of: "https://", with: "")
                          .replacingOccurrences(of: "http://", with: "")
        let displayURL = shortURL.count > 35 ? String(shortURL.prefix(32)) + "..." : shortURL
        titleLabel?.stringValue = "\(notes.count) note\(notes.count == 1 ? "" : "s") — \(displayURL)"

        let alreadyVisible = panel?.isVisible ?? false
        rebuildNoteViews()
        sizeToFit()
        if !alreadyVisible { positionPanel(browserPID: browserPID) }
        panel?.orderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        onDismissed?()
    }

    // MARK: - Build note views

    private func rebuildNoteViews() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, note) in notes.enumerated() {
            let noteView = createNoteView(note: note, index: index, isEven: index % 2 == 0)
            stackView.addArrangedSubview(noteView)
        }
    }

    private func createNoteView(note: SavedNote, index: Int, isEven: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = isEven
            ? NSColor(white: 0.0, alpha: 0.03).cgColor
            : NSColor(white: 0.0, alpha: 0.07).cgColor

        // Edit button (top-right)
        let editBtn = NSButton(frame: .zero)
        editBtn.bezelStyle = .inline
        editBtn.isBordered = false
        editBtn.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
        editBtn.contentTintColor = .tertiaryLabelColor
        editBtn.imageScaling = .scaleProportionallyDown
        editBtn.target = self
        editBtn.action = #selector(editButtonClicked(_:))
        editBtn.tag = index
        editBtn.translatesAutoresizingMaskIntoConstraints = false

        // Note text
        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 12)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        // container width (panelWidth-32) minus leading(12) minus editBtn(18+8) minus gap(4)
        textField.preferredMaxLayoutWidth = panelWidth - 74
        textField.alignment = .left
        textField.translatesAutoresizingMaskIntoConstraints = false

        let cleanText = note.note.replacingOccurrences(of: #"#\w+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        textField.stringValue = cleanText.isEmpty ? note.note : cleanText

        // Timestamp
        let timeLabel = NSTextField(labelWithString: relativeTime(note.createdAt))
        timeLabel.font = .systemFont(ofSize: 9)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .left
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(editBtn)
        container.addSubview(textField)
        container.addSubview(timeLabel)

        // The bottom anchor chain: text → [pills] → timestamp → container bottom
        let tags = note.hashtags
        if !tags.isEmpty {
            let pillField = createPillsField(tags: tags)
            container.addSubview(pillField)

            NSLayoutConstraint.activate([
                editBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                editBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                editBtn.widthAnchor.constraint(equalToConstant: 18),
                editBtn.heightAnchor.constraint(equalToConstant: 18),

                textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                textField.trailingAnchor.constraint(equalTo: editBtn.leadingAnchor, constant: -4),

                pillField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 6),
                pillField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                pillField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

                timeLabel.topAnchor.constraint(equalTo: pillField.bottomAnchor, constant: 4),
                timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                timeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
        } else {
            NSLayoutConstraint.activate([
                editBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                editBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                editBtn.widthAnchor.constraint(equalToConstant: 18),
                editBtn.heightAnchor.constraint(equalToConstant: 18),

                textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                textField.trailingAnchor.constraint(equalTo: editBtn.leadingAnchor, constant: -4),

                timeLabel.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 4),
                timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                timeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
        }

        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: panelWidth - 32).isActive = true
        return container
    }

    @objc private func editButtonClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < notes.count else { return }
        onEditNote?(notes[index])
    }

    private func createPillsField(tags: [String]) -> NSTextField {
        let result = NSMutableAttributedString()
        let pillFont = NSFont.systemFont(ofSize: 9)

        for (i, tag) in tags.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: " ")) }

            let pillText = " \(tag) "
            let textSize = (pillText as NSString).size(withAttributes: [.font: pillFont])
            let pillSize = NSSize(width: textSize.width + 12, height: textSize.height + 6)

            let pillImage = NSImage(size: pillSize, flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: rect.height / 2, yRadius: rect.height / 2)
                NSColor(white: 0.0, alpha: 0.04).setFill()
                path.fill()
                NSColor(white: 0.0, alpha: 0.15).setStroke()
                path.lineWidth = 1
                path.stroke()
                let textRect = NSRect(x: 6, y: 2, width: rect.width - 12, height: rect.height - 4)
                pillText.draw(in: textRect, withAttributes: [
                    .font: pillFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                return true
            }

            let attachment = NSTextAttachment()
            attachment.image = pillImage
            attachment.bounds = NSRect(x: 0, y: -3, width: pillSize.width, height: pillSize.height)
            result.append(NSAttributedString(attachment: attachment))
        }

        let field = NSTextField(labelWithAttributedString: result)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = panelWidth - 40
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    // MARK: - Sizing

    private func sizeToFit() {
        guard let panel else { return }

        // Force layout
        stackView.layoutSubtreeIfNeeded()
        let contentHeight = stackView.fittingSize.height
        let totalHeight = contentHeight + titleBarHeight + 36  // title + padding

        let maxHeight: CGFloat = 500
        let height = min(totalHeight, maxHeight)

        var frame = panel.frame
        let delta = height - frame.size.height
        frame.origin.y -= delta  // grow downward, not upward
        frame.size.height = height
        frame.size.width = panelWidth
        panel.setFrame(frame, display: true)
        panel.maxSize = NSSize(width: 600, height: height)
        panel.minSize = NSSize(width: 300, height: min(height, 100))
    }

    // MARK: - Panel creation

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.onDismissed?() }
        }

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 200))
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 16)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(titleLabel)
        bg.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: titleBarHeight + 4),
            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        p.contentView = bg
        panel = p
    }

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

    private func positionPanel(browserPID: pid_t) {
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
                let screenH = screen.frame.height
                let panelH = panel?.frame.height ?? 200
                let x = min(pos.x + size.width - panelWidth - 50,
                            screen.visibleFrame.maxX - panelWidth - 10)
                let y = screenH - pos.y - panelH - 120
                panel?.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - panelWidth - 50,
                y: screen.visibleFrame.maxY - (panel?.frame.height ?? 200) - 120
            ))
        }
    }
}

// MARK: - Hashtag pill formatting (for Notes Browser HUD)

func formatNoteWithHashtagPills(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let baseFont = NSFont.systemFont(ofSize: 12)
    let baseAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor]

    let pattern = #"#\w+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return NSAttributedString(string: text, attributes: baseAttrs)
    }

    let nsText = text as NSString
    var lastEnd = 0
    var tags: [String] = []

    // Collect text without hashtags
    let cleanText = NSMutableAttributedString()
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
        if match.range.location > lastEnd {
            let before = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            cleanText.append(NSAttributedString(string: before, attributes: baseAttrs))
        }
        tags.append(nsText.substring(with: match.range))
        lastEnd = match.range.location + match.range.length
    }
    if lastEnd < nsText.length {
        cleanText.append(NSAttributedString(string: nsText.substring(from: lastEnd), attributes: baseAttrs))
    }

    result.append(cleanText)

    // Add pills on a new line
    if !tags.isEmpty {
        result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
        for (i, tag) in tags.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: " ", attributes: baseAttrs)) }

            let pillFont = NSFont.systemFont(ofSize: 10)
            let pillText = " \(tag) "
            let textSize = (pillText as NSString).size(withAttributes: [.font: pillFont])
            let pillSize = NSSize(width: textSize.width + 12, height: textSize.height + 6)

            let pillImage = NSImage(size: pillSize, flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                NSColor(white: 0.0, alpha: 0.04).setFill()
                path.fill()
                NSColor(white: 0.0, alpha: 0.15).setStroke()
                path.lineWidth = 1
                path.stroke()
                let textRect = NSRect(x: 6, y: 2, width: rect.width - 12, height: rect.height - 4)
                pillText.draw(in: textRect, withAttributes: [.font: pillFont, .foregroundColor: NSColor.secondaryLabelColor])
                return true
            }

            let attachment = NSTextAttachment()
            attachment.image = pillImage
            attachment.bounds = NSRect(x: 0, y: -3, width: pillSize.width, height: pillSize.height)
            result.append(NSAttributedString(attachment: attachment))
        }
    }

    return result
}
