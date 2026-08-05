import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct DailyEntryJobRunnerTests {
    @MainActor
    @Test func runnerPersistsCompleteRemoteResultAndSucceedsIdempotently() async throws {
        let fixture = try makeFixture()
        let prepared = try DailyEntryJobRunner.prepare(
            story: fixture.story,
            userProfile: fixture.profile,
            initialState: .queued,
            in: fixture.context
        )
        let generator = FixedDailyEntryGenerator(response: makeResponse(for: prepared.request))

        let result = try await DailyEntryJobRunner.run(
            jobID: prepared.job.id,
            userProfile: fixture.profile,
            generator: generator,
            in: fixture.context
        )
        _ = try await DailyEntryJobRunner.run(
            jobID: prepared.job.id,
            userProfile: fixture.profile,
            generator: generator,
            in: fixture.context
        )

        #expect(result.id == fixture.story.id)
        #expect(prepared.job.state == .succeeded)
        #expect(fixture.story.processingStatus == "processed")
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).count == 1)
    }

    @MainActor
    @Test func transientFailureQueuesRetryWithoutLosingTranscript() async throws {
        let fixture = try makeFixture()
        let prepared = try DailyEntryJobRunner.prepare(
            story: fixture.story,
            userProfile: fixture.profile,
            initialState: .queued,
            in: fixture.context
        )

        do {
            _ = try await DailyEntryJobRunner.run(
                jobID: prepared.job.id,
                userProfile: fixture.profile,
                generator: FailingDailyEntryGenerator(),
                in: fixture.context,
                now: Date(timeIntervalSince1970: 1_800_000_100)
            )
            Issue.record("Expected transient transport failure")
        } catch LoreBackendProcessingError.transportUnavailable {
            // Expected.
        }

        #expect(prepared.job.state == .queued)
        #expect(prepared.job.attemptCount == 1)
        #expect(prepared.job.nextAttemptAt != nil)
        #expect(fixture.story.text == "I walked home in the rain.")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptVersion>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).isEmpty)
    }

    @MainActor
    @Test func knownInvalidRequestFromOlderClientCanRecoverFromSavedTranscript() async throws {
        let fixture = try makeFixture()
        let prepared = try DailyEntryJobRunner.prepare(
            story: fixture.story,
            userProfile: fixture.profile,
            initialState: .queued,
            in: fixture.context
        )
        let failureDate = Date(timeIntervalSince1970: 1_800_000_100)
        prepared.job.beginAttempt(at: failureDate)
        prepared.job.markFailed(errorCode: "invalid_request", at: failureDate)
        fixture.story.processingStatus = "failed"
        try fixture.context.save()

        let retryDate = failureDate.addingTimeInterval(1)
        #expect(prepared.job.requeueFailedRequest(
            matchingErrorCode: "invalid_request",
            at: retryDate
        ))
        fixture.story.processingStatus = "awaitingModel"
        try fixture.context.save()

        _ = try await DailyEntryJobRunner.run(
            jobID: prepared.job.id,
            userProfile: fixture.profile,
            generator: FixedDailyEntryGenerator(response: makeResponse(for: prepared.request)),
            in: fixture.context,
            now: retryDate
        )

        #expect(prepared.job.state == .succeeded)
        #expect(prepared.job.attemptCount == 2)
        #expect(fixture.story.processingStatus == "processed")
        #expect(!prepared.job.requeueFailedRequest(matchingErrorCode: "invalid_request"))
        #expect(try fixture.context.fetch(FetchDescriptor<BiographyFragment>()).count == 1)
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let story = Story(
            text: "I walked home in the rain.",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 5,
            processingStatus: "awaitingModel"
        )
        let artifact = TranscriptArtifact(
            storyId: story.id,
            rawText: story.text,
            source: .remoteProvider,
            languageCode: "en-US",
            capturedAt: story.date,
            audioDuration: story.duration
        )
        let version = TranscriptVersion(
            transcriptArtifactId: artifact.id,
            storyId: story.id,
            revision: 1,
            text: story.text,
            kind: .sourceSnapshot,
            author: .source
        )
        let profile = UserProfile(
            name: "Maya",
            hometown: "Portland",
            birthYear: 1990,
            remoteProcessingConsentedAt: Date()
        )
        context.insert(story)
        context.insert(artifact)
        context.insert(version)
        context.insert(profile)
        try context.save()
        return Fixture(context: context, story: story, profile: profile)
    }

    private func makeResponse(for request: DailyEntryGenerationRequest) -> DailyEntryGenerationResponse {
        let sourceID = request.sourceSegments[0].id
        let attestedAt = Date(timeIntervalSince1970: 1_800_000_120)
        return DailyEntryGenerationResponse(
            schemaVersion: "1.0",
            promptVersion: DailyEntryGenerationRequest.currentPromptVersion,
            jobId: request.jobId,
            requestId: "fireworks-request",
            entry: GroundedJournalEntry(
                title: "The Walk Home",
                titleSourceReferences: [sourceID],
                perspective: .thirdPerson,
                sentences: [
                    GroundedJournalSentence(
                        text: "She walked home in the rain.",
                        sourceReferences: [sourceID],
                        factReferences: [],
                        preservesUncertainty: true
                    )
                ]
            ),
            memoryCandidates: [],
            uncertainties: [],
            sensitiveOmissions: [],
            qualityFlags: [],
            followUpQuestions: [],
            provenance: RemoteProcessingProvenance(
                providerId: "fireworks",
                modelAlias: "daily-entry-v1",
                modelId: "accounts/fireworks/models/deepseek-v4-flash",
                modelPolicyVersion: "test-policy",
                providerRequestId: "fireworks-request",
                processedAt: attestedAt,
                processingDurationMilliseconds: 120,
                retentionAttestation: RemoteRetentionAttestation(
                    mode: .zeroDataRetention,
                    maximumRetentionSeconds: 0,
                    policyVersion: "request-ephemeral-v1",
                    attestedAt: attestedAt
                )
            )
        )
    }
}

@MainActor
private struct Fixture {
    let context: ModelContext
    let story: Story
    let profile: UserProfile
}

private struct FixedDailyEntryGenerator: DailyEntryGenerationService {
    let response: DailyEntryGenerationResponse

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        response
    }
}

private struct FailingDailyEntryGenerator: DailyEntryGenerationService {
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.transportUnavailable
    }
}
