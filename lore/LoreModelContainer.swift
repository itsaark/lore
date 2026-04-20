import SwiftData

enum LoreModelContainer {
    static let schema = Schema([
        UserProfile.self,
        Story.self,
        AudioAsset.self,
        StoryMetadata.self,
        BiographyFragment.self
    ])

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
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
