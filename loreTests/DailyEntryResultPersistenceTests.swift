import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct DailyEntryResultPersistenceTests {
    @MainActor
    @Test func persistsCompleteStructuredResultAndUpdatesDerivedModels() throws {
        let fixture = try makeFixture()
        let response = makeResponse(jobId: fixture.job.id)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_100)

        let artifact = try DailyEntryResultPersister.persist(
            response: response,
            request: fixture.request,
            for: fixture.story,
            job: fixture.job,
            in: fixture.context,
            at: savedAt
        )

        #expect(artifact.jobId == fixture.job.id)
        #expect(artifact.storyId == fixture.story.id)
        #expect(artifact.transcriptArtifactId == fixture.transcript.id)
        #expect(artifact.transcriptVersionId == fixture.version.id)
        #expect(artifact.revision == 1)
        #expect(artifact.supersedesArtifactId == nil)
        #expect(artifact.title == "The Rainy Walk Home")
        #expect(artifact.prose == "She remembered walking home in the rain. The street felt unusually quiet.")
        #expect(artifact.providerId == "fireworks")
        #expect(artifact.providerModelAlias == "daily-entry-v1")
        #expect(artifact.providerModelId == "accounts/fireworks/models/gpt-oss-120b")
        #expect(artifact.retentionMode == .zeroDataRetention)
        #expect(artifact.maximumRetentionSeconds == 0)
        #expect(try artifact.decodedResponse() == response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        #expect(try decoder.decode(GroundedJournalEntry.self, from: Data(artifact.entryJSON.utf8)) == response.entry)
        #expect(try decoder.decode([JournalMemoryCandidate].self, from: Data(artifact.memoryCandidatesJSON.utf8)) == response.memoryCandidates)
        #expect(try decoder.decode([JournalUncertainty].self, from: Data(artifact.uncertaintiesJSON.utf8)) == response.uncertainties)
        #expect(try decoder.decode([JournalSensitiveOmission].self, from: Data(artifact.sensitiveOmissionsJSON.utf8)) == response.sensitiveOmissions)
        #expect(try decoder.decode([String].self, from: Data(artifact.qualityFlagsJSON.utf8)) == response.qualityFlags)
        #expect(try decoder.decode([JournalFollowUpQuestion].self, from: Data(artifact.followUpQuestionsJSON.utf8)) == response.followUpQuestions)
        #expect(try decoder.decode(RemoteProcessingProvenance.self, from: Data(artifact.provenanceJSON.utf8)) == response.provenance)

        let fragments = try fixture.context.fetch(FetchDescriptor<BiographyFragment>())
        let fragment = try #require(fragments.first)
        #expect(fragments.count == 1)
        #expect(fragment.id == artifact.biographyFragmentId)
        #expect(fragment.storyId == fixture.story.id)
        #expect(fragment.prose == response.entry.prose)
        #expect(fragment.modelName == response.provenance.modelId)
        #expect(fragment.modelVersion == response.provenance.modelPolicyVersion)
        #expect(fixture.story.title == response.entry.title)
        #expect(fixture.story.biographyProse == response.entry.prose)
        #expect(fixture.story.processingStatus == "processed")
        #expect(fixture.job.state == .succeeded)
        #expect(fixture.job.outputReferenceId == artifact.id)
        #expect(fixture.job.resultSchemaVersion == response.schemaVersion)
        #expect(fixture.job.deletionState == .notApplicable)
        #expect(fixture.job.remoteContentDeletedAt == nil)
        #expect(artifact.responseJSON.contains("audio") == false)
    }

    @MainActor
    @Test func replayingSameJobIsIdempotent() throws {
        let fixture = try makeFixture()
        let response = makeResponse(jobId: fixture.job.id)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_100)
        let replayDate = firstDate.addingTimeInterval(300)

        let first = try DailyEntryResultPersister.persist(
            response: response,
            request: fixture.request,
            for: fixture.story,
            job: fixture.job,
            in: fixture.context,
            at: firstDate
        )
        let completedAt = fixture.job.completedAt
        let replay = try DailyEntryResultPersister.persist(
            response: response,
            request: fixture.request,
            for: fixture.story,
            job: fixture.job,
            in: fixture.context,
            at: replayDate
        )

        #expect(replay.id == first.id)
        #expect(fixture.job.completedAt == completedAt)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).count == 1)
    }

    @MainActor
    @Test func laterJobCreatesLinkedBiographyRevision() throws {
        let fixture = try makeFixture()
        let firstResponse = makeResponse(jobId: fixture.job.id)
        let first = try DailyEntryResultPersister.persist(
            response: firstResponse,
            request: fixture.request,
            for: fixture.story,
            job: fixture.job,
            in: fixture.context
        )

        let secondJob = ProcessingJob(
            idempotencyKey: "daily-entry:\(fixture.story.id):revision-2",
            storyId: fixture.story.id,
            transcriptArtifactId: fixture.transcript.id,
            inputTranscriptVersionId: fixture.version.id,
            kind: .dailyEntry,
            state: .running,
            route: .remote,
            deletionState: .notApplicable
        )
        fixture.context.insert(secondJob)
        try fixture.context.save()
        var secondRequest = fixture.request
        secondRequest.jobId = secondJob.id
        var secondResponse = makeResponse(jobId: secondJob.id)
        secondResponse.entry.title = "The Quiet Walk Home"
        secondResponse.entry.sentences[1].text = "By the second telling, the street felt peacefully quiet."

        let second = try DailyEntryResultPersister.persist(
            response: secondResponse,
            request: secondRequest,
            for: fixture.story,
            job: secondJob,
            in: fixture.context
        )

        #expect(second.revision == 2)
        #expect(second.supersedesArtifactId == first.id)
        #expect(second.biographyFragmentId != first.biographyFragmentId)
        #expect(fixture.story.title == secondResponse.entry.title)
        #expect(fixture.story.biographyProse == secondResponse.entry.prose)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).count == 2)
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).count == 2)
    }

    @MainActor
    @Test func mismatchedTranscriptIsRejectedWithoutPartialWrites() throws {
        let fixture = try makeFixture()
        let response = makeResponse(jobId: fixture.job.id)
        var mismatchedRequest = fixture.request
        mismatchedRequest.transcriptVersionId = UUID()
        var caught: DailyEntryResultPersistenceError?

        do {
            _ = try DailyEntryResultPersister.persist(
                response: response,
                request: mismatchedRequest,
                for: fixture.story,
                job: fixture.job,
                in: fixture.context
            )
        } catch let error as DailyEntryResultPersistenceError {
            caught = error
        }

        #expect(caught == .identifierMismatch)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).isEmpty)
        #expect(fixture.story.biographyProse == nil)
        #expect(fixture.story.processingStatus == "awaitingModel")
        #expect(fixture.job.state == .running)
    }

    @MainActor
    @Test func deletesResultArtifactsAndTheirBiographyFragments() throws {
        let fixture = try makeFixture()
        _ = try DailyEntryResultPersister.persist(
            response: makeResponse(jobId: fixture.job.id),
            request: fixture.request,
            for: fixture.story,
            job: fixture.job,
            in: fixture.context
        )

        let deleted = try DailyEntryResultPersister.deleteResults(
            for: fixture.story,
            in: fixture.context
        )
        try fixture.context.save()

        #expect(deleted == 2)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).isEmpty)
    }

    @MainActor
    private func makeFixture() throws -> DailyEntryFixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let story = Story(
            text: "I walked home in the rain. The street was unusually quiet.",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 8,
            processingStatus: "awaitingModel"
        )
        let transcript = TranscriptArtifact(
            storyId: story.id,
            rawText: story.text,
            source: .remoteProvider,
            languageCode: "en-US",
            providerId: "groq",
            providerModelId: "whisper-large-v3-turbo",
            providerRequestId: "groq-request-1",
            capturedAt: story.date,
            audioDuration: story.duration
        )
        let version = TranscriptVersion(
            transcriptArtifactId: transcript.id,
            storyId: story.id,
            revision: 1,
            text: story.text,
            kind: .sourceSnapshot,
            author: .source
        )
        let job = ProcessingJob(
            idempotencyKey: "daily-entry:\(story.id):\(version.id)",
            storyId: story.id,
            transcriptArtifactId: transcript.id,
            inputTranscriptVersionId: version.id,
            kind: .dailyEntry,
            state: .running,
            route: .remote,
            deletionState: .notApplicable
        )
        let request = DailyEntryGenerationRequest(
            jobId: job.id,
            noteId: story.id,
            transcriptArtifactId: transcript.id,
            transcriptVersionId: version.id,
            capturedLocalDate: "2027-01-15",
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            sourceSegments: [
                TranscriptSourceSegment(
                    id: "source-version",
                    startMilliseconds: 0,
                    endMilliseconds: 8_000,
                    text: version.text,
                    confidence: 0.97,
                    speakerLabel: nil
                )
            ]
        )

        context.insert(story)
        context.insert(transcript)
        context.insert(version)
        context.insert(job)
        try context.save()
        return DailyEntryFixture(
            context: context,
            story: story,
            transcript: transcript,
            version: version,
            job: job,
            request: request
        )
    }

    private func makeResponse(jobId: UUID) -> DailyEntryGenerationResponse {
        DailyEntryGenerationResponse(
            schemaVersion: DailyEntryGenerationResponse.currentSchemaVersion,
            promptVersion: DailyEntryGenerationRequest.currentPromptVersion,
            jobId: jobId,
            requestId: "lore-request-123",
            entry: GroundedJournalEntry(
                title: "The Rainy Walk Home",
                titleSourceReferences: ["source-version"],
                perspective: .thirdPerson,
                sentences: [
                    GroundedJournalSentence(
                        text: "She remembered walking home in the rain.",
                        sourceReferences: ["source-version"],
                        factReferences: [],
                        preservesUncertainty: false
                    ),
                    GroundedJournalSentence(
                        text: "The street felt unusually quiet.",
                        sourceReferences: ["source-version"],
                        factReferences: [],
                        preservesUncertainty: false
                    )
                ]
            ),
            memoryCandidates: [
                JournalMemoryCandidate(
                    id: "memory-1",
                    kind: .lifeEvent,
                    operation: .add,
                    claim: "Maya walked home in the rain.",
                    confidence: .high,
                    sourceReferences: ["source-version"],
                    relatedFactIds: [],
                    requiresUserReview: false
                )
            ],
            uncertainties: [
                JournalUncertainty(
                    description: "The date of the walk is unknown.",
                    sourceReferences: ["source-version"],
                    suggestedQuestion: "When did this happen?"
                )
            ],
            sensitiveOmissions: [
                JournalSensitiveOmission(
                    category: "precise_location",
                    sourceReferences: ["source-version"]
                )
            ],
            qualityFlags: ["preserved_uncertainty"],
            followUpQuestions: [
                JournalFollowUpQuestion(
                    question: "Where were you walking from?",
                    reason: "The starting point was not stated.",
                    sourceReferences: ["source-version"]
                )
            ],
            provenance: RemoteProcessingProvenance(
                providerId: "fireworks",
                modelAlias: "daily-entry-v1",
                modelId: "accounts/fireworks/models/gpt-oss-120b",
                modelPolicyVersion: "2026-08-03-direct-v1",
                providerRequestId: "fireworks-request-456",
                processedAt: Date(timeIntervalSince1970: 1_800_000_050),
                processingDurationMilliseconds: 412,
                retentionAttestation: RemoteRetentionAttestation(
                    mode: .zeroDataRetention,
                    maximumRetentionSeconds: 0,
                    policyVersion: "fireworks-zdr-2026-08-03",
                    attestedAt: Date(timeIntervalSince1970: 1_800_000_051)
                )
            )
        )
    }
}

@MainActor
private struct DailyEntryFixture {
    let context: ModelContext
    let story: Story
    let transcript: TranscriptArtifact
    let version: TranscriptVersion
    let job: ProcessingJob
    let request: DailyEntryGenerationRequest
}
