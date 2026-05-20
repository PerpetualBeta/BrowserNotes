import AppKit

/// Resolves and caches favicons for the hosts that appear in saved notes.
///
/// Three-tier fetch strategy, in order:
///   1. `https://<host>/favicon.ico` — fastest, no third party
///   2. Parse `<link rel="icon">` / `<link rel="shortcut icon">` from the
///      site's HTML and follow that — covers sites that don't host the
///      icon at the well-known path
///   3. `https://icons.duckduckgo.com/ip3/<host>.ico` — last-resort
///      indirection through DDG's icon service
///
/// Results (positive and negative) are cached in memory and on disk under
/// Application Support/BrowserNotes/favicons/. Negative caching is
/// important — without it every Notes Browser open would re-hit the
/// network for hosts that have no resolvable icon.
@MainActor
final class FaviconCache {

    static let shared = FaviconCache()

    /// Placeholder shown while a fetch is in flight or when no icon was
    /// resolvable. SF Symbol — looks consistent with the rest of the UI.
    static let placeholder: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        return img
    }()

    private struct Entry {
        let image: NSImage?  // nil = negative cache (we tried and failed)
    }

    private var memory: [String: Entry] = [:]
    private var inflight: [String: [(NSImage?) -> Void]] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 10
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    private let diskDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BrowserNotes", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    /// Returns a cached icon if available, otherwise calls `completion`
    /// once the resolver finishes (on the main actor). `completion` may
    /// run synchronously when an in-memory hit is available.
    func image(forURL urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let host = Self.host(from: urlString)?.lowercased() else {
            completion(nil); return
        }

        if let entry = memory[host] {
            completion(entry.image); return
        }

        if let image = loadFromDisk(host: host) {
            memory[host] = Entry(image: image)
            completion(image); return
        }

        if hasNegativeMarkerOnDisk(host: host) {
            memory[host] = Entry(image: nil)
            completion(nil); return
        }

        if inflight[host] != nil {
            inflight[host]?.append(completion); return
        }
        inflight[host] = [completion]

        resolve(host: host) { [weak self] image in
            guard let self else { return }
            self.memory[host] = Entry(image: image)
            if let image {
                self.saveToDisk(host: host, image: image)
            } else {
                self.writeNegativeMarker(host: host)
            }
            let waiters = self.inflight.removeValue(forKey: host) ?? []
            for w in waiters { w(image) }
        }
    }

    // MARK: - Resolution

    private nonisolated func resolve(host: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        tryDirect(host: host) { [weak self] image in
            if let image {
                Task { @MainActor in completion(image) }
                return
            }
            self?.tryParsedHTML(host: host) { image in
                if let image {
                    Task { @MainActor in completion(image) }
                    return
                }
                self?.tryDuckDuckGo(host: host) { image in
                    Task { @MainActor in completion(image) }
                }
            }
        }
    }

    private nonisolated func tryDirect(host: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { completion(nil); return }
        fetchImage(url: url, completion: completion)
    }

    private nonisolated func tryParsedHTML(host: String, completion: @escaping (NSImage?) -> Void) {
        guard let pageURL = URL(string: "https://\(host)/") else { completion(nil); return }
        var req = URLRequest(url: pageURL)
        // Mimic a real browser UA — some sites 403 on default URLSession UA.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, response, _ in
            guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion(nil); return
            }
            // Decode as UTF-8, falling back to Latin-1 so we still get the <head>.
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            guard let iconHref = Self.firstIconHref(in: html),
                  let iconURL = URL(string: iconHref, relativeTo: pageURL)?.absoluteURL
            else { completion(nil); return }
            self.fetchImage(url: iconURL, completion: completion)
        }.resume()
    }

    private nonisolated func tryDuckDuckGo(host: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") else { completion(nil); return }
        fetchImage(url: url, completion: completion)
    }

    private nonisolated func fetchImage(url: URL, completion: @escaping (NSImage?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 32,  // discard 1x1 trackers / empty bodies
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0
            else { completion(nil); return }
            completion(image)
        }.resume()
    }

    // MARK: - Disk cache

    private func loadFromDisk(host: String) -> NSImage? {
        let path = diskDir.appendingPathComponent(Self.fileKey(host) + ".png")
        guard let data = try? Data(contentsOf: path), let img = NSImage(data: data) else { return nil }
        return img
    }

    private func saveToDisk(host: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let path = diskDir.appendingPathComponent(Self.fileKey(host) + ".png")
        try? png.write(to: path)
    }

    /// A zero-byte sentinel file marks "we tried and failed" so we don't
    /// re-hit the network for the same host on every popover open.
    private func writeNegativeMarker(host: String) {
        let path = diskDir.appendingPathComponent(Self.fileKey(host) + ".none")
        try? Data().write(to: path)
    }

    private func hasNegativeMarkerOnDisk(host: String) -> Bool {
        let path = diskDir.appendingPathComponent(Self.fileKey(host) + ".none")
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - Helpers

    private static func host(from urlString: String) -> String? {
        if let u = URL(string: urlString), let h = u.host, !h.isEmpty { return h }
        // Fall back for inputs missing a scheme.
        if let u = URL(string: "https://" + urlString), let h = u.host, !h.isEmpty { return h }
        return nil
    }

    private static func fileKey(_ host: String) -> String {
        host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Returns the first href from any `<link rel="…icon…">` in the HTML.
    /// Permissive enough to handle the common variants (rel="icon",
    /// rel="shortcut icon", rel="apple-touch-icon") without pulling in a
    /// full HTML parser.
    private nonisolated static func firstIconHref(in html: String) -> String? {
        // Limit work to the <head> if we can find one.
        let scope: String = {
            if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
                return String(html[html.startIndex..<headEnd.upperBound])
            }
            return String(html.prefix(20_000))
        }()

        let pattern = #"<link\s+[^>]*rel\s*=\s*["']?[^"'>]*icon[^"'>]*["']?[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsScope = scope as NSString
        let matches = regex.matches(in: scope, range: NSRange(location: 0, length: nsScope.length))
        guard !matches.isEmpty else { return nil }

        let hrefPattern = #"href\s*=\s*["']([^"']+)["']"#
        guard let hrefRegex = try? NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive]) else { return nil }

        for m in matches {
            let tag = nsScope.substring(with: m.range)
            let nsTag = tag as NSString
            if let h = hrefRegex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)),
               h.numberOfRanges >= 2 {
                return nsTag.substring(with: h.range(at: 1))
            }
        }
        return nil
    }
}
