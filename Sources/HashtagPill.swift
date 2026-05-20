import AppKit

/// Deterministic colour assignment + pill rendering for hashtags.
///
/// One tag → one colour, always. `#work` is the same colour today as it
/// will be tomorrow, and as it is in every popover that renders it.
/// Achieved by hashing the normalised tag with FNV-1a (a fixed,
/// non-seeded hash) and mapping that to a hue in HSL.
///
/// The text colour inside the pill is chosen by relative luminance so it
/// always reads against the pill background — pastels get black text,
/// jewel tones get white.
enum HashtagPill {

    /// Stable colour for a given tag. Strips leading `#` and case-folds
    /// so `#Work`, `#work`, and `work` all map to the same hue.
    static func color(for tag: String) -> NSColor {
        let key = normalise(tag)
        let hue = CGFloat(fnv1a32(key) % 360) / 360.0
        // Saturation/brightness chosen empirically: vivid enough to be
        // distinguishable across tags, soft enough that white-or-black
        // text always passes a casual legibility check.
        return NSColor(deviceHue: hue, saturation: 0.55, brightness: 0.78, alpha: 1.0)
    }

    /// Black or white, whichever contrasts better with the given pill
    /// background.
    static func textColor(on background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.deviceRGB) ?? background
        // Relative luminance per WCAG 2.x.
        let r = channel(rgb.redComponent)
        let g = channel(rgb.greenComponent)
        let b = channel(rgb.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? .black : .white
    }

    /// Renders a single tag into a rounded pill image suitable for use
    /// as an `NSTextAttachment` or in an `NSImageView`.
    static func image(for tag: String, font: NSFont) -> NSImage {
        let bg = color(for: tag)
        let fg = textColor(on: bg)
        let pillText = " \(displayTag(tag)) "
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let textSize = (pillText as NSString).size(withAttributes: attrs)
        let pillSize = NSSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 4)

        return NSImage(size: pillSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            bg.setFill()
            path.fill()
            let textRect = NSRect(x: 5, y: 2, width: rect.width - 10, height: rect.height - 4)
            pillText.draw(in: textRect, withAttributes: attrs)
            return true
        }
    }

    /// Builds an attributed string of pill attachments laid out
    /// horizontally with a single-space separator. Caller controls the
    /// font; the baseline offset matches the existing visual rhythm.
    static func attributedPills(for tags: [String], font: NSFont, baselineOffset: CGFloat = -3) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, tag) in tags.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: " ")) }
            let img = image(for: tag, font: font)
            let attachment = NSTextAttachment()
            attachment.image = img
            attachment.bounds = NSRect(x: 0, y: baselineOffset, width: img.size.width, height: img.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    // MARK: - Helpers

    private static func normalise(_ tag: String) -> String {
        var s = tag.lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        return s
    }

    /// Always prefixed with `#` for display, regardless of what the
    /// caller passed in.
    private static func displayTag(_ tag: String) -> String {
        tag.hasPrefix("#") ? tag : "#" + tag
    }

    private static func channel(_ c: CGFloat) -> CGFloat {
        // sRGB → linear, per WCAG.
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// FNV-1a 32-bit. Deterministic — unlike Swift's `Hashable`, the
    /// output is identical across processes and OS versions, so disk-
    /// cached colours stay stable.
    private static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return hash
    }
}
