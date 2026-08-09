import Foundation
import SwiftData

/// Model representing a single captured story entry.
@Model
final class Story {
    var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) var text: String = ""
    @Attribute(.allowsCloudEncryption) var date: Date = Date()
    @Attribute(.allowsCloudEncryption) var duration: TimeInterval = 0
    var rawTranscriptExpiresAt: Date?
    var metadataId: UUID?
    @Attribute(.allowsCloudEncryption) var biographyProse: String?
    @Attribute(.allowsCloudEncryption) var title: String?
    var processingStatus: String = "captured"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        text: String,
        date: Date,
        duration: TimeInterval,
        rawTranscriptExpiresAt: Date? = nil,
        metadataId: UUID? = nil,
        biographyProse: String? = nil,
        title: String? = nil,
        processingStatus: String = "captured",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
        self.rawTranscriptExpiresAt = rawTranscriptExpiresAt
        self.metadataId = metadataId
        self.biographyProse = biographyProse
        self.title = title
        self.processingStatus = processingStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Computed property for formatted date display.
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    /// Computed property for formatted duration display.
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

extension Story: Equatable {
    static func == (lhs: Story, rhs: Story) -> Bool {
        lhs.id == rhs.id
    }
}
