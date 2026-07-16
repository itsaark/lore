import Foundation
import SwiftData

struct LegacyStoryPayload: Codable, Equatable {
    let id: UUID
    var text: String
    let date: Date
    let duration: TimeInterval

    init(id: UUID = UUID(), text: String, date: Date, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case date
        case duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }
}
struct LegacyUserProfilePayload: Codable, Equatable {
    var name: String
    var hometown: String
    var birthYear: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        hometown: String,
        birthYear: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.hometown = hometown
        self.birthYear = birthYear
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum LegacyDataMigrator {
    private static let migrationCompleteKey = "LoreSwiftDataMigrationV1Complete"
    private static let transcriptBackfillCompleteKey = "LoreTranscriptArtifactBackfillV2Complete"
    private static let legacyProfileKey = "UserProfile"
    private static let legacyStoriesKey = "SavedStories"
    private static let legacyRecordingsKey = "SavedRecordings"

    static func migrateIfNeeded(
        modelContext: ModelContext,
        userDefaults: UserDefaults = .standard
    ) throws {
        if !userDefaults.bool(forKey: migrationCompleteKey) {
            try migrateProfile(modelContext: modelContext, userDefaults: userDefaults)
            try migrateStories(modelContext: modelContext, userDefaults: userDefaults)
            try modelContext.save()
            userDefaults.set(true, forKey: migrationCompleteKey)
        }

        if !userDefaults.bool(forKey: transcriptBackfillCompleteKey) {
            try backfillTranscriptArtifacts(modelContext: modelContext)
            try modelContext.save()
            userDefaults.set(true, forKey: transcriptBackfillCompleteKey)
        }
    }

    private static func migrateProfile(
        modelContext: ModelContext,
        userDefaults: UserDefaults
    ) throws {
        let existingProfiles = try modelContext.fetch(FetchDescriptor<UserProfile>())
        guard existingProfiles.isEmpty,
              let data = userDefaults.data(forKey: legacyProfileKey) else {
            return
        }

        let legacyProfile = try JSONDecoder().decode(LegacyUserProfilePayload.self, from: data)
        modelContext.insert(
            UserProfile(
                name: legacyProfile.name,
                hometown: legacyProfile.hometown,
                birthYear: legacyProfile.birthYear,
                createdAt: legacyProfile.createdAt,
                updatedAt: legacyProfile.updatedAt
            )
        )
    }

    private static func migrateStories(
        modelContext: ModelContext,
        userDefaults: UserDefaults
    ) throws {
        guard let data = userDefaults.data(forKey: legacyStoriesKey) ?? userDefaults.data(forKey: legacyRecordingsKey) else {
            return
        }

        let legacyStories = try JSONDecoder().decode([LegacyStoryPayload].self, from: data)
        let existingStories = try modelContext.fetch(FetchDescriptor<Story>())
        let existingStoryIds = Set(existingStories.map(\.id))

        for legacyStory in legacyStories where !existingStoryIds.contains(legacyStory.id) {
            modelContext.insert(
                Story(
                    id: legacyStory.id,
                    text: legacyStory.text,
                    date: legacyStory.date,
                    duration: legacyStory.duration,
                    rawTranscriptExpiresAt: nil,
                    createdAt: legacyStory.date,
                    updatedAt: legacyStory.date
                )
            )
        }
    }

    private static func backfillTranscriptArtifacts(modelContext: ModelContext) throws {
        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let audioAssets = try modelContext.fetch(FetchDescriptor<AudioAsset>())
        let storyIdsWithArtifacts = Set(artifacts.compactMap(\.storyId))
        let audioAssetByStoryId = Dictionary(uniqueKeysWithValues: audioAssets.map { ($0.id, $0.id) })

        for story in stories where !storyIdsWithArtifacts.contains(story.id) {
            let rawText = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { continue }

            let artifact = TranscriptArtifact(
                storyId: story.id,
                audioAssetId: audioAssetByStoryId[story.id],
                rawText: story.text,
                source: .legacyStory,
                capturedAt: story.date,
                transcribedAt: story.createdAt,
                audioDuration: story.duration,
                createdAt: story.createdAt
            )
            let sourceVersion = TranscriptVersion(
                transcriptArtifactId: artifact.id,
                storyId: story.id,
                revision: 1,
                text: story.text,
                kind: .sourceSnapshot,
                author: .source,
                createdAt: story.createdAt
            )
            story.rawTranscriptExpiresAt = nil
            modelContext.insert(artifact)
            modelContext.insert(sourceVersion)
        }
    }
}
