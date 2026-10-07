import Foundation

/// Ranks ⌘K results: every query word must appear somewhere; exact identifiers win.
public enum QuickSearch {
    /// Higher is better; nil means no match.
    /// - identifiers: exact-match keys such as "440", "#440" or "CON-108".
    /// - title: primary text; prefix and word-start matches rank higher.
    /// - details: other searchable text (repository, branches, author, Linear title).
    public static func score(_ query: String, identifiers: [String], title: String, details: [String]) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let ids = identifiers.map { $0.lowercased() }
        let lowerTitle = title.lowercased()
        let haystack = ([lowerTitle] + ids + details.map { $0.lowercased() }).joined(separator: " ")
        var total = 0
        for word in words {
            if ids.contains(word) || ids.contains("#" + word) {
                total += 1000
            } else if lowerTitle.hasPrefix(word) {
                total += 300
            } else if lowerTitle.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word), options: .regularExpression) != nil {
                total += 200
            } else if lowerTitle.contains(word) {
                total += 120
            } else if haystack.contains(word) {
                total += 60
            } else {
                return nil
            }
        }
        return total
    }
}
