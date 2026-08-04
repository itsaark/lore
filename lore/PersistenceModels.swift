import Foundation
import SwiftData

enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case appleSpeech
    case remoteProvider
    case imported
    case legacyStory
}

enum TranscriptVersionAuthor: String, Codable, CaseIterable, Sendable {
    case source
    case user
    case system
}

enum TranscriptVersionKind: String, Codable, CaseIterable, Sendable {
    case sourceSnapshot
    case userCorrection
    case automaticCorrection
}

/// The immutable, verbatim output of one transcription pass.
///
/// Corrections belong in `TranscriptVersion`; callers must never rewrite
/// `rawText`. UUID references intentionally keep this additive and avoid
/// changing the existing `Story` model during lightweight migration.
@Model
final class TranscriptArtifact {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var storyId: UUID?
    private(set) var audioAssetId: UUID?
    private(set) var rawText: String
    private(set) var sourceValue: String
    private(set) var languageCode: String?
    private(set) var providerId: String?
    private(set) var providerModelId: String?
    private(set) var providerRequestId: String?
    private(set) var sourceSegmentsJSON: String?
    private(set) var providerProvenanceJSON: String?
    private(set) var capturedAt: Date
    private(set) var transcribedAt: Date
    private(set) var audioDuration: TimeInterval
    private(set) var createdAt: Date

    init(
        id: UUID = UUID(),
        storyId: UUID? = nil,
        audioAssetId: UUID? = nil,
        rawText: String,
        source: TranscriptSource,
        languageCode: String? = nil,
        providerId: String? = nil,
        providerModelId: String? = nil,
        providerRequestId: String? = nil,
        sourceSegmentsJSON: String? = nil,
        providerProvenanceJSON: String? = nil,
        capturedAt: Date,
        transcribedAt: Date = Date(),
        audioDuration: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.storyId = storyId
        self.audioAssetId = audioAssetId
        self.rawText = rawText
        self.sourceValue = source.rawValue
        self.languageCode = languageCode
        self.providerId = providerId
        self.providerModelId = providerModelId
        self.providerRequestId = providerRequestId
        self.sourceSegmentsJSON = sourceSegmentsJSON
        self.providerProvenanceJSON = providerProvenanceJSON
        self.capturedAt = capturedAt
        self.transcribedAt = transcribedAt
        self.audioDuration = audioDuration
        self.createdAt = createdAt
    }

    var source: TranscriptSource {
        TranscriptSource(rawValue: sourceValue) ?? .imported
    }
}

/// An immutable revision layered over a `TranscriptArtifact`.
///
/// A correction creates a new row and points at the version it supersedes.
/// This preserves the raw transcript and the complete correction history.
@Model
final class TranscriptVersion {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var transcriptArtifactId: UUID
    private(set) var storyId: UUID?
    private(set) var supersedesVersionId: UUID?
    private(set) var revision: Int
    private(set) var text: String
    private(set) var kindValue: String
    private(set) var authorValue: String
    private(set) var editSummary: String?
    private(set) var createdAt: Date

    init(
        id: UUID = UUID(),
        transcriptArtifactId: UUID,
        storyId: UUID? = nil,
        supersedesVersionId: UUID? = nil,
        revision: Int,
        text: String,
        kind: TranscriptVersionKind,
        author: TranscriptVersionAuthor,
        editSummary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptArtifactId = transcriptArtifactId
        self.storyId = storyId
        self.supersedesVersionId = supersedesVersionId
        self.revision = revision
        self.text = text
        self.kindValue = kind.rawValue
        self.authorValue = author.rawValue
        self.editSummary = editSummary
        self.createdAt = createdAt
    }

    var kind: TranscriptVersionKind {
        TranscriptVersionKind(rawValue: kindValue) ?? .sourceSnapshot
    }

    var author: TranscriptVersionAuthor {
        TranscriptVersionAuthor(rawValue: authorValue) ?? .system
    }
}

enum ProcessingJobKind: String, Codable, CaseIterable, Sendable {
    case transcription
    case dailyEntry
    case dailyBiography
    case memoryExtraction
    case biographyReconciliation
}

enum ProcessingJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case waitingForNetwork
    case waitingForConsent
    case running
    case succeeded
    case failed
    case cancelled
}

enum ProcessingExecutionRoute: String, Codable, CaseIterable, Sendable {
    case remote
}

enum RemoteContentDeletionState: String, Codable, CaseIterable, Sendable {
    case notApplicable
    case required
    case acknowledged
    case failed
}

/// Durable orchestration state. It deliberately stores references and
/// content-free error metadata, never audio bytes, transcript text, prompts,
/// or generated prose.
@Model
final class ProcessingJob {
    @Attribute(.unique) private(set) var id: UUID
    @Attribute(.unique) private(set) var idempotencyKey: String
    private(set) var storyId: UUID?
    private(set) var transcriptArtifactId: UUID?
    private(set) var inputTranscriptVersionId: UUID?
    var outputReferenceId: UUID?
    private(set) var kindValue: String
    private(set) var stateValue: String
    private(set) var routeValue: String
    var providerId: String?
    var providerModelId: String?
    private(set) var requestSchemaVersion: String
    var resultSchemaVersion: String?
    var attemptCount: Int
    var maximumAttempts: Int
    private(set) var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var nextAttemptAt: Date?
    var leaseExpiresAt: Date?
    var lastErrorCode: String?
    private(set) var deletionStateValue: String
    var remoteContentDeletedAt: Date?

    init(
        id: UUID = UUID(),
        idempotencyKey: String,
        storyId: UUID? = nil,
        transcriptArtifactId: UUID? = nil,
        inputTranscriptVersionId: UUID? = nil,
        outputReferenceId: UUID? = nil,
        kind: ProcessingJobKind,
        state: ProcessingJobState = .queued,
        route: ProcessingExecutionRoute = .remote,
        providerId: String? = nil,
        providerModelId: String? = nil,
        requestSchemaVersion: String = "1.0",
        resultSchemaVersion: String? = nil,
        attemptCount: Int = 0,
        maximumAttempts: Int = 3,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        leaseExpiresAt: Date? = nil,
        lastErrorCode: String? = nil,
        deletionState: RemoteContentDeletionState = .notApplicable,
        remoteContentDeletedAt: Date? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.storyId = storyId
        self.transcriptArtifactId = transcriptArtifactId
        self.inputTranscriptVersionId = inputTranscriptVersionId
        self.outputReferenceId = outputReferenceId
        self.kindValue = kind.rawValue
        self.stateValue = state.rawValue
        self.routeValue = route.rawValue
        self.providerId = providerId
        self.providerModelId = providerModelId
        self.requestSchemaVersion = requestSchemaVersion
        self.resultSchemaVersion = resultSchemaVersion
        self.attemptCount = attemptCount
        self.maximumAttempts = maximumAttempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.nextAttemptAt = nextAttemptAt
        self.leaseExpiresAt = leaseExpiresAt
        self.lastErrorCode = lastErrorCode
        self.deletionStateValue = deletionState.rawValue
        self.remoteContentDeletedAt = remoteContentDeletedAt
    }

    var kind: ProcessingJobKind {
        ProcessingJobKind(rawValue: kindValue) ?? .dailyEntry
    }

    var state: ProcessingJobState {
        get { ProcessingJobState(rawValue: stateValue) ?? .queued }
        set {
            stateValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var route: ProcessingExecutionRoute {
        get { ProcessingExecutionRoute(rawValue: routeValue) ?? .remote }
        set {
            routeValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var deletionState: RemoteContentDeletionState {
        get { RemoteContentDeletionState(rawValue: deletionStateValue) ?? .notApplicable }
        set {
            deletionStateValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    func beginAttempt(at date: Date = Date(), leaseDuration: TimeInterval = 120) {
        attemptCount += 1
        stateValue = ProcessingJobState.running.rawValue
        startedAt = date
        completedAt = nil
        nextAttemptAt = nil
        leaseExpiresAt = date.addingTimeInterval(max(1, leaseDuration))
        lastErrorCode = nil
        updatedAt = date
    }

    /// Returns an interrupted attempt to the durable queue after its lease expires.
    /// The attempt count is intentionally preserved so relaunch recovery cannot retry forever.
    @discardableResult
    func recoverExpiredLease(at date: Date = Date()) -> Bool {
        guard state == .running,
              let leaseExpiresAt,
              leaseExpiresAt <= date else {
            return false
        }

        let attemptsExhausted = attemptCount >= maximumAttempts
        stateValue = attemptsExhausted
            ? ProcessingJobState.failed.rawValue
            : ProcessingJobState.queued.rawValue
        completedAt = attemptsExhausted ? date : nil
        nextAttemptAt = attemptsExhausted ? nil : date
        self.leaseExpiresAt = nil
        lastErrorCode = "interrupted_attempt"
        updatedAt = date
        return true
    }

    func isReadyForAttempt(at date: Date = Date()) -> Bool {
        guard state == .queued, attemptCount < maximumAttempts else {
            return false
        }
        return nextAttemptAt.map { $0 <= date } ?? true
    }

    func markSucceeded(
        outputReferenceId: UUID? = nil,
        transcriptArtifactId: UUID? = nil,
        resultSchemaVersion: String? = nil,
        at date: Date = Date()
    ) {
        self.outputReferenceId = outputReferenceId
        if let transcriptArtifactId {
            self.transcriptArtifactId = transcriptArtifactId
        }
        self.resultSchemaVersion = resultSchemaVersion
        stateValue = ProcessingJobState.succeeded.rawValue
        completedAt = date
        leaseExpiresAt = nil
        nextAttemptAt = nil
        lastErrorCode = nil
        updatedAt = date
    }

    func markFailed(
        errorCode: String,
        retryAt: Date? = nil,
        at date: Date = Date()
    ) {
        lastErrorCode = errorCode
        completedAt = retryAt == nil ? date : nil
        nextAttemptAt = retryAt
        leaseExpiresAt = nil
        stateValue = (retryAt == nil ? ProcessingJobState.failed : .queued).rawValue
        updatedAt = date
    }

    /// Requeues a terminal request only when a newer client can repair the
    /// exact contract failure. The existing attempt ceiling remains in force,
    /// so a malformed request can never be retried indefinitely.
    @discardableResult
    func requeueFailedRequest(
        matchingErrorCode errorCode: String,
        at date: Date = Date()
    ) -> Bool {
        guard state == .failed,
              lastErrorCode == errorCode,
              attemptCount < maximumAttempts else {
            return false
        }

        stateValue = ProcessingJobState.queued.rawValue
        completedAt = nil
        nextAttemptAt = date
        leaseExpiresAt = nil
        updatedAt = date
        return true
    }

    func cancel(at date: Date = Date()) {
        stateValue = ProcessingJobState.cancelled.rawValue
        completedAt = date
        nextAttemptAt = nil
        leaseExpiresAt = nil
        updatedAt = date
    }

    func acknowledgeRemoteContentDeletion(at date: Date = Date()) {
        deletionStateValue = RemoteContentDeletionState.acknowledged.rawValue
        remoteContentDeletedAt = date
        updatedAt = date
    }
}

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
