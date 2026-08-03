import Foundation
import SwiftData

enum LoreModelContainer {
    static let schema = Schema([
        UserProfile.self,
        Story.self,
        AudioAsset.self,
        StoryMetadata.self,
        BiographyFragment.self,
        LifeEvent.self,
        Person.self,
        Place.self,
        Theme.self,
        TranscriptArtifact.self,
        TranscriptVersion.self,
        ProcessingJob.self,
        DailyEntryResultArtifact.self,
        VocabularyEntry.self
    ])

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configurationName = inMemory ? "LoreInMemory-\(UUID().uuidString)" : nil
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    static var preview: ModelContainer {
        do {
            return try make(inMemory: true)
        } catch {
            fatalError("Failed to create preview model container: \(error)")
        }
    }
}
