import Foundation
import Testing
@testable import lore

struct LifeDialTests {
    private let journal = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return JournalCalendar(calendar: calendar)
    }()

    private func date(_ key: String) -> Date { journal.date(forDayKey: key)! }

    private func dial(birthYear: Int? = 1990, earliest: Date? = nil, today: String = "2026-11-18") -> LifeDial {
        LifeDial(birthYear: birthYear, earliestData: earliest, now: date(today), calendar: journal.calendar)
    }

    private func unit(_ key: String, at level: LifeDial.Level, in dial: LifeDial) -> LifeDial.Selection {
        LifeDial.Selection(level: level, index: dial.index(of: date(key), at: level))
    }

    @Test func rangesAndIndicesRoundTripAtBothEndsOfEveryLevel() throws {
        let dial = dial()
        let dates = ["1990-01-01", "1995-12-31", "1996-01-01", "2000-02-29",
                     "2002-01-01", "2025-12-31", "2026-01-01", "2026-11-18"]

        for level in dial.levels {
            for key in dates {
                let selection = unit(key, at: level, in: dial)
                let range = try #require(dial.range(of: selection))
                #expect(range.contains(date(key)))
                #expect(dial.index(of: range.lowerBound, at: level) == selection.index)
                #expect(dial.index(of: range.upperBound.addingTimeInterval(-1), at: level) == selection.index)
                #expect(dial.selection(at: level, position: selection.center) == selection)
                if selection.index < dial.lastIndex(at: level) {
                    #expect(dial.index(of: range.upperBound, at: level) == selection.index + 1)
                }
            }
            #expect(dial.range(of: LifeDial.Selection(level: level, index: -1)) == nil)
            #expect(dial.range(of: LifeDial.Selection(level: level, index: dial.lastIndex(at: level) + 1)) == nil)
        }
    }

    @Test func weeksStartOnMondayAndSpanTheYearBoundary() throws {
        let dial = dial(birthYear: 2025)
        let first = try #require(dial.range(of: unit("2025-01-01", at: .week, in: dial)))
        #expect(first.lowerBound == date("2025-01-01"))
        #expect(first.upperBound == date("2025-01-06"))

        let selection = unit("2026-01-01", at: .week, in: dial)
        let range = try #require(dial.range(of: selection))
        #expect(range.lowerBound == date("2025-12-29"))
        #expect(range.upperBound == date("2026-01-05"))
        #expect(dial.tickLabel(for: selection) == "2026")
        #expect(dial.labels(for: selection) == .init(title: "Dec 29 – Jan 4", subtitle: "2025 – 2026"))
        #expect(dial.labels(for: unit("2026-11-18", at: .week, in: dial)).title == "Nov 16 – 22")
    }

    @Test func monthYearAndLeapDayBoundariesUseCalendarDays() throws {
        let dial = dial()
        let leapDay = unit("2000-02-29", at: .day, in: dial)
        #expect(dial.range(of: leapDay) == date("2000-02-29")..<date("2000-03-01"))
        let february = unit("2000-02-29", at: .month, in: dial)
        #expect(dial.range(of: february) == date("2000-02-01")..<date("2000-03-01"))
        #expect(unit("2000-03-01", at: .month, in: dial).index == february.index + 1)
        let year = unit("2000-12-31", at: .year, in: dial)
        #expect(dial.range(of: year) == date("2000-01-01")..<date("2001-01-01"))
        #expect(unit("2001-01-01", at: .year, in: dial).index == year.index + 1)

        let springForward = unit("2026-03-08", at: .day, in: dial)
        let range = try #require(dial.range(of: springForward))
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == 23 * 3600)
        #expect(unit("2026-03-09", at: .day, in: dial).index == springForward.index + 1)
    }

    @Test func clampsToBirthAndTodayWithAnInclusiveLastDay() throws {
        let dial = dial()
        for level in dial.levels {
            let latest = dial.lastIndex(at: level)
            #expect(dial.index(of: date("1989-12-31"), at: level) == 0)
            #expect(dial.index(of: date("2026-11-19"), at: level) == latest)
            #expect(dial.clamp(-20, at: level) == 0.5)
            #expect(dial.clamp(Double(latest + 20), at: level) == Double(latest) + 0.5)
            let current = try #require(dial.range(of: unit("2026-11-18", at: level, in: dial)))
            #expect(current.contains(dial.today))
            #expect(current.upperBound == date("2026-11-19"))
        }
    }

    @Test func missingBirthYearUsesDataOrThirtyYearsAndHidesPeriods() {
        let withData = dial(birthYear: 0, earliest: date("2019-03-13"))
        #expect(withData.start == date("2019-03-13"))
        #expect(withData.levels == [.year, .month, .week, .day])
        #expect(withData.range(of: .init(level: .period, index: 0)) == nil)
        #expect(withData.zoom(from: unit("2026-11-18", at: .year, in: withData), towardFiner: false) == nil)
        let withoutData = dial(birthYear: nil)
        #expect(withoutData.start == date("1996-11-18"))
        #expect(dial(birthYear: 2027).birthYear == nil)
    }

    @Test func ageBasedPeriodsHaveNoGapsAndEndToday() {
        let dial = dial()
        #expect(dial.periods.map(\.title) == [
            "Early childhood", "School years", "Teenage years", "College years", "First jobs",
            "Ages 26–29", "Ages 30–33", "Ages 34–36"
        ])
        #expect(dial.periods.map(\.startYear) == [1990, 1996, 2002, 2008, 2012, 2016, 2020, 2024])
        #expect(dial.periods.map(\.endYear) == [1995, 2001, 2007, 2011, 2015, 2019, 2023, 2026])
        #expect(dial.labels(for: unit("2008-01-01", at: .period, in: dial)).subtitle == "2008 – 2011")
        #expect(dial.labels(for: unit("2026-11-18", at: .period, in: dial)).subtitle == "2024 – today")
        #expect(LifeDial.draftPeriods(birthYear: 2024, through: 2026) == [
            .init(title: "Early childhood", startYear: 2024, endYear: 2026)
        ])
        #expect(LifeDial.draftPeriods(birthYear: 2027, through: 2026).isEmpty)
    }

    @Test func zoomThroughCurrentUnitsLandsOnTodayAndPastUnitsUseTheirCenter() throws {
        let dial = dial(today: "2026-11-29")
        var current = unit("2026-11-29", at: .period, in: dial)
        for level in [LifeDial.Level.year, .month, .week, .day] {
            current = try #require(dial.zoom(from: current, towardFiner: true))
            #expect(current == unit("2026-11-29", at: level, in: dial))
        }
        #expect(dial.labels(for: current) == .init(title: "Today", subtitle: "November 29, 2026"))
        #expect(dial.zoom(from: current, towardFiner: true) == nil)

        let pastMonth = unit("2026-10-01", at: .month, in: dial)
        let week = try #require(dial.zoom(from: pastMonth, towardFiner: true))
        #expect(week == unit("2026-10-16", at: .week, in: dial))
        #expect(dial.zoom(from: week, towardFiner: false) == pastMonth)
    }

    @Test func picturePickIsStableAndPrefersCoversThenPhotos() {
        let selection = LifeDial.Selection(level: .year, index: 3)
        let first = LifeDial.PictureCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .cover)
        let second = LifeDial.PictureCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, kind: .cover)
        let photo = LifeDial.PictureCandidate(id: UUID(), kind: .photo)
        let painting = LifeDial.PictureCandidate(id: UUID(), kind: .illustration)
        let candidates = [second, painting, first, photo]
        let picked = LifeDial.pickPicture(from: candidates, for: selection)

        #expect(picked == second.id)
        #expect(picked == LifeDial.pickPicture(from: Array(candidates.reversed()), for: selection))
        #expect(LifeDial.pickPicture(from: [painting, photo], for: selection) == photo.id)
        #expect(LifeDial.pickPicture(from: [painting], for: selection) == painting.id)
        #expect(LifeDial.pickPicture(from: [], for: selection) == nil)
    }
}
