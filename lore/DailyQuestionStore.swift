import Foundation
import SwiftData

/// Questions belong to a particular revision of a day story. This cache stays
/// in LoreLocal even though its source story can sync to another device.
@Model
final class DailyQuestionFollowUps {
    @Attribute(.unique) private(set) var sourceDayStoryID: UUID
    private(set) var sourceFingerprint: String
    private(set) var questions: [String]

    init(sourceDayStoryID: UUID, sourceFingerprint: String, questions: [String]) {
        self.sourceDayStoryID = sourceDayStoryID
        self.sourceFingerprint = sourceFingerprint
        self.questions = questions
    }

    func replace(sourceFingerprint: String, questions: [String]) {
        self.sourceFingerprint = sourceFingerprint
        self.questions = questions
    }
}

enum DailyQuestionOutcome: String {
    case answered
    case dismissed
}

@Model
final class DailyQuestionHistory {
    @Attribute(.unique) private(set) var dayKey: String
    private(set) var questionID: String?
    var questionText: String?
    private(set) var textKey: String?
    private(set) var sourceDayStoryID: UUID?
    private var outcomeValue: String?

    var outcome: DailyQuestionOutcome? {
        get { outcomeValue.flatMap(DailyQuestionOutcome.init(rawValue:)) }
        set { outcomeValue = newValue?.rawValue }
    }

    init(dayKey: String, presentation: DailyQuestionPresentation?) {
        self.dayKey = dayKey
        questionID = presentation?.question.id
        questionText = presentation?.question.text
        textKey = presentation?.question.textKey
        sourceDayStoryID = presentation?.sourceDayStoryID
    }
}

/// Survives audio cleanup and transcription retries without becoming part of
/// the synced Story or any processing request.
@Model
final class DailyQuestionCapture {
    @Attribute(.unique) private(set) var storyID: UUID
    private(set) var dayKey: String
    private(set) var questionID: String
    private(set) var promptQuestionText: String

    init(storyID: UUID, presentation: DailyQuestionPresentation) {
        self.storyID = storyID
        dayKey = presentation.dayKey
        questionID = presentation.question.id
        promptQuestionText = presentation.question.text
    }

    static func fetch(for storyID: UUID, in context: ModelContext) throws -> DailyQuestionCapture? {
        var descriptor = FetchDescriptor<DailyQuestionCapture>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

@MainActor
enum DailyQuestionStore {
    /// Claims the day's one presentation. An empty row also pins a day on
    /// which every question is cooling down.
    static func claim(
        on date: Date,
        calendar: JournalCalendar = JournalCalendar(),
        in context: ModelContext
    ) throws -> DailyQuestionPresentation? {
        let today = calendar.day(for: date)
        guard try history(for: today.dayKey, in: context) == nil else { return nil }

        // The 60-day window includes today.
        let cooldownStart = dayKey(daysBefore: 59, today: today, calendar: calendar)
        let followUpStart = dayKey(daysBefore: 14, today: today, calendar: calendar)
        let history = try context.fetch(FetchDescriptor<DailyQuestionHistory>())
        let recentKeys = Set(history.filter { $0.dayKey >= cooldownStart }.compactMap(\.textKey))
        let resolvedFollowUpKeys = Set(history.filter {
            $0.sourceDayStoryID != nil && $0.outcome != nil
        }.compactMap(\.textKey))
        let excluded = recentKeys.union(resolvedFollowUpKeys)
        let followUp = try nextFollowUp(
            from: followUpStart,
            through: today.dayKey,
            excluding: excluded,
            in: context
        )

        let lastEvergreenDisplay = Dictionary(
            history.filter { $0.sourceDayStoryID == nil }.compactMap { row in
                row.questionID.map { ($0, row.dayKey) }
            },
            uniquingKeysWith: { max($0, $1) }
        )
        let evergreen = followUp == nil ? DailyQuestion.evergreen
            .filter { !excluded.contains($0.textKey) }
            .min { (lastEvergreenDisplay[$0.id] ?? "") < (lastEvergreenDisplay[$1.id] ?? "") } : nil
        let presentation = followUp.map {
            DailyQuestionPresentation(dayKey: today.dayKey, question: $0.question, sourceDayStoryID: $0.sourceID)
        } ?? evergreen.map {
            DailyQuestionPresentation(dayKey: today.dayKey, question: $0, sourceDayStoryID: nil)
        }

        for row in history where row.dayKey < cooldownStart {
            guard let questionID = row.questionID else {
                context.delete(row)
                continue
            }
            if row.sourceDayStoryID != nil {
                if row.outcome != nil {
                    // Keep the suppression key without retaining old personal text.
                    row.questionText = nil
                } else {
                    context.delete(row)
                }
            } else if lastEvergreenDisplay[questionID] != row.dayKey {
                context.delete(row)
            }
        }
        context.insert(DailyQuestionHistory(dayKey: today.dayKey, presentation: presentation))
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return presentation
    }

    private static func dayKey(daysBefore: Int, today: JournalDay, calendar: JournalCalendar) -> String {
        let date = calendar.calendar.date(byAdding: .day, value: -daysBefore, to: today.date) ?? today.date
        return calendar.dayKey(for: date)
    }

    private static func nextFollowUp(
        from firstDay: String,
        through today: String,
        excluding excluded: Set<String>,
        in context: ModelContext
    ) throws -> (question: DailyQuestion, sourceID: UUID)? {
        let sources = try context.fetch(FetchDescriptor<DailyBiographyEntry>(
            predicate: #Predicate { $0.memoryStoryId == nil && $0.dayKey >= firstDay && $0.dayKey <= today },
            sortBy: [SortDescriptor(\.dayKey, order: .reverse), SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        let cache = try context.fetch(FetchDescriptor<DailyQuestionFollowUps>())
        let followUps = Dictionary(cache.map { ($0.sourceDayStoryID, $0) }, uniquingKeysWith: { first, _ in first })
        var seenDays = Set<String>()
        for source in sources where seenDays.insert(source.dayKey).inserted {
            guard let cached = followUps[source.id], cached.sourceFingerprint == source.sourceFingerprint else {
                continue
            }
            for text in cached.questions {
                let question = DailyQuestion.followUp(text)
                if !excluded.contains(question.textKey) { return (question, source.id) }
            }
        }
        return nil
    }

    static func history(for dayKey: String, in context: ModelContext) throws -> DailyQuestionHistory? {
        var descriptor = FetchDescriptor<DailyQuestionHistory>(predicate: #Predicate { $0.dayKey == dayKey })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func dismiss(_ presentation: DailyQuestionPresentation, in context: ModelContext) throws {
        guard let row = try history(for: presentation.dayKey, in: context),
              row.questionID == presentation.question.id,
              row.outcome == nil else { return }
        row.outcome = .dismissed
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    static func markAnswered(storyID: UUID, transcript: String, in context: ModelContext) throws {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let capture = try DailyQuestionCapture.fetch(for: storyID, in: context),
              let row = try history(for: capture.dayKey, in: context),
              row.questionID == capture.questionID,
              row.outcome == nil else { return }
        row.outcome = .answered
    }

    static func saveFollowUps(
        for source: DailyBiographyEntry,
        response: DailyEntryGenerationResponse,
        request: DailyEntryGenerationRequest,
        in context: ModelContext
    ) throws {
        let validSources = Set(request.sourceSegments.map(\.id))
        let sensitiveSources = Set(response.sensitiveOmissions.flatMap(\.sourceReferences))
        let eligible = eligibleQuestions(
            response.followUpQuestions, validSources: validSources, sensitiveSources: sensitiveSources
        )
        let sourceID = source.id
        let existing = try context.fetch(FetchDescriptor<DailyQuestionFollowUps>(
            predicate: #Predicate { $0.sourceDayStoryID == sourceID }
        )).first
        if let existing {
            if eligible.isEmpty {
                context.delete(existing)
            } else {
                existing.replace(sourceFingerprint: source.sourceFingerprint, questions: eligible)
            }
        } else if !eligible.isEmpty {
            context.insert(DailyQuestionFollowUps(
                sourceDayStoryID: source.id, sourceFingerprint: source.sourceFingerprint, questions: eligible
            ))
        }
    }

    static func eligibleQuestions(
        _ followUps: [JournalFollowUpQuestion],
        validSources: Set<String>,
        sensitiveSources: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        let questionMarks: Set<Character> = ["?", "？", "؟", "՞"]
        return followUps.compactMap { followUp in
            let text = followUp.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let references = Set(followUp.sourceReferences)
            guard !references.isEmpty, references.isSubset(of: validSources),
                  references.isDisjoint(with: sensitiveSources),
                  text.count <= 120, text.rangeOfCharacter(from: .newlines) == nil,
                  text.contains(where: \.isLetter),
                  let last = text.last, questionMarks.contains(last),
                  text.dropLast().allSatisfy({ !questionMarks.contains($0) }) else { return nil }
            return seen.insert(DailyQuestion.followUp(text).textKey).inserted ? text : nil
        }
    }

    /// Source deletion also erases its wording from the ledger, retaining the
    /// hash so a dismissed question stays suppressed if another story asks it.
    @discardableResult
    static func removeFollowUps(for sourceIDs: Set<UUID>, in context: ModelContext) throws -> Int {
        guard !sourceIDs.isEmpty else { return 0 }
        var count = 0
        for cached in try context.fetch(FetchDescriptor<DailyQuestionFollowUps>())
            where sourceIDs.contains(cached.sourceDayStoryID) {
            context.delete(cached)
            count += 1
        }
        for row in try context.fetch(FetchDescriptor<DailyQuestionHistory>()) {
            if let sourceID = row.sourceDayStoryID, sourceIDs.contains(sourceID), row.questionText != nil {
                row.questionText = nil
                count += 1
            }
        }
        return count
    }

    static func reconcileFollowUps(in context: ModelContext) throws -> Bool {
        let sources = try context.fetch(FetchDescriptor<DailyBiographyEntry>())
        let revisions = Dictionary(
            sources.map { ($0.id, $0.sourceFingerprint) }, uniquingKeysWith: { current, _ in current }
        )
        let cached = try context.fetch(FetchDescriptor<DailyQuestionFollowUps>())
        let superseded = cached.filter {
            guard let revision = revisions[$0.sourceDayStoryID] else { return false }
            return $0.sourceFingerprint != revision
        }
        let shown = try context.fetch(FetchDescriptor<DailyQuestionHistory>())
        let referenced = Set(cached.map(\.sourceDayStoryID) + shown.compactMap(\.sourceDayStoryID))
        superseded.forEach(context.delete)
        let removed = try removeFollowUps(for: referenced.subtracting(revisions.keys), in: context)
        return !superseded.isEmpty || removed > 0
    }
}
