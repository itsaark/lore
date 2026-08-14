import Foundation
import SwiftData

enum ReflectionSessionState: String, Codable, CaseIterable, Sendable {
    case active
    case finalizing
    case completed
    case failed
    case discarded
}

@Model
final class ReflectionSession {
    private(set) var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) private(set) var startedAt: Date = Date()
    @Attribute(.allowsCloudEncryption) private(set) var endedAt: Date?
    @Attribute(.allowsCloudEncryption) private(set) var capturedLocalDate: String = ""
    private(set) var stateValue: String = ReflectionSessionState.active.rawValue
    private(set) var storyId: UUID?
    private(set) var transcriptArtifactId: UUID?
    private(set) var resultArtifactId: UUID?
    private(set) var sttModelAlias: String = "reflection-stt-v1"
    private(set) var ttsModelAlias: String = "reflection-voice-v1"
    private(set) var guideModelAlias: String = "reflection-guide-v1"
    private(set) var entryModelAlias: String = "reflection-entry-v1"
    private(set) var policyVersion: String = ""
    private(set) var schemaVersion: String = ReflectionFinalizationRequest.currentSchemaVersion
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        capturedLocalDate: String,
        state: ReflectionSessionState = .active,
        storyId: UUID? = nil,
        transcriptArtifactId: UUID? = nil,
        resultArtifactId: UUID? = nil,
        sttModelAlias: String = "reflection-stt-v1",
        ttsModelAlias: String = "reflection-voice-v1",
        guideModelAlias: String = "reflection-guide-v1",
        entryModelAlias: String = "reflection-entry-v1",
        policyVersion: String = "",
        schemaVersion: String = ReflectionFinalizationRequest.currentSchemaVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.capturedLocalDate = capturedLocalDate
        self.stateValue = state.rawValue
        self.storyId = storyId
        self.transcriptArtifactId = transcriptArtifactId
        self.resultArtifactId = resultArtifactId
        self.sttModelAlias = sttModelAlias
        self.ttsModelAlias = ttsModelAlias
        self.guideModelAlias = guideModelAlias
        self.entryModelAlias = entryModelAlias
        self.policyVersion = policyVersion
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var state: ReflectionSessionState {
        ReflectionSessionState(rawValue: stateValue) ?? .failed
    }

    func beginFinalization(
        storyId: UUID,
        transcriptArtifactId: UUID,
        endedAt: Date
    ) {
        self.storyId = storyId
        self.transcriptArtifactId = transcriptArtifactId
        self.endedAt = endedAt
        stateValue = ReflectionSessionState.finalizing.rawValue
        updatedAt = endedAt
    }

    func markCompleted(resultArtifactId: UUID, at date: Date = Date()) {
        self.resultArtifactId = resultArtifactId
        stateValue = ReflectionSessionState.completed.rawValue
        endedAt = endedAt ?? date
        updatedAt = date
    }

    func markFailed(at date: Date = Date()) {
        stateValue = ReflectionSessionState.failed.rawValue
        endedAt = endedAt ?? date
        updatedAt = date
    }

    func discard(at date: Date = Date()) {
        stateValue = ReflectionSessionState.discarded.rawValue
        endedAt = date
        updatedAt = date
    }
}

@Model
final class ReflectionTurn {
    private(set) var id: UUID = UUID()
    private(set) var sessionId: UUID = UUID()
    private(set) var sequence: Int = 0
    private(set) var roleValue: String = ReflectionConversationRole.user.rawValue
    @Attribute(.allowsCloudEncryption) private(set) var text: String = ""
    private(set) var isEvidenceEligible: Bool = false
    @Attribute(.allowsCloudEncryption) private(set) var startedAt: Date = Date()
    @Attribute(.allowsCloudEncryption) private(set) var endedAt: Date = Date()
    private(set) var languageCode: String?
    private(set) var confidence: Double?
    @Attribute(.allowsCloudEncryption) private(set) var sourceSegmentsJSON: String = "[]"
    private(set) var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        sequence: Int,
        role: ReflectionConversationRole,
        text: String,
        isEvidenceEligible: Bool,
        startedAt: Date,
        endedAt: Date,
        languageCode: String? = nil,
        confidence: Double? = nil,
        sourceSegmentsJSON: String = "[]",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sequence = sequence
        self.roleValue = role.rawValue
        self.text = text
        self.isEvidenceEligible = isEvidenceEligible
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.languageCode = languageCode
        self.confidence = confidence
        self.sourceSegmentsJSON = sourceSegmentsJSON
        self.createdAt = createdAt
    }

    var role: ReflectionConversationRole {
        ReflectionConversationRole(rawValue: roleValue) ?? .user
    }

    static func committed(
        id: UUID = UUID(),
        sessionId: UUID,
        sequence: Int,
        role: ReflectionConversationRole,
        text: String,
        startedAt: Date,
        endedAt: Date,
        languageCode: String? = nil,
        confidence: Double? = nil,
        sourceSegments: [TranscriptSourceSegment] = [],
        createdAt: Date = Date()
    ) throws -> ReflectionTurn {
        let data = try ReflectionPersistenceCoding.encoder.encode(sourceSegments)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReflectionPersistenceError.encodingFailed
        }
        return ReflectionTurn(
            id: id,
            sessionId: sessionId,
            sequence: sequence,
            role: role,
            text: text,
            isEvidenceEligible: role == .user,
            startedAt: startedAt,
            endedAt: endedAt,
            languageCode: languageCode,
            confidence: confidence,
            sourceSegmentsJSON: json,
            createdAt: createdAt
        )
    }

    func decodedSourceSegments() throws -> [TranscriptSourceSegment] {
        try ReflectionPersistenceCoding.decoder.decode(
            [TranscriptSourceSegment].self,
            from: Data(sourceSegmentsJSON.utf8)
        )
    }

    var conversationTurn: ReflectionConversationTurn {
        ReflectionConversationTurn(
            id: id,
            sequence: sequence,
            role: role,
            text: text,
            isEvidenceEligible: isEvidenceEligible
        )
    }
}

struct ReflectionFinalizationPackage {
    let story: Story
    let transcriptArtifact: TranscriptArtifact
    let transcriptVersion: TranscriptVersion
    let job: ProcessingJob
    let request: ReflectionFinalizationRequest
}

enum ReflectionPersistenceError: Error, LocalizedError, Equatable {
    case invalidSessionState
    case invalidTurns
    case missingSession
    case missingTurnSourceSegments
    case encodingFailed
    case identifierMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSessionState:
            return "The reflection is not ready to be finalized."
        case .invalidTurns:
            return "The reflection contains invalid or unfinished turns."
        case .missingSession:
            return "The reflection session is not stored locally."
        case .missingTurnSourceSegments:
            return "A user turn is missing its finalized transcript evidence."
        case .encodingFailed:
            return "Lore could not encode the reflection transcript."
        case .identifierMismatch:
            return "The reflection result does not match its stored source."
        }
    }
}

@MainActor
enum ReflectionSourceCommitter {
    static func freeze(
        session: ReflectionSession,
        turns: [ReflectionTurn],
        languageCode: String,
        subject: JournalSubject,
        acceptedPriorFacts: [JournalPriorFact] = [],
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws -> ReflectionFinalizationPackage {
        guard session.state == .active else {
            throw ReflectionPersistenceError.invalidSessionState
        }
        let sessions = try modelContext.fetch(FetchDescriptor<ReflectionSession>())
        guard sessions.contains(where: { $0.id == session.id }) else {
            throw ReflectionPersistenceError.missingSession
        }

        let orderedTurns = turns.sorted { $0.sequence < $1.sequence }
        let storedTurnIds = Set(
            try modelContext.fetch(FetchDescriptor<ReflectionTurn>())
                .filter { $0.sessionId == session.id }
                .map(\.id)
        )
        guard
            !orderedTurns.isEmpty,
            orderedTurns.allSatisfy({ $0.sessionId == session.id }),
            Set(orderedTurns.map(\.id)).isSubset(of: storedTurnIds),
            Set(orderedTurns.map(\.id)).count == orderedTurns.count,
            Set(orderedTurns.map(\.sequence)).count == orderedTurns.count,
            orderedTurns.allSatisfy({
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.endedAt >= $0.startedAt
                    && ($0.isEvidenceEligible == ($0.role == .user))
            })
        else {
            throw ReflectionPersistenceError.invalidTurns
        }

        let userTurns = orderedTurns.filter { $0.role == .user }
        guard !userTurns.isEmpty else {
            throw ReflectionPersistenceError.invalidTurns
        }

        var evidenceTurns: [ReflectionEvidenceTurn] = []
        var sourceSegments: [TranscriptSourceSegment] = []
        for turn in userTurns {
            let segments = try turn.decodedSourceSegments()
            guard
                !segments.isEmpty,
                segments.allSatisfy({
                    !$0.id.isEmpty
                        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && $0.endMilliseconds >= $0.startMilliseconds
                })
            else {
                throw ReflectionPersistenceError.missingTurnSourceSegments
            }
            evidenceTurns.append(ReflectionEvidenceTurn(
                turnId: turn.id,
                sourceSegmentIds: segments.map(\.id)
            ))
            sourceSegments.append(contentsOf: segments)
        }
        guard Set(sourceSegments.map(\.id)).count == sourceSegments.count else {
            throw ReflectionPersistenceError.invalidTurns
        }

        // The backend contract reuses `note_id` as the source identity and
        // requires it to equal the reflection session ID.
        let storyId = session.id
        let transcriptArtifactId = UUID()
        let transcriptVersionId = UUID()
        let jobId = UUID()
        let userText = userTurns.map(\.text).joined(separator: "\n\n")
        let duration = max(0, date.timeIntervalSince(session.startedAt))
        let sourceSegmentsJSON: String
        do {
            let data = try ReflectionPersistenceCoding.encoder.encode(sourceSegments)
            guard let value = String(data: data, encoding: .utf8) else {
                throw ReflectionPersistenceError.encodingFailed
            }
            sourceSegmentsJSON = value
        } catch let error as ReflectionPersistenceError {
            throw error
        } catch {
            throw ReflectionPersistenceError.encodingFailed
        }

        let story = Story(
            id: storyId,
            text: userText,
            date: session.startedAt,
            duration: duration,
            processingStatus: "awaitingModel",
            sourceKind: .reflection,
            createdAt: date,
            updatedAt: date
        )
        let transcriptArtifact = TranscriptArtifact(
            id: transcriptArtifactId,
            storyId: storyId,
            rawText: userText,
            source: .remoteProvider,
            languageCode: languageCode,
            providerId: "soniox",
            providerModelId: session.sttModelAlias,
            sourceSegmentsJSON: sourceSegmentsJSON,
            capturedAt: session.startedAt,
            transcribedAt: date,
            audioDuration: duration,
            createdAt: date
        )
        let transcriptVersion = TranscriptVersion(
            id: transcriptVersionId,
            transcriptArtifactId: transcriptArtifactId,
            storyId: storyId,
            revision: 1,
            text: userText,
            kind: .sourceSnapshot,
            author: .source,
            createdAt: date
        )
        let job = ProcessingJob(
            id: jobId,
            idempotencyKey: "reflection-finalize:\(jobId.uuidString.lowercased())",
            storyId: storyId,
            transcriptArtifactId: transcriptArtifactId,
            inputTranscriptVersionId: transcriptVersionId,
            kind: .dailyEntry,
            state: .queued,
            route: .remote,
            requestSchemaVersion: ReflectionFinalizationRequest.currentSchemaVersion,
            deletionState: .notApplicable
        )
        let entryRequest = DailyEntryGenerationRequest(
            jobId: jobId,
            noteId: storyId,
            transcriptArtifactId: transcriptArtifactId,
            transcriptVersionId: transcriptVersionId,
            capturedLocalDate: session.capturedLocalDate,
            languageCode: languageCode,
            subject: subject,
            renderConfiguration: JournalRenderConfiguration(perspective: .thirdPerson),
            sourceSegments: sourceSegments,
            acceptedPriorFacts: acceptedPriorFacts
        )
        let request = ReflectionFinalizationRequest(
            sessionId: session.id,
            entryRequest: entryRequest,
            evidenceTurns: evidenceTurns,
            assistantTurns: orderedTurns.compactMap { turn in
                guard turn.role == .lore else { return nil }
                return ReflectionAssistantTurn(
                    turnId: turn.id,
                    sequence: turn.sequence,
                    text: turn.text
                )
            }
        )

        modelContext.insert(story)
        modelContext.insert(transcriptArtifact)
        modelContext.insert(transcriptVersion)
        modelContext.insert(job)
        session.beginFinalization(
            storyId: storyId,
            transcriptArtifactId: transcriptArtifactId,
            endedAt: date
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        return ReflectionFinalizationPackage(
            story: story,
            transcriptArtifact: transcriptArtifact,
            transcriptVersion: transcriptVersion,
            job: job,
            request: request
        )
    }

    /// Reconstructs the exact finalization boundary after a relaunch without
    /// persisting credentials, audio, or a second set of source artifacts.
    static func resumeFinalization(
        session: ReflectionSession,
        subject: JournalSubject,
        acceptedPriorFacts: [JournalPriorFact] = [],
        in modelContext: ModelContext
    ) throws -> ReflectionFinalizationPackage {
        guard
            session.state == .finalizing,
            let storyId = session.storyId,
            storyId == session.id,
            let transcriptArtifactId = session.transcriptArtifactId
        else {
            throw ReflectionPersistenceError.invalidSessionState
        }

        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        let transcripts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        let turns = try modelContext.fetch(FetchDescriptor<ReflectionTurn>())
            .filter { $0.sessionId == session.id }
            .sorted { $0.sequence < $1.sequence }
        guard
            let story = stories.first(where: { $0.id == storyId && $0.sourceKind == .reflection }),
            let transcript = transcripts.first(where: {
                $0.id == transcriptArtifactId && $0.storyId == storyId
            }),
            let version = versions.first(where: {
                $0.transcriptArtifactId == transcriptArtifactId && $0.storyId == storyId
            }),
            let job = jobs.first(where: {
                $0.storyId == storyId
                    && $0.transcriptArtifactId == transcriptArtifactId
                    && $0.inputTranscriptVersionId == version.id
                    && $0.kind == .dailyEntry
            }),
            !turns.isEmpty
        else {
            throw ReflectionPersistenceError.identifierMismatch
        }

        var sourceSegments: [TranscriptSourceSegment] = []
        var evidenceTurns: [ReflectionEvidenceTurn] = []
        for turn in turns where turn.role == .user {
            let segments = try turn.decodedSourceSegments()
            guard !segments.isEmpty else {
                throw ReflectionPersistenceError.missingTurnSourceSegments
            }
            sourceSegments.append(contentsOf: segments)
            evidenceTurns.append(ReflectionEvidenceTurn(
                turnId: turn.id,
                sourceSegmentIds: segments.map(\.id)
            ))
        }
        guard
            !evidenceTurns.isEmpty,
            Set(sourceSegments.map(\.id)).count == sourceSegments.count
        else {
            throw ReflectionPersistenceError.invalidTurns
        }

        let entryRequest = DailyEntryGenerationRequest(
            jobId: job.id,
            noteId: story.id,
            transcriptArtifactId: transcript.id,
            transcriptVersionId: version.id,
            capturedLocalDate: session.capturedLocalDate,
            languageCode: transcript.languageCode ?? "en",
            subject: subject,
            renderConfiguration: JournalRenderConfiguration(perspective: .thirdPerson),
            sourceSegments: sourceSegments,
            acceptedPriorFacts: acceptedPriorFacts
        )
        return ReflectionFinalizationPackage(
            story: story,
            transcriptArtifact: transcript,
            transcriptVersion: version,
            job: job,
            request: ReflectionFinalizationRequest(
                sessionId: session.id,
                entryRequest: entryRequest,
                evidenceTurns: evidenceTurns,
                assistantTurns: turns.compactMap { turn in
                    guard turn.role == .lore else { return nil }
                    return ReflectionAssistantTurn(
                        turnId: turn.id,
                        sequence: turn.sequence,
                        text: turn.text
                    )
                }
            )
        )
    }
}

@MainActor
enum ReflectionFinalizationPersister {
    @discardableResult
    static func persist(
        response: DailyEntryGenerationResponse,
        package: ReflectionFinalizationPackage,
        session: ReflectionSession,
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws -> DailyEntryResultArtifact {
        guard
            session.state == .finalizing,
            session.id == package.request.sessionId,
            session.storyId == package.story.id,
            session.transcriptArtifactId == package.transcriptArtifact.id,
            response.jobId == package.job.id
        else {
            throw ReflectionPersistenceError.identifierMismatch
        }

        let artifact = try DailyEntryResultPersister.persist(
            response: response,
            request: package.request.entryRequest,
            for: package.story,
            job: package.job,
            in: modelContext,
            at: date
        )
        session.markCompleted(resultArtifactId: artifact.id, at: date)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return artifact
    }
}

private enum ReflectionPersistenceCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
