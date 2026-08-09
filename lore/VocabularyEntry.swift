import Foundation
import SwiftData

/// A preferred spelling or an explicit speech-recognition replacement.
/// Vocabulary remains in Lore's private archive and is never sent to processing providers by itself.
@Model
final class VocabularyEntry {
    var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) var phrase: String = ""
    @Attribute(.allowsCloudEncryption) var normalizedPhrase: String = ""
    @Attribute(.allowsCloudEncryption) var replacement: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        phrase: String,
        replacement: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.phrase = phrase
        self.normalizedPhrase = Self.normalizedKey(for: phrase)
        self.replacement = replacement
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isReplacement: Bool {
        replacement?.isEmpty == false
    }

    static func normalizedKey(for phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
    }
}
