import Foundation

/// A saved note from the database
struct SavedNote {
    let id: Int64
    let url: String
    let note: String
    let createdAt: String

    /// Extracts hashtags from the note text
    var hashtags: [String] {
        let pattern = #"#\w+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(note.startIndex..., in: note)
        return regex.matches(in: note, range: range).compactMap {
            Range($0.range, in: note).map { String(note[$0]) }
        }
    }
}
