//
//  loreTests.swift
//  loreTests
//
//  Created by Aark Koduru on 7/18/25.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct loreTests {

    @Test func breathingOrbSpeedChangesKeepContinuousPhase() {
        let clock = BreathingOrbPhaseClock()
        let initialTime = clock.time(at: 100, targetSpeed: 0.14, baseSpeed: 3.24)
        let quietTime = clock.time(at: 100.016, targetSpeed: 0.14, baseSpeed: 3.24)
        let louderTime = clock.time(at: 100.032, targetSpeed: 0.30, baseSpeed: 3.24)

        #expect(initialTime == 0.6)
        #expect(quietTime > initialTime)
        #expect(louderTime > quietTime)
        #expect(louderTime - quietTime < 0.02)
    }

    @Test func audioLevelEnvelopeRespondsToWhispersWithoutJumping() {
        var envelope = AudioLevelEnvelope()
        let whisperRMS = pow(Float(10), -56 / 20)
        let whisperPeak = pow(Float(10), -49 / 20)

        let firstFrame = envelope.process(
            rms: whisperRMS,
            peak: whisperPeak,
            frameDuration: 1.0 / 43.0
        )
        _ = envelope.process(
            rms: whisperRMS,
            peak: whisperPeak,
            frameDuration: 1.0 / 43.0
        )
        let thirdFrame = envelope.process(
            rms: whisperRMS,
            peak: whisperPeak,
            frameDuration: 1.0 / 43.0
        )

        #expect(firstFrame > 0.1)
        #expect(thirdFrame > firstFrame)
        #expect(thirdFrame < 0.4)
    }

    @Test func audioLevelEnvelopeReleasesSmoothlyAfterSpeech() {
        var envelope = AudioLevelEnvelope()
        let speechRMS = pow(Float(10), -28 / 20)
        let speechPeak = pow(Float(10), -18 / 20)

        for _ in 0..<6 {
            _ = envelope.process(
                rms: speechRMS,
                peak: speechPeak,
                frameDuration: 1.0 / 43.0
            )
        }
        let spokenLevel = envelope.value
        let firstSilentFrame = envelope.process(
            rms: 0,
            peak: 0,
            frameDuration: 1.0 / 43.0
        )

        for _ in 0..<24 {
            _ = envelope.process(
                rms: 0,
                peak: 0,
                frameDuration: 1.0 / 43.0
            )
        }

        #expect(firstSilentFrame < spokenLevel)
        #expect(firstSilentFrame > spokenLevel * 0.75)
        #expect(envelope.value < firstSilentFrame * 0.1)
    }

    @Test func legacyStoryDecodesPayloadWithoutID() throws {
        let json = """
        {
            "text": "A childhood memory from Hyderabad.",
            "date": 742694400,
            "duration": 75
        }
        """

        let data = try #require(json.data(using: .utf8))
        let story = try JSONDecoder().decode(LegacyStoryPayload.self, from: data)

        #expect(story.text == "A childhood memory from Hyderabad.")
        #expect(story.duration == 75)
    }

    @Test func storyKeepsStableID() {
        let id = UUID()
        let story = Story(id: id, text: "Today felt quieter than usual.", date: Date(), duration: 12)

        #expect(story.id == id)
    }

    @Test func vocabularyEntryPersistsPreferredSpellingAndReplacement() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let preferred = VocabularyEntry(phrase: "Hyderabad")
        let replacement = VocabularyEntry(phrase: "Marisa", replacement: "Marissa")

        context.insert(preferred)
        context.insert(replacement)
        try context.save()

        let entries = try context.fetch(FetchDescriptor<VocabularyEntry>())

        #expect(entries.count == 2)
        #expect(entries.first(where: { $0.phrase == "Hyderabad" })?.isReplacement == false)
        #expect(entries.first(where: { $0.phrase == "Marisa" })?.replacement == "Marissa")
        #expect(VocabularyEntry.normalizedKey(for: "  HYDERÁBAD ") == "hyderabad")
    }

    @Test func transcriptArtifactsVersionsAndJobsPersistAdditively() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let storyID = UUID()
        let artifact = TranscriptArtifact(
            storyId: storyID,
            rawText: "Melissa—no, Marissa—is my cousin.",
            source: .appleSpeech,
            languageCode: "en-US",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            audioDuration: 4
        )
        let sourceVersion = TranscriptVersion(
            transcriptArtifactId: artifact.id,
            storyId: storyID,
            revision: 1,
            text: artifact.rawText,
            kind: .sourceSnapshot,
            author: .source
        )
        let correction = TranscriptVersion(
            transcriptArtifactId: artifact.id,
            storyId: storyID,
            supersedesVersionId: sourceVersion.id,
            revision: 2,
            text: "Marissa is my cousin.",
            kind: .userCorrection,
            author: .user,
            editSummary: "Confirmed name spelling"
        )
        let job = ProcessingJob(
            idempotencyKey: "daily-entry:\(storyID.uuidString):2",
            storyId: storyID,
            transcriptArtifactId: artifact.id,
            inputTranscriptVersionId: correction.id,
            kind: .dailyEntry,
            route: .remote,
            deletionState: .required
        )

        context.insert(artifact)
        context.insert(sourceVersion)
        context.insert(correction)
        context.insert(job)
        try context.save()

        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
        let jobs = try context.fetch(FetchDescriptor<ProcessingJob>())

        #expect(artifacts.count == 1)
        #expect(artifacts.first?.rawText == "Melissa—no, Marissa—is my cousin.")
        #expect(artifacts.first?.source == .appleSpeech)
        #expect(versions.count == 2)
        #expect(versions.contains(where: { $0.kind == .userCorrection && $0.author == .user }))
        #expect(jobs.first?.kind == .dailyEntry)
        #expect(jobs.first?.state == .queued)
        #expect(jobs.first?.deletionState == .required)

        let attemptDate = Date(timeIntervalSince1970: 1_800_000_100)
        job.beginAttempt(at: attemptDate, leaseDuration: 60)
        #expect(job.state == .running)
        #expect(job.attemptCount == 1)
        #expect(job.leaseExpiresAt == attemptDate.addingTimeInterval(60))

        let retryDate = attemptDate.addingTimeInterval(30)
        job.markFailed(errorCode: "network_unavailable", retryAt: retryDate, at: attemptDate)
        #expect(job.state == .queued)
        #expect(job.lastErrorCode == "network_unavailable")
        #expect(job.nextAttemptAt == retryDate)
    }

    @Test func exhaustedInterruptedJobBecomesTerminalFailure() {
        let job = ProcessingJob(
            idempotencyKey: "transcription:interrupted",
            kind: .transcription,
            route: .remote,
            maximumAttempts: 1
        )
        let attemptDate = Date(timeIntervalSince1970: 1_800_000_000)
        job.beginAttempt(at: attemptDate, leaseDuration: 30)

        #expect(job.recoverExpiredLease(at: attemptDate.addingTimeInterval(31)))
        #expect(job.state == .failed)
        #expect(job.nextAttemptAt == nil)
        #expect(job.completedAt == attemptDate.addingTimeInterval(31))
        #expect(job.lastErrorCode == "interrupted_attempt")
    }

    @Test func userRequestedRestartResetsATerminalTranscriptionJob() {
        let job = ProcessingJob(
            idempotencyKey: "transcription:retry",
            kind: .transcription,
            state: .failed,
            route: .remote,
            attemptCount: 3,
            maximumAttempts: 3,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastErrorCode: "app_attest_server_unavailable"
        )
        let restartDate = Date(timeIntervalSince1970: 1_800_000_100)

        job.restartAfterUserRequest(at: restartDate)

        #expect(job.state == .queued)
        #expect(job.attemptCount == 0)
        #expect(job.completedAt == nil)
        #expect(job.nextAttemptAt == restartDate)
        #expect(job.lastErrorCode == nil)
        #expect(job.isReadyForAttempt(at: restartDate))
    }

    @Test func remoteProcessingContractsRoundTripWithoutProviderCredentials() throws {
        let request = DailyEntryGenerationRequest(
            jobId: UUID(),
            noteId: UUID(),
            transcriptArtifactId: UUID(),
            transcriptVersionId: UUID(),
            capturedLocalDate: "2026-07-14",
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            sourceSegments: [
                TranscriptSourceSegment(
                    id: "s1",
                    startMilliseconds: 0,
                    endMilliseconds: 4_000,
                    text: "Melissa—no, Marissa—is my cousin.",
                    confidence: 0.91,
                    speakerLabel: nil
                )
            ]
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DailyEntryGenerationRequest.self, from: encoded)

        #expect(decoded == request)
        #expect(decoded.retentionPolicy.mode == .zeroDataRetention)
        #expect(decoded.retentionPolicy.maximumRetentionSeconds == 0)
        #expect(String(decoding: encoded, as: UTF8.self).contains("apiKey") == false)
    }

    @Test func unconfiguredRemoteBackendFailsClosed() async {
        let backend = UnconfiguredLoreBackendProcessingClient()
        let request = RemoteTranscriptionRequest(
            jobId: UUID(),
            audio: RemoteAudioPayload(
                bytes: Data([0x00, 0x01]),
                mimeType: "audio/mp4",
                filenameExtension: "m4a",
                durationSeconds: 1
            )
        )
        var error: LoreBackendProcessingError?

        do {
            _ = try await backend.transcribe(request)
        } catch let caught as LoreBackendProcessingError {
            error = caught
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(error == .notConfigured)
    }

    @Test func storyDisplayContentPrefersGeneratedBiographyProseWhenAvailable() {
        let story = Story(
            text: "I remembered walking home from school in the rain.",
            date: Date(),
            duration: 34,
            biographyProse: "He remembered the long walk home from school through the rain.",
            processingStatus: "processed"
        )

        let content = StoryDisplayContent(story: story)

        #expect(content.primaryPreview == "He remembered the long walk home from school through the rain.")
        #expect(content.sourceTranscriptPreview == "I remembered walking home from school in the rain.")
        #expect(content.transcriptText == "I remembered walking home from school in the rain.")
    }

    @Test func storyDisplayContentKeepsTranscriptPrimaryWithoutJournalEntry() {
        let story = Story(
            text: "I started a new chapter today.",
            date: Date(),
            duration: 8,
            processingStatus: "processing"
        )

        let content = StoryDisplayContent(story: story)

        #expect(content.primaryPreview == "I started a new chapter today.")
        #expect(content.sourceTranscriptPreview == nil)
    }

    @Test func storyDisplayContentNeverHidesTranscriptAfterBackgroundFailure() {
        let story = Story(
            text: "This memory should remain readable.",
            date: Date(),
            duration: 11,
            processingStatus: "failed"
        )

        let content = StoryDisplayContent(story: story)

        #expect(content.primaryPreview == "This memory should remain readable.")
        #expect(content.transcriptText == "This memory should remain readable.")
    }

    @Test func legacyMigrationImportsProfileAndStories() throws {
        let defaults = try makeIsolatedDefaults()
        let profile = LegacyUserProfilePayload(name: "Aark", hometown: "Hyderabad", birthYear: 1994)
        let storyID = UUID()
        let storyDate = Date(timeIntervalSince1970: 742_694_400)
        let stories = [
            LegacyStoryPayload(
                id: storyID,
                text: "A childhood memory from Hyderabad.",
                date: storyDate,
                duration: 75
            )
        ]

        defaults.set(try JSONEncoder().encode(profile), forKey: "UserProfile")
        defaults.set(try JSONEncoder().encode(stories), forKey: "SavedStories")

        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        try LegacyDataMigrator.migrateIfNeeded(modelContext: context, userDefaults: defaults)

        let migratedProfiles = try context.fetch(FetchDescriptor<UserProfile>())
        let migratedStories = try context.fetch(FetchDescriptor<Story>())

        #expect(migratedProfiles.count == 1)
        #expect(migratedProfiles.first?.name == "Aark")
        #expect(migratedProfiles.first?.hometown == "Hyderabad")
        #expect(migratedProfiles.first?.birthYear == 1994)
        #expect(migratedStories.count == 1)
        #expect(migratedStories.first?.id == storyID)
        #expect(migratedStories.first?.rawTranscriptExpiresAt == nil)
        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.storyId == storyID)
        #expect(artifacts.first?.rawText == "A childhood memory from Hyderabad.")
        #expect(artifacts.first?.source == .legacyStory)
        #expect(versions.count == 1)
        #expect(versions.first?.transcriptArtifactId == artifacts.first?.id)
    }

    @Test func legacyMigrationDoesNotDuplicateStories() throws {
        let defaults = try makeIsolatedDefaults()
        let storyID = UUID()
        let stories = [
            LegacyStoryPayload(
                id: storyID,
                text: "A memory already stored.",
                date: Date(),
                duration: 18
            )
        ]

        defaults.set(try JSONEncoder().encode(stories), forKey: "SavedStories")

        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        try LegacyDataMigrator.migrateIfNeeded(modelContext: context, userDefaults: defaults)
        defaults.set(false, forKey: "LoreSwiftDataMigrationV1Complete")
        try LegacyDataMigrator.migrateIfNeeded(modelContext: context, userDefaults: defaults)

        let migratedStories = try context.fetch(FetchDescriptor<Story>())
        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())

        #expect(migratedStories.count == 1)
        #expect(migratedStories.first?.id == storyID)
        #expect(artifacts.count == 1)
    }


    @MainActor
    @Test func capturedStoryPersistsPlaceholderAudioAssetMetadata() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(42)
        let metadataService = LocalMetadataService(
            timezoneProvider: { TimeZone(identifier: "America/Los_Angeles")! },
            locationCaptureProvider: {
                MetadataLocationCapture(
                    authorizationStatus: .denied,
                    captureStatus: .permissionDenied
                )
            }
        )

        let story = try await SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A remembered afternoon by the lake.",
            startTime: startTime,
            endTime: endTime,
            metadataService: metadataService,
            modelContext: context
        )

        let stories = try context.fetch(FetchDescriptor<Story>())
        let audioAssets = try context.fetch(FetchDescriptor<AudioAsset>())
        let metadataRecords = try context.fetch(FetchDescriptor<StoryMetadata>())
        let asset = try #require(audioAssets.first)
        let metadata = try #require(metadataRecords.first)

        #expect(stories.count == 1)
        #expect(stories.first?.id == story.id)
        #expect(stories.first?.metadataId == metadata.id)
        #expect(metadataRecords.count == 1)
        #expect(metadata.captureDate == startTime)
        #expect(metadata.timezone == "America/Los_Angeles")
        #expect(metadata.latitude == nil)
        #expect(metadata.longitude == nil)
        #expect(metadata.weatherSummary == nil)
        #expect(metadata.permissionSnapshot?.contains("\"locationAuthorizationStatus\":\"denied\"") == true)
        #expect(metadata.permissionSnapshot?.contains("\"locationCaptureStatus\":\"permissionDenied\"") == true)
        #expect(metadata.permissionSnapshot?.contains("\"weatherStatus\":\"notRequested\"") == true)
        #expect(audioAssets.count == 1)
        #expect(asset.id == story.id)
        #expect(asset.createdAt == endTime)
        #expect(asset.expiresAt == endTime.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(asset.duration == 42)
        #expect(asset.isDeleted == false)
        #expect(SpeechRecognitionViewModel.isPlaceholderAudioURL(asset.fileURL))
    }

    @MainActor
    @Test func capturedStoryCanPersistBeforeOptionalMetadataFinishes() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(14)

        let story = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "This story should appear before location or weather metadata is ready.",
            startTime: startTime,
            endTime: endTime,
            modelContext: context
        )

        let stories = try context.fetch(FetchDescriptor<Story>())
        let metadataRecords = try context.fetch(FetchDescriptor<StoryMetadata>())
        let metadata = try #require(metadataRecords.first)

        #expect(stories.count == 1)
        #expect(stories.first?.id == story.id)
        #expect(story.metadataId == metadata.id)
        #expect(metadata.captureDate == startTime)
        #expect(metadata.permissionSnapshot?.contains("\"locationAuthorizationStatus\":\"pending\"") == true)
        #expect(metadata.permissionSnapshot?.contains("\"weatherStatus\":\"pending\"") == true)
    }


    @MainActor
    @Test func capturedStoryPersistsRealAudioAssetFileURLWhenAvailable() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(23)
        let capturedLocation = CLLocation(latitude: 17.3850, longitude: 78.4867)
        let metadataService = LocalMetadataService(
            timezoneProvider: { TimeZone(identifier: "Asia/Kolkata")! },
            locationCaptureProvider: {
                MetadataLocationCapture(
                    authorizationStatus: .authorizedWhenInUse,
                    captureStatus: .captured,
                    location: capturedLocation,
                    locationName: "Hyderabad, Telangana, India"
                )
            },
            weatherCaptureProvider: { location in
                #expect(location.coordinate.latitude == capturedLocation.coordinate.latitude)
                #expect(location.coordinate.longitude == capturedLocation.coordinate.longitude)
                return MetadataWeatherCapture(
                    summary: "Clear",
                    temperatureCelsius: 31.4,
                    source: "WeatherKit"
                )
            }
        )
        let audioFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-real-audio-\(UUID().uuidString).caf")
        try Data([0, 1, 2, 3]).write(to: audioFileURL)

        let story = try await SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A story with retained local audio.",
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            metadataService: metadataService,
            modelContext: context
        )

        let asset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)
        let metadata = try #require(try context.fetch(FetchDescriptor<StoryMetadata>()).first)

        #expect(asset.id == story.id)
        #expect(asset.fileURL == audioFileURL.absoluteString)
        #expect(asset.createdAt == endTime)
        #expect(asset.expiresAt == endTime.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(asset.duration == 23)
        #expect(asset.isDeleted == false)
        #expect(!SpeechRecognitionViewModel.isPlaceholderAudioURL(asset.fileURL))
        #expect(story.metadataId == metadata.id)
        #expect(metadata.captureDate == startTime)
        #expect(metadata.timezone == "Asia/Kolkata")
        #expect(metadata.locationName == "Hyderabad, Telangana, India")
        #expect(metadata.latitude == 17.3850)
        #expect(metadata.longitude == 78.4867)
        #expect(metadata.weatherSummary == "Clear")
        #expect(metadata.temperature == 31.4)
        #expect(metadata.weatherSource == "WeatherKit")
        #expect(metadata.permissionSnapshot?.contains("\"locationAuthorizationStatus\":\"authorizedWhenInUse\"") == true)
        #expect(metadata.permissionSnapshot?.contains("\"locationCaptureStatus\":\"captured\"") == true)
        #expect(metadata.permissionSnapshot?.contains("\"weatherStatus\":\"available\"") == true)

        try? fileManager.removeItem(at: audioFileURL)
    }

    @MainActor
    @Test func managedAudioAssetPersistsContainerRelativeReference() throws {
        let audioDirectory = try SpeechRecognitionViewModel.audioStorageDirectory()
        let storyID = UUID()
        let audioFileURL = audioDirectory.appendingPathComponent("\(storyID.uuidString).caf")

        let asset = SpeechRecognitionViewModel.makeAudioAsset(
            storyID: storyID,
            fileURL: audioFileURL,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 12
        )

        #expect(asset.fileURL == audioFileURL.lastPathComponent)
    }

    @MainActor
    @Test func staleContainerAudioURLRecoversFromCurrentManagedDirectory() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lore-path-recovery-\(UUID().uuidString)", isDirectory: true)
        let currentAudioDirectory = testRoot
            .appendingPathComponent("current-container", isDirectory: true)
            .appendingPathComponent("Library/Application Support/Lore/Audio", isDirectory: true)
        try fileManager.createDirectory(
            at: currentAudioDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        let filename = "\(UUID().uuidString).caf"
        let currentAudioURL = currentAudioDirectory.appendingPathComponent(filename)
        try Data([0, 1, 2, 3]).write(to: currentAudioURL)
        let staleAudioURL = testRoot
            .appendingPathComponent("old-container", isDirectory: true)
            .appendingPathComponent("Library/Application Support/Lore/Audio", isDirectory: true)
            .appendingPathComponent(filename)

        let resolvedURL = SpeechRecognitionViewModel.resolveAudioFileURL(
            storedReference: staleAudioURL.absoluteString,
            audioDirectory: currentAudioDirectory,
            fileManager: fileManager
        )

        #expect(resolvedURL?.standardizedFileURL == currentAudioURL.standardizedFileURL)
        #expect(
            SpeechRecognitionViewModel.persistedAudioFileReference(
                for: try #require(resolvedURL),
                audioDirectory: currentAudioDirectory
            ) == filename
        )
    }

    @MainActor
    @Test func relativeAudioReferenceCannotEscapeManagedDirectory() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lore-path-safety-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = testRoot.appendingPathComponent("Audio", isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try Data([0]).write(to: testRoot.appendingPathComponent("outside.caf"))

        let resolvedURL = SpeechRecognitionViewModel.resolveAudioFileURL(
            storedReference: "../outside.caf",
            audioDirectory: audioDirectory,
            fileManager: fileManager
        )

        #expect(resolvedURL == nil)
    }

    @MainActor
    @Test func cleanupDeletesOnlyAudioWithCommittedImmutableTranscript() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let committedFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-audio-cleanup-\(UUID().uuidString).caf")
        let pendingFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-audio-pending-cleanup-\(UUID().uuidString).caf")
        try Data([0, 1, 2]).write(to: committedFileURL)
        try Data([3, 4, 5]).write(to: pendingFileURL)

        _ = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "This transcript is durable.",
            startTime: now.addingTimeInterval(-10),
            endTime: now.addingTimeInterval(-9),
            audioFileURL: committedFileURL,
            modelContext: context
        )
        let (_, pendingJob) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: now.addingTimeInterval(-8),
            endTime: now.addingTimeInterval(-7),
            audioFileURL: pendingFileURL,
            modelContext: context
        )
        let assets = try context.fetch(FetchDescriptor<AudioAsset>())
        assets.forEach { $0.expiresAt = now.addingTimeInterval(-1) }
        try context.save()

        let cleanedCount = try SpeechRecognitionViewModel.cleanupExpiredAudioAssets(
            in: context,
            now: now,
            fileManager: fileManager
        )

        #expect(cleanedCount == 1)
        #expect(fileManager.fileExists(atPath: committedFileURL.path) == false)
        #expect(fileManager.fileExists(atPath: pendingFileURL.path))
        #expect(pendingJob.state == .queued)
        try? fileManager.removeItem(at: pendingFileURL)
    }

    @MainActor
    @Test func deletingStoryAudioAssetsRemovesLinkedFilesAndMetadata() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(31)
        let audioFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-delete-audio-\(UUID().uuidString).caf")
        try Data([4, 5, 6, 7]).write(to: audioFileURL)
        let metadataService = LocalMetadataService(
            locationCaptureProvider: {
                MetadataLocationCapture(
                    authorizationStatus: .denied,
                    captureStatus: .permissionDenied
                )
            }
        )
        let story = try await SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A story whose audio should be deleted.",
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            metadataService: metadataService,
            modelContext: context
        )

        let deletedAssetCount = try SpeechRecognitionViewModel.deleteAudioAssets(
            for: story,
            in: context,
            fileManager: fileManager
        )
        let deletedMetadataCount = try SpeechRecognitionViewModel.deleteStoryMetadata(
            for: story,
            in: context
        )
        context.delete(story)
        try context.save()

        #expect(deletedAssetCount == 1)
        #expect(deletedMetadataCount == 1)
        #expect(fileManager.fileExists(atPath: audioFileURL.path) == false)
        #expect(try context.fetch(FetchDescriptor<AudioAsset>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StoryMetadata>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Story>()).isEmpty)
    }

    @Test func memoryGraphPersistsLifeEventTemporalUncertaintyAndSources() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let firstStoryId = UUID()
        let secondStoryId = UUID()
        let approximateStart = try makeDate(year: 2012, month: 1, day: 1)
        let event = LifeEvent(
            title: "Moved to Seattle",
            summary: "A major move during an uncertain year.",
            eventDateKind: .approximate,
            eventStartDate: approximateStart,
            approximateLabel: "around 2012",
            confidence: 0.72,
            sourceStoryIds: [firstStoryId, secondStoryId]
        )

        context.insert(event)
        try context.save()

        let fetchedEvents = try context.fetch(FetchDescriptor<LifeEvent>())
        let fetchedEvent = try #require(fetchedEvents.first)

        #expect(fetchedEvents.count == 1)
        #expect(fetchedEvent.title == "Moved to Seattle")
        #expect(fetchedEvent.dateKind == .approximate)
        #expect(fetchedEvent.eventDateKind == LifeEventDateKind.approximate.rawValue)
        #expect(fetchedEvent.eventStartDate == approximateStart)
        #expect(fetchedEvent.eventEndDate == nil)
        #expect(fetchedEvent.approximateLabel == "around 2012")
        #expect(fetchedEvent.sourceStoryIds == [firstStoryId, secondStoryId])
    }

    @Test func memoryGraphPersistsPeoplePlacesAndThemesWithSources() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sourceStoryId = UUID()
        let secondSourceStoryId = UUID()

        context.insert(Person(
            displayName: "Priya",
            aliases: ["P"],
            relationshipToUser: "friend",
            summary: "A close friend from college.",
            confidence: 0.89,
            sourceStoryIds: [sourceStoryId]
        ))
        context.insert(Place(
            displayName: "Hyderabad",
            placeKind: "hometown",
            locationHint: "India",
            summary: "The user's hometown.",
            confidence: 0.93,
            sourceStoryIds: [sourceStoryId, secondSourceStoryId]
        ))
        context.insert(Theme(
            name: "reinvention",
            summary: "Choosing a new path after a move.",
            confidence: 0.67,
            sourceStoryIds: [secondSourceStoryId]
        ))
        try context.save()

        let person = try #require(try context.fetch(FetchDescriptor<Person>()).first)
        let place = try #require(try context.fetch(FetchDescriptor<Place>()).first)
        let theme = try #require(try context.fetch(FetchDescriptor<Theme>()).first)

        #expect(person.displayName == "Priya")
        #expect(person.aliases == ["P"])
        #expect(person.relationshipToUser == "friend")
        #expect(person.sourceStoryIds == [sourceStoryId])
        #expect(place.displayName == "Hyderabad")
        #expect(place.placeKind == "hometown")
        #expect(place.locationHint == "India")
        #expect(place.sourceStoryIds == [sourceStoryId, secondSourceStoryId])
        #expect(theme.name == "reinvention")
        #expect(theme.sourceStoryIds == [secondSourceStoryId])
    }

    @Test func memoryGraphServiceParsesModelJSONWithDateStringsAndDefaults() throws {
        let storyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let json = """
        ```json
        {
          "lifeEvents": [
            {
              "title": "Moved to Seattle",
              "summary": "A move described as probably around 2012.",
              "eventDateKind": "approximate",
              "eventStartDate": "2012",
              "approximateLabel": "around 2012",
              "confidence": 1.4,
              "sourceStoryIds": ["\(storyID.uuidString)"]
            }
          ],
          "people": [
            {
              "displayName": "Priya",
              "confidence": 0.7
            }
          ],
          "memoryFacts": [
            {
              "text": "Extra model output should not break graph candidate parsing."
            }
          ]
        }
        ```
        """

        let result = try MemoryGraphService.parseExtractionJSON(json)
        let event = try #require(result.lifeEvents.first)
        let person = try #require(result.people.first)
        let expectedDate = try makeDate(year: 2012, month: 1, day: 1)

        #expect(event.title == "Moved to Seattle")
        #expect(event.eventDateKind == .approximate)
        #expect(event.eventStartDate == expectedDate)
        #expect(event.approximateLabel == "around 2012")
        #expect(event.confidence == 1)
        #expect(event.sourceStoryIds == [storyID])
        #expect(person.displayName == "Priya")
        #expect(person.aliases == [])
        #expect(person.sourceStoryIds == [])
        #expect(result.places == [])
        #expect(result.themes == [])
    }

    @Test func memoryGraphServicePersistsAndMergesCandidatesByStableNames() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let firstStory = Story(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "I moved to Seattle and met Priya.",
            date: Date(),
            duration: 14
        )
        let secondStory = Story(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            text: "Priya helped me after the move to Seattle.",
            date: Date(),
            duration: 18
        )
        let firstJSON = """
        {
          "lifeEvents": [
            {
              "title": "Moved to Seattle",
              "summary": "The first version of the event.",
              "eventDateKind": "unknown",
              "confidence": 0.4
            }
          ],
          "people": [
            {
              "displayName": "Priya",
              "aliases": ["P"],
              "relationshipToUser": "friend",
              "summary": "A close friend.",
              "confidence": 0.6
            }
          ],
          "places": [
            {
              "displayName": "Seattle",
              "placeKind": "city",
              "summary": "A city tied to the move.",
              "confidence": 0.8
            }
          ],
          "themes": [
            {
              "name": "reinvention",
              "summary": "Starting over.",
              "confidence": 0.5
            }
          ]
        }
        """
        let secondJSON = """
        {
          "lifeEvents": [
            {
              "title": "Moved to Seattle",
              "summary": "A higher-confidence version of the event.",
              "eventDateKind": "approximate",
              "eventStartDate": "2012-01-01",
              "approximateLabel": "around 2012",
              "confidence": 0.9
            }
          ],
          "people": [
            {
              "displayName": "Priya",
              "aliases": ["Pri"],
              "relationshipToUser": "friend",
              "summary": "A friend who helped after the move.",
              "confidence": 0.85
            }
          ],
          "places": [
            {
              "displayName": "Seattle",
              "placeKind": "city",
              "locationHint": "Washington",
              "summary": "The city where the move happened.",
              "confidence": 0.9
            }
          ],
          "themes": [
            {
              "name": "Reinvention",
              "summary": "Choosing a new life after a move.",
              "confidence": 0.75
            }
          ]
        }
        """

        try MemoryGraphService.persistExtractionJSON(firstJSON, for: firstStory, in: context)
        try MemoryGraphService.persistExtractionJSON(secondJSON, for: secondStory, in: context)

        let events = try context.fetch(FetchDescriptor<LifeEvent>())
        let people = try context.fetch(FetchDescriptor<Person>())
        let places = try context.fetch(FetchDescriptor<Place>())
        let themes = try context.fetch(FetchDescriptor<Theme>())
        let event = try #require(events.first)
        let person = try #require(people.first)
        let place = try #require(places.first)
        let theme = try #require(themes.first)

        #expect(events.count == 1)
        #expect(people.count == 1)
        #expect(places.count == 1)
        #expect(themes.count == 1)
        #expect(event.summary == "A higher-confidence version of the event.")
        #expect(event.dateKind == .approximate)
        #expect(event.approximateLabel == "around 2012")
        #expect(event.sourceStoryIds == [firstStory.id, secondStory.id])
        #expect(person.aliases == ["P", "Pri"])
        #expect(person.summary == "A friend who helped after the move.")
        #expect(person.sourceStoryIds == [firstStory.id, secondStory.id])
        #expect(place.locationHint == "Washington")
        #expect(place.sourceStoryIds == [firstStory.id, secondStory.id])
        #expect(theme.summary == "Choosing a new life after a move.")
        #expect(theme.sourceStoryIds == [firstStory.id, secondStory.id])
    }


    @Test func remoteProcessingConsentPersistsAsOnePermission() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let consentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = UserProfile(
            name: "Aark",
            hometown: "Hyderabad",
            birthYear: 1994,
            remoteProcessingConsentedAt: consentDate
        )

        context.insert(profile)
        try context.save()

        let persisted = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(persisted.hasRemoteProcessingConsent)
        #expect(persisted.remoteProcessingConsentedAt == consentDate)
    }

    @Test func remoteOnlyRoutingUsesWifiAndCellular() {
        let policy = SpeechTranscriptionPolicy.production
        let preferences = RemoteProcessingPreferences(hasConsent: true)

        #expect(policy.route(for: .init(preferences: preferences, networkConnection: .wifi)) == .remote)
        #expect(policy.route(for: .init(preferences: preferences, networkConnection: .cellular)) == .remote)
    }

    @Test func remoteOnlyRoutingWaitsWithoutConsentOrConnectivity() {
        let policy = SpeechTranscriptionPolicy.production

        #expect(policy.route(for: .init(
            preferences: RemoteProcessingPreferences(hasConsent: false),
            networkConnection: .wifi
        )) == .deferred(reason: .remoteProcessingConsentRequired))
        #expect(policy.route(for: .init(
            preferences: RemoteProcessingPreferences(hasConsent: true),
            networkConnection: .unavailable
        )) == .deferred(reason: .networkUnavailable))
    }

    @MainActor
    @Test func transcriptCorrectionAppendsVersionWithoutMutatingRawArtifact() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let story = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "Melissa is my cousin.",
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_005),
            modelContext: context
        )

        try SpeechRecognitionViewModel.applyUserCorrection(
            "Marissa is my cousin.",
            to: story,
            in: context,
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let artifact = try #require(try context.fetch(FetchDescriptor<TranscriptArtifact>()).first)
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
            .sorted { $0.revision < $1.revision }

        #expect(artifact.rawText == "Melissa is my cousin.")
        #expect(story.text == "Marissa is my cousin.")
        #expect(versions.count == 2)
        #expect(versions[0].kind == .sourceSnapshot)
        #expect(versions[1].kind == .userCorrection)
        #expect(versions[1].supersedesVersionId == versions[0].id)
        #expect(versions[1].text == "Marissa is my cousin.")
    }

    @MainActor
    @Test func successfulTranscriptDeletionRemovesAudioButKeepsAuditMetadata() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-success-delete-\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let story = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "A durable transcript.",
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_010),
            audioFileURL: audioURL,
            transcriptSource: .remoteProvider,
            languageCode: "en-US",
            providerId: "test-provider",
            providerModelId: "test-model",
            providerRequestId: "request-123",
            modelContext: context
        )

        let deletedCount = try SpeechRecognitionViewModel.deleteAudioAfterSuccessfulTranscription(
            for: story,
            in: context
        )
        let verificationContext = ModelContext(container)
        let remainingAssets = try verificationContext.fetch(FetchDescriptor<AudioAsset>())
        let artifact = try #require(try verificationContext.fetch(FetchDescriptor<TranscriptArtifact>()).first)
        let version = try #require(try verificationContext.fetch(FetchDescriptor<TranscriptVersion>()).first)

        #expect(deletedCount == 1)
        #expect(remainingAssets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
        #expect(story.rawTranscriptExpiresAt == nil)
        #expect(artifact.rawText == "A durable transcript.")
        #expect(artifact.source == .remoteProvider)
        #expect(artifact.providerId == "test-provider")
        #expect(artifact.providerModelId == "test-model")
        #expect(artifact.providerRequestId == "request-123")
        #expect(version.text == artifact.rawText)
        #expect(version.transcriptArtifactId == artifact.id)
    }

    @MainActor
    @Test func remoteGenerationRequestUsesNewestTranscriptVersion() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let story = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "Melissa is my cousin.",
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_005),
            modelContext: context
        )
        try SpeechRecognitionViewModel.applyUserCorrection(
            "Marissa is my cousin.",
            to: story,
            in: context,
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let request = try RemoteGenerationRequestFactory.makeRequest(
            for: story,
            userProfile: UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994),
            in: context,
            locale: Locale(identifier: "en-US")
        )
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
            .sorted { $0.revision < $1.revision }

        #expect(request.transcriptVersionId == versions.last?.id)
        #expect(request.sourceSegments.map(\.text) == ["Marissa is my cousin."])
        #expect(request.subject.displayName == "Aark")
    }

    @MainActor
    @Test func missingTranscriptDefersAudioDeletionForRemoteRetry() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-deferred-delete-\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let story = try SpeechRecognitionViewModel.persistCapturedStoryImmediately(
            transcript: "",
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_010),
            audioFileURL: audioURL,
            modelContext: context
        )

        let deletedCount = try SpeechRecognitionViewModel.deleteAudioAfterSuccessfulTranscription(
            for: story,
            in: context
        )
        let asset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)

        #expect(deletedCount == 0)
        #expect(asset.isDeleted == false)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        try? FileManager.default.removeItem(at: audioURL)
    }

    @MainActor
    @Test func remoteTranscriptionPersistsCaptureAndRunningJobBeforeUpload() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-ordering-\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: audioURL)
        let (story, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_010),
            audioFileURL: audioURL,
            modelContext: context
        )
        var observedDurableOrderingBarrier = false
        let transcriber = InspectingRemoteSpeechTranscriber { requestedURL, localeIdentifier in
            let storedStories = try context.fetch(FetchDescriptor<Story>())
            let storedAssets = try context.fetch(FetchDescriptor<AudioAsset>())
            let storedJobs = try context.fetch(FetchDescriptor<ProcessingJob>())
            let storedArtifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
            observedDurableOrderingBarrier = storedStories.contains { $0.id == story.id }
                && storedAssets.contains { $0.id == story.id && !$0.isDeleted }
                && storedJobs.first(where: { $0.id == job.id })?.state == .running
                && storedArtifacts.isEmpty
            #expect(requestedURL == audioURL)
            #expect(localeIdentifier == "en-US")
            return RemoteSpeechTranscription(
                transcript: "The provider returned a durable memory.",
                provider: "groq",
                model: "whisper-large-v3-turbo",
                requestID: "groq-request-1"
            )
        }

        let completedStory = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: job.id,
            remoteTranscriber: transcriber,
            localeIdentifier: "en-US",
            modelContext: context
        )

        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
        let storedJobs = try context.fetch(FetchDescriptor<ProcessingJob>())
        #expect(observedDurableOrderingBarrier)
        #expect(completedStory.text == "The provider returned a durable memory.")
        #expect(artifacts.count == 1)
        #expect(versions.count == 1)
        #expect(storedJobs.first?.state == .succeeded)
        #expect(storedJobs.first?.transcriptArtifactId == artifacts.first?.id)
        #expect(try context.fetch(FetchDescriptor<AudioAsset>()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
    }

    @MainActor
    @Test func transcriptionJobRecoversAndCanonicalizesStaleContainerURL() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioDirectory = try SpeechRecognitionViewModel.audioStorageDirectory()
        let filename = "\(UUID().uuidString).caf"
        let audioURL = audioDirectory.appendingPathComponent(filename)
        try Data([1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let (_, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_010),
            audioFileURL: audioURL,
            modelContext: context
        )
        let asset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)
        asset.fileURL = URL(fileURLWithPath: "/stale-app-container/Library/Application Support/Lore/Audio")
            .appendingPathComponent(filename)
            .absoluteString
        try context.save()

        var recoveredCurrentFile = false
        let transcriber = InspectingRemoteSpeechTranscriber { requestedURL, _ in
            let storedAsset = try #require(
                try context.fetch(FetchDescriptor<AudioAsset>()).first
            )
            recoveredCurrentFile = requestedURL.standardizedFileURL == audioURL.standardizedFileURL
                && storedAsset.fileURL == filename
            return RemoteSpeechTranscription(
                transcript: "The recovered recording was transcribed.",
                provider: "groq",
                model: "whisper-large-v3-turbo"
            )
        }

        _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: job.id,
            remoteTranscriber: transcriber,
            localeIdentifier: "en-US",
            modelContext: context
        )

        #expect(recoveredCurrentFile)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
    }

    @MainActor
    @Test func audioTranscodeFailureHasDistinctRetryableJobCode() {
        let story = Story(text: "", date: Date(), duration: 1)
        let job = SpeechRecognitionViewModel.makePendingTranscriptionJob(
            for: story,
            route: .remote,
            failure: RemoteSpeechTranscriptionError.audioTranscodeFailed
        )

        #expect(job.lastErrorCode == "audio_transcode_failed")
    }

    @MainActor
    @Test func remoteFailureQueuesRetryAndRetainsAudioUntilAttemptsExhaust() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-retry-\(UUID().uuidString).caf")
        try Data([4, 5, 6]).write(to: audioURL)
        let (_, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(),
            endTime: Date().addingTimeInterval(4),
            audioFileURL: audioURL,
            modelContext: context
        )
        let transcriber = InspectingRemoteSpeechTranscriber { _, _ in
            throw TestRemoteTranscriptionFailure.networkUnavailable
        }

        for attempt in 0..<3 {
            do {
                _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
                    jobID: job.id,
                    remoteTranscriber: transcriber,
                    localeIdentifier: "en-US",
                    modelContext: context,
                    now: Date().addingTimeInterval(Double(attempt) * 1_000)
                )
                Issue.record("The failing provider unexpectedly succeeded")
            } catch TestRemoteTranscriptionFailure.networkUnavailable {
                // Expected.
            }

            #expect(FileManager.default.fileExists(atPath: audioURL.path))
            #expect(try context.fetch(FetchDescriptor<AudioAsset>()).count == 1)
            #expect(job.attemptCount == attempt + 1)
            #expect(job.state == (attempt == 2 ? .failed : .queued))
        }

        #expect(job.lastErrorCode == "remote_transcription_failed")
        #expect(try context.fetch(FetchDescriptor<TranscriptArtifact>()).isEmpty)
        try? FileManager.default.removeItem(at: audioURL)
    }

    @MainActor
    @Test func remoteTranscriptCommitIsIdempotent() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-idempotent-\(UUID().uuidString).caf")
        try Data([7, 8, 9]).write(to: audioURL)
        let (story, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_003),
            audioFileURL: audioURL,
            modelContext: context
        )
        let audioAsset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)
        job.beginAttempt()
        try context.save()
        let response = RemoteSpeechTranscription(
            transcript: "Only one immutable source snapshot.",
            provider: "groq",
            model: "whisper-large-v3-turbo",
            requestID: "same-response"
        )

        _ = try SpeechRecognitionViewModel.commitRemoteTranscription(
            response,
            for: story,
            audioAsset: audioAsset,
            job: job,
            localeIdentifier: "en-US",
            modelContext: context
        )
        _ = try SpeechRecognitionViewModel.commitRemoteTranscription(
            response,
            for: story,
            audioAsset: audioAsset,
            job: job,
            localeIdentifier: "en-US",
            modelContext: context
        )

        #expect(try context.fetch(FetchDescriptor<TranscriptArtifact>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TranscriptVersion>()).count == 1)
        #expect(job.state == .succeeded)
        try? FileManager.default.removeItem(at: audioURL)
    }

    @MainActor
    @Test func cancellingTranscriptionRetainsAudioAndPersistsCancelledState() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-cancelled-\(UUID().uuidString).caf")
        try Data([10, 11]).write(to: audioURL)
        let (story, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(),
            endTime: Date().addingTimeInterval(2),
            audioFileURL: audioURL,
            modelContext: context
        )
        let transcriber = InspectingRemoteSpeechTranscriber { _, _ in
            throw CancellationError()
        }

        do {
            _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
                jobID: job.id,
                remoteTranscriber: transcriber,
                localeIdentifier: "en-US",
                modelContext: context
            )
            Issue.record("The cancelled provider unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }

        #expect(job.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try context.fetch(FetchDescriptor<AudioAsset>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TranscriptArtifact>()).isEmpty)
        let audioAsset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)
        do {
            _ = try SpeechRecognitionViewModel.commitRemoteTranscription(
                RemoteSpeechTranscription(
                    transcript: "A late response that must be ignored.",
                    provider: "groq",
                    model: "whisper-large-v3-turbo"
                ),
                for: story,
                audioAsset: audioAsset,
                job: job,
                localeIdentifier: "en-US",
                modelContext: context
            )
            Issue.record("A cancelled job committed a late provider response")
        } catch TranscriptionJobRunnerError.jobCancelled {
            // Expected.
        }
        #expect(try context.fetch(FetchDescriptor<TranscriptArtifact>()).isEmpty)
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "loreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(calendar: calendar, year: year, month: month, day: day)
        return try #require(components.date)
    }
}

private enum TestRemoteTranscriptionFailure: Error {
    case networkUnavailable
}

private final class InspectingRemoteSpeechTranscriber: RemoteSpeechTranscribing, @unchecked Sendable {
    typealias Handler = @MainActor (URL, String) throws -> RemoteSpeechTranscription

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func transcribe(
        audioFileURL: URL,
        localeIdentifier: String
    ) async throws -> RemoteSpeechTranscription {
        try await handler(audioFileURL, localeIdentifier)
    }
}
