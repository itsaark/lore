import CryptoKit
import Foundation
import SwiftData

/// Identifies a derived biography and its painting. Each coarse memory
/// stands on its own, even when several memories share a start date.
enum BiographyIdentity {
    static func key(dayKey: String, memoryStoryId: UUID?) -> String {
        memoryStoryId.map { "memory:" + $0.uuidString.lowercased() } ?? dayKey
    }
}

/// A synced, replaceable biography for a calendar day or one coarse memory.
/// Source stories and transcript versions remain canonical and are never rewritten.
@Model
final class DailyBiographyEntry {
    private(set) var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) private(set) var dayKey: String = ""
    private(set) var memoryStoryId: UUID?
    @Attribute(.allowsCloudEncryption) private(set) var calendarDate: Date = Date()
    private(set) var sourceStoryIds: [UUID] = []
    private(set) var sourceTranscriptArtifactIds: [UUID] = []
    private(set) var sourceTranscriptVersionIds: [UUID] = []
    private(set) var sourceFingerprint: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var timezoneIdentifiers: [String] = []
    @Attribute(.allowsCloudEncryption) private(set) var title: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var prose: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var combinedTranscript: String = ""
    private(set) var noteCount: Int = 0
    private(set) var providerId: String = ""
    private(set) var providerModelAlias: String = ""
    private(set) var providerModelId: String = ""
    private(set) var providerModelPolicyVersion: String = ""
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    var biographyKey: String { BiographyIdentity.key(dayKey: dayKey, memoryStoryId: memoryStoryId) }

    var formattedCalendarDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: calendarDate)
    }

    init(
        id: UUID = UUID(),
        dayKey: String,
        memoryStoryId: UUID? = nil,
        calendarDate: Date,
        sourceStoryIds: [UUID],
        sourceTranscriptArtifactIds: [UUID],
        sourceTranscriptVersionIds: [UUID],
        sourceFingerprint: String,
        timezoneIdentifiers: [String],
        title: String,
        prose: String,
        combinedTranscript: String,
        provider: RemoteProcessingProvenance,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayKey = dayKey
        self.memoryStoryId = memoryStoryId
        self.calendarDate = calendarDate
        self.sourceStoryIds = sourceStoryIds
        self.sourceTranscriptArtifactIds = sourceTranscriptArtifactIds
        self.sourceTranscriptVersionIds = sourceTranscriptVersionIds
        self.sourceFingerprint = sourceFingerprint
        self.timezoneIdentifiers = timezoneIdentifiers
        self.title = title
        self.prose = prose
        self.combinedTranscript = combinedTranscript
        self.noteCount = sourceStoryIds.count
        self.providerId = provider.providerId
        self.providerModelAlias = provider.modelAlias
        self.providerModelId = provider.modelId
        self.providerModelPolicyVersion = provider.modelPolicyVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func replace(
        sourceStoryIds: [UUID],
        sourceTranscriptArtifactIds: [UUID],
        sourceTranscriptVersionIds: [UUID],
        sourceFingerprint: String,
        timezoneIdentifiers: [String],
        title: String,
        prose: String,
        combinedTranscript: String,
        provider: RemoteProcessingProvenance,
        at date: Date
    ) {
        self.sourceStoryIds = sourceStoryIds
        self.sourceTranscriptArtifactIds = sourceTranscriptArtifactIds
        self.sourceTranscriptVersionIds = sourceTranscriptVersionIds
        self.sourceFingerprint = sourceFingerprint
        self.timezoneIdentifiers = timezoneIdentifiers
        self.title = title
        self.prose = prose
        self.combinedTranscript = combinedTranscript
        noteCount = sourceStoryIds.count
        providerId = provider.providerId
        providerModelAlias = provider.modelAlias
        providerModelId = provider.modelId
        providerModelPolicyVersion = provider.modelPolicyVersion
        updatedAt = date
    }
}

/// Content-free durable input identity for a daily biography generation job.
/// Transcript text is rebuilt from the canonical local versions only when the job runs.
@Model
final class DailyBiographyGenerationSnapshot {
    private(set) var id: UUID
    private(set) var jobId: UUID
    private(set) var dayKey: String
    private(set) var memoryStoryId: UUID?
    var biographyKey: String { BiographyIdentity.key(dayKey: dayKey, memoryStoryId: memoryStoryId) }
    private(set) var calendarDate: Date
    private(set) var sourceStoryIds: [UUID]
    private(set) var sourceTranscriptArtifactIds: [UUID]
    private(set) var sourceTranscriptVersionIds: [UUID]
    private(set) var sourceFingerprint: String
    private(set) var timezoneIdentifiers: [String]
    private(set) var createdAt: Date

    init(
        id: UUID = UUID(),
        jobId: UUID,
        dayKey: String,
        memoryStoryId: UUID? = nil,
        calendarDate: Date,
        sourceStoryIds: [UUID],
        sourceTranscriptArtifactIds: [UUID],
        sourceTranscriptVersionIds: [UUID],
        sourceFingerprint: String,
        timezoneIdentifiers: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobId = jobId
        self.dayKey = dayKey
        self.memoryStoryId = memoryStoryId
        self.calendarDate = calendarDate
        self.sourceStoryIds = sourceStoryIds
        self.sourceTranscriptArtifactIds = sourceTranscriptArtifactIds
        self.sourceTranscriptVersionIds = sourceTranscriptVersionIds
        self.sourceFingerprint = sourceFingerprint
        self.timezoneIdentifiers = timezoneIdentifiers
        self.createdAt = createdAt
    }
}

enum DailyBiographyJobRunnerError: Error, LocalizedError, Equatable {
    case jobNotFound
    case snapshotNotFound
    case sourceNotFound
    case jobNotReady
    case jobCancelled
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .jobNotFound:
            "Lore could not find the saved daily-biography job."
        case .snapshotNotFound:
            "Lore could not find the daily-biography source snapshot."
        case .sourceNotFound:
            "One or more source transcripts for this day are unavailable."
        case .jobNotReady:
            "This daily-biography job is waiting before it can retry."
        case .jobCancelled:
            "This daily-biography job was cancelled."
        case .invalidResponse:
            "The generated daily biography was not grounded in its sources."
        }
    }
}

@MainActor
enum DailyBiographyJobRunner {
    static let retryableAuthenticationCodes: Set<String> = [
        "assertion_invalid", "app_attest_key_unknown", "counter_replayed", "unauthorized",
        "challenge_expired", "challenge_replayed", "auth_unavailable",
        "app_attest_key_invalid", "app_attest_backoff", "app_attest_server_unavailable",
        "app_attest_system_failure"
    ]

    struct PreparedDay: Equatable {
        let jobId: UUID
        let dayKey: String
        let sourceStoryIds: [UUID]
    }

    private struct Source {
        let story: Story
        let artifact: TranscriptArtifact
        let version: TranscriptVersion
        let timezone: TimeZone
    }

    private struct BiographyGroup {
        let dayKey: String
        let memoryStoryId: UUID?
        var biographyKey: String { BiographyIdentity.key(dayKey: dayKey, memoryStoryId: memoryStoryId) }
        let calendarDate: Date
        let sources: [Source]
        let fingerprint: String
        let timezoneIdentifiers: [String]
    }

    private struct RequestPackage {
        let request: DailyEntryGenerationRequest
        let stories: [Story]
        let artifacts: [TranscriptArtifact]
        let versions: [TranscriptVersion]
        let combinedTranscript: String
    }

    @discardableResult
    static func prepareCompletedDays(
        initialState: ProcessingJobState,
        in modelContext: ModelContext,
        now: Date = Date()
    ) throws -> [PreparedDay] {
        let groups = try biographyGroups(in: modelContext)
        let entries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
        let snapshots = try modelContext.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        let jobsById = Dictionary(
            jobs.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.updatedAt >= candidate.updatedAt ? current : candidate
            }
        )
        var prepared: [PreparedDay] = []

        for group in groups {
            if entries.contains(where: {
                $0.biographyKey == group.biographyKey && $0.sourceFingerprint == group.fingerprint
            }) {
                continue
            }

            if let existingSnapshot = snapshots.first(where: {
                $0.biographyKey == group.biographyKey && $0.sourceFingerprint == group.fingerprint
            }), let existingJob = jobsById[existingSnapshot.jobId] {
                if existingJob.state != .succeeded && existingJob.state != .cancelled {
                    prepared.append(PreparedDay(
                        jobId: existingJob.id,
                        dayKey: group.dayKey,
                        sourceStoryIds: existingSnapshot.sourceStoryIds
                    ))
                    continue
                }
                // Deleting a note can restore a previous fingerprint after its
                // original entry was replaced and then removed.
                modelContext.delete(existingSnapshot)
                modelContext.delete(existingJob)
            }

            for obsolete in snapshots where obsolete.biographyKey == group.biographyKey
                && obsolete.sourceFingerprint != group.fingerprint {
                if let job = jobsById[obsolete.jobId],
                   job.state != .succeeded,
                   job.state != .failed,
                   job.state != .cancelled {
                    job.cancel(at: now)
                }
            }

            let jobId = UUID()
            let first = group.sources[0]
            let job = ProcessingJob(
                id: jobId,
                idempotencyKey: "daily-biography:\(group.biographyKey):\(group.fingerprint)",
                storyId: first.story.id,
                transcriptArtifactId: first.artifact.id,
                inputTranscriptVersionId: first.version.id,
                kind: .dailyBiography,
                state: initialState,
                route: .remote,
                createdAt: now,
                updatedAt: now
            )
            let snapshot = DailyBiographyGenerationSnapshot(
                jobId: jobId,
                dayKey: group.dayKey,
                memoryStoryId: group.memoryStoryId,
                calendarDate: group.calendarDate,
                sourceStoryIds: group.sources.map(\.story.id),
                sourceTranscriptArtifactIds: group.sources.map(\.artifact.id),
                sourceTranscriptVersionIds: group.sources.map(\.version.id),
                sourceFingerprint: group.fingerprint,
                timezoneIdentifiers: group.timezoneIdentifiers,
                createdAt: now
            )
            modelContext.insert(job)
            modelContext.insert(snapshot)
            prepared.append(PreparedDay(
                jobId: job.id,
                dayKey: group.dayKey,
                sourceStoryIds: snapshot.sourceStoryIds
            ))
        }

        try modelContext.save()
        return prepared
    }

    @discardableResult
    static func run(
        jobID: UUID,
        userProfile: UserProfile,
        generator: any DailyEntryGenerationService,
        in modelContext: ModelContext,
        now: Date = Date(),
        leaseDuration: TimeInterval = 180
    ) async throws -> DailyBiographyEntry {
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        guard let job = jobs.first(where: { $0.id == jobID && $0.kind == .dailyBiography }) else {
            throw DailyBiographyJobRunnerError.jobNotFound
        }
        let snapshots = try modelContext.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
        guard let snapshot = snapshots.first(where: { $0.jobId == jobID }) else {
            throw DailyBiographyJobRunnerError.snapshotNotFound
        }
        let entries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
        if job.state == .succeeded,
           let outputId = job.outputReferenceId,
           let entry = entries.first(where: { $0.id == outputId }) {
            return entry
        }
        guard job.state != .cancelled else {
            throw DailyBiographyJobRunnerError.jobCancelled
        }

        if job.recoverExpiredLease(at: now) {
            try saveOrRollback(modelContext)
        }
        guard job.isReadyForAttempt(at: now) else {
            throw DailyBiographyJobRunnerError.jobNotReady
        }

        let package = try makeRequest(
            snapshot: snapshot,
            jobId: job.id,
            userProfile: userProfile,
            in: modelContext
        )
        let biographyKey = snapshot.biographyKey
        let sourceFingerprint = snapshot.sourceFingerprint
        job.beginAttempt(at: now, leaseDuration: leaseDuration)
        let attempt = job.attemptCount
        try saveOrRollback(modelContext)

        do {
            let response = try await generator.generateDailyEntry(package.request)
            try Task.checkCancellation()
            guard job.modelContext != nil, !job.isDeleted, job.state == .running, job.attemptCount == attempt else {
                throw DailyBiographyJobRunnerError.jobCancelled
            }
            guard try biographyGroups(in: modelContext).contains(where: {
                $0.biographyKey == biographyKey && $0.fingerprint == sourceFingerprint
            }) else {
                job.cancel(at: Date())
                try saveOrRollback(modelContext)
                throw DailyBiographyJobRunnerError.jobCancelled
            }
            try validate(response: response, for: package.request)

            let entry: DailyBiographyEntry
            let currentEntries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
            if let existing = currentEntries.first(where: { $0.biographyKey == biographyKey }) {
                existing.replace(
                    sourceStoryIds: package.stories.map(\.id),
                    sourceTranscriptArtifactIds: package.artifacts.map(\.id),
                    sourceTranscriptVersionIds: package.versions.map(\.id),
                    sourceFingerprint: snapshot.sourceFingerprint,
                    timezoneIdentifiers: snapshot.timezoneIdentifiers,
                    title: response.entry.title,
                    prose: response.entry.prose,
                    combinedTranscript: package.combinedTranscript,
                    provider: response.provenance,
                    at: now
                )
                entry = existing
            } else {
                entry = DailyBiographyEntry(
                    dayKey: snapshot.dayKey,
                    memoryStoryId: snapshot.memoryStoryId,
                    calendarDate: snapshot.calendarDate,
                    sourceStoryIds: package.stories.map(\.id),
                    sourceTranscriptArtifactIds: package.artifacts.map(\.id),
                    sourceTranscriptVersionIds: package.versions.map(\.id),
                    sourceFingerprint: snapshot.sourceFingerprint,
                    timezoneIdentifiers: snapshot.timezoneIdentifiers,
                    title: response.entry.title,
                    prose: response.entry.prose,
                    combinedTranscript: package.combinedTranscript,
                    provider: response.provenance,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(entry)
            }
            if snapshot.memoryStoryId == nil {
                try DailyQuestionStore.saveFollowUps(
                    for: entry, response: response, request: package.request, in: modelContext
                )
            }
            // The day's story now covers these notes; they have no separate
            // per-note entry to wait for.
            for story in package.stories where story.processingStatus == "awaitingModel" {
                story.processingStatus = "processed"
                story.updatedAt = now
            }
            job.providerId = response.provenance.providerId
            job.providerModelId = response.provenance.modelId
            job.markSucceeded(
                outputReferenceId: entry.id,
                resultSchemaVersion: response.schemaVersion,
                at: now
            )
            try saveOrRollback(modelContext)
            return entry
        } catch is CancellationError {
            guard job.modelContext != nil, !job.isDeleted, job.state == .running, job.attemptCount == attempt else {
                throw CancellationError()
            }
            modelContext.rollback()
            job.cancel(at: Date())
            try saveOrRollback(modelContext)
            throw CancellationError()
        } catch LoreBackendProcessingError.cancelled {
            guard job.modelContext != nil, !job.isDeleted, job.state == .running, job.attemptCount == attempt else {
                throw CancellationError()
            }
            modelContext.rollback()
            job.cancel(at: Date())
            try saveOrRollback(modelContext)
            throw CancellationError()
        } catch {
            guard job.modelContext != nil, !job.isDeleted, job.state == .running,
                  job.attemptCount == attempt else { throw error }
            modelContext.rollback()
            let terminal = isTerminal(error) || job.attemptCount >= job.maximumAttempts
            let failureDate = Date()
            job.markFailed(
                errorCode: errorCode(error),
                retryAt: terminal ? nil : failureDate.addingTimeInterval(retryDelay(job.attemptCount)),
                at: failureDate
            )
            try saveOrRollback(modelContext)
            throw error
        }
    }

    private static func saveOrRollback(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    static func deleteSupportData(
        containing storyID: UUID,
        emptyDayKey: String? = nil,
        in modelContext: ModelContext
    ) throws -> Int {
        let allEntries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
        let entries = allEntries.filter {
            $0.memoryStoryId == storyID || $0.sourceStoryIds.contains(storyID) || $0.biographyKey == emptyDayKey
        }
        let snapshots = try modelContext.fetch(FetchDescriptor<DailyBiographyGenerationSnapshot>())
            .filter {
                $0.memoryStoryId == storyID || $0.sourceStoryIds.contains(storyID) || $0.biographyKey == emptyDayKey
            }
        let snapshotJobIds = Set(snapshots.map(\.jobId))
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
            .filter { snapshotJobIds.contains($0.id) }

        let removedEntryIds = Set(entries.map(\.id))
        let remainingKeys = Set(allEntries.filter { !removedEntryIds.contains($0.id) }.map(\.biographyKey))
        var affectedKeys = Set(entries.map(\.biographyKey) + snapshots.map(\.biographyKey))
        if let emptyDayKey { affectedKeys.insert(emptyDayKey) }
        let removedKeys = affectedKeys.subtracting(remainingKeys)
        let illustrations = try modelContext.fetch(FetchDescriptor<DayIllustration>())
            .filter { $0.memoryStoryId == storyID || removedKeys.contains($0.biographyKey) }

        try DailyQuestionStore.removeFollowUps(for: removedEntryIds, in: modelContext)
        entries.forEach(modelContext.delete)
        illustrations.forEach(modelContext.delete)
        snapshots.forEach(modelContext.delete)
        jobs.forEach(modelContext.delete)
        return entries.count + illustrations.count + snapshots.count + jobs.count
    }

    private static func biographyGroups(in modelContext: ModelContext) throws -> [BiographyGroup] {
        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        let metadata = try modelContext.fetch(FetchDescriptor<StoryMetadata>())
        let metadataById = Dictionary(
            metadata.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var sourcesByBiography: [String: [Source]] = [:]

        for story in stories {
            let timezone = story.metadataId
                .flatMap { metadataById[$0] }
                .flatMap { TimeZone(identifier: $0.timezone) }
                ?? .current
            guard let artifact = artifacts.first(where: { $0.storyId == story.id }) else {
                continue
            }
            guard let version = versions
                .filter({ $0.transcriptArtifactId == artifact.id })
                .max(by: { $0.revision < $1.revision }) else {
                continue
            }
            guard !version.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let dayKey = story.effectiveDayKey(recordedDayKey: localDayKey(for: story.date, timezone: timezone))
            let key = BiographyIdentity.key(dayKey: dayKey ?? "", memoryStoryId: dayKey == nil ? story.id : nil)
            sourcesByBiography[key, default: []].append(Source(
                story: story,
                artifact: artifact,
                version: version,
                timezone: timezone
            ))
        }

        return sourcesByBiography.compactMap { key, sources in
            let sorted = sources.sorted { $0.story.date < $1.story.date }
            let first = sorted[0].story
            let rememberedTime = first.rememberedTime
            let memoryStoryId = rememberedTime?.isCoarse == true ? first.id : nil
            let dayKey = memoryStoryId == nil ? key : rememberedTime?.startDate ?? key
            guard let calendarDate = calendarDate(for: dayKey) else { return nil }
            let identifiers = sorted.map(\.timezone.identifier)
            return BiographyGroup(
                dayKey: dayKey,
                memoryStoryId: memoryStoryId,
                calendarDate: calendarDate,
                sources: sorted,
                fingerprint: fingerprint(key: key, sources: sorted, memoryTime: memoryStoryId == nil ? nil : rememberedTime),
                timezoneIdentifiers: identifiers
            )
        }
        .sorted { ($0.dayKey, $0.biographyKey) < ($1.dayKey, $1.biographyKey) }
    }

    private static func makeRequest(
        snapshot: DailyBiographyGenerationSnapshot,
        jobId: UUID,
        userProfile: UserProfile,
        in modelContext: ModelContext
    ) throws -> RequestPackage {
        let allStories = try modelContext.fetch(FetchDescriptor<Story>())
        let allArtifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let allVersions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        let storyById = Dictionary(
            allStories.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.updatedAt >= candidate.updatedAt ? current : candidate
            }
        )
        let artifactById = Dictionary(
            allArtifacts.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.createdAt >= candidate.createdAt ? current : candidate
            }
        )
        let versionById = Dictionary(
            allVersions.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.createdAt >= candidate.createdAt ? current : candidate
            }
        )

        var tuples: [(Story, TranscriptArtifact, TranscriptVersion)] = []
        for index in snapshot.sourceStoryIds.indices {
            guard snapshot.sourceTranscriptArtifactIds.indices.contains(index),
                  snapshot.sourceTranscriptVersionIds.indices.contains(index),
                  let story = storyById[snapshot.sourceStoryIds[index]],
                  let artifact = artifactById[snapshot.sourceTranscriptArtifactIds[index]],
                  let version = versionById[snapshot.sourceTranscriptVersionIds[index]],
                  artifact.storyId == story.id,
                  version.storyId == story.id,
                  version.transcriptArtifactId == artifact.id else {
                throw DailyBiographyJobRunnerError.sourceNotFound
            }
            tuples.append((story, artifact, version))
        }
        tuples.sort { $0.0.date < $1.0.date }
        guard let first = tuples.first else {
            throw DailyBiographyJobRunnerError.sourceNotFound
        }

        let metadataById = Dictionary(
            try modelContext.fetch(FetchDescriptor<StoryMetadata>()).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let segments = tuples.map { story, _, version in
            let timezone = story.metadataId
                .flatMap { metadataById[$0] }
                .flatMap { TimeZone(identifier: $0.timezone) }
                ?? .current
            return TranscriptSourceSegment(
                id: version.id.uuidString.lowercased(),
                chunkId: story.id.uuidString.lowercased(),
                startMilliseconds: 0,
                endMilliseconds: max(0, Int(story.duration * 1_000)),
                text: version.text,
                confidence: nil,
                speakerLabel: nil,
                recordedAt: TranscriptSourceSegment.recordedAtString(for: story.date, in: timezone)
            )
        }
        // The v1 generation envelope has one canonical note/artifact/version
        // anchor. Daily consolidation uses the earliest source as that stable
        // anchor while every transcript remains independently identified in
        // sourceSegments and in the durable local snapshot above.
        let rememberedTime = first.0.rememberedTime.flatMap(DailyEntryGenerationRequest.RememberedRange.init)
        guard (snapshot.memoryStoryId == nil && rememberedTime == nil)
                || (snapshot.memoryStoryId == first.0.id && rememberedTime != nil && tuples.count == 1
                    && snapshot.dayKey == rememberedTime?.startDate) else {
            throw DailyBiographyJobRunnerError.sourceNotFound
        }
        let capturedDay = snapshot.memoryStoryId == nil ? snapshot.dayKey : localDayKey(
            for: first.0.date, timezone: snapshot.timezoneIdentifiers.first.flatMap(TimeZone.init(identifier:)) ?? .current
        )
        let request = DailyEntryGenerationRequest(
            jobId: jobId,
            noteId: first.0.id,
            transcriptArtifactId: first.1.id,
            transcriptVersionId: first.2.id,
            capturedLocalDate: capturedDay,
            rememberedTime: rememberedTime,
            languageCode: first.1.languageCode ?? Locale.current.identifier,
            subject: JournalSubject(displayName: userProfile.name, pronouns: []),
            renderConfiguration: JournalRenderConfiguration(targetWords: min(600, max(160, tuples.count * 120))),
            sourceSegments: segments
        )

        return RequestPackage(
            request: request,
            stories: tuples.map(\.0),
            artifacts: tuples.map(\.1),
            versions: tuples.map(\.2),
            combinedTranscript: combinedTranscript(from: tuples, timezoneIdentifiers: snapshot.timezoneIdentifiers)
        )
    }

    private static func validate(
        response: DailyEntryGenerationResponse,
        for request: DailyEntryGenerationRequest
    ) throws {
        let sourceIds = Set(request.sourceSegments.map(\.id))
        let validSentences = response.entry.sentences.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.sourceReferences.isEmpty
                && Set($0.sourceReferences).isSubset(of: sourceIds)
        }
        // A day story need not cite every note: the writer merges small notes
        // and sets sensitive ones aside on purpose. Invented references are
        // still rejected above and by the backend.
        guard response.schemaVersion == DailyEntryGenerationResponse.currentSchemaVersion,
              response.promptVersion == request.promptVersion,
              response.jobId == request.jobId,
              !response.entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.entry.titleSourceReferences.isEmpty,
              Set(response.entry.titleSourceReferences).isSubset(of: sourceIds),
              !response.entry.sentences.isEmpty,
              validSentences else {
            throw DailyBiographyJobRunnerError.invalidResponse
        }
    }

    private static func combinedTranscript(
        from tuples: [(Story, TranscriptArtifact, TranscriptVersion)],
        timezoneIdentifiers: [String]
    ) -> String {
        tuples.enumerated().map { index, tuple in
            let (story, _, version) = tuple
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeZone = timezoneIdentifiers.indices.contains(index)
                ? TimeZone(identifier: timezoneIdentifiers[index]) ?? .current
                : .current
            formatter.dateFormat = "h:mm a"
            return "\(formatter.string(from: story.date))\n\(version.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .joined(separator: "\n\n")
    }

    private static func localDayKey(for date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func calendarDate(for dayKey: String) -> Date? {
        let components = dayKey.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = TimeZone(secondsFromGMT: 0)
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        dateComponents.hour = 12
        return dateComponents.date
    }

    private static func fingerprint(key: String, sources: [Source], memoryTime: RememberedTime?) -> String {
        var components = [key]
        if let memoryTime {
            components += [memoryTime.precision.rawValue, memoryTime.startDate, memoryTime.endDate]
        }
        let source = (components + sources.map {
            "\($0.story.id.uuidString.lowercased()):\($0.version.id.uuidString.lowercased())"
        }).joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isTerminal(_ error: Error) -> Bool {
        switch error {
        case LoreBackendProcessingError.notConfigured,
             LoreBackendProcessingError.invalidConfiguration,
             LoreBackendProcessingError.invalidRequest,
             LoreBackendProcessingError.payloadTooLarge,
             DailyBiographyJobRunnerError.sourceNotFound:
            true
        case let LoreBackendProcessingError.rejected(code, retryable, _):
            !retryable && !retryableAuthenticationCodes.contains(code)
        default:
            false
        }
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case LoreBackendProcessingError.notConfigured:
            "remote_not_configured"
        case LoreBackendProcessingError.invalidConfiguration:
            "remote_invalid_configuration"
        case LoreBackendProcessingError.invalidRequest:
            "remote_invalid_request"
        case LoreBackendProcessingError.payloadTooLarge:
            "remote_payload_too_large"
        case LoreBackendProcessingError.rateLimited:
            "remote_rate_limited"
        case LoreBackendProcessingError.transportUnavailable:
            "network_unavailable"
        case LoreBackendProcessingError.invalidResponse:
            "invalid_remote_response"
        case let LoreBackendProcessingError.rejected(code, _, _):
            code
        case DailyBiographyJobRunnerError.sourceNotFound:
            "daily_biography_source_missing"
        case DailyBiographyJobRunnerError.invalidResponse:
            "daily_biography_invalid_response"
        default:
            "remote_daily_biography_failed"
        }
    }

    private static func retryDelay(_ attempt: Int) -> TimeInterval {
        min(600, 30 * pow(2, Double(max(0, attempt - 1))))
    }
}
