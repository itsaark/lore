import Foundation

enum RemoteRetentionMode: String, Codable, CaseIterable, Sendable {
    case zeroDataRetention
    case deleteImmediatelyAfterProcessing
}

struct RemoteRetentionPolicy: Codable, Equatable, Sendable {
    var mode: RemoteRetentionMode
    var maximumRetentionSeconds: Int

    init(
        mode: RemoteRetentionMode = .zeroDataRetention,
        maximumRetentionSeconds: Int = 0
    ) {
        self.mode = mode
        self.maximumRetentionSeconds = max(0, maximumRetentionSeconds)
    }
}

struct RemoteAudioPayload: Codable, Equatable, Sendable {
    var bytes: Data
    var mimeType: String
    var filenameExtension: String
    var durationSeconds: TimeInterval

    init(
        bytes: Data,
        mimeType: String,
        filenameExtension: String,
        durationSeconds: TimeInterval
    ) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.filenameExtension = filenameExtension
        self.durationSeconds = durationSeconds
    }
}

struct RemoteTranscriptionRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var jobId: UUID
    var audio: RemoteAudioPayload
    var languageCode: String?
    var vocabularyHints: [String]
    var retentionPolicy: RemoteRetentionPolicy

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        jobId: UUID,
        audio: RemoteAudioPayload,
        languageCode: String? = nil,
        vocabularyHints: [String] = [],
        retentionPolicy: RemoteRetentionPolicy = RemoteRetentionPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.audio = audio
        self.languageCode = languageCode
        self.vocabularyHints = vocabularyHints
        self.retentionPolicy = retentionPolicy
    }
}

struct TranscriptSourceSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var startMilliseconds: Int
    var endMilliseconds: Int
    var text: String
    var confidence: Double?
    var speakerLabel: String?
}

struct RemoteDeletionReceipt: Codable, Equatable, Sendable {
    var mode: RemoteRetentionMode
    var acknowledgedAt: Date
    var providerReceiptId: String?
}

struct RemoteProcessingProvenance: Codable, Equatable, Sendable {
    var providerId: String
    var modelId: String
    var providerRequestId: String?
    var processedAt: Date
    var deletionReceipt: RemoteDeletionReceipt
}

struct RemoteTranscriptionResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var jobId: UUID
    var transcript: String
    var languageCode: String?
    var segments: [TranscriptSourceSegment]
    var provenance: RemoteProcessingProvenance
}

enum JournalPerspective: String, Codable, CaseIterable, Sendable {
    case firstPerson
    case thirdPerson
}

enum JournalTense: String, Codable, CaseIterable, Sendable {
    case past
    case present
}

struct JournalSubject: Codable, Equatable, Sendable {
    var displayName: String
    var pronouns: [String]
}

struct JournalRenderConfiguration: Codable, Equatable, Sendable {
    var perspective: JournalPerspective
    var tense: JournalTense
    var tone: String
    var targetWords: Int

    init(
        perspective: JournalPerspective = .thirdPerson,
        tense: JournalTense = .past,
        tone: String = "warm_restrained",
        targetWords: Int = 130
    ) {
        self.perspective = perspective
        self.tense = tense
        self.tone = tone
        self.targetWords = max(40, targetWords)
    }
}

struct JournalPriorFact: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var statement: String
    var status: String
    var sourceReferences: [String]
}

struct DailyEntryGenerationRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let currentPromptVersion = "grounded-journal-v1"

    var schemaVersion: String
    var promptVersion: String
    var jobId: UUID
    var noteId: UUID
    var transcriptArtifactId: UUID
    var transcriptVersionId: UUID
    var capturedLocalDate: String
    var languageCode: String
    var subject: JournalSubject
    var renderConfiguration: JournalRenderConfiguration
    var sourceSegments: [TranscriptSourceSegment]
    var acceptedPriorFacts: [JournalPriorFact]
    var retentionPolicy: RemoteRetentionPolicy

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        promptVersion: String = Self.currentPromptVersion,
        jobId: UUID,
        noteId: UUID,
        transcriptArtifactId: UUID,
        transcriptVersionId: UUID,
        capturedLocalDate: String,
        languageCode: String,
        subject: JournalSubject,
        renderConfiguration: JournalRenderConfiguration = JournalRenderConfiguration(),
        sourceSegments: [TranscriptSourceSegment],
        acceptedPriorFacts: [JournalPriorFact] = [],
        retentionPolicy: RemoteRetentionPolicy = RemoteRetentionPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
        self.jobId = jobId
        self.noteId = noteId
        self.transcriptArtifactId = transcriptArtifactId
        self.transcriptVersionId = transcriptVersionId
        self.capturedLocalDate = capturedLocalDate
        self.languageCode = languageCode
        self.subject = subject
        self.renderConfiguration = renderConfiguration
        self.sourceSegments = sourceSegments
        self.acceptedPriorFacts = acceptedPriorFacts
        self.retentionPolicy = retentionPolicy
    }
}

struct GroundedJournalSentence: Codable, Equatable, Sendable {
    var text: String
    var sourceReferences: [String]
    var factReferences: [String]
    var preservesUncertainty: Bool
}

struct GroundedJournalEntry: Codable, Equatable, Sendable {
    var title: String
    var titleSourceReferences: [String]
    var perspective: JournalPerspective
    var sentences: [GroundedJournalSentence]

    var prose: String {
        sentences.map(\.text).joined(separator: " ")
    }
}

enum JournalMemoryCandidateKind: String, Codable, CaseIterable, Sendable {
    case personAlias
    case relationship
    case lifeEvent
    case place
    case date
    case theme
    case preference
    case correction
    case other
}

enum JournalMemoryCandidateOperation: String, Codable, CaseIterable, Sendable {
    case add
    case confirm
    case correct
    case supersede
    case flagConflict
}

enum JournalCandidateConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

struct JournalMemoryCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: JournalMemoryCandidateKind
    var operation: JournalMemoryCandidateOperation
    var claim: String
    var confidence: JournalCandidateConfidence
    var sourceReferences: [String]
    var relatedFactIds: [String]
    var requiresUserReview: Bool
}

struct JournalUncertainty: Codable, Equatable, Sendable {
    var description: String
    var sourceReferences: [String]
    var suggestedQuestion: String?
}

struct JournalSensitiveOmission: Codable, Equatable, Sendable {
    var category: String
    var sourceReferences: [String]
}

struct JournalFollowUpQuestion: Codable, Equatable, Sendable {
    var question: String
    var reason: String
    var sourceReferences: [String]
}

struct DailyEntryGenerationResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var jobId: UUID
    var entry: GroundedJournalEntry
    var memoryCandidates: [JournalMemoryCandidate]
    var uncertainties: [JournalUncertainty]
    var sensitiveOmissions: [JournalSensitiveOmission]
    var qualityFlags: [String]
    var followUpQuestions: [JournalFollowUpQuestion]
    var provenance: RemoteProcessingProvenance
}

enum LoreBackendProcessingError: Error, LocalizedError, Equatable {
    case notConfigured
    case invalidResponse
    case rejected(code: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote processing is not configured."
        case .invalidResponse:
            return "The processing service returned an invalid response."
        case let .rejected(code):
            return "The processing service rejected the request (\(code))."
        }
    }
}

/// Boundary for Lore's own backend. Implementations may route to any approved
/// inference provider, but provider credentials never cross this interface or
/// ship in the app bundle.
protocol LoreBackendProcessingClient: Sendable {
    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse
}

struct UnconfiguredLoreBackendProcessingClient: LoreBackendProcessingClient {
    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse {
        throw LoreBackendProcessingError.notConfigured
    }

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.notConfigured
    }
}
