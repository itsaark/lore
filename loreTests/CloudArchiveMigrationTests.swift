import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct CloudArchiveMigrationTests {
    @MainActor
    @Test func reconciliationKeepsNewestLogicalRecordAfterCloudConflicts() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)
        let storyID = UUID()

        context.insert(UserProfile(
            name: "Older profile",
            hometown: "One",
            birthYear: 1990,
            createdAt: older,
            updatedAt: older
        ))
        context.insert(UserProfile(
            name: "Newest profile",
            hometown: "Two",
            birthYear: 1991,
            createdAt: newer,
            updatedAt: newer
        ))
        context.insert(Story(
            id: storyID,
            text: "Older text",
            date: older,
            duration: 1,
            updatedAt: older
        ))
        context.insert(Story(
            id: storyID,
            text: "Newest text",
            date: newer,
            duration: 1,
            updatedAt: newer
        ))
        context.insert(VocabularyEntry(
            phrase: "Hyderabad",
            createdAt: older,
            updatedAt: older
        ))
        context.insert(VocabularyEntry(
            phrase: "hyderabad",
            replacement: "Hyderabad",
            createdAt: newer,
            updatedAt: newer
        ))
        try context.save()

        let deleted = try CloudArchiveReconciler.reconcile(in: context)
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let stories = try context.fetch(FetchDescriptor<Story>())
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyEntry>())

        #expect(deleted == 3)
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Newest profile")
        #expect(stories.count == 1)
        #expect(stories.first?.text == "Newest text")
        #expect(vocabulary.count == 1)
        #expect(vocabulary.first?.replacement == "Hyderabad")
    }

    @Test func legacyArchiveMovesIntoSplitStoresWithoutLosingTextOrLocalJobs() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("CloudArchiveMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("Legacy.store")
        let archiveURL = directory.appendingPathComponent("LoreArchive.store")
        let localURL = directory.appendingPathComponent("LoreLocal.store")
        let defaultsName = "CloudArchiveMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)

        let profileID = UUID()
        let storyID = UUID()
        let artifactID = UUID()
        let versionID = UUID()
        let jobID = UUID()

        do {
            let legacy = try ModelContainer(
                for: LoreModelContainer.schema,
                configurations: [LoreModelContainer.legacyConfiguration(url: legacyURL)]
            )
            let context = ModelContext(legacy)
            context.insert(UserProfile(
                id: profileID,
                name: "Aark",
                hometown: "Hyderabad",
                birthYear: 1994
            ))
            context.insert(Story(
                id: storyID,
                text: "The durable source transcript.",
                date: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 42,
                title: "A day worth keeping"
            ))
            context.insert(TranscriptArtifact(
                id: artifactID,
                storyId: storyID,
                audioAssetId: storyID,
                rawText: "The durable source transcript.",
                source: .remoteProvider,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                audioDuration: 42
            ))
            context.insert(TranscriptVersion(
                id: versionID,
                transcriptArtifactId: artifactID,
                storyId: storyID,
                revision: 1,
                text: "The durable source transcript.",
                kind: .sourceSnapshot,
                author: .source
            ))
            context.insert(AudioAsset(
                id: storyID,
                fileURL: directory.appendingPathComponent("capture.caf").absoluteString,
                expiresAt: Date.distantFuture,
                duration: 42
            ))
            context.insert(ProcessingJob(
                id: jobID,
                idempotencyKey: "transcription:\(storyID.uuidString)",
                storyId: storyID,
                kind: .transcription
            ))
            try context.save()
        }

        try CloudArchiveMigrator.migrateIfNeeded(
            legacyStoreURL: legacyURL,
            archiveStoreURL: archiveURL,
            localStoreURL: localURL,
            fileManager: fileManager,
            userDefaults: defaults
        )
        try CloudArchiveMigrator.migrateIfNeeded(
            legacyStoreURL: legacyURL,
            archiveStoreURL: archiveURL,
            localStoreURL: localURL,
            fileManager: fileManager,
            userDefaults: defaults
        )

        let migrated = try ModelContainer(
            for: LoreModelContainer.schema,
            configurations: LoreModelContainer.splitConfigurations(
                archiveStoreURL: archiveURL,
                localStoreURL: localURL,
                syncsWithICloud: false
            )
        )
        let context = ModelContext(migrated)
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let stories = try context.fetch(FetchDescriptor<Story>())
        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try context.fetch(FetchDescriptor<TranscriptVersion>())
        let audioAssets = try context.fetch(FetchDescriptor<AudioAsset>())
        let jobs = try context.fetch(FetchDescriptor<ProcessingJob>())

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == profileID)
        #expect(profiles.first?.name == "Aark")
        #expect(stories.count == 1)
        #expect(stories.first?.id == storyID)
        #expect(stories.first?.text == "The durable source transcript.")
        #expect(artifacts.first?.id == artifactID)
        #expect(artifacts.first?.rawText == "The durable source transcript.")
        #expect(versions.first?.id == versionID)
        #expect(versions.first?.text == "The durable source transcript.")
        #expect(audioAssets.count == 1)
        #expect(audioAssets.first?.id == storyID)
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == jobID)

        #expect(fileManager.fileExists(atPath: legacyURL.path))
        #expect(fileManager.fileExists(atPath: archiveURL.path))
        #expect(fileManager.fileExists(atPath: localURL.path))
    }
}
