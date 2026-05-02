import Foundation
import SwiftData

@Model
final class AudioAsset {
    @Attribute(.unique) var id: UUID
    var fileURL: String
    var createdAt: Date
    var expiresAt: Date
    var duration: TimeInterval
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        fileURL: String,
        createdAt: Date = Date(),
        expiresAt: Date,
        duration: TimeInterval,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.duration = duration
        self.isDeleted = isDeleted
    }
}
@Model
final class StoryMetadata {
    @Attribute(.unique) var id: UUID
    var captureDate: Date
    var timezone: String
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    var weatherSummary: String?
    var temperature: Double?
    var weatherSource: String?
    var permissionSnapshot: String?

    init(
        id: UUID = UUID(),
        captureDate: Date,
        timezone: String = TimeZone.current.identifier,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weatherSummary: String? = nil,
        temperature: Double? = nil,
        weatherSource: String? = nil,
        permissionSnapshot: String? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.timezone = timezone
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.weatherSummary = weatherSummary
        self.temperature = temperature
        self.weatherSource = weatherSource
        self.permissionSnapshot = permissionSnapshot
    }
}

@Model
final class BiographyFragment {
    @Attribute(.unique) var id: UUID
    var storyId: UUID
    var lifeEventIds: [UUID]
    var chapterId: UUID?
    var prose: String
    var style: String
    var modelName: String
    var modelVersion: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyId: UUID,
        lifeEventIds: [UUID] = [],
        chapterId: UUID? = nil,
        prose: String,
        style: String,
        modelName: String,
        modelVersion: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.storyId = storyId
        self.lifeEventIds = lifeEventIds
        self.chapterId = chapterId
        self.prose = prose
        self.style = style
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum LifeEventDateKind: String, Codable, CaseIterable, Sendable {
    case exact
    case approximate
    case range
    case unknown
}

@Model
final class LifeEvent {
    @Attribute(.unique) var id: UUID
    var title: String
    var summary: String
    var eventDateKind: String
    var eventStartDate: Date?
    var eventEndDate: Date?
    var approximateLabel: String?
    var confidence: Double
    var sourceStoryIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        summary: String = "",
        eventDateKind: LifeEventDateKind = .unknown,
        eventStartDate: Date? = nil,
        eventEndDate: Date? = nil,
        approximateLabel: String? = nil,
        confidence: Double = 0,
        sourceStoryIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.eventDateKind = eventDateKind.rawValue
        self.eventStartDate = eventStartDate
        self.eventEndDate = eventEndDate
        self.approximateLabel = approximateLabel
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var dateKind: LifeEventDateKind {
        LifeEventDateKind(rawValue: eventDateKind) ?? .unknown
    }
}

@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var aliases: [String]
    var relationshipToUser: String?
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        aliases: [String] = [],
        relationshipToUser: String? = nil,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.relationshipToUser = relationshipToUser
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Place {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var placeKind: String?
    var locationHint: String?
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        placeKind: String? = nil,
        locationHint: String? = nil,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.placeKind = placeKind
        self.locationHint = locationHint
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Theme {
    @Attribute(.unique) var id: UUID
    var name: String
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MemoryGraphExtractionResult: Codable, Equatable, Sendable {
    var lifeEvents: [LifeEventCandidate]
    var people: [PersonCandidate]
    var places: [PlaceCandidate]
    var themes: [ThemeCandidate]

    init(
        lifeEvents: [LifeEventCandidate] = [],
        people: [PersonCandidate] = [],
        places: [PlaceCandidate] = [],
        themes: [ThemeCandidate] = []
    ) {
        self.lifeEvents = lifeEvents
        self.people = people
        self.places = places
        self.themes = themes
    }

    enum CodingKeys: String, CodingKey {
        case lifeEvents
        case people
        case places
        case themes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifeEvents = try container.decodeIfPresent([LifeEventCandidate].self, forKey: .lifeEvents) ?? []
        people = try container.decodeIfPresent([PersonCandidate].self, forKey: .people) ?? []
        places = try container.decodeIfPresent([PlaceCandidate].self, forKey: .places) ?? []
        themes = try container.decodeIfPresent([ThemeCandidate].self, forKey: .themes) ?? []
    }
}

struct LifeEventCandidate: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var eventDateKind: LifeEventDateKind
    var eventStartDate: Date?
    var eventEndDate: Date?
    var approximateLabel: String?
    var confidence: Double
    var sourceStoryIds: [UUID]

    init(
        title: String,
        summary: String = "",
        eventDateKind: LifeEventDateKind = .unknown,
        eventStartDate: Date? = nil,
        eventEndDate: Date? = nil,
        approximateLabel: String? = nil,
        confidence: Double = 0,
        sourceStoryIds: [UUID] = []
    ) {
        self.title = title
        self.summary = summary
        self.eventDateKind = eventDateKind
        self.eventStartDate = eventStartDate
        self.eventEndDate = eventEndDate
        self.approximateLabel = approximateLabel
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
    }

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case eventDateKind
        case eventStartDate
        case eventEndDate
        case approximateLabel
        case confidence
        case sourceStoryIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        eventDateKind = try container.decodeIfPresent(LifeEventDateKind.self, forKey: .eventDateKind) ?? .unknown
        eventStartDate = CandidateDecoding.decodeDate(from: container, forKey: .eventStartDate)
        eventEndDate = CandidateDecoding.decodeDate(from: container, forKey: .eventEndDate)
        approximateLabel = try container.decodeIfPresent(String.self, forKey: .approximateLabel)
        confidence = CandidateDecoding.clampedConfidence(
            try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        )
        sourceStoryIds = CandidateDecoding.decodeStoryIds(from: container, forKey: .sourceStoryIds)
    }
}

struct PersonCandidate: Codable, Equatable, Sendable {
    var displayName: String
    var aliases: [String]
    var relationshipToUser: String?
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]

    init(
        displayName: String,
        aliases: [String] = [],
        relationshipToUser: String? = nil,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = []
    ) {
        self.displayName = displayName
        self.aliases = aliases
        self.relationshipToUser = relationshipToUser
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
    }

    enum CodingKeys: String, CodingKey {
        case displayName
        case aliases
        case relationshipToUser
        case summary
        case confidence
        case sourceStoryIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        relationshipToUser = try container.decodeIfPresent(String.self, forKey: .relationshipToUser)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        confidence = CandidateDecoding.clampedConfidence(
            try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        )
        sourceStoryIds = CandidateDecoding.decodeStoryIds(from: container, forKey: .sourceStoryIds)
    }
}

struct PlaceCandidate: Codable, Equatable, Sendable {
    var displayName: String
    var placeKind: String?
    var locationHint: String?
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]

    init(
        displayName: String,
        placeKind: String? = nil,
        locationHint: String? = nil,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = []
    ) {
        self.displayName = displayName
        self.placeKind = placeKind
        self.locationHint = locationHint
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
    }

    enum CodingKeys: String, CodingKey {
        case displayName
        case placeKind
        case locationHint
        case summary
        case confidence
        case sourceStoryIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        placeKind = try container.decodeIfPresent(String.self, forKey: .placeKind)
        locationHint = try container.decodeIfPresent(String.self, forKey: .locationHint)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        confidence = CandidateDecoding.clampedConfidence(
            try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        )
        sourceStoryIds = CandidateDecoding.decodeStoryIds(from: container, forKey: .sourceStoryIds)
    }
}

struct ThemeCandidate: Codable, Equatable, Sendable {
    var name: String
    var summary: String
    var confidence: Double
    var sourceStoryIds: [UUID]

    init(
        name: String,
        summary: String = "",
        confidence: Double = 0,
        sourceStoryIds: [UUID] = []
    ) {
        self.name = name
        self.summary = summary
        self.confidence = confidence
        self.sourceStoryIds = sourceStoryIds
    }

    enum CodingKeys: String, CodingKey {
        case name
        case summary
        case confidence
        case sourceStoryIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        confidence = CandidateDecoding.clampedConfidence(
            try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        )
        sourceStoryIds = CandidateDecoding.decodeStoryIds(from: container, forKey: .sourceStoryIds)
    }
}

private enum CandidateDecoding {
    static func decodeDate<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }

        if let timestamp = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: timestamp)
        }

        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        return parseDate(value)
    }

    static func decodeStoryIds<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [UUID] {
        if let ids = try? container.decodeIfPresent([UUID].self, forKey: key) {
            return ids
        }

        guard let values = try? container.decodeIfPresent([String].self, forKey: key) else {
            return []
        }

        return values.compactMap(UUID.init(uuidString:))
    }

    static func clampedConfidence(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter().date(from: trimmedValue) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for format in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmedValue) {
                return date
            }
        }

        return nil
    }
}
