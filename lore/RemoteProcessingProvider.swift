import Foundation

enum RemoteRetentionMode: String, Codable, CaseIterable, Sendable {
    /// The backend and provider must treat request content as ephemeral and
    /// attest that no durable content was retained.
    case zeroDataRetention = "request_ephemeral"
    case deleteImmediatelyAfterProcessing = "delete_immediately_after_processing"
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
    var chunkIndex: Int
    var chunkCount: Int
    var startMilliseconds: Int
    var languageCode: String?
    var vocabularyHints: [String]
    var retentionPolicy: RemoteRetentionPolicy

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        jobId: UUID,
        audio: RemoteAudioPayload,
        chunkIndex: Int = 0,
        chunkCount: Int = 1,
        startMilliseconds: Int = 0,
        languageCode: String? = nil,
        vocabularyHints: [String] = [],
        retentionPolicy: RemoteRetentionPolicy = RemoteRetentionPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.audio = audio
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.startMilliseconds = startMilliseconds
        self.languageCode = languageCode
        self.vocabularyHints = vocabularyHints
        self.retentionPolicy = retentionPolicy
    }
}

struct TranscriptSourceSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var chunkId: String? = nil
    var startMilliseconds: Int
    var endMilliseconds: Int
    var text: String
    var confidence: Double?
    var speakerLabel: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case chunkId
        case startMilliseconds
        case endMilliseconds
        case text
        case confidence
        case speakerLabel
    }

    init(
        id: String,
        chunkId: String? = nil,
        startMilliseconds: Int,
        endMilliseconds: Int,
        text: String,
        confidence: Double?,
        speakerLabel: String?
    ) {
        self.id = id
        self.chunkId = chunkId
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.confidence = confidence
        self.speakerLabel = speakerLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chunkId = try container.decodeIfPresent(String.self, forKey: .chunkId)
        startMilliseconds = try container.decode(Int.self, forKey: .startMilliseconds)
        endMilliseconds = try container.decode(Int.self, forKey: .endMilliseconds)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(chunkId, forKey: .chunkId)
        try container.encode(startMilliseconds, forKey: .startMilliseconds)
        try container.encode(endMilliseconds, forKey: .endMilliseconds)
        try container.encode(text, forKey: .text)

        // The wire contract represents unavailable segment metadata as JSON
        // null. Synthesized Codable omits nil optionals, which caused older
        // backends to reject an otherwise valid daily-entry request.
        if let confidence {
            try container.encode(confidence, forKey: .confidence)
        } else {
            try container.encodeNil(forKey: .confidence)
        }
        if let speakerLabel {
            try container.encode(speakerLabel, forKey: .speakerLabel)
        } else {
            try container.encodeNil(forKey: .speakerLabel)
        }
    }
}

struct RemoteRetentionAttestation: Codable, Equatable, Sendable {
    var mode: RemoteRetentionMode
    var maximumRetentionSeconds: Int
    var policyVersion: String
    var attestedAt: Date
}

struct RemoteProcessingProvenance: Codable, Equatable, Sendable {
    var providerId: String
    var modelAlias: String
    var modelId: String
    var modelPolicyVersion: String
    var providerRequestId: String?
    var processedAt: Date
    var processingDurationMilliseconds: Int
    var retentionAttestation: RemoteRetentionAttestation
}

struct RemoteTranscriptionChunk: Codable, Equatable, Sendable {
    var id: String
    var index: Int
    var count: Int
    var startMilliseconds: Int
    var durationMilliseconds: Int
}

struct RemoteTranscriptionResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var jobId: UUID
    var requestId: String
    var chunk: RemoteTranscriptionChunk
    var transcript: String
    var languageCode: String?
    var segments: [TranscriptSourceSegment]
    var provenance: RemoteProcessingProvenance
}

enum JournalPerspective: String, Codable, CaseIterable, Sendable {
    case firstPerson = "first_person"
    case thirdPerson = "third_person"
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
    case personAlias = "person_alias"
    case relationship
    case lifeEvent = "life_event"
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
    case flagConflict = "flag_conflict"
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
    var promptVersion: String
    var jobId: UUID
    var requestId: String
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
    case invalidConfiguration
    case invalidRequest
    case payloadTooLarge(maximumBytes: Int)
    case cancelled
    case transportUnavailable
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse(requestId: String?)
    case rejected(code: String, retryable: Bool, retryAfterSeconds: Int?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote processing is not configured."
        case .invalidConfiguration:
            return "Remote processing has an invalid configuration."
        case .invalidRequest:
            return "The processing request is invalid."
        case let .payloadTooLarge(maximumBytes):
            return "The audio is larger than the supported \(maximumBytes)-byte chunk size."
        case .cancelled:
            return "The processing request was cancelled."
        case .transportUnavailable:
            return "Remote processing is temporarily unavailable."
        case let .rateLimited(retryAfterSeconds):
            if let retryAfterSeconds {
                return "Remote processing is busy. Try again in \(retryAfterSeconds) seconds."
            }
            return "Remote processing is busy. Please try again shortly."
        case .invalidResponse:
            return "The processing service returned an invalid response."
        case let .rejected(code, _, _):
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
