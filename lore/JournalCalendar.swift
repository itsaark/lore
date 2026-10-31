import Foundation

/// One local calendar day on the journal home. `dayKey` matches
/// `DailyBiographyEntry.dayKey` and `DayPhoto.dayKey`.
struct JournalDay: Hashable, Identifiable {
    let dayKey: String
    /// Local start of the day.
    let date: Date

    var id: String { dayKey }
}

struct JournalWeek: Hashable, Identifiable {
    let weekNumber: Int
    /// Seven consecutive days starting on the calendar's first weekday.
    let days: [JournalDay]

    var id: String { days.first?.dayKey ?? "" }
    var start: Date { days.first?.date ?? .distantPast }
    var end: Date { days.last?.date ?? .distantPast }
}

struct JournalMonth: Hashable, Identifiable {
    let year: Int
    let month: Int
    /// Every day of the month in order.
    let days: [JournalDay]
    /// Empty grid cells before the first day so it lands under its weekday.
    let leadingBlankCount: Int

    var id: String { String(format: "%04d-%02d", year, month) }
    var firstDate: Date { days.first?.date ?? .distantPast }
}

/// Pure week and month bucketing for the calendar home. All dates are local
/// days in `calendar`'s time zone, and weeks follow its `firstWeekday`.
struct JournalCalendar {
    /// Upper bound on how far back the home lists weeks or months.
    static let maximumWeekCount = 520
    static let maximumMonthCount = 120

    let calendar: Calendar
    private let dayKeyFormatter: DateFormatter
    private let rangeFormatter: DateIntervalFormatter
    private let monthTitleFormatter: DateFormatter

    init(calendar: Calendar = .autoupdatingCurrent) {
        var calendar = calendar
        // Day keys are always Gregorian, so bucketing must be too.
        if calendar.identifier != .gregorian {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.locale = calendar.locale
            gregorian.timeZone = calendar.timeZone
            gregorian.firstWeekday = calendar.firstWeekday
            gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
            calendar = gregorian
        }
        self.calendar = calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayKeyFormatter = formatter

        let range = DateIntervalFormatter()
        range.calendar = calendar
        range.locale = calendar.locale ?? .current
        range.timeZone = calendar.timeZone
        range.dateTemplate = "dMMM"
        rangeFormatter = range

        let monthTitle = DateFormatter()
        monthTitle.calendar = calendar
        monthTitle.locale = calendar.locale ?? .current
        monthTitle.timeZone = calendar.timeZone
        monthTitle.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        monthTitleFormatter = monthTitle
    }

    func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// Local start of the day a key names, or nil for a malformed key.
    func date(forDayKey dayKey: String) -> Date? {
        let values = dayKey.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        let components = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == values[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    func day(for date: Date) -> JournalDay {
        let start = calendar.startOfDay(for: date)
        return JournalDay(dayKey: dayKey(for: start), date: start)
    }

    func weekNumber(for date: Date) -> Int {
        calendar.component(.weekOfYear, from: date)
    }

    func week(containing date: Date) -> JournalWeek {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let days = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map(day(for:))
        }
        return JournalWeek(weekNumber: weekNumber(for: start), days: days)
    }

    /// Weeks from the one containing `today` back to the one containing
    /// `earliest`, newest first.
    func weeks(from earliest: Date, through today: Date) -> [JournalWeek] {
        var weeks: [JournalWeek] = []
        var cursor = week(containing: today)
        let earliestStart = week(containing: min(earliest, today)).start
        while weeks.count < Self.maximumWeekCount {
            weeks.append(cursor)
            guard cursor.start > earliestStart,
                  let previous = calendar.date(byAdding: .day, value: -7, to: cursor.start) else { break }
            cursor = week(containing: previous)
        }
        return weeks
    }

    func month(containing date: Date) -> JournalMonth {
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let days = (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map(day(for:))
        }
        let weekday = calendar.component(.weekday, from: start)
        return JournalMonth(
            year: components.year ?? 0,
            month: components.month ?? 0,
            days: days,
            leadingBlankCount: (weekday - calendar.firstWeekday + 7) % 7
        )
    }

    /// Months from the one containing `today` back to the one containing
    /// `earliest`, newest first.
    func months(from earliest: Date, through today: Date) -> [JournalMonth] {
        var months: [JournalMonth] = []
        var cursor = month(containing: today)
        let earliestStart = month(containing: min(earliest, today)).firstDate
        while months.count < Self.maximumMonthCount {
            months.append(cursor)
            guard cursor.firstDate > earliestStart,
                  let previous = calendar.date(byAdding: .day, value: -1, to: cursor.firstDate) else { break }
            cursor = month(containing: previous)
        }
        return months
    }

    /// Weekday symbols ordered from the calendar's first weekday.
    var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// "20–26 Oct" or "27 Oct – 2 Nov", ordered for the calendar's locale.
    func rangeLabel(for week: JournalWeek) -> String {
        rangeFormatter.string(from: week.start, to: week.end)
    }

    /// "October 2026".
    func monthTitle(for date: Date) -> String {
        monthTitleFormatter.string(from: date)
    }
}
