import Foundation
import SwiftData

/// An immutable, privately synced snapshot of one completed daily-entry generation.
///
/// The canonical response and each structured section are stored as JSON so
/// future app versions can reinterpret memory candidates and review signals
/// without contacting the provider again. This artifact never contains audio.
@Model
final class DailyEntryResultArtifact {
    private(set) var id: UUID = UUID()
    private(set) var jobId: UUID = UUID()
    private(set) var storyId: UUID = UUID()
    private(set) var transcriptArtifactId: UUID = UUID()
    private(set) var transcriptVersionId: UUID = UUID()
    private(set) var biographyFragmentId: UUID = UUID()
    private(set) var revision: Int = 0
    private(set) var supersedesArtifactId: UUID?
    private(set) var schemaVersion: String = ""
    private(set) var promptVersion: String = ""
    private(set) var requestId: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var title: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var prose: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var responseJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var entryJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var memoryCandidatesJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var uncertaintiesJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var sensitiveOmissionsJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var qualityFlagsJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var followUpQuestionsJSON: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var provenanceJSON: String = ""
    private(set) var providerId: String = ""
    private(set) var providerModelAlias: String = ""
    private(set) var providerModelId: String = ""
    private(set) var providerModelPolicyVersion: String = ""
    private(set) var providerRequestId: String?
    private(set) var processedAt: Date = Date()
    private(set) var processingDurationMilliseconds: Int = 0
    private(set) var retentionModeValue: String = ""
    private(set) var maximumRetentionSeconds: Int = 0
    private(set) var retentionPolicyVersion: String = ""
    private(set) var retentionAttestedAt: Date = Date()
    private(set) var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        jobId: UUID,
        storyId: UUID,
        transcriptArtifactId: UUID,
        transcriptVersionId: UUID,
        biographyFragmentId: UUID,
        revision: Int,
        supersedesArtifactId: UUID?,
        response: DailyEntryGenerationResponse,
        responseJSON: String,
        entryJSON: String,
        memoryCandidatesJSON: String,
        uncertaintiesJSON: String,
        sensitiveOmissionsJSON: String,
        qualityFlagsJSON: String,
        followUpQuestionsJSON: String,
        provenanceJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobId = jobId
        self.storyId = storyId
        self.transcriptArtifactId = transcriptArtifactId
        self.transcriptVersionId = transcriptVersionId
        self.biographyFragmentId = biographyFragmentId
        self.revision = revision
        self.supersedesArtifactId = supersedesArtifactId
        self.schemaVersion = response.schemaVersion
        self.promptVersion = response.promptVersion
        self.requestId = response.requestId
        self.title = response.entry.title
        self.prose = response.entry.prose
        self.responseJSON = responseJSON
        self.entryJSON = entryJSON
        self.memoryCandidatesJSON = memoryCandidatesJSON
        self.uncertaintiesJSON = uncertaintiesJSON
        self.sensitiveOmissionsJSON = sensitiveOmissionsJSON
        self.qualityFlagsJSON = qualityFlagsJSON
        self.followUpQuestionsJSON = followUpQuestionsJSON
        self.provenanceJSON = provenanceJSON
        self.providerId = response.provenance.providerId
        self.providerModelAlias = response.provenance.modelAlias
        self.providerModelId = response.provenance.modelId
        self.providerModelPolicyVersion = response.provenance.modelPolicyVersion
        self.providerRequestId = response.provenance.providerRequestId
        self.processedAt = response.provenance.processedAt
        self.processingDurationMilliseconds = response.provenance.processingDurationMilliseconds
        self.retentionModeValue = response.provenance.retentionAttestation.mode.rawValue
        self.maximumRetentionSeconds = response.provenance.retentionAttestation.maximumRetentionSeconds
        self.retentionPolicyVersion = response.provenance.retentionAttestation.policyVersion
        self.retentionAttestedAt = response.provenance.retentionAttestation.attestedAt
        self.createdAt = createdAt
    }

    var retentionMode: RemoteRetentionMode? {
        RemoteRetentionMode(rawValue: retentionModeValue)
    }

    @MainActor
    func decodedResponse() throws -> DailyEntryGenerationResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            DailyEntryGenerationResponse.self,
            from: Data(responseJSON.utf8)
        )
    }
}

enum DailyEntryResultPersistenceError: Error, LocalizedError, Equatable {
    case invalidJobKind
    case identifierMismatch
    case missingStory
    case missingTranscriptArtifact
    case missingTranscriptVersion
    case invalidResponse
    case encodingFailed
    case idempotencyConflict
    case missingBiographyFragment

    var errorDescription: String? {
        switch self {
        case .invalidJobKind:
            return "The processing job is not a daily-entry job."
        case .identifierMismatch:
            return "The daily-entry result does not match its job, story, or transcript."
        case .missingStory:
            return "The source story is not stored locally."
        case .missingTranscriptArtifact:
            return "The source transcript artifact is not stored locally."
        case .missingTranscriptVersion:
            return "The source transcript version is not stored locally."
        case .invalidResponse:
            return "The daily-entry response is incomplete or not source-grounded."
        case .encodingFailed:
            return "Lore could not encode the daily-entry result for local storage."
        case .idempotencyConflict:
            return "This daily-entry job already stored a different result."
        case .missingBiographyFragment:
            return "The stored daily-entry result is missing its biography fragment."
        }
    }
}

/// Atomically installs a provider response into SwiftData.
///
/// `job.id` is the idempotency boundary. Replaying the exact same response
/// repairs derived Story/ProcessingJob state if needed but never creates a
/// second artifact or biography fragment. A later job for the same story
/// creates a new immutable artifact and links it to the prior revision.
@MainActor
enum DailyEntryResultPersister {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    @discardableResult
    static func persist(
        response: DailyEntryGenerationResponse,
        request: DailyEntryGenerationRequest,
        for story: Story,
        job: ProcessingJob,
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws -> DailyEntryResultArtifact {
        try validateIdentifiers(
            response: response,
            request: request,
            story: story,
            job: job,
            in: modelContext
        )
        try validateResponse(response, for: request)

        let encoded = try encode(response)
        let allArtifacts = try modelContext.fetch(FetchDescriptor<DailyEntryResultArtifact>())

        if let existing = allArtifacts.first(where: { $0.jobId == job.id }) {
            guard
                existing.storyId == story.id,
                existing.transcriptArtifactId == request.transcriptArtifactId,
                existing.transcriptVersionId == request.transcriptVersionId,
                existing.responseJSON == encoded.response
            else {
                throw DailyEntryResultPersistenceError.idempotencyConflict
            }

            let fragments = try modelContext.fetch(FetchDescriptor<BiographyFragment>())
            guard fragments.contains(where: { $0.id == existing.biographyFragmentId }) else {
                throw DailyEntryResultPersistenceError.missingBiographyFragment
            }

            try reconcileDerivedState(
                artifact: existing,
                response: response,
                story: story,
                job: job,
                in: modelContext,
                at: date
            )
            return existing
        }

        let prior = allArtifacts
            .filter { $0.storyId == story.id }
            .max { lhs, rhs in lhs.revision < rhs.revision }
        let revision = (prior?.revision ?? 0) + 1
        let fragmentId = UUID()
        let artifactId = UUID()
        let fragment = BiographyFragment(
            id: fragmentId,
            storyId: story.id,
            prose: response.entry.prose,
            style: response.entry.perspective.rawValue,
            modelName: response.provenance.modelId,
            modelVersion: response.provenance.modelPolicyVersion,
            createdAt: date,
            updatedAt: date
        )
        let artifact = DailyEntryResultArtifact(
            id: artifactId,
            jobId: job.id,
            storyId: story.id,
            transcriptArtifactId: request.transcriptArtifactId,
            transcriptVersionId: request.transcriptVersionId,
            biographyFragmentId: fragmentId,
            revision: revision,
            supersedesArtifactId: prior?.id,
            response: response,
            responseJSON: encoded.response,
            entryJSON: encoded.entry,
            memoryCandidatesJSON: encoded.memoryCandidates,
            uncertaintiesJSON: encoded.uncertainties,
            sensitiveOmissionsJSON: encoded.sensitiveOmissions,
            qualityFlagsJSON: encoded.qualityFlags,
            followUpQuestionsJSON: encoded.followUpQuestions,
            provenanceJSON: encoded.provenance,
            createdAt: date
        )

        modelContext.insert(fragment)
        modelContext.insert(artifact)

        do {
            applyDerivedState(
                artifact: artifact,
                response: response,
                story: story,
                job: job,
                at: date
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return artifact
    }

    /// Deletes locally persisted generated output for a story. The caller owns
    /// the surrounding transaction so story, transcript, job, and result rows
    /// can be removed together when deleting a note.
    @discardableResult
    static func deleteResults(
        for story: Story,
        in modelContext: ModelContext
    ) throws -> Int {
        let artifacts = try modelContext.fetch(FetchDescriptor<DailyEntryResultArtifact>())
            .filter { $0.storyId == story.id }
        let fragmentIds = Set(artifacts.map(\.biographyFragmentId))
        let fragments = try modelContext.fetch(FetchDescriptor<BiographyFragment>())
            .filter { fragmentIds.contains($0.id) }

        artifacts.forEach(modelContext.delete)
        fragments.forEach(modelContext.delete)
        return artifacts.count + fragments.count
    }

    private static func validateIdentifiers(
        response: DailyEntryGenerationResponse,
        request: DailyEntryGenerationRequest,
        story: Story,
        job: ProcessingJob,
        in modelContext: ModelContext
    ) throws {
        guard job.kind == .dailyEntry else {
            throw DailyEntryResultPersistenceError.invalidJobKind
        }
        guard
            response.jobId == request.jobId,
            request.jobId == job.id,
            request.noteId == story.id,
            job.storyId == story.id,
            job.transcriptArtifactId == request.transcriptArtifactId,
            job.inputTranscriptVersionId == request.transcriptVersionId
        else {
            throw DailyEntryResultPersistenceError.identifierMismatch
        }

        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        guard stories.contains(where: { $0.id == story.id }) else {
            throw DailyEntryResultPersistenceError.missingStory
        }
        let transcriptArtifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        guard let transcriptArtifact = transcriptArtifacts.first(where: {
            $0.id == request.transcriptArtifactId && $0.storyId == story.id
        }) else {
            throw DailyEntryResultPersistenceError.missingTranscriptArtifact
        }
        let transcriptVersions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        guard transcriptVersions.contains(where: {
            $0.id == request.transcriptVersionId
                && $0.transcriptArtifactId == transcriptArtifact.id
                && $0.storyId == story.id
        }) else {
            throw DailyEntryResultPersistenceError.missingTranscriptVersion
        }
    }

    private static func validateResponse(
        _ response: DailyEntryGenerationResponse,
        for request: DailyEntryGenerationRequest
    ) throws {
        let sourceIds = Set(request.sourceSegments.map(\.id))
        let factIds = Set(request.acceptedPriorFacts.map(\.id))
        let referencesAreGrounded = response.entry.sentences.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.sourceReferences.isEmpty
                && Set($0.sourceReferences).isSubset(of: sourceIds)
                && Set($0.factReferences).isSubset(of: factIds)
        }
            && response.memoryCandidates.allSatisfy {
                Set($0.sourceReferences).isSubset(of: sourceIds)
                    && Set($0.relatedFactIds).isSubset(of: factIds)
            }
            && response.uncertainties.allSatisfy {
                Set($0.sourceReferences).isSubset(of: sourceIds)
            }
            && response.sensitiveOmissions.allSatisfy {
                Set($0.sourceReferences).isSubset(of: sourceIds)
            }
            && response.followUpQuestions.allSatisfy {
                Set($0.sourceReferences).isSubset(of: sourceIds)
            }
        let provenance = response.provenance
        let retention = provenance.retentionAttestation

        guard
            request.schemaVersion == DailyEntryGenerationRequest.currentSchemaVersion,
            request.promptVersion == DailyEntryGenerationRequest.currentPromptVersion,
            request.retentionPolicy.mode == .zeroDataRetention,
            request.retentionPolicy.maximumRetentionSeconds == 0,
            response.schemaVersion == DailyEntryGenerationResponse.currentSchemaVersion,
            response.promptVersion == request.promptVersion,
            !response.requestId.isEmpty,
            !response.entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !response.entry.titleSourceReferences.isEmpty,
            Set(response.entry.titleSourceReferences).isSubset(of: sourceIds),
            !response.entry.sentences.isEmpty,
            !response.entry.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            referencesAreGrounded,
            !provenance.providerId.isEmpty,
            !provenance.modelAlias.isEmpty,
            !provenance.modelId.isEmpty,
            !provenance.modelPolicyVersion.isEmpty,
            provenance.processingDurationMilliseconds >= 0,
            retention.mode == .zeroDataRetention,
            retention.maximumRetentionSeconds == 0,
            !retention.policyVersion.isEmpty
        else {
            throw DailyEntryResultPersistenceError.invalidResponse
        }
    }

    private static func reconcileDerivedState(
        artifact: DailyEntryResultArtifact,
        response: DailyEntryGenerationResponse,
        story: Story,
        job: ProcessingJob,
        in modelContext: ModelContext,
        at date: Date
    ) throws {
        let alreadyConsistent = story.title == artifact.title
            && story.biographyProse == artifact.prose
            && story.processingStatus == "processed"
            && job.state == .succeeded
            && job.outputReferenceId == artifact.id
            && job.providerId == artifact.providerId
            && job.providerModelId == artifact.providerModelId
            && job.resultSchemaVersion == artifact.schemaVersion
        guard !alreadyConsistent else { return }

        do {
            applyDerivedState(
                artifact: artifact,
                response: response,
                story: story,
                job: job,
                at: date
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func applyDerivedState(
        artifact: DailyEntryResultArtifact,
        response: DailyEntryGenerationResponse,
        story: Story,
        job: ProcessingJob,
        at date: Date
    ) {
        story.title = artifact.title
        story.biographyProse = artifact.prose
        story.processingStatus = "processed"
        story.updatedAt = date
        job.providerId = response.provenance.providerId
        job.providerModelId = response.provenance.modelId
        job.markSucceeded(
            outputReferenceId: artifact.id,
            resultSchemaVersion: response.schemaVersion,
            at: date
        )
        // The response carries a policy attestation, not a provider-issued
        // deletion receipt. Request-ephemeral jobs therefore remain
        // `notApplicable`; never convert the attestation into a false receipt.
    }

    private static func encode(
        _ response: DailyEntryGenerationResponse
    ) throws -> EncodedDailyEntryResult {
        do {
            return EncodedDailyEntryResult(
                response: try json(response),
                entry: try json(response.entry),
                memoryCandidates: try json(response.memoryCandidates),
                uncertainties: try json(response.uncertainties),
                sensitiveOmissions: try json(response.sensitiveOmissions),
                qualityFlags: try json(response.qualityFlags),
                followUpQuestions: try json(response.followUpQuestions),
                provenance: try json(response.provenance)
            )
        } catch {
            throw DailyEntryResultPersistenceError.encodingFailed
        }
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DailyEntryResultPersistenceError.encodingFailed
        }
        return string
    }
}

private struct EncodedDailyEntryResult {
    let response: String
    let entry: String
    let memoryCandidates: String
    let uncertainties: String
    let sensitiveOmissions: String
    let qualityFlags: String
    let followUpQuestions: String
    let provenance: String
}
