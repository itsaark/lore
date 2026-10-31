import Foundation

/// Everything the journal knows about one local day: its consolidated entry,
/// the voice notes captured that day, and which of those notes already carry
/// prose that has not been folded into a daily entry yet.
struct JournalDayContent {
    let dayKey: String
    fileprivate(set) var entries: [DailyBiographyEntry] = []
    /// Every voice note captured that day, oldest first.
    fileprivate(set) var stories: [Story] = []
    /// Notes with prose that no daily entry covers yet, oldest first.
    fileprivate(set) var draftStories: [Story] = []

    var entry: DailyBiographyEntry? { entries.first }
    var hasEntry: Bool { !entries.isEmpty || !draftStories.isEmpty }
    var hasNotes: Bool { !stories.isEmpty }

    var title: String? {
        if let entry { return entry.title.trimmed.nilIfEmpty }
        return draftStories.lazy.compactMap { $0.title?.trimmed.nilIfEmpty }.first
    }

    var noteCount: Int {
        max(stories.count, entry?.noteCount ?? 0)
    }

    /// Groups entries and notes by day key. Notes fall back to their local
    /// capture day when `storyDayKeys` has no key for them.
    static func index(
        stories: [Story],
        dailyEntries: [DailyBiographyEntry],
        storyDayKeys: [UUID: String],
        calendar: JournalCalendar = JournalCalendar()
    ) -> [String: JournalDayContent] {
        let compiledStoryIds = Set(dailyEntries.flatMap(\.sourceStoryIds))
        var index: [String: JournalDayContent] = [:]

        for entry in dailyEntries.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            index[entry.dayKey, default: Self(dayKey: entry.dayKey)].entries.append(entry)
        }
        for story in stories.sorted(by: { $0.date < $1.date }) {
            let dayKey = storyDayKeys[story.id] ?? calendar.dayKey(for: story.date)
            index[dayKey, default: Self(dayKey: dayKey)].stories.append(story)
            guard !compiledStoryIds.contains(story.id),
                  !(story.biographyProse ?? "").trimmed.isEmpty else { continue }
            index[dayKey]?.draftStories.append(story)
        }
        return index
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
