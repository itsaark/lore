import SwiftUI

/// The autobiography so far: one chapter per month, written by Lore from the
/// days already recorded. A chapter appears once a month has at least one
/// finished day, and is rewritten as more of that month's days finish.
struct StoryBookView: View {
    let chapters: [StoryChapter]
    let dailyEntries: [DailyBiographyEntry]

    private let journalCalendar = JournalCalendar()

    private struct Page: Identifiable {
        let monthKey: String
        let number: Int
        let chapter: StoryChapter?
        var id: String { monthKey }
    }

    /// Every month that has a chapter or a finished day waiting for one, in
    /// order. A month without a chapter yet shows a quiet placeholder.
    private var pages: [Page] {
        let pending = Set(StoryChapterRunner.staleMonthKeys(
            entries: dailyEntries,
            chapters: [],
            now: Date(),
            calendar: journalCalendar
        ))
        let keys = Set(chapters.map(\.chapterKey)).union(pending).sorted()
        return keys.enumerated().map { index, key in
            Page(
                monthKey: key,
                number: index + 1,
                chapter: chapters.first { $0.chapterKey == key }
            )
        }
    }

    var body: some View {
        let pages = pages
        ScrollView {
            if pages.isEmpty {
                Text("Your story gathers one month at a time. Once a day has finished, Lore starts writing that month's chapter.")
                    .font(LoreTheme.caption(.body))
                    .foregroundStyle(LoreTheme.tertiaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            } else {
                LazyVStack(alignment: .leading, spacing: 56) {
                    ForEach(pages) { page in
                        chapterView(page)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 56)
            }
        }
        .scrollIndicators(.hidden)
        .loreCanvas()
        .navigationTitle("Your story")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .accessibilityIdentifier("storyBookView")
    }

    private func monthLabel(_ key: String) -> String {
        guard let date = journalCalendar.date(forDayKey: key + "-01") else { return key }
        return journalCalendar.monthTitle(for: date)
    }

    private func chapterView(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Chapter \(page.number) · \(monthLabel(page.monthKey))")
                .font(LoreTheme.eyebrow)
                .foregroundStyle(LoreTheme.secondaryInk)
                .textCase(.uppercase)

            if let chapter = page.chapter {
                Text(chapter.title)
                    .font(LoreTheme.display(30))
                    .foregroundStyle(LoreTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(
                        Array(chapter.prose.components(separatedBy: "\n\n").enumerated()),
                        id: \.offset
                    ) { _, paragraph in
                        Text(paragraph)
                            .font(LoreTheme.body)
                            .foregroundStyle(LoreTheme.ink.opacity(0.9))
                            .lineSpacing(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            } else {
                Text("Lore is writing this chapter.")
                    .font(LoreTheme.caption(.body))
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
