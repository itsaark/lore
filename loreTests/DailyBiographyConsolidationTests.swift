import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
@MainActor
struct DailyBiographyConsolidationTests {
    @Test func completedDayCombinesEveryTranscriptOnceAndKeepsSources() async throws {
        let fixture = try makeFixture()
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )

        #expect(prepared.count == 2)
        let past = try #require(prepared.first { $0.dayKey == "2026-08-03" })
        #expect(past.sourceStoryIds == fixture.pastStories.map(\.id))

        let entry = try await DailyBiographyJobRunner.run(
            jobID: past.jobId,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context,
            now: fixture.now
        )

        #expect(entry.dayKey == "2026-08-03")
        #expect(entry.noteCount == 2)
        #expect(entry.sourceStoryIds == fixture.pastStories.map(\.id))
        #expect(entry.combinedTranscript.contains("Morning memory."))
        #expect(entry.combinedTranscript.contains("Evening memory."))
        #expect(fixture.pastStories[0].biographyProse == "Morning fragment.")
        #expect(fixture.pastStories[1].biographyProse == "Evening fragment.")
        #expect(try fixture.context.fetch(FetchDescriptor<DailyBiographyEntry>()).count == 1)

        let replay = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )
        #expect(!replay.contains { $0.dayKey == "2026-08-03" })
    }

    @Test func dayStoryIsKeptWhenTheWriterLeavesANoteUncited() async throws {
        let fixture = try makeFixture()
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )
        let past = try #require(prepared.first { $0.dayKey == "2026-08-03" })

        let entry = try await DailyBiographyJobRunner.run(
            jobID: past.jobId,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(citesOnlyFirstNote: true),
            in: fixture.context,
            now: fixture.now
        )

        #expect(entry.dayKey == "2026-08-03")
        #expect(entry.sourceStoryIds == fixture.pastStories.map(\.id))
    }

    @Test func currentCalendarDayIsWrittenFromItsFirstNote() throws {
        let fixture = try makeFixture()
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )

        let today = try #require(prepared.first { $0.dayKey == "2026-08-04" })
        #expect(today.sourceStoryIds == [fixture.currentStory.id])
    }

    @Test func dayInProgressIsRewrittenAsNotesAreAdded() throws {
        let fixture = try makeFixture()
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-08-03T23:30:00Z"))
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: lateEvening
        )

        let day = try #require(prepared.first { $0.dayKey == "2026-08-03" })
        #expect(day.sourceStoryIds == fixture.pastStories.map(\.id))
    }

    @Test func transcriptCorrectionCreatesANewRevisionForTheSameDayEntry() async throws {
        let fixture = try makeFixture()
        let first = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        ).first)
        let original = try await DailyBiographyJobRunner.run(
            jobID: first.jobId,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context,
            now: fixture.now
        )
        let originalID = original.id
        let originalFingerprint = original.sourceFingerprint

        let artifact = try #require(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>())
            .first(where: { $0.storyId == fixture.pastStories[0].id }))
        let prior = try #require(try fixture.context.fetch(FetchDescriptor<TranscriptVersion>())
            .first(where: { $0.transcriptArtifactId == artifact.id }))
        let correction = TranscriptVersion(
            transcriptArtifactId: artifact.id,
            storyId: fixture.pastStories[0].id,
            supersedesVersionId: prior.id,
            revision: 2,
            text: "Corrected morning memory.",
            kind: .userCorrection,
            author: .user,
            createdAt: fixture.now
        )
        fixture.context.insert(correction)
        try fixture.context.save()

        let replacement = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        ).first)
        let updated = try await DailyBiographyJobRunner.run(
            jobID: replacement.jobId,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context,
            now: fixture.now
        )

        #expect(updated.id == originalID)
        #expect(updated.sourceFingerprint != originalFingerprint)
        #expect(updated.combinedTranscript.contains("Corrected morning memory."))
        #expect(try fixture.context.fetch(FetchDescriptor<DailyBiographyEntry>()).count == 1)
    }

    @Test func invalidProviderResponseCanResumeWithinTheAttemptCeiling() async throws {
        let fixture = try makeFixture()
        let prepared = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        ).first)
        let job = try #require(try fixture.context.fetch(FetchDescriptor<ProcessingJob>())
            .first(where: { $0.id == prepared.jobId }))
        job.beginAttempt(at: fixture.now)
        job.markFailed(errorCode: "invalid_provider_response", at: fixture.now)
        try fixture.context.save()

        let retryDate = fixture.now.addingTimeInterval(1)
        #expect(job.requeueFailedRequest(
            matchingErrorCode: "invalid_provider_response",
            at: retryDate
        ))

        let entry = try await DailyBiographyJobRunner.run(
            jobID: job.id,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context,
            now: retryDate
        )

        #expect(job.state == .succeeded)
        #expect(job.attemptCount == 2)
        #expect(entry.dayKey == "2026-08-03")
    }

    @Test(arguments: ["assertion_invalid", "counter_replayed", "challenge_expired", "invalid_request"])
    func dayStoryRetriesAuthenticationRejectionsWithItsNormalBackoff(code: String) async throws {
        let fixture = try makeFixture()
        let prepared = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        ).first)
        let job = try #require(try fixture.context.fetch(FetchDescriptor<ProcessingJob>())
            .first(where: { $0.id == prepared.jobId }))
        let error = LoreBackendProcessingError.rejected(code: code, retryable: false, retryAfterSeconds: nil)

        await #expect(throws: error) {
            try await DailyBiographyJobRunner.run(
                jobID: job.id,
                userProfile: fixture.profile,
                generator: RejectedDailyBiographyGenerator(error: error),
                in: fixture.context,
                now: fixture.now
            )
        }

        #expect(job.attemptCount == 1)
        #expect(job.lastErrorCode == code)
        if code == "invalid_request" {
            #expect(job.state == .failed)
            #expect(job.nextAttemptAt == nil)
        } else {
            #expect(job.state == .queued)
            #expect(job.nextAttemptAt == job.updatedAt.addingTimeInterval(30))
        }
    }

    @Test func launchRecoveryRetriesAnOldAssertionFailureAfterTheCooldown() async throws {
        let fixture = try makeFixture()
        let days = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )
        let past = try #require(days.first { $0.dayKey == "2026-08-03" })
        let current = try #require(days.first { $0.dayKey == "2026-08-04" })
        let jobs = try fixture.context.fetch(FetchDescriptor<ProcessingJob>())
        let authFailure = try #require(jobs.first { $0.id == past.jobId })
        let invalidRequest = try #require(jobs.first { $0.id == current.jobId })
        for (job, code) in [(authFailure, "assertion_invalid"), (invalidRequest, "invalid_request")] {
            job.beginAttempt(at: fixture.now)
            job.markFailed(errorCode: code, at: fixture.now)
        }
        try fixture.context.save()

        let viewModel = SpeechRecognitionViewModel(
            remoteDailyEntryGenerator: SuccessfulDailyBiographyGenerator(),
            networkConnectionProvider: FixedSpeechNetworkConnectionProvider(.wifi),
            requestsMicrophonePermissionOnInit: false
        )
        viewModel.configure(modelContext: fixture.context, userProfile: fixture.profile)
        await viewModel.resumePendingDailyBiographyJobs(now: fixture.now.addingTimeInterval(3_599))
        #expect(authFailure.state == .failed)
        #expect(authFailure.attemptCount == 1)

        await viewModel.resumePendingDailyBiographyJobs(now: fixture.now.addingTimeInterval(3_600))
        #expect(authFailure.state == .succeeded)
        #expect(authFailure.attemptCount == 2)
        #expect(authFailure.lastErrorCode == nil)
        #expect(invalidRequest.state == .failed)
        #expect(invalidRequest.attemptCount == 1)
        let entries = try fixture.context.fetch(FetchDescriptor<DailyBiographyEntry>())
        #expect(entries.map(\.dayKey) == [past.dayKey])
    }

    private func makeFixture() throws -> DailyBiographyFixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-04T18:00:00Z"))
        let morning = try #require(ISO8601DateFormatter().date(from: "2026-08-03T15:00:00Z"))
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-08-03T23:00:00Z"))
        let current = try #require(ISO8601DateFormatter().date(from: "2026-08-04T16:00:00Z"))
        let profile = UserProfile(
            name: "Maya",
            hometown: "Portland",
            birthYear: 1990,
            remoteProcessingConsentedAt: now
        )

        let pastStories = [
            Story(text: "Morning memory.", date: morning, duration: 12, biographyProse: "Morning fragment."),
            Story(text: "Evening memory.", date: evening, duration: 18, biographyProse: "Evening fragment.")
        ]
        let currentStory = Story(
            text: "Current day memory.",
            date: current,
            duration: 8,
            biographyProse: "Current fragment."
        )

        context.insert(profile)
        for story in pastStories + [currentStory] {
            let metadata = StoryMetadata(captureDate: story.date, timezone: "UTC")
            story.metadataId = metadata.id
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
            context.insert(story)
            context.insert(metadata)
            context.insert(artifact)
            context.insert(version)
        }
        try context.save()
        return DailyBiographyFixture(
            context: context,
            now: now,
            profile: profile,
            pastStories: pastStories,
            currentStory: currentStory
        )
    }
}

@MainActor
private struct DailyBiographyFixture {
    let context: ModelContext
    let now: Date
    let profile: UserProfile
    let pastStories: [Story]
    let currentStory: Story
}

private struct RejectedDailyBiographyGenerator: DailyEntryGenerationService {
    let error: LoreBackendProcessingError

    func generateDailyEntry(_ request: DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse {
        throw error
    }
}

private struct SuccessfulDailyBiographyGenerator: DailyEntryGenerationService {
    /// Writes only from the first note, as the writer may when it merges or
    /// sets aside the others.
    var citesOnlyFirstNote = false

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        let segments = citesOnlyFirstNote ? Array(request.sourceSegments.prefix(1)) : request.sourceSegments
        let sourceIds = segments.map(\.id)
        let processedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return DailyEntryGenerationResponse(
            schemaVersion: "1.0",
            promptVersion: DailyEntryGenerationRequest.currentPromptVersion,
            jobId: request.jobId,
            requestId: "daily-biography-test",
            entry: GroundedJournalEntry(
                title: "A complete day",
                titleSourceReferences: sourceIds,
                perspective: .thirdPerson,
                sentences: segments.map {
                    GroundedJournalSentence(
                        text: "Remembered: \($0.text)",
                        sourceReferences: [$0.id],
                        factReferences: [],
                        preservesUncertainty: true
                    )
                }
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
                providerRequestId: "daily-biography-test",
                processedAt: processedAt,
                processingDurationMilliseconds: 8,
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
