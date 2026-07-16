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
            route: .adaptive,
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
        let service = BackendRemoteTranscriptionService(
            backend: UnconfiguredLoreBackendProcessingClient()
        )
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
            _ = try await service.transcribe(request)
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
        #expect(content.listStatusText == "Draft Ready")
    }

    @Test func storyDisplayContentKeepsTranscriptPrimaryWhileDraftIsPending() {
        let story = Story(
            text: "I started a new chapter today.",
            date: Date(),
            duration: 8,
            processingStatus: "processing"
        )

        let content = StoryDisplayContent(story: story)

        #expect(content.primaryPreview == "I started a new chapter today.")
        #expect(content.sourceTranscriptPreview == nil)
        #expect(content.listStatusText == "Writing Draft")
        #expect(content.detailStatusText == "Writing biography prose and updating memory.")
    }

    @Test func storyDisplayContentReportsFailedDraftWithoutHidingTranscript() {
        let story = Story(
            text: "This memory should remain readable.",
            date: Date(),
            duration: 11,
            processingStatus: "failed"
        )

        let content = StoryDisplayContent(story: story)

        #expect(content.primaryPreview == "This memory should remain readable.")
        #expect(content.transcriptText == "This memory should remain readable.")
        #expect(content.listStatusText == "Draft Failed")
        #expect(content.detailStatusText == "Lore could not finish processing this story.")
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
    @Test func modelManagerDownloadsAndLoadsSelectedModel() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults, runtime: TestDeterministicLocalModelRuntime())

        #expect(modelManager.status.tier == .lightweight17B)
        #expect(modelManager.status.state == .notDownloaded)

        modelManager.select(.lightweight17B)
        await modelManager.downloadSelectedModel()

        #expect(modelManager.status.tier == .lightweight17B)
        #expect(modelManager.status.state == .loaded)
        #expect(modelManager.status.isReady)
        #expect(modelManager.status.message == "Local generation fallback is ready.")
    }

    @MainActor
    @Test func modelManagerDoesNotLoadPersistedDownloadOnLaunch() async throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(LocalModelTier.standard4B.rawValue, forKey: "LoreSelectedLocalModelTier")
        defaults.set(LocalModelTier.standard4B.rawValue, forKey: "LoreDownloadedLocalModelTier")

        let modelManager = ModelManager(userDefaults: defaults, runtime: TestDeterministicLocalModelRuntime())

        #expect(modelManager.status.tier == .standard4B)
        #expect(modelManager.status.state == .downloaded)
        #expect(modelManager.status.isReady == false)
    }

    @MainActor
    @Test func modelManagerUnloadsLoadedModelButKeepsDownloadedState() async throws {
        let defaults = try makeIsolatedDefaults()
        let runtime = CapturingLocalModelRuntime(output: "Generated biography prose.")
        let modelManager = ModelManager(userDefaults: defaults, runtime: runtime)

        await modelManager.downloadSelectedModel()
        modelManager.unloadModel()

        #expect(modelManager.status.state == .downloaded)
        #expect(modelManager.status.isReady == false)
        #expect(runtime.unloadCount == 1)
    }

    @MainActor
    @Test func generationAutoLoadsDownloadedModelWhenNeeded() async throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(LocalModelTier.standard4B.rawValue, forKey: "LoreSelectedLocalModelTier")
        defaults.set(LocalModelTier.standard4B.rawValue, forKey: "LoreDownloadedLocalModelTier")
        let runtime = CapturingLocalModelRuntime(output: "Generated biography prose.")
        let modelManager = ModelManager(userDefaults: defaults, runtime: runtime)
        let generationService = LocalGenerationService(modelManager: modelManager)
        let story = Story(text: "I started a new chapter today.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        let prose = try await generationService.writeBiographyProse(from: story, userProfile: profile)

        #expect(prose == "Generated biography prose.")
        #expect(runtime.loadedTiers == [.standard4B])
        #expect(modelManager.status.isReady)
    }

    @MainActor
    @Test func generationServiceRequiresLoadedModel() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults, runtime: TestDeterministicLocalModelRuntime())
        let generationService = LocalGenerationService(modelManager: modelManager)
        let story = Story(text: "I started a new chapter today.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)
        var didRequireModel = false

        do {
            _ = try await generationService.writeBiographyProse(from: story, userProfile: profile)
        } catch GenerationError.localModelNotReady {
            didRequireModel = true
        }

        #expect(didRequireModel)
    }

    @MainActor
    @Test func generationServiceDelegatesBiographyPromptToModelManagerRuntime() async throws {
        let defaults = try makeIsolatedDefaults()
        let runtime = CapturingLocalModelRuntime(output: "Generated biography prose.")
        let modelManager = ModelManager(userDefaults: defaults, runtime: runtime)
        let generationService = LocalGenerationService(modelManager: modelManager)
        let story = Story(text: "I started a new chapter today.", date: Date(timeIntervalSince1970: 742_694_400), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        await modelManager.downloadSelectedModel()

        let prose = try await generationService.writeBiographyProse(from: story, userProfile: profile)

        #expect(prose == "Generated biography prose.")
        #expect(runtime.loadedTiers == [.lightweight17B])
        #expect(runtime.requests.count == 1)
        #expect(runtime.requests.first?.task == .biographyProse)
        #expect(runtime.requests.first?.prompt.contains("Return only polished prose.") == true)
        #expect(runtime.requests.first?.prompt.contains("I started a new chapter today.") == true)
    }

    @MainActor
    @Test func generationServiceWritesDeterministicFallbackBiographyProseWhenModelIsReady() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults, runtime: TestDeterministicLocalModelRuntime())
        let generationService = LocalGenerationService(modelManager: modelManager)
        let story = Story(text: "I started a new chapter today.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        await modelManager.downloadSelectedModel()

        let prose = try await generationService.writeBiographyProse(from: story, userProfile: profile)

        #expect(prose.contains("Aark"))
        #expect(prose.contains("Hyderabad"))
        #expect(prose.contains("I started a new chapter today."))
    }

    @MainActor
    @Test func generationPromptFactoryBuildsLocalBiographyAndGraphPrompts() {
        let storyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let story = Story(
            id: storyID,
            text: "This was probably around 2012, when I moved to Seattle.",
            date: Date(timeIntervalSince1970: 742_694_400),
            duration: 12
        )
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        let biographyPrompt = GenerationPromptFactory.makeBiographyProsePrompt(
            story: story,
            userProfile: profile
        )
        let graphPrompt = GenerationPromptFactory.makeMemoryGraphExtractionPrompt(
            story: story,
            userProfile: profile
        )

        #expect(biographyPrompt.contains("private local biographer"))
        #expect(biographyPrompt.contains("Do not invent facts"))
        #expect(biographyPrompt.contains("Aark"))
        #expect(biographyPrompt.contains("Hyderabad"))
        #expect(biographyPrompt.contains(storyID.uuidString))
        #expect(biographyPrompt.contains("This was probably around 2012"))
        #expect(graphPrompt.contains("Return strict JSON"))
        #expect(graphPrompt.contains("eventDateKind: exact, approximate, range, or unknown"))
        #expect(graphPrompt.contains(storyID.uuidString))
    }

    @MainActor
    @Test func generationServiceExtractsDeterministicFallbackMemoryGraph() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults, runtime: TestDeterministicLocalModelRuntime())
        let generationService = LocalGenerationService(modelManager: modelManager)
        let storyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let story = Story(id: storyID, text: "I remembered summers in Hyderabad with my cousins.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        await modelManager.downloadSelectedModel()

        let graphJSON = try await generationService.extractMemoryGraph(from: story, userProfile: profile)
        let data = try #require(graphJSON.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["lifeEvents"] != nil)
        #expect(object["memoryFacts"] != nil)
        #expect(graphJSON.contains(storyID.uuidString))
        #expect(graphJSON.contains("Hyderabad"))
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

    @Test func recognitionNoSpeechAfterTranscriptIsBenign() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1110,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
        )

        #expect(
            SpeechRecognitionViewModel.shouldIgnoreRecognitionError(
                error,
                isStoppedByUser: false,
                hasTranscript: true
            )
        )
    }

    @Test func recognitionNoSpeechWithoutTranscriptWhileRecordingIsNotIgnored() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1110,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
        )

        #expect(
            !SpeechRecognitionViewModel.shouldIgnoreRecognitionError(
                error,
                isStoppedByUser: false,
                hasTranscript: false
            )
        )
    }

    @Test func recognitionNoSpeechAfterUserStopIsBenign() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1110,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
        )

        #expect(
            SpeechRecognitionViewModel.shouldIgnoreRecognitionError(
                error,
                isStoppedByUser: true,
                hasTranscript: false
            )
        )
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
    @Test func cleanupMarksExpiredAudioAssetsDeletedAndRemovesFiles() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-audio-cleanup-\(UUID().uuidString).caf")
        try Data([0, 1, 2]).write(to: expiredFileURL)

        let expiredFileAsset = AudioAsset(
            fileURL: expiredFileURL.absoluteString,
            createdAt: now.addingTimeInterval(-9 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(-1),
            duration: 9
        )
        let expiredPlaceholderAsset = SpeechRecognitionViewModel.makePlaceholderAudioAsset(
            storyID: UUID(),
            createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            duration: 12
        )
        expiredPlaceholderAsset.expiresAt = now.addingTimeInterval(-1)
        let activeAsset = SpeechRecognitionViewModel.makePlaceholderAudioAsset(
            storyID: UUID(),
            createdAt: now,
            duration: 4
        )

        context.insert(expiredFileAsset)
        context.insert(expiredPlaceholderAsset)
        context.insert(activeAsset)
        try context.save()

        let cleanedCount = try SpeechRecognitionViewModel.cleanupExpiredAudioAssets(
            in: context,
            now: now,
            fileManager: fileManager
        )

        #expect(cleanedCount == 2)
        #expect(fileManager.fileExists(atPath: expiredFileURL.path) == false)
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

    @Test func marketedIPhone16FamilyDefaultsToRemoteTranscription() throws {
        let defaults = try makeIsolatedDefaults()
        let policy = SpeechTranscriptionPolicy.production(userDefaults: defaults)
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: "iPhone17,3",
            osMajorVersion: 26,
            supportsOnDeviceRecognition: true
        )

        #expect(policy.route(for: capabilities) == .remote(reason: .hardwareNotValidated))
    }

    @Test func marketedIPhone17FamilyUsesOnDeviceTranscriptionWhenCapabilityExists() throws {
        let defaults = try makeIsolatedDefaults()
        let policy = SpeechTranscriptionPolicy.production(userDefaults: defaults)
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: "iPhone18,1",
            osMajorVersion: 26,
            supportsOnDeviceRecognition: true
        )

        #expect(policy.route(for: capabilities) == .onDevice)
    }

    @Test func olderIPhoneDefaultsToRemoteTranscription() throws {
        let defaults = try makeIsolatedDefaults()
        let policy = SpeechTranscriptionPolicy.production(userDefaults: defaults)
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: "iPhone16,2",
            osMajorVersion: 26,
            supportsOnDeviceRecognition: true
        )

        #expect(policy.route(for: capabilities) == .remote(reason: .hardwareNotValidated))
    }

    @Test func eligibleHardwareStillRoutesRemoteWithoutOnDeviceCapability() throws {
        let defaults = try makeIsolatedDefaults()
        let policy = SpeechTranscriptionPolicy.production(userDefaults: defaults)
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: "iPhone18,1",
            osMajorVersion: 26,
            supportsOnDeviceRecognition: false
        )

        #expect(policy.route(for: capabilities) == .remote(reason: .onDeviceRecognitionUnsupported))
    }

    @Test func validationAllowlistCannotBypassIPhone17HardwareFloor() {
        let policy = SpeechTranscriptionPolicy(
            validatedLocalHardwareIdentifiers: ["iPhone16,2"]
        )
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: "iPhone16,2",
            osMajorVersion: 26,
            supportsOnDeviceRecognition: true
        )

        #expect(policy.route(for: capabilities) == .remote(reason: .hardwareNotValidated))
    }

    @Test func marketedIPhone17FamilyUsesLocalBiographyGeneration() {
        let policy = BiographyGenerationPolicy()
        let capabilities = BiographyGenerationCapabilities(
            hardwareIdentifier: "iPhone18,1",
            supportsLocalRuntime: true
        )

        #expect(policy.route(for: capabilities) == .local)
    }

    @Test func marketedIPhone16FamilyUsesRemoteBiographyGeneration() {
        let policy = BiographyGenerationPolicy()
        let capabilities = BiographyGenerationCapabilities(
            hardwareIdentifier: "iPhone17,3",
            supportsLocalRuntime: true
        )

        #expect(policy.route(for: capabilities) == .remote)
    }

    @Test func unknownHardwareUsesRemoteBiographyGeneration() {
        let policy = BiographyGenerationPolicy()
        let capabilities = BiographyGenerationCapabilities(
            hardwareIdentifier: "simulator",
            supportsLocalRuntime: true
        )

        #expect(policy.route(for: capabilities) == .remote)
    }

    @Test func eligibleHardwareUsesRemoteBiographyGenerationWithoutMLXRuntime() {
        let policy = BiographyGenerationPolicy()
        let capabilities = BiographyGenerationCapabilities(
            hardwareIdentifier: "iPhone18,1",
            supportsLocalRuntime: false
        )

        #expect(policy.route(for: capabilities) == .remote)
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

@MainActor
private final class CapturingLocalModelRuntime: LocalModelRuntime {
    let displayName = "Capturing runtime"
    let isMLXBacked = true
    let output: String
    private(set) var loadedTiers: [LocalModelTier] = []
    private(set) var requests: [LocalGenerationRequest] = []
    private(set) var unloadCount = 0

    init(output: String) {
        self.output = output
    }

    func download(tier: LocalModelTier) async throws {}

    func load(tier: LocalModelTier) async throws {
        loadedTiers.append(tier)
    }

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        requests.append(request)
        return output
    }

    func unload() {
        unloadCount += 1
    }

    func delete(tier: LocalModelTier) throws {}
}

@MainActor
private struct TestDeterministicLocalModelRuntime: LocalModelRuntime {
    let displayName = "Test deterministic runtime"
    let isMLXBacked = false

    func download(tier: LocalModelTier) async throws {}
    func load(tier: LocalModelTier) async throws {}

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        switch request.task {
        case .biographyProse:
            return request.prompt
        case .memoryGraphExtraction:
            let escapedPrompt = request.prompt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
            {
              "lifeEvents": [],
              "people": [],
              "places": [],
              "themes": [],
              "memoryFacts": [],
              "sourcePrompt": "\(escapedPrompt)"
            }
            """
        }
    }

    func unload() {}
    func delete(tier: LocalModelTier) throws {}
}
