import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
@MainActor
struct StoryChapterTests {
    private let now = ISO8601DateFormatter().date(from: "2026-08-04T18:00:00Z")!

    @Test func writesOneChapterPerMonthFromFinishedDaysOnly() async throws {
        let fixture = try makeFixture(days: [
            ("2026-07-02", "fp-a"), ("2026-07-20", "fp-b"), ("2026-08-01", "fp-c"), ("2026-08-04", "fp-today")
        ])
        let generator = RecordingChapterGenerator()
        fixture.profile.narratorPronouns = .she

        let written = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile,
            generator: generator,
            in: fixture.context,
            now: now,
            calendar: utcCalendar
        )

        #expect(written == 2)
        #expect(generator.requests.map(\.subject.pronouns) == [["she", "her", "hers"], ["she", "her", "hers"]])
        let chapters = try fixture.context.fetch(FetchDescriptor<StoryChapter>())
            .sorted { $0.chapterKey < $1.chapterKey }
        #expect(chapters.map(\.chapterKey) == ["2026-07", "2026-08"])
        #expect(chapters[0].sourceDayKeys == ["2026-07-02", "2026-07-20"])
        // Today's day is still open, so it never feeds August's chapter.
        #expect(chapters[1].sourceDayKeys == ["2026-08-01"])
        #expect(generator.requests.flatMap { $0.sourceDays.map(\.id) }.contains("2026-08-04") == false)
    }

    @Test func unchangedMonthsAreNotRewrittenWhenPronounsChange() async throws {
        let fixture = try makeFixture(days: [("2026-07-02", "fp-a")])
        let generator = RecordingChapterGenerator()

        _ = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )
        fixture.profile.narratorPronouns = .they
        let second = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        #expect(second == 0)
        #expect(generator.requests.count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<StoryChapter>()).count == 1)
    }

    @Test func aNewFinishedDayRewritesItsMonthsChapter() async throws {
        let fixture = try makeFixture(days: [("2026-07-02", "fp-a")])
        let generator = RecordingChapterGenerator()
        _ = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        fixture.context.insert(entry(day: "2026-07-09", fingerprint: "fp-new"))
        try fixture.context.save()
        let rewritten = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        #expect(rewritten == 1)
        let chapters = try fixture.context.fetch(FetchDescriptor<StoryChapter>())
        #expect(chapters.count == 1)
        #expect(chapters[0].sourceDayKeys == ["2026-07-02", "2026-07-09"])
    }

    @Test func aChapterWhoseDaysAreGoneIsRemoved() async throws {
        let fixture = try makeFixture(days: [("2026-07-02", "fp-a")])
        let generator = RecordingChapterGenerator()
        _ = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        for entry in try fixture.context.fetch(FetchDescriptor<DailyBiographyEntry>()) {
            fixture.context.delete(entry)
        }
        try fixture.context.save()
        _ = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        #expect(try fixture.context.fetch(FetchDescriptor<StoryChapter>()).isEmpty)
    }

    @Test func aResponseCitingUnknownDaysIsRejected() async throws {
        let fixture = try makeFixture(days: [("2026-07-02", "fp-a")])
        let generator = RecordingChapterGenerator(citation: "2026-12-31")

        let written = try await StoryChapterRunner.refresh(
            userProfile: fixture.profile, generator: generator,
            in: fixture.context, now: now, calendar: utcCalendar
        )

        #expect(written == 0)
        #expect(try fixture.context.fetch(FetchDescriptor<StoryChapter>()).isEmpty)
    }

    @Test func sentencesGroupIntoParagraphs() {
        let prose = StoryChapterRunner.paragraphs(
            from: (1...9).map { "S\($0)." }, perParagraph: 4
        )
        #expect(prose == "S1. S2. S3. S4.\n\nS5. S6. S7. S8.\n\nS9.")
    }

    // MARK: Fixtures

    private var utcCalendar: JournalCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return JournalCalendar(calendar: calendar)
    }

    private func makeFixture(days: [(String, String)]) throws -> ChapterFixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(
            name: "Maya", hometown: "Portland", birthYear: 1990, remoteProcessingConsentedAt: now
        )
        context.insert(profile)
        for (day, fingerprint) in days {
            context.insert(entry(day: day, fingerprint: fingerprint))
        }
        try context.save()
        return ChapterFixture(context: context, profile: profile)
    }

    private func entry(day: String, fingerprint: String) -> DailyBiographyEntry {
        DailyBiographyEntry(
            dayKey: day,
            calendarDate: ISO8601DateFormatter().date(from: day + "T00:00:00Z")!,
            sourceStoryIds: [UUID()],
            sourceTranscriptArtifactIds: [UUID()],
            sourceTranscriptVersionIds: [UUID()],
            sourceFingerprint: fingerprint,
            timezoneIdentifiers: ["UTC"],
            title: "Title \(day)",
            prose: "Prose for \(day).",
            combinedTranscript: "Transcript \(day).",
            provider: provenance()
        )
    }
}

@MainActor
private struct ChapterFixture {
    let context: ModelContext
    let profile: UserProfile
}

private func provenance() -> RemoteProcessingProvenance {
    let processedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return RemoteProcessingProvenance(
        providerId: "fireworks",
        modelAlias: "story-chapter-v1",
        modelId: "test-model",
        modelPolicyVersion: "test-policy",
        providerRequestId: "chapter-test",
        processedAt: processedAt,
        processingDurationMilliseconds: 8,
        retentionAttestation: RemoteRetentionAttestation(
            mode: .zeroDataRetention,
            maximumRetentionSeconds: 0,
            policyVersion: "test-policy",
            attestedAt: processedAt
        )
    )
}

private final class RecordingChapterGenerator: DailyEntryGenerationService, @unchecked Sendable {
    private let citation: String?
    private let lock = NSLock()
    private var recorded: [StoryChapterGenerationRequest] = []

    init(citation: String? = nil) { self.citation = citation }

    var requests: [StoryChapterGenerationRequest] {
        lock.withLock { recorded }
    }

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.notConfigured
    }

    func generateStoryChapter(
        _ request: StoryChapterGenerationRequest
    ) async throws -> StoryChapterGenerationResponse {
        lock.withLock { recorded.append(request) }
        let ids = citation.map { [$0] } ?? request.sourceDays.map(\.id)
        return StoryChapterGenerationResponse(
            schemaVersion: StoryChapterGenerationRequest.currentSchemaVersion,
            promptVersion: request.promptVersion,
            jobId: request.jobId,
            requestId: "chapter-test",
            entry: GroundedJournalEntry(
                title: "A month",
                titleSourceReferences: ids,
                perspective: .thirdPerson,
                sentences: ids.map {
                    GroundedJournalSentence(
                        text: "Something happened on \($0).",
                        sourceReferences: [$0],
                        factReferences: [],
                        preservesUncertainty: false
                    )
                }
            ),
            provenance: provenance()
        )
    }
}
