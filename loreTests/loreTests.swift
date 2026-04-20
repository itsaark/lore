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

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "loreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
