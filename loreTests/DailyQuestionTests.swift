import Foundation
import SwiftData
import Testing
@testable import lore

@MainActor
struct DailyQuestionTests {
    private let calendar = JournalCalendar(
        calendar: Calendar(identifier: .gregorian, timeZone: TimeZone(secondsFromGMT: 0)!)
    )
    private let baseDate = Date(timeIntervalSince1970: 1_767_225_600) // Jan 1, 2026 UTC.

    @Test func oncePerDayAndPinnedWhenNewFollowUpsArrive() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let original = try #require(try claim(0, in: context))

        let followUp = "What could you see from the ferry booth?"
        try insertDayStory(offset: 0, questions: [followUp], in: context)

        let reopened = ModelContext(container)
        #expect(try claim(0, in: reopened) == nil)
        let pinned = try DailyQuestionStore.history(for: original.dayKey, in: reopened)
        #expect(pinned?.questionID == original.question.id)
        #expect(pinned?.questionText == original.question.text)
        #expect(try claim(1, in: reopened)?.question.text == followUp)
    }

    @Test func prefersMostRecentFollowUpsAndRespectsTheLookback() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        try insertDayStory(offset: -15, questions: ["What did the old kitchen look like?"], in: context)
        try insertDayStory(offset: -8, questions: ["What did you hear from the porch?"], in: context)
        let newest = try insertDayStory(
            offset: -3,
            questions: ["What did you see from the stairs?", "What tune was playing?"],
            in: context
        )

        let selection = try #require(try claim(0, in: context))
        #expect(selection.sourceDayStoryID == newest.id)
        #expect(selection.question.text == "What did you see from the stairs?")
        #expect(try claim(1, in: context)?.question.text == "What tune was playing?")
        #expect(try claim(2, in: context)?.question.text == "What did you hear from the porch?")
        #expect(try claim(3, in: context)?.question.id == "e01")
    }

    @Test func evergreenOrderAndSixtyDayCooldown() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        #expect(DailyQuestion.evergreen.count == 40)
        for (offset, question) in DailyQuestion.evergreen.enumerated() {
            #expect(try claim(offset, in: context)?.question == question)
        }

        for offset in 40..<60 {
            #expect(try claim(offset, in: context) == nil)
        }

        try insertDayStory(offset: 59, questions: ["What did you see on your walk?"], in: context)
        #expect(try claim(59, in: context) == nil)
        #expect(try claim(60, in: context)?.sourceDayStoryID != nil)
        #expect(try claim(61, in: context)?.question.id == "e01")
        #expect(try claim(62, in: context)?.question.id == "e02")
    }

    @Test func normalizesRepeatedTextAndNeverReturnsADismissedFollowUp() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let text = "What’s on the kitchen shelf?"
        try insertDayStory(offset: -1, questions: [text], in: context)
        let selection = try #require(try claim(0, in: context))
        try DailyQuestionStore.dismiss(selection, in: context)
        #expect(try DailyQuestionStore.history(for: selection.dayKey, in: context)?.outcome == .dismissed)
        #expect(try claim(0, in: context) == nil)

        try insertDayStory(offset: 60, questions: ["WHAT'S  on the kitchen shelf?"], in: context)
        #expect(try claim(61, in: context)?.question.id == "e01")
        #expect(try claim(62, in: context)?.question.id == "e02")
    }

    @Test func unansweredFollowUpsCoolDownAcrossSources() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let text = "What did the old kitchen look like?"
        try insertDayStory(offset: -1, questions: [text], in: context)
        #expect(try claim(0, in: context)?.question.text == text)
        try insertDayStory(offset: 58, questions: [text.uppercased()], in: context)
        #expect(try claim(59, in: context)?.question.id == "e01")
        #expect(try claim(60, in: context)?.question.text == text.uppercased())
    }

    @Test func deletedSourceDropsItsQuestionsWithoutReplacingTodaysCard() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let source = try insertDayStory(
            offset: -1,
            questions: ["What could you hear outside the ferry booth?", "How did the window open?"],
            in: context
        )
        let selection = try #require(try claim(0, in: context))
        let noteID = try #require(source.sourceStoryIds.first)
        try DailyBiographyJobRunner.deleteSupportData(containing: noteID, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<DailyQuestionFollowUps>()) == 0)
        #expect(try DailyQuestionStore.history(for: selection.dayKey, in: context)?.questionText == nil)
        #expect(try claim(0, in: context) == nil)
        #expect(try claim(1, in: context)?.question.id == "e01")
    }

    @Test func rolloverUsesLocalMidnightAcrossDaylightSaving() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let local = JournalCalendar(
            calendar: Calendar(identifier: .gregorian, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        )
        let formatter = ISO8601DateFormatter()
        let early = try #require(formatter.date(from: "2026-03-08T08:00:00Z"))
        let justBeforeNextDay = try #require(formatter.date(from: "2026-03-09T06:59:59Z"))
        let nextDay = justBeforeNextDay.addingTimeInterval(1)

        let first = try DailyQuestionStore.claim(on: early, calendar: local, in: context)
        #expect(first?.dayKey == "2026-03-08")
        #expect(try DailyQuestionStore.claim(on: justBeforeNextDay, calendar: local, in: context) == nil)
        let second = try DailyQuestionStore.claim(on: nextDay, calendar: local, in: context)
        #expect(second?.dayKey == "2026-03-09")
        #expect(second?.question.id == "e02")
    }

    @Test func followUpFilterKeepsOnlyShortGroundedSingleQuestions() {
        let valid = "What was on the kitchen shelf?"
        let texts = [
            " \(valid) ", valid.uppercased(), "What? Why?", "What\nhappened?", "A statement.",
            "What did \(String(repeating: "x", count: 120)) look like?"
        ]
        let candidates = texts.map {
            JournalFollowUpQuestion(question: $0, reason: "", sourceReferences: ["safe"])
        } + [
            JournalFollowUpQuestion(question: "What was nearby?", reason: "", sourceReferences: ["omitted"]),
            JournalFollowUpQuestion(question: "What did you see?", reason: "", sourceReferences: ["unknown"]),
            JournalFollowUpQuestion(question: "What did you hear?", reason: "", sourceReferences: [])
        ]
        #expect(DailyQuestionStore.eligibleQuestions(
            candidates, validSources: ["safe", "omitted"], sensitiveSources: ["omitted"]
        ) == [valid])
    }

    @Test func captureKeepsItsPromptAndAnswersOriginalDayOnlyAfterTranscriptCommits() throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = container.mainContext
        let question = try #require(try claim(0, in: context))
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        try Data([1]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let capture = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(10),
            audioFileURL: audioURL,
            modelContext: context,
            question: question
        )

        let reopened = ModelContext(container)
        let prompt = try #require(try DailyQuestionCapture.fetch(for: capture.story.id, in: reopened))
        #expect(prompt.promptQuestionText == question.question.text)
        #expect(try DailyQuestionStore.history(for: question.dayKey, in: reopened)?.outcome == nil)
        #expect(try claim(0, in: reopened) == nil)
        let next = try #require(try claim(1, in: context))

        let asset = try #require(context.fetch(FetchDescriptor<AudioAsset>()).first)
        #expect(throws: RemoteSpeechTranscriptionError.emptyTranscript) {
            try SpeechRecognitionViewModel.commitRemoteTranscription(
                RemoteSpeechTranscription(transcript: " \n", provider: "test", model: "test"),
                for: capture.story, audioAsset: asset, job: capture.job,
                localeIdentifier: "en", modelContext: context
            )
        }
        #expect(try DailyQuestionStore.history(for: question.dayKey, in: context)?.outcome == nil)

        try SpeechRecognitionViewModel.commitRemoteTranscription(
            RemoteSpeechTranscription(transcript: "There was a blue lunch tin.", provider: "test", model: "test"),
            for: capture.story, audioAsset: asset, job: capture.job,
            localeIdentifier: "en", modelContext: context, at: baseDate.addingTimeInterval(86_500)
        )
        #expect(try DailyQuestionStore.history(for: question.dayKey, in: context)?.outcome == .answered)
        #expect(try DailyQuestionStore.history(for: next.dayKey, in: context)?.outcome == nil)
    }

    private func date(at offset: Int) -> Date {
        calendar.calendar.date(byAdding: .day, value: offset, to: baseDate)!
    }

    private func claim(_ offset: Int, in context: ModelContext) throws -> DailyQuestionPresentation? {
        try DailyQuestionStore.claim(on: date(at: offset), calendar: calendar, in: context)
    }

    @discardableResult
    private func insertDayStory(
        offset: Int,
        questions: [String],
        in context: ModelContext
    ) throws -> DailyBiographyEntry {
        let date = date(at: offset)
        let source = DailyBiographyEntry(
            dayKey: calendar.dayKey(for: date),
            calendarDate: date,
            sourceStoryIds: [UUID()],
            sourceTranscriptArtifactIds: [],
            sourceTranscriptVersionIds: [],
            sourceFingerprint: UUID().uuidString,
            timezoneIdentifiers: ["UTC"],
            title: "A day story",
            prose: "The day story.",
            combinedTranscript: "A journal note.",
            provider: .init(
                providerId: "test", modelAlias: "test", modelId: "test",
                modelPolicyVersion: "test", providerRequestId: "test", processedAt: date,
                processingDurationMilliseconds: 0,
                retentionAttestation: .init(
                    mode: .zeroDataRetention, maximumRetentionSeconds: 0, policyVersion: "test", attestedAt: date
                )
            )
        )
        context.insert(source)
        context.insert(DailyQuestionFollowUps(
            sourceDayStoryID: source.id, sourceFingerprint: source.sourceFingerprint, questions: questions
        ))
        try context.save()
        return source
    }
}

private extension Calendar {
    init(identifier: Identifier, timeZone: TimeZone) {
        self.init(identifier: identifier)
        self.timeZone = timeZone
    }
}
