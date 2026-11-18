import CryptoKit
import Foundation
import SwiftData

// MARK: - Wire contract

/// One finished day, as the person's own journal already tells it. A chapter
/// is written from these entries, never from raw transcripts.
struct StoryChapterSourceDay: Codable, Equatable, Sendable {
    var id: String
    var dayKey: String
    var title: String
    var prose: String
}

struct StoryChapterGenerationRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let currentPromptVersion = "story-chapter-v1"

    var schemaVersion: String = Self.currentSchemaVersion
    var promptVersion: String = Self.currentPromptVersion
    var jobId: UUID
    /// The calendar month the chapter covers, "YYYY-MM".
    var chapterKey: String
    var languageCode: String
    var subject: JournalSubject
    var renderConfiguration: JournalRenderConfiguration
    var sourceDays: [StoryChapterSourceDay]
    var retentionPolicy: RemoteRetentionPolicy = RemoteRetentionPolicy()
}

struct StoryChapterGenerationResponse: Codable, Equatable, Sendable {
    var schemaVersion: String
    var promptVersion: String
    var jobId: UUID
    var requestId: String
    var entry: GroundedJournalEntry
    var provenance: RemoteProcessingProvenance
}

// MARK: - Persisted chapter

/// One month of the person's autobiography, written from that month's
/// finished daily entries. Derived and replaceable: the daily entries and
/// transcripts stay canonical.
@Model
final class StoryChapter {
    private(set) var id: UUID = UUID()
    /// "YYYY-MM".
    private(set) var chapterKey: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var title: String = ""
    @Attribute(.allowsCloudEncryption) private(set) var prose: String = ""
    private(set) var sourceDayKeys: [String] = []
    private(set) var sourceFingerprint: String = ""
    private(set) var providerId: String = ""
    private(set) var providerModelId: String = ""
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        chapterKey: String,
        title: String,
        prose: String,
        sourceDayKeys: [String],
        sourceFingerprint: String,
        provider: RemoteProcessingProvenance,
        at date: Date = Date()
    ) {
        self.id = id
        self.chapterKey = chapterKey
        self.title = title
        self.prose = prose
        self.sourceDayKeys = sourceDayKeys
        self.sourceFingerprint = sourceFingerprint
        self.providerId = provider.providerId
        self.providerModelId = provider.modelId
        self.createdAt = date
        self.updatedAt = date
    }

    func replace(
        title: String,
        prose: String,
        sourceDayKeys: [String],
        sourceFingerprint: String,
        provider: RemoteProcessingProvenance,
        at date: Date
    ) {
        self.title = title
        self.prose = prose
        self.sourceDayKeys = sourceDayKeys
        self.sourceFingerprint = sourceFingerprint
        self.providerId = provider.providerId
        self.providerModelId = provider.modelId
        self.updatedAt = date
    }
}

// MARK: - Runner

enum StoryChapterRunnerError: Error, Equatable {
    case invalidResponse
}

/// Keeps one chapter per calendar month in step with the finished days in it.
/// Only days that have ended feed a chapter, so the open month is rewritten
/// at most once a day instead of on every recording.
@MainActor
enum StoryChapterRunner {
    private struct Month {
        let key: String
        let entries: [DailyBiographyEntry]
        let fingerprint: String
    }

    /// Months that have finished days but no up-to-date chapter yet.
    static func staleMonthKeys(
        entries: [DailyBiographyEntry],
        chapters: [StoryChapter],
        now: Date = Date(),
        calendar: JournalCalendar = JournalCalendar()
    ) -> [String] {
        months(from: entries, now: now, calendar: calendar)
            .filter { month in
                chapters.first(where: { $0.chapterKey == month.key })?.sourceFingerprint != month.fingerprint
            }
            .map(\.key)
    }

    /// Writes every stale chapter, oldest month first, and removes chapters
    /// whose days no longer exist. Returns the number of chapters written.
    @discardableResult
    static func refresh(
        userProfile: UserProfile,
        generator: any DailyEntryGenerationService,
        in modelContext: ModelContext,
        now: Date = Date(),
        calendar: JournalCalendar = JournalCalendar()
    ) async throws -> Int {
        let entries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
        let months = months(from: entries, now: now, calendar: calendar)
        let monthKeys = Set(months.map(\.key))

        let chapters = try modelContext.fetch(FetchDescriptor<StoryChapter>())
        let orphaned = chapters.filter { !monthKeys.contains($0.chapterKey) }
        if !orphaned.isEmpty {
            orphaned.forEach(modelContext.delete)
            try modelContext.save()
        }

        var written = 0
        for key in months.map(\.key) {
            try Task.checkCancellation()

            do {
                let entries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
                guard let month = Self.months(from: entries, now: now, calendar: calendar)
                    .first(where: { $0.key == key }) else { continue }
                let chapters = try modelContext.fetch(FetchDescriptor<StoryChapter>())
                guard chapters.first(where: { $0.chapterKey == key })?.sourceFingerprint != month.fingerprint else {
                    continue
                }

                let request = makeRequest(for: month, userProfile: userProfile)
                let response = try await generator.generateStoryChapter(request)
                try Task.checkCancellation()
                try validate(response, for: request)

                // Notes and their daily entries may change while the chapter is writing.
                let currentEntries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>())
                guard Self.months(from: currentEntries, now: now, calendar: calendar)
                    .first(where: { $0.key == key })?.fingerprint == month.fingerprint else { continue }
                let existing = try modelContext.fetch(FetchDescriptor<StoryChapter>())
                    .first { $0.chapterKey == key }
                let prose = paragraphs(from: response.entry.sentences.map(\.text))
                let dayKeys = request.sourceDays.map(\.dayKey)
                if let existing {
                    existing.replace(
                        title: response.entry.title,
                        prose: prose,
                        sourceDayKeys: dayKeys,
                        sourceFingerprint: month.fingerprint,
                        provider: response.provenance,
                        at: now
                    )
                } else {
                    let chapter = StoryChapter(
                        chapterKey: month.key,
                        title: response.entry.title,
                        prose: prose,
                        sourceDayKeys: dayKeys,
                        sourceFingerprint: month.fingerprint,
                        provider: response.provenance,
                        at: now
                    )
                    modelContext.insert(chapter)
                }
                try modelContext.save()
                written += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One month failing must not block the others; it stays stale
                // and is retried on the next refresh.
                modelContext.rollback()
                print("Story chapter \(key) did not complete: \(error)")
            }
        }
        return written
    }

    // MARK: Building blocks

    private static func months(
        from entries: [DailyBiographyEntry],
        now: Date,
        calendar: JournalCalendar
    ) -> [Month] {
        let todayKey = calendar.dayKey(for: now)
        let finished = entries
            .filter { $0.dayKey < todayKey && !$0.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Dictionary(grouping: finished) { String($0.dayKey.prefix(7)) }
            .map { key, group in
                let sorted = group.sorted { $0.dayKey < $1.dayKey }
                return Month(key: key, entries: sorted, fingerprint: fingerprint(for: sorted))
            }
            .sorted { $0.key < $1.key }
    }

    private static func fingerprint(for entries: [DailyBiographyEntry]) -> String {
        let source = (["story-chapter-v1"] + entries.map { "\($0.dayKey):\($0.sourceFingerprint)" })
            .joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeRequest(
        for month: Month,
        userProfile: UserProfile
    ) -> StoryChapterGenerationRequest {
        StoryChapterGenerationRequest(
            jobId: UUID(),
            chapterKey: month.key,
            languageCode: Locale.current.identifier,
            subject: JournalSubject(displayName: userProfile.name, pronouns: []),
            renderConfiguration: JournalRenderConfiguration(
                targetWords: min(1_200, max(200, month.entries.count * 90))
            ),
            sourceDays: month.entries.map {
                StoryChapterSourceDay(
                    id: $0.dayKey,
                    dayKey: $0.dayKey,
                    title: $0.title,
                    prose: $0.prose
                )
            }
        )
    }

    private static func validate(
        _ response: StoryChapterGenerationResponse,
        for request: StoryChapterGenerationRequest
    ) throws {
        let sourceIds = Set(request.sourceDays.map(\.id))
        let sentences = response.entry.sentences
        let validSentences = sentences.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.sourceReferences.isEmpty
                && Set($0.sourceReferences).isSubset(of: sourceIds)
        }
        guard response.schemaVersion == StoryChapterGenerationRequest.currentSchemaVersion,
              response.promptVersion == request.promptVersion,
              response.jobId == request.jobId,
              !response.entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.entry.titleSourceReferences.isEmpty,
              Set(response.entry.titleSourceReferences).isSubset(of: sourceIds),
              !sentences.isEmpty,
              validSentences else {
            throw StoryChapterRunnerError.invalidResponse
        }
    }

    /// Groups sentences into short paragraphs so a chapter reads as prose, not
    /// one block. The writer returns sentences only.
    static func paragraphs(from sentences: [String], perParagraph: Int = 4) -> String {
        stride(from: 0, to: sentences.count, by: perParagraph)
            .map { start in
                sentences[start..<min(start + perParagraph, sentences.count)].joined(separator: " ")
            }
            .joined(separator: "\n\n")
    }
}
