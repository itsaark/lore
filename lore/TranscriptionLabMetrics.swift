#if DEBUG
import Foundation

/// Scoring for the developer Transcription Lab. Both metrics compare words
/// after the same normalization, so casing and punctuation never count as
/// recognition errors.
enum TranscriptionLabMetrics {
    struct WordErrorRate: Codable, Equatable, Sendable {
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let referenceWordCount: Int

        var errors: Int { substitutions + deletions + insertions }

        /// Errors divided by reference words. Can exceed 1 when the hypothesis
        /// inserts many words.
        var rate: Double {
            referenceWordCount == 0 ? 0 : Double(errors) / Double(referenceWordCount)
        }
    }

    struct NameRecall: Codable, Equatable, Sendable {
        let found: [String]
        let missed: [String]

        var total: Int { found.count + missed.count }
        var rate: Double { total == 0 ? 0 : Double(found.count) / Double(total) }
    }

    /// Lowercases, drops apostrophes so "don't" and "dont" agree, and turns
    /// every other punctuation or symbol character into a word break.
    static func normalizedWords(_ text: String) -> [String] {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text.lowercased() {
            if character == "'" || character == "\u{2019}" || character == "\u{2018}" {
                continue
            }
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Word-level Levenshtein alignment of `hypothesis` against `reference`.
    /// Returns nil when the reference has no words to score against.
    static func wordErrorRate(reference: String, hypothesis: String) -> WordErrorRate? {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        guard !ref.isEmpty else { return nil }

        struct Cell {
            var cost: Int
            var substitutions: Int
            var deletions: Int
            var insertions: Int
        }

        // Rolling rows: row i holds the best alignment of ref[0..<i] to hyp[0..<j].
        var previous = (0...hyp.count).map { Cell(cost: $0, substitutions: 0, deletions: 0, insertions: $0) }
        for i in 1...ref.count {
            var current = [Cell(cost: i, substitutions: 0, deletions: i, insertions: 0)]
            current.reserveCapacity(hyp.count + 1)
            for j in stride(from: 1, through: hyp.count, by: 1) {
                if ref[i - 1] == hyp[j - 1] {
                    current.append(previous[j - 1])
                    continue
                }
                var substitution = previous[j - 1]
                substitution.cost += 1
                substitution.substitutions += 1
                var deletion = previous[j]
                deletion.cost += 1
                deletion.deletions += 1
                var insertion = current[j - 1]
                insertion.cost += 1
                insertion.insertions += 1
                current.append([substitution, deletion, insertion].min { $0.cost < $1.cost }!)
            }
            previous = current
        }

        let best = previous[hyp.count]
        return WordErrorRate(
            substitutions: best.substitutions,
            deletions: best.deletions,
            insertions: best.insertions,
            referenceWordCount: ref.count
        )
    }

    /// A name counts as found when its normalized words appear consecutively
    /// in the normalized hypothesis, so "Anne" does not match "Annex".
    /// Returns nil when no names were listed.
    static func nameRecall(names: [String], hypothesis: String) -> NameRecall? {
        let listed = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !normalizedWords($0).isEmpty }
        guard !listed.isEmpty else { return nil }

        let hyp = normalizedWords(hypothesis)
        var found: [String] = []
        var missed: [String] = []
        for name in listed {
            let needle = normalizedWords(name)
            let isPresent = hyp.count >= needle.count && (0...(hyp.count - needle.count)).contains {
                Array(hyp[$0..<($0 + needle.count)]) == needle
            }
            if isPresent {
                found.append(name)
            } else {
                missed.append(name)
            }
        }
        return NameRecall(found: found, missed: missed)
    }

    /// Splits the "names said in this clip" field.
    static func parseNames(_ field: String) -> [String] {
        var seen = Set<String>()
        return field
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
#endif
