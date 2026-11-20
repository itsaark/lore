import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct CloudArchiveMigrationTests {
    private let memory = RememberedTime(precision: .year, startDate: "2003-01-01", endDate: "2003-12-31")

    @MainActor
    @Test func legacyJSONKeepsRememberedTimeAndDefaultsOlderNotesToTheirRecordingDay() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let suiteName = "LegacyMemoryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        let old = LegacyStoryPayload(text: "Ordinary", date: captured, duration: 1)
        let pinned = LegacyStoryPayload(text: "Remembered", date: captured, duration: 2, rememberedTime: memory)
        defaults.set(try JSONEncoder().encode([old, pinned]), forKey: "SavedStories")
        try LegacyDataMigrator.migrateIfNeeded(modelContext: context, userDefaults: defaults)

        let stories = try context.fetch(FetchDescriptor<Story>())
        #expect(stories.first { $0.id == old.id }?.rememberedTime == nil)
        #expect(stories.first { $0.id == pinned.id }?.rememberedTime == memory)
        #expect(stories.allSatisfy { $0.date == captured })
    }

    @MainActor
    @Test func reconciliationKeepsDistinctMemoriesAndDaysWithTheSameStartDate() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let firstMemory = UUID()
        let secondMemory = UUID()
        let firstPainting = DayIllustration(dayKey: memory.startDate, memoryStoryId: firstMemory, at: .now)
        let newerPainting = DayIllustration(
            dayKey: memory.startDate, memoryStoryId: firstMemory, at: .now.addingTimeInterval(1)
        )
        context.insert(firstPainting)
        context.insert(newerPainting)
        context.insert(DayIllustration(dayKey: memory.startDate, memoryStoryId: secondMemory, at: .now))
        context.insert(DayIllustration(dayKey: memory.startDate, at: .now))
        let values = [nil, firstMemory, secondMemory, firstMemory].map { id in
            archiveEntry(memoryStoryId: id)
        }
        values.forEach(context.insert)
        try context.save()

        #expect(try CloudArchiveReconciler.reconcile(in: context) == 2)
        let entries = try context.fetch(FetchDescriptor<DailyBiographyEntry>())
        let paintings = try context.fetch(FetchDescriptor<DayIllustration>())
        #expect(Set(entries.map(\.memoryStoryId)) == [nil, firstMemory, secondMemory])
        #expect(Set(paintings.map(\.memoryStoryId)) == [nil, firstMemory, secondMemory])
        #expect(paintings.first { $0.memoryStoryId == firstMemory }?.id == newerPainting.id)
    }

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
            updatedAt: older,
            rememberedTime: memory
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
        #expect(stories.first?.rememberedTime == memory)
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
                birthYear: 1994,
                narratorPronouns: .he
            ))
            context.insert(Story(
                id: storyID,
                text: "The durable source transcript.",
                date: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 42,
                title: "A day worth keeping",
                sourceKind: .reflection,
                rememberedTime: memory
            ))
            context.insert(archiveEntry(memoryStoryId: storyID))
            context.insert(DayIllustration(dayKey: memory.startDate, memoryStoryId: storyID, at: .now))
            context.insert(ReflectionSession(
                id: storyID,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                capturedLocalDate: "2027-01-15"
            ))
            context.insert(ReflectionTurn(
                sessionId: storyID,
                sequence: 0,
                role: .lore,
                text: "What felt worth remembering?",
                isEvidenceEligible: false,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                endedAt: Date(timeIntervalSince1970: 1_800_000_002)
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
        let reflectionSessions = try context.fetch(FetchDescriptor<ReflectionSession>())
        let reflectionTurns = try context.fetch(FetchDescriptor<ReflectionTurn>())

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == profileID)
        #expect(profiles.first?.name == "Aark")
        #expect(profiles.first?.narratorPronouns == .he)
        #expect(stories.count == 1)
        #expect(stories.first?.id == storyID)
        #expect(stories.first?.text == "The durable source transcript.")
        #expect(stories.first?.sourceKind == .reflection)
        #expect(stories.first?.rememberedTime == memory)
        let entries = try context.fetch(FetchDescriptor<DailyBiographyEntry>())
        #expect(entries.first?.memoryStoryId == storyID)
        let paintings = try context.fetch(FetchDescriptor<DayIllustration>())
        #expect(paintings.first?.memoryStoryId == storyID)
        #expect(paintings.first?.dayKey == memory.startDate)
        #expect(artifacts.first?.id == artifactID)
        #expect(artifacts.first?.rawText == "The durable source transcript.")
        #expect(versions.first?.id == versionID)
        #expect(versions.first?.text == "The durable source transcript.")
        #expect(audioAssets.count == 1)
        #expect(audioAssets.first?.id == storyID)
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == jobID)
        #expect(reflectionSessions.first?.id == storyID)
        #expect(reflectionTurns.first?.sessionId == storyID)
        #expect(reflectionTurns.first?.isEvidenceEligible == false)

        #expect(fileManager.fileExists(atPath: legacyURL.path))
        #expect(fileManager.fileExists(atPath: archiveURL.path))
        #expect(fileManager.fileExists(atPath: localURL.path))
    }

    private func archiveEntry(memoryStoryId: UUID?) -> DailyBiographyEntry {
        let date = Date(timeIntervalSince1970: 1_041_422_400)
        return DailyBiographyEntry(
            dayKey: memory.startDate, memoryStoryId: memoryStoryId, calendarDate: date,
            sourceStoryIds: [memoryStoryId ?? UUID()], sourceTranscriptArtifactIds: [],
            sourceTranscriptVersionIds: [], sourceFingerprint: "test", timezoneIdentifiers: ["UTC"],
            title: "An archive entry", prose: "An archived memory.", combinedTranscript: "Source note.",
            provider: RemoteProcessingProvenance(
                providerId: "test", modelAlias: "test", modelId: "test", modelPolicyVersion: "test",
                providerRequestId: nil, processedAt: date, processingDurationMilliseconds: 0,
                retentionAttestation: .init(
                    mode: .zeroDataRetention, maximumRetentionSeconds: 0, policyVersion: "test", attestedAt: date
                )
            )
        )
    }
}
