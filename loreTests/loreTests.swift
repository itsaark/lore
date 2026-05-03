//
//  loreTests.swift
//  loreTests
//
//  Created by Aark Koduru on 7/18/25.
//

import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct loreTests {

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
        #expect(content.detailStatusText == "Writing biography prose and updating memory on device.")
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
        #expect(content.detailStatusText == "Lore could not finish local processing for this story.")
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
        #expect(migratedStories.first?.rawTranscriptExpiresAt != nil)
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

        #expect(migratedStories.count == 1)
        #expect(migratedStories.first?.id == storyID)
    }

    @MainActor
    @Test func modelManagerDownloadsAndLoadsSelectedModel() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults)

        #expect(modelManager.status.tier == .standard4B)
        #expect(modelManager.status.state == .notDownloaded)

        modelManager.select(.lightweight17B)
        await modelManager.downloadSelectedModel()
        await modelManager.loadSelectedModel()

        #expect(modelManager.status.tier == .lightweight17B)
        #expect(modelManager.status.state == .loaded)
        #expect(modelManager.status.isReady)
        #expect(modelManager.status.message == "Local generation fallback is ready.")
    }

    @MainActor
    @Test func generationServiceRequiresLoadedModel() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults)
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
        await modelManager.loadSelectedModel()

        let prose = try await generationService.writeBiographyProse(from: story, userProfile: profile)

        #expect(prose == "Generated biography prose.")
        #expect(runtime.loadedTiers == [.standard4B])
        #expect(runtime.requests.count == 1)
        #expect(runtime.requests.first?.task == .biographyProse)
        #expect(runtime.requests.first?.prompt.contains("Return only polished prose.") == true)
        #expect(runtime.requests.first?.prompt.contains("I started a new chapter today.") == true)
    }

    @MainActor
    @Test func generationServiceWritesDeterministicFallbackBiographyProseWhenModelIsReady() async throws {
        let defaults = try makeIsolatedDefaults()
        let modelManager = ModelManager(userDefaults: defaults)
        let generationService = LocalGenerationService(modelManager: modelManager)
        let story = Story(text: "I started a new chapter today.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        await modelManager.downloadSelectedModel()
        await modelManager.loadSelectedModel()

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
        let modelManager = ModelManager(userDefaults: defaults)
        let generationService = LocalGenerationService(modelManager: modelManager)
        let storyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let story = Story(id: storyID, text: "I remembered summers in Hyderabad with my cousins.", date: Date(), duration: 8)
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)

        await modelManager.downloadSelectedModel()
        await modelManager.loadSelectedModel()

        let graphJSON = try await generationService.extractMemoryGraph(from: story, userProfile: profile)
        let data = try #require(graphJSON.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["lifeEvents"] != nil)
        #expect(object["memoryFacts"] != nil)
        #expect(graphJSON.contains(storyID.uuidString))
        #expect(graphJSON.contains("Hyderabad"))
    }

    @MainActor
    @Test func capturedStoryPersistsPlaceholderAudioAssetMetadata() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(42)

        let story = try SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A remembered afternoon by the lake.",
            startTime: startTime,
            endTime: endTime,
            modelContext: context
        )

        let stories = try context.fetch(FetchDescriptor<Story>())
        let audioAssets = try context.fetch(FetchDescriptor<AudioAsset>())
        let asset = try #require(audioAssets.first)

        #expect(stories.count == 1)
        #expect(stories.first?.id == story.id)
        #expect(audioAssets.count == 1)
        #expect(asset.id == story.id)
        #expect(asset.createdAt == endTime)
        #expect(asset.expiresAt == endTime.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(asset.duration == 42)
        #expect(asset.isDeleted == false)
        #expect(SpeechRecognitionViewModel.isPlaceholderAudioURL(asset.fileURL))
    }

    @MainActor
    @Test func capturedStoryPersistsRealAudioAssetFileURLWhenAvailable() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(23)
        let audioFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-real-audio-\(UUID().uuidString).caf")
        try Data([0, 1, 2, 3]).write(to: audioFileURL)

        let story = try SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A story with retained local audio.",
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            modelContext: context
        )

        let asset = try #require(try context.fetch(FetchDescriptor<AudioAsset>()).first)

        #expect(asset.id == story.id)
        #expect(asset.fileURL == audioFileURL.absoluteString)
        #expect(asset.createdAt == endTime)
        #expect(asset.expiresAt == endTime.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(asset.duration == 23)
        #expect(asset.isDeleted == false)
        #expect(!SpeechRecognitionViewModel.isPlaceholderAudioURL(asset.fileURL))

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
    @Test func deletingStoryAudioAssetsRemovesLinkedFilesAndMetadata() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let fileManager = FileManager.default
        let startTime = Date(timeIntervalSince1970: 1_800_000_000)
        let endTime = startTime.addingTimeInterval(31)
        let audioFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("lore-delete-audio-\(UUID().uuidString).caf")
        try Data([4, 5, 6, 7]).write(to: audioFileURL)
        let story = try SpeechRecognitionViewModel.persistCapturedStory(
            transcript: "A story whose audio should be deleted.",
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            modelContext: context
        )

        let deletedAssetCount = try SpeechRecognitionViewModel.deleteAudioAssets(
            for: story,
            in: context,
            fileManager: fileManager
        )
        context.delete(story)
        try context.save()

        #expect(deletedAssetCount == 1)
        #expect(fileManager.fileExists(atPath: audioFileURL.path) == false)
        #expect(try context.fetch(FetchDescriptor<AudioAsset>()).isEmpty)
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

    init(output: String) {
        self.output = output
    }

    func load(tier: LocalModelTier) async throws {
        loadedTiers.append(tier)
    }

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        requests.append(request)
        return output
    }
}
