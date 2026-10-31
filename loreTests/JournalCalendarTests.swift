import CoreGraphics
import Foundation
import Testing
@testable import lore

struct JournalCalendarTests {
    /// Monday-first weeks with ISO numbering, as in most of Europe.
    private func isoCalendar(timeZone: String = "Europe/London") -> JournalCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return JournalCalendar(calendar: calendar)
    }

    /// Sunday-first weeks, as in the US.
    private func usCalendar() -> JournalCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return JournalCalendar(calendar: calendar)
    }

    private func date(_ dayKey: String, hour: Int = 12, in calendar: JournalCalendar) -> Date {
        calendar.calendar.date(byAdding: .hour, value: hour, to: calendar.date(forDayKey: dayKey)!)!
    }

    @Test func dayKeysRoundTripInLocalTime() {
        let calendar = isoCalendar(timeZone: "Asia/Kolkata")
        let lateEvening = date("2026-10-30", hour: 23, in: calendar)

        #expect(calendar.dayKey(for: lateEvening) == "2026-10-30")
        #expect(calendar.dayKey(for: calendar.date(forDayKey: "2026-10-30")!) == "2026-10-30")
    }

    @Test func malformedDayKeysAreRejected() {
        let calendar = isoCalendar()

        #expect(calendar.date(forDayKey: "2026-10") == nil)
        #expect(calendar.date(forDayKey: "not-a-day") == nil)
        #expect(calendar.date(forDayKey: "2026-02-30") == nil)
    }

    @Test func weekStartsOnLocaleFirstWeekday() {
        let iso = isoCalendar().week(containing: date("2026-10-30", in: isoCalendar()))
        #expect(iso.days.map(\.dayKey).first == "2026-10-26")
        #expect(iso.days.map(\.dayKey).last == "2026-11-01")
        #expect(iso.days.count == 7)
        #expect(iso.weekNumber == 44)

        let us = usCalendar().week(containing: date("2026-10-30", in: usCalendar()))
        #expect(us.days.first?.dayKey == "2026-10-25")
        #expect(us.days.last?.dayKey == "2026-10-31")
    }

    @Test func weekNumberFollowsIsoRulesAcrossYearBoundary() {
        let calendar = isoCalendar()

        // 1 January 2027 is a Friday, so it belongs to week 53 of 2026.
        #expect(calendar.weekNumber(for: date("2027-01-01", in: calendar)) == 53)
        #expect(calendar.weekNumber(for: date("2027-01-04", in: calendar)) == 1)
    }

    @Test func weeksRunNewestFirstFromTodayBackToEarliest() {
        let calendar = isoCalendar()
        let weeks = calendar.weeks(
            from: date("2026-10-08", in: calendar),
            through: date("2026-10-30", in: calendar)
        )

        #expect(weeks.map(\.id) == ["2026-10-26", "2026-10-19", "2026-10-12", "2026-10-05"])
        #expect(weeks.map(\.weekNumber) == [44, 43, 42, 41])
    }

    @Test func weeksAcrossDaylightSavingChangeStayContiguous() {
        // UK clocks go back on 25 October 2026.
        let calendar = isoCalendar()
        let weeks = calendar.weeks(
            from: date("2026-10-19", in: calendar),
            through: date("2026-10-27", in: calendar)
        )

        #expect(weeks.count == 2)
        #expect(weeks[1].days.map(\.dayKey) == [
            "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22",
            "2026-10-23", "2026-10-24", "2026-10-25",
        ])
    }

    @Test func earliestDayAfterTodayYieldsOnlyCurrentWeek() {
        let calendar = isoCalendar()
        let weeks = calendar.weeks(
            from: date("2026-12-01", in: calendar),
            through: date("2026-10-30", in: calendar)
        )

        #expect(weeks.map(\.id) == ["2026-10-26"])
    }

    @Test func monthsHaveEveryDayAndLeadingBlanks() {
        let iso = isoCalendar()
        let october = iso.month(containing: date("2026-10-30", in: iso))
        #expect(october.id == "2026-10")
        #expect(october.days.count == 31)
        #expect(october.days.first?.dayKey == "2026-10-01")
        // 1 October 2026 is a Thursday: Mon, Tue, Wed come first.
        #expect(october.leadingBlankCount == 3)

        let us = usCalendar()
        #expect(us.month(containing: date("2026-10-30", in: us)).leadingBlankCount == 4)

        let february = iso.month(containing: date("2028-02-10", in: iso))
        #expect(february.days.count == 29)
    }

    @Test func monthsRunNewestFirstAcrossYears() {
        let calendar = isoCalendar()
        let months = calendar.months(
            from: date("2025-11-20", in: calendar),
            through: date("2026-01-05", in: calendar)
        )

        #expect(months.map(\.id) == ["2026-01", "2025-12", "2025-11"])
    }

    @Test func weekdaySymbolsStartOnFirstWeekday() {
        #expect(isoCalendar().orderedWeekdaySymbols == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(usCalendar().orderedWeekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
    }

    @Test func rangeLabelsUseShortMonths() {
        let calendar = isoCalendar()
        let sameMonth = calendar.week(containing: date("2026-10-21", in: calendar))
        let crossesMonth = calendar.week(containing: date("2026-10-30", in: calendar))

        // ICU spaces the dash with thin or narrow spaces depending on the OS.
        func normalized(_ label: String) -> String {
            label.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        }
        #expect(normalized(calendar.rangeLabel(for: sameMonth)) == "19–25Oct")
        #expect(normalized(calendar.rangeLabel(for: crossesMonth)) == "26Oct–1Nov")
        #expect(calendar.monthTitle(for: date("2026-10-30", in: calendar)) == "October 2026")
    }

    @MainActor
    @Test func dayContentGroupsEntriesAndUnconsolidatedNotes() {
        let calendar = isoCalendar()
        let consolidated = Story(text: "Morning.", date: date("2026-10-29", hour: 9, in: calendar), duration: 10, biographyProse: "Morning prose.")
        let draft = Story(text: "Late.", date: date("2026-10-30", hour: 22, in: calendar), duration: 10, biographyProse: "Late prose.", title: "A late walk")
        let pending = Story(text: "", date: date("2026-10-30", hour: 8, in: calendar), duration: 10)
        let entry = DailyBiographyEntry(
            dayKey: "2026-10-29",
            calendarDate: date("2026-10-29", in: calendar),
            sourceStoryIds: [consolidated.id],
            sourceTranscriptArtifactIds: [],
            sourceTranscriptVersionIds: [],
            sourceFingerprint: "",
            timezoneIdentifiers: [],
            title: "Thursday by the river",
            prose: "Entry prose.",
            combinedTranscript: "Morning.",
            provider: RemoteProcessingProvenance(
                providerId: "test",
                modelAlias: "daily-entry-v1",
                modelId: "test-model",
                modelPolicyVersion: "test-policy",
                providerRequestId: nil,
                processedAt: Date(),
                processingDurationMilliseconds: 1,
                retentionAttestation: RemoteRetentionAttestation(
                    mode: .zeroDataRetention,
                    maximumRetentionSeconds: 0,
                    policyVersion: "test-policy",
                    attestedAt: Date()
                )
            )
        )

        let index = JournalDayContent.index(
            stories: [draft, consolidated, pending],
            dailyEntries: [entry],
            storyDayKeys: [:],
            calendar: calendar
        )

        #expect(Set(index.keys) == ["2026-10-29", "2026-10-30"])
        #expect(index["2026-10-29"]?.title == "Thursday by the river")
        #expect(index["2026-10-29"]?.draftStories.isEmpty == true)
        #expect(index["2026-10-30"]?.stories.map(\.id) == [pending.id, draft.id])
        #expect(index["2026-10-30"]?.draftStories.map(\.id) == [draft.id])
        #expect(index["2026-10-30"]?.title == "A late walk")
        #expect(index["2026-10-30"]?.hasEntry == true)
    }

    @MainActor
    @Test func storyDayKeysOverrideCaptureDate() {
        let calendar = isoCalendar()
        let story = Story(text: "Travel.", date: date("2026-10-30", hour: 1, in: calendar), duration: 5)

        let index = JournalDayContent.index(
            stories: [story],
            dailyEntries: [],
            storyDayKeys: [story.id: "2026-10-29"],
            calendar: calendar
        )

        #expect(index["2026-10-29"]?.hasNotes == true)
        #expect(index["2026-10-29"]?.hasEntry == false)
        #expect(index["2026-10-30"] == nil)
    }

    // MARK: Zoom

    @Test func spreadingZoomsInAndPinchingZoomsOut() {
        let base = JournalDensity.week.zoom

        #expect(JournalZoom.zoom(base: base, magnification: 1) == base)
        #expect(JournalZoom.zoom(base: base, magnification: 2) == base + JournalZoom.levelsPerDoubling)
        #expect(JournalZoom.zoom(base: base, magnification: 0.5) < base)
    }

    @Test func zoomRubberBandsPastBothEnds() {
        let farOut = JournalZoom.zoom(base: JournalDensity.month.zoom, magnification: 0.05)
        let farIn = JournalZoom.zoom(base: JournalDensity.dayFull.zoom, magnification: 20)

        #expect(farOut < 0 && farOut > -JournalZoom.maximumOvershoot)
        #expect(farIn > 4 && farIn < 4 + JournalZoom.maximumOvershoot)
        // Resistance grows with distance: twice the drag is less than twice the overshoot.
        let small = JournalZoom.rubberBanded(4.2) - 4
        let large = JournalZoom.rubberBanded(4.4) - 4
        #expect(large > small && large < small * 2)
    }

    @Test func layoutSwitchesHalfwayBetweenLevels() {
        #expect(JournalZoom.layout(at: 0.49) == .month)
        #expect(JournalZoom.layout(at: 0.51) == .week)
        #expect(JournalZoom.layout(at: 1.49) == .week)
        #expect(JournalZoom.layout(at: 1.51) == .days)
        #expect(JournalZoom.layout(at: 3.9) == .days)
        #expect(JournalZoom.nearestLevel(-0.2) == .month)
        #expect(JournalZoom.nearestLevel(4.25) == .dayFull)
    }

    @Test func shortPinchesCommitOneStepAndTinyOnesSpringBack() {
        #expect(JournalZoom.snapTarget(base: .week, zoom: 1.2) == .week)
        #expect(JournalZoom.snapTarget(base: .week, zoom: 1.35) == .dayTitles)
        #expect(JournalZoom.snapTarget(base: .week, zoom: 0.8) == .week)
        #expect(JournalZoom.snapTarget(base: .week, zoom: 0.65) == .month)
        #expect(JournalZoom.snapTarget(base: .dayTitles, zoom: 3.4) == .dayFull)
        // Two whole steps plus a little settles on the second step.
        #expect(JournalZoom.snapTarget(base: .dayFull, zoom: 1.9) == .dayTitles)
        #expect(JournalZoom.snapTarget(base: .dayFull, zoom: 1.6) == .week)
    }

    @Test func snappingClampsAtTheEnds() {
        #expect(JournalZoom.snapTarget(base: .month, zoom: -0.3) == .month)
        #expect(JournalZoom.snapTarget(base: .dayFull, zoom: 4.3) == .dayFull)
    }

    @Test func proseRevealGrowsFromTitlesToFullText() {
        func reveal(_ zoom: Double, full: CGFloat = 300) -> CGFloat {
            JournalZoom.proseRevealHeight(zoom: zoom, fullHeight: full, previewHeight: 54)
        }

        #expect(reveal(1.6) == 0)
        #expect(reveal(2) == 0)
        #expect(reveal(2.5) == 27)
        #expect(reveal(3) == 54)
        #expect(reveal(3.5) == 177)
        #expect(reveal(4) == 300)
        #expect(reveal(4.2) == 300)
        // Short prose is fully shown by the preview level.
        #expect(reveal(3, full: 30) == 30)
        #expect(reveal(4, full: 30) == 30)
    }

    @Test func thumbnailAndProseFadeInAtTheirLevels() {
        #expect(JournalZoom.thumbnailProgress(zoom: 3) == 0)
        #expect(JournalZoom.thumbnailProgress(zoom: 3.5) == 0.5)
        #expect(JournalZoom.thumbnailProgress(zoom: 4.3) == 1)
        #expect(JournalZoom.proseOpacity(zoom: 2) == 0)
        #expect(JournalZoom.proseOpacity(zoom: 3) == 1)
    }

    // MARK: Scroll anchoring

    @Test func anchorIsNilWhileTheTopIsVisible() {
        let calendar = isoCalendar()

        #expect(JournalScrollID.anchorDayKey(
            visibleIDs: [JournalScrollID.top, "day-2026-10-29"],
            previous: "2026-10-01",
            calendar: calendar
        ) == nil)
        #expect(JournalScrollID.anchorDayKey(
            visibleIDs: [JournalScrollID.hero, "day-2026-10-29"],
            previous: nil,
            calendar: calendar
        ) == nil)
    }

    @Test func anchorIsTheNewestVisibleDay() {
        let anchor = JournalScrollID.anchorDayKey(
            visibleIDs: ["day-2026-10-20", "day-2026-10-27", "day-2026-10-22"],
            previous: nil,
            calendar: isoCalendar()
        )

        #expect(anchor == "2026-10-27")
    }

    @Test func anchorSurvivesZoomingOutAndBackIn() {
        let calendar = isoCalendar()

        // Reading 21 Oct in the day list, zoom out: week 19–25 Oct is on top.
        #expect(JournalScrollID.anchorDayKey(
            visibleIDs: ["week-2026-10-19", "week-2026-10-12", "weekSection-2026-10-12"],
            previous: "2026-10-21",
            calendar: calendar
        ) == "2026-10-21")
        // Out again to the month grid.
        #expect(JournalScrollID.anchorDayKey(
            visibleIDs: ["month-2026-10"],
            previous: "2026-10-21",
            calendar: calendar
        ) == "2026-10-21")
        // Without a previous day, a week anchors on its newest day and a month on its last.
        #expect(JournalScrollID.anchorDayKey(visibleIDs: ["week-2026-10-19"], previous: nil, calendar: calendar) == "2026-10-25")
        #expect(JournalScrollID.anchorDayKey(visibleIDs: ["month-2026-09"], previous: "2026-10-21", calendar: calendar) == "2026-09-30")
    }

    @Test func targetsFindTheAnchorInEachLayout() {
        let calendar = isoCalendar()
        let rows = ["2026-10-29", "2026-10-24", "2026-10-21", "2026-10-03"]

        #expect(JournalScrollID.target(for: "2026-10-21", in: .days, dayRowKeys: rows, calendar: calendar) == "day-2026-10-21")
        // A day with no row lands on the next older one.
        #expect(JournalScrollID.target(for: "2026-10-23", in: .days, dayRowKeys: rows, calendar: calendar) == "day-2026-10-21")
        #expect(JournalScrollID.target(for: "2026-09-01", in: .days, dayRowKeys: rows, calendar: calendar) == "day-2026-10-03")
        #expect(JournalScrollID.target(for: "2026-10-21", in: .days, dayRowKeys: [], calendar: calendar) == JournalScrollID.top)
        #expect(JournalScrollID.target(for: "2026-10-21", in: .week, dayRowKeys: rows, calendar: calendar) == "week-2026-10-19")
        #expect(JournalScrollID.target(for: "2026-10-21", in: .month, dayRowKeys: rows, calendar: calendar) == "month-2026-10")
    }
}
