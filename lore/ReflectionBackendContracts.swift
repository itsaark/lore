import Foundation

enum ReflectionConversationRole: String, Codable, CaseIterable, Sendable {
    case user
    case lore
}

/// A bounded wire representation of a committed turn. Provisional STT text
/// must never be placed in this type.
struct ReflectionConversationTurn: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sequence: Int
    var role: ReflectionConversationRole
    var text: String
    var isEvidenceEligible: Bool

    init(
        id: UUID = UUID(),
        sequence: Int,
        role: ReflectionConversationRole,
        text: String,
        isEvidenceEligible: Bool
    ) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.text = text
        self.isEvidenceEligible = isEvidenceEligible
    }
}

struct ReflectionSessionCredentialsRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var sessionId: UUID
    var languageCode: String

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        sessionId: UUID,
        languageCode: String
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.languageCode = languageCode
    }
}

struct ReflectionSTTCredential: Codable, Equatable, Sendable {
    var temporaryApiKey: String
    var expiresAt: Date
    var websocketUrl: URL
    var modelAlias: String
    var audioFormat: String
    var sampleRate: Int
    var numChannels: Int
}

struct ReflectionTTSCredential: Codable, Equatable, Sendable {
    var temporaryApiKey: String
    var expiresAt: Date
    var websocketUrl: URL
    var modelAlias: String
    var voice: String
    var audioFormat: String
    var sampleRate: Int
}

/// Temporary keys are intentionally value-only and must remain in active
/// session memory. Callers must not log, serialize, or persist this response.
struct ReflectionSessionCredentialsResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var sessionId: UUID
    var stt: ReflectionSTTCredential
    var tts: ReflectionTTSCredential
    var maximumSessionDurationSeconds: Int
}

struct ReflectionResponseRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let currentPromptVersion = "reflection-guide-v1"

    var schemaVersion: String
    var promptVersion: String
    var sessionId: UUID
    var languageCode: String
    var subject: JournalSubject
    var turns: [ReflectionConversationTurn]
    var acceptedPriorFacts: [JournalPriorFact]
    var retentionPolicy: RemoteRetentionPolicy

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        promptVersion: String = Self.currentPromptVersion,
        sessionId: UUID,
        languageCode: String,
        subject: JournalSubject,
        turns: [ReflectionConversationTurn],
        acceptedPriorFacts: [JournalPriorFact] = [],
        retentionPolicy: RemoteRetentionPolicy = RemoteRetentionPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
        self.sessionId = sessionId
        self.languageCode = languageCode
        self.subject = subject
        self.turns = turns
        self.acceptedPriorFacts = acceptedPriorFacts
        self.retentionPolicy = retentionPolicy
    }
}

struct ReflectionResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    var schemaVersion: String
    var promptVersion: String
    var sessionId: UUID
    var requestId: String
    var spokenText: String
    var shouldOfferFinish: Bool
    var provenance: RemoteProcessingProvenance
}

struct ReflectionEvidenceTurn: Codable, Equatable, Sendable {
    var turnId: UUID
    var sourceSegmentIds: [String]
}

struct ReflectionAssistantTurn: Codable, Equatable, Sendable {
    var turnId: UUID
    var sequence: Int
    var text: String
}

struct ReflectionFinalizationRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let currentPromptVersion = "reflection-entry-v1"

    var schemaVersion: String
    var promptVersion: String
    var sessionId: UUID
    var entryRequest: DailyEntryGenerationRequest
    var evidenceTurns: [ReflectionEvidenceTurn]
    var assistantTurns: [ReflectionAssistantTurn]

    init(
        schemaVersion: String = Self.currentSchemaVersion,
        promptVersion: String = Self.currentPromptVersion,
        sessionId: UUID,
        entryRequest: DailyEntryGenerationRequest,
        evidenceTurns: [ReflectionEvidenceTurn],
        assistantTurns: [ReflectionAssistantTurn]
    ) {
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
        self.sessionId = sessionId
        self.entryRequest = entryRequest
        self.evidenceTurns = evidenceTurns
        self.assistantTurns = assistantTurns
    }
}

protocol LoreReflectionBackendClient: Sendable {
    func createReflectionSessionCredentials(
        _ request: ReflectionSessionCredentialsRequest
    ) async throws -> ReflectionSessionCredentialsResponse

    func generateReflectionResponse(
        _ request: ReflectionResponseRequest
    ) async throws -> ReflectionResponse

    func finalizeReflection(
        _ request: ReflectionFinalizationRequest
    ) async throws -> DailyEntryGenerationResponse
}

struct UnconfiguredLoreReflectionBackendClient: LoreReflectionBackendClient {
    func createReflectionSessionCredentials(
        _ request: ReflectionSessionCredentialsRequest
    ) async throws -> ReflectionSessionCredentialsResponse {
        throw LoreBackendProcessingError.notConfigured
    }

    func generateReflectionResponse(
        _ request: ReflectionResponseRequest
    ) async throws -> ReflectionResponse {
        throw LoreBackendProcessingError.notConfigured
    }

    func finalizeReflection(
        _ request: ReflectionFinalizationRequest
    ) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.notConfigured
    }
}
