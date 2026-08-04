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

        #expect(prepared.count == 1)
        #expect(prepared[0].dayKey == "2026-08-03")
        #expect(prepared[0].sourceStoryIds == fixture.pastStories.map(\.id))

        let entry = try await DailyBiographyJobRunner.run(
            jobID: prepared[0].jobId,
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
        #expect(replay.isEmpty)
    }

    @Test func currentCalendarDayWaitsUntilItEnds() throws {
        let fixture = try makeFixture()
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )

        #expect(prepared.count == 1)
        #expect(!prepared[0].sourceStoryIds.contains(fixture.currentStory.id))
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

private struct SuccessfulDailyBiographyGenerator: DailyEntryGenerationService {
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        let sourceIds = request.sourceSegments.map(\.id)
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
                sentences: request.sourceSegments.map {
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
