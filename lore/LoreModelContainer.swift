import Foundation
import SwiftData

enum LoreModelContainer {
    static let cloudKitContainerIdentifier = "iCloud.cascadianpines.lore"

    /// Canonical user-authored and derived records that should follow the
    /// person's private iCloud account across devices and reinstalls.
    static let archiveSchema = Schema([
        UserProfile.self,
        Story.self,
        StoryMetadata.self,
        BiographyFragment.self,
        LifeEvent.self,
        Person.self,
        Place.self,
        Theme.self,
        TranscriptArtifact.self,
        TranscriptVersion.self,
        DailyEntryResultArtifact.self,
        ReflectionSession.self,
        ReflectionTurn.self,
        DailyBiographyEntry.self,
        VocabularyEntry.self
    ])

    /// Device-bound orchestration records. Audio files themselves live only
    /// in this installation's sandbox, so their paths and retry jobs must not
    /// be delivered to another phone by CloudKit.
    static let localSchema = Schema([
        AudioAsset.self,
        ProcessingJob.self,
        DailyBiographyGenerationSnapshot.self
    ])

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
        ReflectionSession.self,
        ReflectionTurn.self,
        DailyBiographyEntry.self,
        DailyBiographyGenerationSnapshot.self,
        VocabularyEntry.self
    ])

    static func make(
        inMemory: Bool = false,
        syncsWithICloud: Bool = true,
        storeDirectory: URL? = nil,
        legacyStoreURL: URL? = nil
    ) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(
                "LoreInMemory-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let fileManager = FileManager.default
        let directory = try storeDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let archiveURL = directory.appendingPathComponent("LoreArchive.store")
        let localURL = directory.appendingPathComponent("LoreLocal.store")
        let resolvedLegacyURL = legacyStoreURL ?? legacyConfiguration().url

        try CloudArchiveMigrator.migrateIfNeeded(
            legacyStoreURL: resolvedLegacyURL,
            archiveStoreURL: archiveURL,
            localStoreURL: localURL
        )

        let configurations = splitConfigurations(
            archiveStoreURL: archiveURL,
            localStoreURL: localURL,
            syncsWithICloud: syncsWithICloud
        )

        return try ModelContainer(
            for: schema,
            configurations: configurations
        )
    }

    static func legacyConfiguration(url: URL? = nil) -> ModelConfiguration {
        if let url {
            return ModelConfiguration(
                nil,
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        return ModelConfiguration(
            nil,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
    }

    static func splitConfigurations(
        archiveStoreURL: URL,
        localStoreURL: URL,
        syncsWithICloud: Bool
    ) -> [ModelConfiguration] {
        let archiveConfiguration = ModelConfiguration(
            "LoreArchive",
            schema: archiveSchema,
            url: archiveStoreURL,
            allowsSave: true,
            cloudKitDatabase: syncsWithICloud
                ? .private(cloudKitContainerIdentifier)
                : .none
        )
        let localConfiguration = ModelConfiguration(
            "LoreLocal",
            schema: localSchema,
            url: localStoreURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return [archiveConfiguration, localConfiguration]
    }

    static var preview: ModelContainer {
        do {
            return try make(inMemory: true)
        } catch {
            fatalError("Failed to create preview model container: \(error)")
        }
    }
}
