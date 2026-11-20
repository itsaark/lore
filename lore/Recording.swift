import Foundation
import SwiftData

enum StorySourceKind: String, Codable, CaseIterable, Sendable {
    case note
    case reflection
}

enum RememberedTimeSource: String, Codable, Sendable {
    case pinned, inferred, user
}

enum MemoryAnchorState: String, Codable, Sendable {
    case pending, done
}

/// Inclusive local Gregorian dates. Day keys preserve the selected dates
/// when the phone changes time zone or the archive syncs to another device.
struct RememberedTime: Codable, Equatable, Sendable {
    enum Precision: String, Codable, Sendable {
        case day, week, month, year, period
    }

    let precision: Precision
    let startDate: String
    let endDate: String

    var isCoarse: Bool { precision != .day }
}

/// Model representing a single captured story entry.
@Model
final class Story {
    var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) var text: String = ""
    @Attribute(.allowsCloudEncryption) var date: Date = Date()
    @Attribute(.allowsCloudEncryption) private(set) var rememberedTimePrecision: String?
    @Attribute(.allowsCloudEncryption) private(set) var rememberedTimeStart: String?
    @Attribute(.allowsCloudEncryption) private(set) var rememberedTimeEnd: String?
    @Attribute(.allowsCloudEncryption) private var rememberedTimeSourceValue: String?
    @Attribute(.allowsCloudEncryption) var rememberedTimeIsPrivate: Bool?
    @Attribute(.allowsCloudEncryption) var rememberedTimeUpdatedAt: Date?
    @Attribute(.allowsCloudEncryption) private var memoryAnchorStateValue: String?
    @Attribute(.allowsCloudEncryption) var duration: TimeInterval = 0
    var rawTranscriptExpiresAt: Date?
    var metadataId: UUID?
    @Attribute(.allowsCloudEncryption) var biographyProse: String?
    @Attribute(.allowsCloudEncryption) var title: String?
    var processingStatus: String = "captured"
    private(set) var sourceKindValue: String = StorySourceKind.note.rawValue
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
        sourceKind: StorySourceKind = .note,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rememberedTime: RememberedTime? = nil,
        rememberedTimeSource: RememberedTimeSource? = nil,
        rememberedTimeIsPrivate: Bool? = nil,
        rememberedTimeUpdatedAt: Date? = nil,
        memoryAnchorState: MemoryAnchorState? = nil
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
        self.sourceKindValue = sourceKind.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rememberedTime = rememberedTime
        self.rememberedTimeSource = rememberedTimeSource
        self.rememberedTimeIsPrivate = rememberedTimeIsPrivate
        self.rememberedTimeUpdatedAt = rememberedTimeUpdatedAt
        self.memoryAnchorState = memoryAnchorState
    }

    /// Existing remembered dates with no explicit source were pinned on capture.
    var rememberedTimeSource: RememberedTimeSource? {
        get { rememberedTimeSourceValue.flatMap(RememberedTimeSource.init(rawValue:)) }
        set { rememberedTimeSourceValue = newValue?.rawValue }
    }

    /// A nil state belongs to captures made before anchor inference shipped.
    var memoryAnchorState: MemoryAnchorState? {
        get { memoryAnchorStateValue.flatMap(MemoryAnchorState.init(rawValue:)) }
        set { memoryAnchorStateValue = newValue?.rawValue }
    }

    var rememberedTimeRequiresPrivacy: Bool {
        if let rememberedTimeIsPrivate { return rememberedTimeIsPrivate }
        return rememberedTimeSource == .inferred
            || (rememberedTimeSource == .user && rememberedTime?.precision == .period)
    }

    var rememberedTime: RememberedTime? {
        get {
            guard let raw = rememberedTimePrecision, let precision = RememberedTime.Precision(rawValue: raw),
                  let start = rememberedTimeStart, let end = rememberedTimeEnd, start <= end,
                  precision != .day || start == end else { return nil }
            return RememberedTime(precision: precision, startDate: start, endDate: end)
        }
        set {
            rememberedTimePrecision = newValue?.precision.rawValue
            rememberedTimeStart = newValue?.startDate
            rememberedTimeEnd = newValue?.endDate
        }
    }

    /// Coarse memories have their own entry and do not appear on a day page.
    func effectiveDayKey(recordedDayKey: @autoclosure () -> String) -> String? {
        guard let rememberedTime else { return recordedDayKey() }
        return rememberedTime.isCoarse ? nil : rememberedTime.startDate
    }

    var sourceKind: StorySourceKind {
        StorySourceKind(rawValue: sourceKindValue) ?? .note
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
