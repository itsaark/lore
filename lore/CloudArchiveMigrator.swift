import Foundation
import SwiftData

/// Copies the original single SwiftData store into the CloudKit archive and
/// device-local stores. The legacy store is intentionally retained as a
/// recovery copy. Inserts are keyed by stable IDs so an interrupted migration
/// can safely resume without duplicating records.
enum CloudArchiveMigrator {
    private static let completionKey = "LoreCloudArchiveSplitMigrationV1Complete"

    static func migrateIfNeeded(
        legacyStoreURL: URL,
        archiveStoreURL: URL,
        localStoreURL: URL,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) throws {
        guard !userDefaults.bool(forKey: completionKey) else { return }
        guard fileManager.fileExists(atPath: legacyStoreURL.path) else {
            userDefaults.set(true, forKey: completionKey)
            return
        }

        let legacyContainer = try ModelContainer(
            for: LoreModelContainer.schema,
            configurations: [LoreModelContainer.legacyConfiguration(url: legacyStoreURL)]
        )
        let legacyContext = ModelContext(legacyContainer)

        guard try containsArchiveData(in: legacyContext) else {
            userDefaults.set(true, forKey: completionKey)
            return
        }

        let targetContainer = try ModelContainer(
            for: LoreModelContainer.schema,
            configurations: LoreModelContainer.splitConfigurations(
                archiveStoreURL: archiveStoreURL,
                localStoreURL: localStoreURL,
                syncsWithICloud: false
            )
        )
        let targetContext = ModelContext(targetContainer)

        try copyArchive(from: legacyContext, to: targetContext)
        try copyLocalState(from: legacyContext, to: targetContext)
        try targetContext.save()
        try verifyStableIdentifiers(from: legacyContext, in: targetContext)
        userDefaults.set(true, forKey: completionKey)
    }

    private static func containsArchiveData(in context: ModelContext) throws -> Bool {
        try !context.fetch(FetchDescriptor<UserProfile>()).isEmpty
            || !context.fetch(FetchDescriptor<Story>()).isEmpty
            || !context.fetch(FetchDescriptor<StoryMetadata>()).isEmpty
            || !context.fetch(FetchDescriptor<TranscriptArtifact>()).isEmpty
            || !context.fetch(FetchDescriptor<TranscriptVersion>()).isEmpty
            || !context.fetch(FetchDescriptor<BiographyFragment>()).isEmpty
            || !context.fetch(FetchDescriptor<LifeEvent>()).isEmpty
            || !context.fetch(FetchDescriptor<Person>()).isEmpty
            || !context.fetch(FetchDescriptor<Place>()).isEmpty
            || !context.fetch(FetchDescriptor<Theme>()).isEmpty
            || !context.fetch(FetchDescriptor<DailyEntryResultArtifact>()).isEmpty
            || !context.fetch(FetchDescriptor<ReflectionSession>()).isEmpty
            || !context.fetch(FetchDescriptor<ReflectionTurn>()).isEmpty
            || !context.fetch(FetchDescriptor<DailyBiographyEntry>()).isEmpty
            || !context.fetch(FetchDescriptor<VocabularyEntry>()).isEmpty
    }

    private static func copyArchive(from source: ModelContext, to target: ModelContext) throws {
        let profileIDs = Set(try target.fetch(FetchDescriptor<UserProfile>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<UserProfile>()) where !profileIDs.contains(value.id) {
            let copy = UserProfile(
                id: value.id,
                name: value.name,
                hometown: value.hometown,
                birthYear: value.birthYear,
                remoteProcessingConsentedAt: value.remoteProcessingConsentedAt,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            )
            copy.processingModeValue = value.processingModeValue
            copy.remoteTextProcessingConsentedAt = value.remoteTextProcessingConsentedAt
            copy.remoteAudioUploadConsentedAt = value.remoteAudioUploadConsentedAt
            copy.allowsCellularRemoteProcessing = value.allowsCellularRemoteProcessing
            target.insert(copy)
        }

        let storyIDs = Set(try target.fetch(FetchDescriptor<Story>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<Story>()) where !storyIDs.contains(value.id) {
            target.insert(Story(
                id: value.id,
                text: value.text,
                date: value.date,
                duration: value.duration,
                rawTranscriptExpiresAt: value.rawTranscriptExpiresAt,
                metadataId: value.metadataId,
                biographyProse: value.biographyProse,
                title: value.title,
                processingStatus: value.processingStatus,
                sourceKind: value.sourceKind,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let metadataIDs = Set(try target.fetch(FetchDescriptor<StoryMetadata>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<StoryMetadata>()) where !metadataIDs.contains(value.id) {
            target.insert(StoryMetadata(
                id: value.id,
                captureDate: value.captureDate,
                timezone: value.timezone,
                locationName: value.locationName,
                latitude: value.latitude,
                longitude: value.longitude,
                weatherSummary: value.weatherSummary,
                temperature: value.temperature,
                weatherSource: value.weatherSource,
                permissionSnapshot: value.permissionSnapshot
            ))
        }

        let artifactIDs = Set(try target.fetch(FetchDescriptor<TranscriptArtifact>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<TranscriptArtifact>()) where !artifactIDs.contains(value.id) {
            target.insert(TranscriptArtifact(
                id: value.id,
                storyId: value.storyId,
                audioAssetId: value.audioAssetId,
                rawText: value.rawText,
                source: value.source,
                languageCode: value.languageCode,
                providerId: value.providerId,
                providerModelId: value.providerModelId,
                providerRequestId: value.providerRequestId,
                sourceSegmentsJSON: value.sourceSegmentsJSON,
                providerProvenanceJSON: value.providerProvenanceJSON,
                capturedAt: value.capturedAt,
                transcribedAt: value.transcribedAt,
                audioDuration: value.audioDuration,
                createdAt: value.createdAt
            ))
        }

        let versionIDs = Set(try target.fetch(FetchDescriptor<TranscriptVersion>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<TranscriptVersion>()) where !versionIDs.contains(value.id) {
            target.insert(TranscriptVersion(
                id: value.id,
                transcriptArtifactId: value.transcriptArtifactId,
                storyId: value.storyId,
                supersedesVersionId: value.supersedesVersionId,
                revision: value.revision,
                text: value.text,
                kind: value.kind,
                author: value.author,
                editSummary: value.editSummary,
                createdAt: value.createdAt
            ))
        }

        let fragmentIDs = Set(try target.fetch(FetchDescriptor<BiographyFragment>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<BiographyFragment>()) where !fragmentIDs.contains(value.id) {
            target.insert(BiographyFragment(
                id: value.id,
                storyId: value.storyId,
                lifeEventIds: value.lifeEventIds,
                chapterId: value.chapterId,
                prose: value.prose,
                style: value.style,
                modelName: value.modelName,
                modelVersion: value.modelVersion,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let lifeEventIDs = Set(try target.fetch(FetchDescriptor<LifeEvent>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<LifeEvent>()) where !lifeEventIDs.contains(value.id) {
            target.insert(LifeEvent(
                id: value.id,
                title: value.title,
                summary: value.summary,
                eventDateKind: value.dateKind,
                eventStartDate: value.eventStartDate,
                eventEndDate: value.eventEndDate,
                approximateLabel: value.approximateLabel,
                confidence: value.confidence,
                sourceStoryIds: value.sourceStoryIds,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let personIDs = Set(try target.fetch(FetchDescriptor<Person>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<Person>()) where !personIDs.contains(value.id) {
            target.insert(Person(
                id: value.id,
                displayName: value.displayName,
                aliases: value.aliases,
                relationshipToUser: value.relationshipToUser,
                summary: value.summary,
                confidence: value.confidence,
                sourceStoryIds: value.sourceStoryIds,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let placeIDs = Set(try target.fetch(FetchDescriptor<Place>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<Place>()) where !placeIDs.contains(value.id) {
            target.insert(Place(
                id: value.id,
                displayName: value.displayName,
                placeKind: value.placeKind,
                locationHint: value.locationHint,
                summary: value.summary,
                confidence: value.confidence,
                sourceStoryIds: value.sourceStoryIds,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let themeIDs = Set(try target.fetch(FetchDescriptor<Theme>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<Theme>()) where !themeIDs.contains(value.id) {
            target.insert(Theme(
                id: value.id,
                name: value.name,
                summary: value.summary,
                confidence: value.confidence,
                sourceStoryIds: value.sourceStoryIds,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let vocabularyIDs = Set(try target.fetch(FetchDescriptor<VocabularyEntry>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<VocabularyEntry>()) where !vocabularyIDs.contains(value.id) {
            target.insert(VocabularyEntry(
                id: value.id,
                phrase: value.phrase,
                replacement: value.replacement,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let resultIDs = Set(try target.fetch(FetchDescriptor<DailyEntryResultArtifact>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<DailyEntryResultArtifact>()) where !resultIDs.contains(value.id) {
            target.insert(DailyEntryResultArtifact(
                id: value.id,
                jobId: value.jobId,
                storyId: value.storyId,
                transcriptArtifactId: value.transcriptArtifactId,
                transcriptVersionId: value.transcriptVersionId,
                biographyFragmentId: value.biographyFragmentId,
                revision: value.revision,
                supersedesArtifactId: value.supersedesArtifactId,
                response: try decodedDailyEntryResponse(value.responseJSON),
                responseJSON: value.responseJSON,
                entryJSON: value.entryJSON,
                memoryCandidatesJSON: value.memoryCandidatesJSON,
                uncertaintiesJSON: value.uncertaintiesJSON,
                sensitiveOmissionsJSON: value.sensitiveOmissionsJSON,
                qualityFlagsJSON: value.qualityFlagsJSON,
                followUpQuestionsJSON: value.followUpQuestionsJSON,
                provenanceJSON: value.provenanceJSON,
                createdAt: value.createdAt
            ))
        }

        let reflectionSessionIDs = Set(try target.fetch(FetchDescriptor<ReflectionSession>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<ReflectionSession>()) where !reflectionSessionIDs.contains(value.id) {
            target.insert(ReflectionSession(
                id: value.id,
                startedAt: value.startedAt,
                endedAt: value.endedAt,
                capturedLocalDate: value.capturedLocalDate,
                state: value.state,
                storyId: value.storyId,
                transcriptArtifactId: value.transcriptArtifactId,
                resultArtifactId: value.resultArtifactId,
                sttModelAlias: value.sttModelAlias,
                ttsModelAlias: value.ttsModelAlias,
                guideModelAlias: value.guideModelAlias,
                entryModelAlias: value.entryModelAlias,
                policyVersion: value.policyVersion,
                schemaVersion: value.schemaVersion,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }

        let reflectionTurnIDs = Set(try target.fetch(FetchDescriptor<ReflectionTurn>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<ReflectionTurn>()) where !reflectionTurnIDs.contains(value.id) {
            target.insert(ReflectionTurn(
                id: value.id,
                sessionId: value.sessionId,
                sequence: value.sequence,
                role: value.role,
                text: value.text,
                isEvidenceEligible: value.isEvidenceEligible,
                startedAt: value.startedAt,
                endedAt: value.endedAt,
                languageCode: value.languageCode,
                confidence: value.confidence,
                sourceSegmentsJSON: value.sourceSegmentsJSON,
                createdAt: value.createdAt
            ))
        }

        let biographyIDs = Set(try target.fetch(FetchDescriptor<DailyBiographyEntry>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<DailyBiographyEntry>()) where !biographyIDs.contains(value.id) {
            let provider = RemoteProcessingProvenance(
                providerId: value.providerId,
                modelAlias: value.providerModelAlias,
                modelId: value.providerModelId,
                modelPolicyVersion: value.providerModelPolicyVersion,
                providerRequestId: nil,
                processedAt: value.updatedAt,
                processingDurationMilliseconds: 0,
                retentionAttestation: RemoteRetentionAttestation(
                    mode: .deleteImmediatelyAfterProcessing,
                    maximumRetentionSeconds: 0,
                    policyVersion: "local-cloud-migration-v1",
                    attestedAt: value.updatedAt
                )
            )
            target.insert(DailyBiographyEntry(
                id: value.id,
                dayKey: value.dayKey,
                calendarDate: value.calendarDate,
                sourceStoryIds: value.sourceStoryIds,
                sourceTranscriptArtifactIds: value.sourceTranscriptArtifactIds,
                sourceTranscriptVersionIds: value.sourceTranscriptVersionIds,
                sourceFingerprint: value.sourceFingerprint,
                timezoneIdentifiers: value.timezoneIdentifiers,
                title: value.title,
                prose: value.prose,
                combinedTranscript: value.combinedTranscript,
                provider: provider,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            ))
        }
    }

    private static func copyLocalState(from source: ModelContext, to target: ModelContext) throws {
        let audioIDs = Set(try target.fetch(FetchDescriptor<AudioAsset>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<AudioAsset>()) where !audioIDs.contains(value.id) {
            target.insert(AudioAsset(
                id: value.id,
                fileURL: value.fileURL,
                createdAt: value.createdAt,
                expiresAt: value.expiresAt,
                duration: value.duration,
                isDeleted: value.isDeleted
            ))
        }

        let jobIDs = Set(try target.fetch(FetchDescriptor<ProcessingJob>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<ProcessingJob>()) where !jobIDs.contains(value.id) {
            target.insert(ProcessingJob(
                id: value.id,
                idempotencyKey: value.idempotencyKey,
                storyId: value.storyId,
                transcriptArtifactId: value.transcriptArtifactId,
                inputTranscriptVersionId: value.inputTranscriptVersionId,
                outputReferenceId: value.outputReferenceId,
                kind: value.kind,
                state: value.state,
                route: value.route,
                providerId: value.providerId,
                providerModelId: value.providerModelId,
                requestSchemaVersion: value.requestSchemaVersion,
                resultSchemaVersion: value.resultSchemaVersion,
                attemptCount: value.attemptCount,
                maximumAttempts: value.maximumAttempts,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt,
                startedAt: value.startedAt,
                completedAt: value.completedAt,
                nextAttemptAt: value.nextAttemptAt,
                leaseExpiresAt: value.leaseExpiresAt,
                lastErrorCode: value.lastErrorCode,
                deletionState: value.deletionState,
                remoteContentDeletedAt: value.remoteContentDeletedAt
            ))
        }

        let snapshotIDs = Set(try target.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>()) where !snapshotIDs.contains(value.id) {
            target.insert(DailyBiographyGenerationSnapshot(
                id: value.id,
                jobId: value.jobId,
                dayKey: value.dayKey,
                calendarDate: value.calendarDate,
                sourceStoryIds: value.sourceStoryIds,
                sourceTranscriptArtifactIds: value.sourceTranscriptArtifactIds,
                sourceTranscriptVersionIds: value.sourceTranscriptVersionIds,
                sourceFingerprint: value.sourceFingerprint,
                timezoneIdentifiers: value.timezoneIdentifiers,
                createdAt: value.createdAt
            ))
        }
    }

    private static func verifyStableIdentifiers(
        from source: ModelContext,
        in target: ModelContext
    ) throws {
        try requireSubset(source.fetch(FetchDescriptor<UserProfile>()).map(\.id), in: target.fetch(FetchDescriptor<UserProfile>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<Story>()).map(\.id), in: target.fetch(FetchDescriptor<Story>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<StoryMetadata>()).map(\.id), in: target.fetch(FetchDescriptor<StoryMetadata>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<TranscriptArtifact>()).map(\.id), in: target.fetch(FetchDescriptor<TranscriptArtifact>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<TranscriptVersion>()).map(\.id), in: target.fetch(FetchDescriptor<TranscriptVersion>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<BiographyFragment>()).map(\.id), in: target.fetch(FetchDescriptor<BiographyFragment>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<LifeEvent>()).map(\.id), in: target.fetch(FetchDescriptor<LifeEvent>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<Person>()).map(\.id), in: target.fetch(FetchDescriptor<Person>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<Place>()).map(\.id), in: target.fetch(FetchDescriptor<Place>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<Theme>()).map(\.id), in: target.fetch(FetchDescriptor<Theme>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<VocabularyEntry>()).map(\.id), in: target.fetch(FetchDescriptor<VocabularyEntry>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<DailyEntryResultArtifact>()).map(\.id), in: target.fetch(FetchDescriptor<DailyEntryResultArtifact>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<ReflectionSession>()).map(\.id), in: target.fetch(FetchDescriptor<ReflectionSession>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<ReflectionTurn>()).map(\.id), in: target.fetch(FetchDescriptor<ReflectionTurn>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<DailyBiographyEntry>()).map(\.id), in: target.fetch(FetchDescriptor<DailyBiographyEntry>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<AudioAsset>()).map(\.id), in: target.fetch(FetchDescriptor<AudioAsset>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<ProcessingJob>()).map(\.id), in: target.fetch(FetchDescriptor<ProcessingJob>()).map(\.id))
        try requireSubset(source.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>()).map(\.id), in: target.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>()).map(\.id))
    }

    private static func requireSubset(_ source: [UUID], in target: [UUID]) throws {
        guard Set(source).isSubset(of: Set(target)) else {
            throw CloudArchiveMigrationError.verificationFailed
        }
    }

    private static func decodedDailyEntryResponse(
        _ responseJSON: String
    ) throws -> DailyEntryGenerationResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            DailyEntryGenerationResponse.self,
            from: Data(responseJSON.utf8)
        )
    }
}

enum CloudArchiveMigrationError: Error, LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "Lore could not verify the iCloud archive migration. The original local archive was preserved."
    }
}
