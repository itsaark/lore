import Foundation
import SwiftData

/// Model representing a single captured story entry.
@Model
final class Story {
    @Attribute(.unique) var id: UUID
    var text: String
    var date: Date
    var duration: TimeInterval
    var rawTranscriptExpiresAt: Date?
    var biographyProse: String?
    var title: String?
    var processingStatus: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        date: Date,
        duration: TimeInterval,
        rawTranscriptExpiresAt: Date? = nil,
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
