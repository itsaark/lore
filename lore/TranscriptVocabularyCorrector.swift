import Foundation

/// Applies the person's explicit replacement entries ("Marisa" → "Marissa")
/// to a transcript. Matching is whole-word and case-insensitive; surrounding
/// punctuation and spacing are kept, and the replacement is inserted exactly
/// as the person spelled it. All entries apply in one pass, so a replacement
/// is never itself replaced by another entry.
///
/// Preferred-spelling entries (no replacement) are not applied here.
struct TranscriptVocabularyCorrector: Equatable, Sendable {
    struct Replacement: Equatable, Sendable {
        let phrase: String
        let replacement: String
    }

    let replacements: [Replacement]

    init(replacements: [Replacement]) {
        // Normalized keys are unique per phrase; when two entries collide the
        // first one in the caller's order wins.
        var seen = Set<String>()
        self.replacements = replacements
            .map {
                Replacement(
                    phrase: $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacement: $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.phrase.isEmpty && !$0.replacement.isEmpty }
            .filter { seen.insert(Self.key($0.phrase)).inserted }
    }

    /// Most recently edited entries win a collision, so the result does not
    /// depend on fetch order.
    init(entries: [VocabularyEntry]) {
        let sorted = entries
            .filter(\.isReplacement)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        self.init(replacements: sorted.map {
            Replacement(phrase: $0.phrase, replacement: $0.replacement ?? "")
        })
    }

    var isEmpty: Bool { replacements.isEmpty }

    func apply(to text: String) -> String {
        guard !replacements.isEmpty, !text.isEmpty, let expression = makeExpression() else {
            return text
        }
        var byKey: [String: String] = [:]
        for entry in replacements {
            byKey[Self.key(entry.phrase)] = entry.replacement
        }

        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            let matched = source.substring(with: match.range)
            guard let replacement = byKey[Self.key(matched)] else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    private func makeExpression() -> NSRegularExpression? {
        // Longest phrase first so "New York City" beats "New York".
        let alternatives = replacements
            .sorted { ($0.phrase.count, $0.phrase) > ($1.phrase.count, $1.phrase) }
            .map { entry in
                entry.phrase
                    .split(whereSeparator: \.isWhitespace)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{N}_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Case-insensitive key with runs of whitespace collapsed, matching how
    /// the expression treats spaces inside a phrase.
    private static func key(_ phrase: String) -> String {
        phrase
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
