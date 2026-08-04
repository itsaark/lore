import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct ProcessingRecoveryTests {
    @MainActor
    @Test func completedTranscriptionDoesNotRestartAnExistingDeferredDailyEntry() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeFixture(now: now, retryAt: now.addingTimeInterval(3_600))
        let viewModel = SpeechRecognitionViewModel(
            remoteDailyEntryGenerator: UnexpectedDailyEntryGenerator(),
            networkConnectionProvider: FixedSpeechNetworkConnectionProvider(.wifi),
            requestsMicrophonePermissionOnInit: false
        )
        viewModel.configure(modelContext: fixture.context, userProfile: fixture.profile)
        await viewModel.resumePendingTranscriptionJobs(now: now)

        #expect(viewModel.errorMessage == nil)
        #expect(fixture.dailyEntryJob.state == .queued)
        #expect(fixture.dailyEntryJob.attemptCount == 1)
        #expect(fixture.dailyEntryJob.nextAttemptAt == now.addingTimeInterval(3_600))
    }

    @MainActor
    @Test func scheduledDailyEntryRetryDoesNotCancelItselfWhenTimerWakes() async throws {
        let now = Date()
        let fixture = try makeFixture(now: now, retryAt: now.addingTimeInterval(0.2))
        let viewModel = SpeechRecognitionViewModel(
            remoteDailyEntryGenerator: SuccessfulDailyEntryGenerator(),
            networkConnectionProvider: FixedSpeechNetworkConnectionProvider(.wifi),
            requestsMicrophonePermissionOnInit: false
        )
        viewModel.configure(modelContext: fixture.context, userProfile: fixture.profile)

        for _ in 0..<100 where fixture.dailyEntryJob.state != .succeeded {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(fixture.dailyEntryJob.state == .succeeded)
        #expect(fixture.story.processingStatus == "processed")
        #expect(viewModel.errorMessage == nil)
    }

    @MainActor
    private func makeFixture(now: Date, retryAt: Date) throws -> RecoveryFixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let story = Story(
            text: "I walked home in the rain.",
            date: now,
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
        let transcriptionJob = ProcessingJob(
            idempotencyKey: "transcription:\(story.id.uuidString)",
            storyId: story.id,
            transcriptArtifactId: artifact.id,
            outputReferenceId: artifact.id,
            kind: .transcription,
            state: .succeeded,
            route: .remote
        )
        let dailyEntryJob = ProcessingJob(
            idempotencyKey: "daily-entry:\(story.id.uuidString):\(version.id.uuidString)",
            storyId: story.id,
            transcriptArtifactId: artifact.id,
            inputTranscriptVersionId: version.id,
            kind: .dailyEntry,
            state: .queued,
            route: .remote,
            attemptCount: 1,
            nextAttemptAt: retryAt,
            lastErrorCode: "network_unavailable"
        )
        let profile = UserProfile(
            name: "Maya",
            hometown: "Portland",
            birthYear: 1990,
            remoteProcessingConsentedAt: now
        )

        context.insert(story)
        context.insert(artifact)
        context.insert(version)
        context.insert(transcriptionJob)
        context.insert(dailyEntryJob)
        context.insert(profile)
        try context.save()
        return RecoveryFixture(
            context: context,
            story: story,
            profile: profile,
            dailyEntryJob: dailyEntryJob
        )
    }
}

@MainActor
private struct RecoveryFixture {
    let context: ModelContext
    let story: Story
    let profile: UserProfile
    let dailyEntryJob: ProcessingJob
}

private struct UnexpectedDailyEntryGenerator: DailyEntryGenerationService {
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        Issue.record("A daily-entry job with a future retry time must not run during launch recovery.")
        throw LoreBackendProcessingError.transportUnavailable
    }
}

private struct SuccessfulDailyEntryGenerator: DailyEntryGenerationService {
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        let sourceID = request.sourceSegments[0].id
        let processedAt = Date()
        return DailyEntryGenerationResponse(
            schemaVersion: "1.0",
            promptVersion: DailyEntryGenerationRequest.currentPromptVersion,
            jobId: request.jobId,
            requestId: "retry-request",
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
                modelId: "test-model",
                modelPolicyVersion: "test-policy",
                providerRequestId: "retry-request",
                processedAt: processedAt,
                processingDurationMilliseconds: 10,
                retentionAttestation: RemoteRetentionAttestation(
                    mode: .zeroDataRetention,
                    maximumRetentionSeconds: 0,
                    policyVersion: "test-policy",
                    attestedAt: processedAt
                )
            )
        )
    }
}
