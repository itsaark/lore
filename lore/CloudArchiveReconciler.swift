import Foundation
import SwiftData

/// CloudKit cannot enforce SwiftData uniqueness. After an import, collapse
/// records that represent the same stable or logical identity so concurrent
/// device creation never crashes dictionary construction or duplicates a day.
@MainActor
enum CloudArchiveReconciler {
    @discardableResult
    static func reconcile(in context: ModelContext) throws -> Int {
        var deleted = 0

        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<UserProfile>()),
            key: { _ in "profile" },
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<Story>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<StoryMetadata>()),
            key: \.id,
            prefers: { $0.captureDate >= $1.captureDate },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<TranscriptArtifact>()),
            key: \.id,
            prefers: { $0.createdAt >= $1.createdAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<TranscriptVersion>()),
            key: \.id,
            prefers: {
                ($0.revision, $0.createdAt) >= ($1.revision, $1.createdAt)
            },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<BiographyFragment>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<LifeEvent>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<Person>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<Place>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )
        deleted += reconcileByKey(
            try context.fetch(FetchDescriptor<Theme>()),
            key: \.id,
            prefers: { $0.updatedAt >= $1.updatedAt },
            in: context
        )

        deleted += try reconcileDailyEntryResults(in: context)
        deleted += try reconcileDailyBiographies(in: context)
        deleted += try reconcileVocabulary(in: context)

        if deleted > 0 {
            try context.save()
        }
        return deleted
    }

    private static func reconcileByKey<Model: PersistentModel, Key: Hashable>(
        _ values: [Model],
        key: (Model) -> Key,
        prefers: (Model, Model) -> Bool,
        in context: ModelContext
    ) -> Int {
        var selected: [Key: Model] = [:]
        var deleted = 0

        for candidate in values {
            let candidateKey = key(candidate)
            guard let current = selected[candidateKey] else {
                selected[candidateKey] = candidate
                continue
            }

            if prefers(candidate, current) {
                context.delete(current)
                selected[candidateKey] = candidate
            } else {
                context.delete(candidate)
            }
            deleted += 1
        }
        return deleted
    }

    private static func reconcileDailyEntryResults(in context: ModelContext) throws -> Int {
        let values = try context.fetch(FetchDescriptor<DailyEntryResultArtifact>())
            .sorted { lhs, rhs in
                (lhs.revision, lhs.createdAt) > (rhs.revision, rhs.createdAt)
            }
        var ids = Set<UUID>()
        var jobIDs = Set<UUID>()
        var deleted = 0

        for value in values {
            guard !ids.contains(value.id), !jobIDs.contains(value.jobId) else {
                context.delete(value)
                deleted += 1
                continue
            }
            ids.insert(value.id)
            jobIDs.insert(value.jobId)
        }
        return deleted
    }

    private static func reconcileDailyBiographies(in context: ModelContext) throws -> Int {
        let values = try context.fetch(FetchDescriptor<DailyBiographyEntry>())
            .sorted { $0.updatedAt > $1.updatedAt }
        var ids = Set<UUID>()
        var dayKeys = Set<String>()
        var deleted = 0

        for value in values {
            guard !ids.contains(value.id), !dayKeys.contains(value.dayKey) else {
                context.delete(value)
                deleted += 1
                continue
            }
            ids.insert(value.id)
            dayKeys.insert(value.dayKey)
        }
        return deleted
    }

    private static func reconcileVocabulary(in context: ModelContext) throws -> Int {
        let values = try context.fetch(FetchDescriptor<VocabularyEntry>())
            .sorted { $0.updatedAt > $1.updatedAt }
        var ids = Set<UUID>()
        var normalizedPhrases = Set<String>()
        var deleted = 0

        for value in values {
            guard !ids.contains(value.id),
                  !normalizedPhrases.contains(value.normalizedPhrase) else {
                context.delete(value)
                deleted += 1
                continue
            }
            ids.insert(value.id)
            normalizedPhrases.insert(value.normalizedPhrase)
        }
        return deleted
    }
}
