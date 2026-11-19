import CryptoKit
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
            generator: SuccessfulDailyBiographyGenerator(includesFollowUps: true),
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
        let followUps = try fixture.context.fetch(FetchDescriptor<DailyQuestionFollowUps>())
        #expect(followUps.first?.sourceDayStoryID == entry.id)
        #expect(followUps.first?.sourceFingerprint == entry.sourceFingerprint)
        #expect(followUps.first?.questions == ["What did you hear that morning?"])

        let replay = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued,
            in: fixture.context,
            now: fixture.now
        )
        #expect(!replay.contains { $0.dayKey == "2026-08-03" })
    }

    @Test func ordinaryDayFingerprintRemainsByteIdenticalAndReusesItsEntry() async throws {
        let fixture = try makeFixture()
        let dayKey = "2026-08-03"
        let job = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: fixture.now
        ).first { $0.dayKey == dayKey })
        let versions = try fixture.context.fetch(FetchDescriptor<TranscriptVersion>())
        let sourceIds = try fixture.pastStories.map { story in
            let version = try #require(versions.first { $0.storyId == story.id })
            return "\(story.id.uuidString.lowercased()):\(version.id.uuidString.lowercased())"
        }
        let legacyBytes = Data(([dayKey] + sourceIds).joined(separator: "|").utf8)
        let legacyFingerprint = SHA256.hash(data: legacyBytes).map { String(format: "%02x", $0) }.joined()
        let entry = try await DailyBiographyJobRunner.run(
            jobID: job.jobId, userProfile: fixture.profile, generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context, now: fixture.now
        )
        #expect(entry.sourceFingerprint == legacyFingerprint)
        let pending = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: fixture.now
        )
        #expect(!pending.contains { $0.dayKey == dayKey })
    }

    @Test func aBackdatedDayNoteJoinsAndRewritesThatDay() async throws {
        let fixture = try makeFixture()
        let key = "2026-08-03"
        let initial = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: fixture.now
        ).first { $0.dayKey == key })
        let generator = RecordingBiographyGenerator()
        let original = try await DailyBiographyJobRunner.run(
            jobID: initial.jobId, userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: fixture.now
        )
        let oldFingerprint = original.sourceFingerprint
        let note = Story(
            text: "I remembered a detail later.", date: fixture.now, duration: 5,
            rememberedTime: RememberedTime(precision: .day, startDate: key, endDate: key)
        )
        insertTranscribedNote(note, in: fixture.context)

        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: fixture.now
        )
        let past = try #require(prepared.first { $0.dayKey == key })
        #expect(past.sourceStoryIds == fixture.pastStories.map(\.id) + [note.id])
        #expect(prepared.first { $0.dayKey == "2026-08-04" }?.sourceStoryIds == [fixture.currentStory.id])
        let rewritten = try await DailyBiographyJobRunner.run(
            jobID: past.jobId, userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: fixture.now
        )
        #expect(rewritten.id == original.id)
        #expect(rewritten.sourceFingerprint != oldFingerprint)
        #expect(note.date == fixture.now)
        #expect(rewritten.memoryStoryId == nil)
        #expect(rewritten.prose.contains(note.text))
        #expect(await generator.requests.last?.capturedLocalDate == key)
        #expect(await generator.requests.last?.rememberedTime == nil)
        let index = JournalDayContent.index(stories: [note], dailyEntries: [rewritten], storyDayKeys: [:])
        #expect(index[key]?.stories.map(\.id) == [note.id])
    }

    @Test func coarseMemoriesAreIndependentOfDaysAndChaptersAndRewriteAfterEditing() async throws {
        let fixture = try makeFixture()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T18:00:00Z"))
        // Both memories start in the recording month and share a date with one another.
        let range = RememberedTime(precision: .week, startDate: "2026-08-10", endDate: "2026-08-16")
        let notes = ["First memory.", "Second memory."].map {
            Story(text: $0, date: now, duration: 4, rememberedTime: range)
        }
        let today = Story(text: "Actually happened today.", date: now, duration: 4)
        for note in notes + [today] { insertTranscribedNote(note, in: fixture.context) }
        let prepared = try DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: now
        )
        #expect(prepared.first { $0.dayKey == "2026-08-18" }?.sourceStoryIds == [today.id])
        let memories = prepared.filter { $0.dayKey == range.startDate }
        #expect(Set(memories.flatMap(\.sourceStoryIds)) == Set(notes.map(\.id)))
        #expect(memories.allSatisfy { $0.sourceStoryIds.count == 1 })

        let generator = RecordingBiographyGenerator()
        var entries: [DailyBiographyEntry] = []
        for memory in memories {
            entries.append(try await DailyBiographyJobRunner.run(
                jobID: memory.jobId, userProfile: fixture.profile, generator: generator,
                in: fixture.context, now: now
            ))
        }

        #expect(Set(entries.compactMap(\.memoryStoryId)) == Set(notes.map(\.id)))
        let requests = await generator.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.capturedLocalDate == "2026-08-18")
            #expect(request.sourceSegments.count == 1)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let wire = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
            #expect(wire["remembered_time"] as? [String: String] == [
                "precision": "week", "start_date": "2026-08-10", "end_date": "2026-08-16"
            ])
        }
        #expect(StoryChapterRunner.staleMonthKeys(
            entries: entries, chapters: [], now: now.addingTimeInterval(86_400)
        ).isEmpty)
        let index = JournalDayContent.index(
            stories: notes, dailyEntries: entries, storyDayKeys: [:]
        )
        #expect(index.isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<DailyQuestionFollowUps>()).isEmpty)

        let note = notes[0]
        let original = try #require(entries.first { $0.memoryStoryId == note.id })
        let originalFingerprint = original.sourceFingerprint
        try SpeechRecognitionViewModel.applyUserCorrection("Corrected memory.", to: note, in: fixture.context)
        let correction = try #require(DailyBiographyJobRunner.prepareCompletedDays(
            initialState: .queued, in: fixture.context, now: now
        ).first { $0.sourceStoryIds == [note.id] })
        let updated = try await DailyBiographyJobRunner.run(
            jobID: correction.jobId, userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now
        )
        #expect(updated.id == original.id)
        #expect(updated.sourceFingerprint != originalFingerprint)
        #expect(updated.prose.contains("Corrected memory."))

        fixture.context.insert(DayIllustration(dayKey: range.startDate, at: now))
        for memory in notes {
            fixture.context.insert(DayIllustration(dayKey: range.startDate, memoryStoryId: memory.id, at: now))
        }
        try fixture.context.save()
        let viewModel = makeViewModel(for: fixture, connection: .unavailable)
        try #require(viewModel.deleteStory(note))
        #expect(viewModel.dailyBiographyEntries.map(\.memoryStoryId) == [notes[1].id])
        let paintings = try fixture.context.fetch(FetchDescriptor<DayIllustration>())
        #expect(paintings.count == 2)
        #expect(Set(paintings.map(\.memoryStoryId)) == [nil, notes[1].id])
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

    @Test func deletingOneNoteImmediatelyRewritesTheDayWithoutItAndRemovesItsAudio() async throws {
        let fixture = try makeFixture(includeEvening: false)
        let viewModel = makeViewModel(for: fixture, connection: .wifi)
        await viewModel.resumePendingDailyBiographyJobs()
        let remaining = fixture.pastStories[0]
        let deleted = fixture.pastStories[1]
        let dayKey = "2026-08-03"
        let firstJobID = try #require(fixture.context.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
            .first { $0.dayKey == dayKey }?.jobId)

        // First write the day with both notes, so deletion restores a fingerprint
        // that already has a succeeded job.
        insertTranscribedNote(deleted, in: fixture.context)
        try fixture.context.save()
        await viewModel.resumePendingDailyBiographyJobs()
        let original = try #require(viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey })
        let originalID = original.id
        #expect(original.sourceStoryIds == [remaining.id, deleted.id])

        let deletedID = deleted.id
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(deletedID).m4a")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        fixture.context.insert(AudioAsset(
            id: deletedID,
            fileURL: audio.absoluteString,
            expiresAt: Date().addingTimeInterval(3600),
            duration: deleted.duration
        ))
        try fixture.context.save()

        try #require(viewModel.deleteStory(deleted))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try fixture.context.fetch(FetchDescriptor<AudioAsset>()).isEmpty)
        #expect(!viewModel.stories.contains { $0.id == deletedID })
        #expect(!viewModel.dailyBiographyEntries.contains { $0.dayKey == dayKey })

        // The deletion itself must start the rewrite; no manual recovery call.
        try await waitForRewrite { viewModel.dailyBiographyEntries.contains { $0.dayKey == dayKey } }
        let replacement = try #require(viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey })
        #expect(replacement.id != originalID)
        #expect(replacement.sourceStoryIds == [remaining.id])
        #expect(!replacement.combinedTranscript.contains("Evening memory."))

        let snapshots = try fixture.context.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
            .filter { $0.dayKey == dayKey }
        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snapshot.jobId != firstJobID)
        #expect(snapshot.sourceStoryIds == [remaining.id])
        let jobs = try fixture.context.fetch(FetchDescriptor<ProcessingJob>())
        #expect(jobs.first { $0.id == snapshot.jobId }?.state == .succeeded)
        #expect(!jobs.contains { $0.storyId == deletedID })
    }

    @Test(arguments: [false, true])
    func deletingTheOnlyNoteRemovesDaySupportDataAndKeepsPhotos(illustrationAlreadyOrphaned: Bool) async throws {
        let fixture = try makeFixture()
        let days = try DailyBiographyJobRunner.prepareCompletedDays(initialState: .queued, in: fixture.context)
        let day = try #require(days.first { $0.sourceStoryIds == [fixture.currentStory.id] })
        let entry = try await DailyBiographyJobRunner.run(
            jobID: day.jobId,
            userProfile: fixture.profile,
            generator: SuccessfulDailyBiographyGenerator(),
            in: fixture.context
        )
        if illustrationAlreadyOrphaned { fixture.context.delete(entry) }
        fixture.context.insert(DayIllustration(dayKey: day.dayKey, at: fixture.now))
        let photo = DayPhoto(
            dayKey: day.dayKey,
            encoded: .init(imageData: Data([1]), thumbnailData: Data([2]), pixelWidth: 1, pixelHeight: 1)
        )
        let photoID = photo.id
        fixture.context.insert(photo)
        try fixture.context.save()

        let viewModel = makeViewModel(for: fixture, connection: .unavailable)
        try #require(viewModel.deleteStory(fixture.currentStory))

        #expect(!viewModel.dailyBiographyEntries.contains { $0.dayKey == day.dayKey })
        #expect(!viewModel.storyDayKeys.values.contains(day.dayKey))
        #expect(try fixture.context.fetch(FetchDescriptor<DayIllustration>()).isEmpty)
        #expect(try !fixture.context.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
            .contains { $0.dayKey == day.dayKey })
        #expect(try !fixture.context.fetch(FetchDescriptor<ProcessingJob>()).contains { $0.id == day.jobId })
        #expect(try fixture.context.fetch(FetchDescriptor<DayPhoto>()).map(\.id) == [photoID])
    }

    @Test func deletingDuringGenerationDiscardsTheInFlightStoryAndRunsTheReplacement() async throws {
        let fixture = try makeFixture()
        let generator = DailyBiographyGeneratorWithInterruption()
        let viewModel = makeViewModel(for: fixture, connection: .wifi, generator: generator)
        let removed = fixture.pastStories[1]
        generator.beforeTwoNoteResponse = {
            try #require(viewModel.deleteStory(removed))
            await viewModel.resumePendingDailyBiographyJobs(now: fixture.now)
        }

        await viewModel.resumePendingDailyBiographyJobs(now: fixture.now)

        let entry = try #require(viewModel.dailyBiographyEntries.first { $0.dayKey == "2026-08-03" })
        #expect(entry.sourceStoryIds == [fixture.pastStories[0].id])
        #expect(!entry.prose.contains("Evening memory."))
        #expect(!viewModel.stories.contains { $0 === removed })
    }

    @Test(arguments: [0, -2])
    func delayedTranscriptionAndCorrectionsImmediatelyRewriteTheCaptureDay(dayOffset: Int) async throws {
        let fixture = try makeFixture()
        let calendar = JournalCalendar()
        let now = Date()
        let date = try #require(calendar.calendar.date(byAdding: .day, value: dayOffset, to: now))
        let capture = calendar.calendar.startOfDay(for: date).addingTimeInterval(120)
        let dayKey = calendar.dayKey(for: capture)
        let existing = Story(text: "An earlier note.", date: capture.addingTimeInterval(-60), duration: 10)
        insertTranscribedNote(existing, in: fixture.context, timezone: calendar.calendar.timeZone.identifier)

        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let (pending, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: capture,
            endTime: capture.addingTimeInterval(10),
            audioFileURL: audio,
            modelContext: fixture.context
        )
        job.markFailed(errorCode: "remote_transcription_failed", at: now)
        try fixture.context.save()

        let viewModel = makeViewModel(
            for: fixture,
            connection: .wifi,
            transcriber: DailyBiographyTestTranscriber()
        )
        await viewModel.resumePendingDailyBiographyJobs()
        let initial = try #require(viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey })
        let initialID = initial.id
        #expect(initial.sourceStoryIds == [existing.id])

        viewModel.retryTranscription(for: pending)
        try await waitForRewrite {
            viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey }?.sourceStoryIds == [existing.id, pending.id]
        }
        #expect(initial.combinedTranscript.contains("The delayed voice note."))

        viewModel.updateStory(pending, withText: "The corrected voice note.")
        try await waitForRewrite {
            viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey }?.combinedTranscript
                .contains("The corrected voice note.") == true
        }
        #expect(viewModel.dailyBiographyEntries.first { $0.dayKey == dayKey }?.id == initialID)
        #expect(!initial.combinedTranscript.contains("The delayed voice note."))
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

    private func makeViewModel(
        for fixture: DailyBiographyFixture,
        connection: SpeechNetworkConnection,
        generator: any DailyEntryGenerationService = SuccessfulDailyBiographyGenerator(),
        transcriber: any RemoteSpeechTranscribing = UnavailableRemoteSpeechTranscriber()
    ) -> SpeechRecognitionViewModel {
        let viewModel = SpeechRecognitionViewModel(
            remoteDailyEntryGenerator: generator,
            remoteTranscriber: transcriber,
            networkConnectionProvider: FixedSpeechNetworkConnectionProvider(connection),
            requestsMicrophonePermissionOnInit: false
        )
        viewModel.configure(modelContext: fixture.context, userProfile: fixture.profile)
        return viewModel
    }

    private func waitForRewrite(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for the day to be rewritten")
    }

    private func makeFixture(includeEvening: Bool = true) throws -> DailyBiographyFixture {
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
        for story in pastStories.prefix(includeEvening ? 2 : 1) + [currentStory] {
            insertTranscribedNote(story, in: context)
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

    private func insertTranscribedNote(_ story: Story, in context: ModelContext, timezone: String = "UTC") {
        let metadata = StoryMetadata(captureDate: story.date, timezone: timezone)
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
}

@MainActor
private final class DailyBiographyGeneratorWithInterruption: DailyEntryGenerationService {
    var beforeTwoNoteResponse: (() async throws -> Void)?

    func generateDailyEntry(_ request: DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse {
        if request.sourceSegments.count == 2, let beforeTwoNoteResponse {
            self.beforeTwoNoteResponse = nil
            try await beforeTwoNoteResponse()
        }
        return try await SuccessfulDailyBiographyGenerator().generateDailyEntry(request)
    }
}

private struct DailyBiographyTestTranscriber: RemoteSpeechTranscribing {
    func transcribe(audioFileURL: URL, localeIdentifier: String) async throws -> RemoteSpeechTranscription {
        RemoteSpeechTranscription(transcript: "The delayed voice note.", provider: "test", model: "test")
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

private actor RecordingBiographyGenerator: DailyEntryGenerationService {
    private(set) var requests: [DailyEntryGenerationRequest] = []

    func generateDailyEntry(_ request: DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse {
        requests.append(request)
        return try await SuccessfulDailyBiographyGenerator(includesFollowUps: true).generateDailyEntry(request)
    }
}

private struct SuccessfulDailyBiographyGenerator: DailyEntryGenerationService {
    /// Writes only from the first note, as the writer may when it merges or
    /// sets aside the others.
    var citesOnlyFirstNote = false
    var includesFollowUps = false

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
            followUpQuestions: includesFollowUps ? [
                .init(question: "What did you hear that morning?", reason: "A detail from the scene.", sourceReferences: sourceIds),
                .init(question: "What? Why?", reason: "", sourceReferences: sourceIds)
            ] : [],
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
