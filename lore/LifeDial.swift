import Foundation

/// Calendar coordinates for the dial. Index zero is the first unit in the
/// archive's range, and an index plus one half is its detent on the ruler.
struct LifeDial: Equatable, Sendable {
    enum Level: Int, CaseIterable, Sendable {
        case period, year, month, week, day

        var spacing: Double {
            switch self {
            case .period: 46
            case .year: 14
            case .month: 12
            case .week: 14
            case .day: 11
            }
        }

        var name: String {
            switch self {
            case .period: "period"
            case .year: "year"
            case .month: "month"
            case .week: "week"
            case .day: "day"
            }
        }
    }

    struct Selection: Hashable, Sendable {
        let level: Level
        let index: Int

        var center: Double { Double(index) + 0.5 }
    }

    struct Period: Equatable, Sendable {
        let title: String
        let startYear: Int
        /// The last calendar year included, even when it ends partway through.
        let endYear: Int
    }

    struct Labels: Equatable, Sendable {
        let title: String
        let subtitle: String

        var accessibilityValue: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
    }

    struct PictureCandidate: Equatable, Sendable {
        enum Kind: Int, Sendable {
            case cover, photo, illustration
        }

        let id: UUID
        let kind: Kind
    }

    let calendar: Calendar
    let birthYear: Int?
    let start: Date
    let today: Date
    let periods: [Period]
    private let end: Date
    private let firstWeek: Date
    private let firstMonth: Date
    private let firstYear: Int
    private let months: [String]
    private let shortMonths: [String]
    private let weekdays: [String]
    private var lastIndices: [Level: Int] = [:]

    init(birthYear: Int?, earliestData: Date?, now: Date, calendar sourceCalendar: Calendar = .current) {
        // Journal day keys are local Gregorian dates. The dial's weeks
        // always start on Monday, like the prototype.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = sourceCalendar.locale ?? .current
        calendar.timeZone = sourceCalendar.timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let today = calendar.startOfDay(for: now)
        let currentYear = calendar.component(.year, from: today)
        let knownBirthYear = birthYear.flatMap { (1...currentYear).contains($0) ? $0 : nil }
        let start: Date
        if let knownBirthYear {
            start = calendar.date(from: DateComponents(year: knownBirthYear, month: 1, day: 1))!
        } else if let earliestData, earliestData <= now {
            start = calendar.startOfDay(for: earliestData)
        } else {
            start = calendar.date(byAdding: .year, value: -30, to: today)!
        }

        self.calendar = calendar
        self.birthYear = knownBirthYear
        self.start = start
        self.today = today
        end = calendar.date(byAdding: .day, value: 1, to: today)!
        firstWeek = calendar.dateInterval(of: .weekOfYear, for: start)!.start
        firstMonth = calendar.dateInterval(of: .month, for: start)!.start
        firstYear = calendar.component(.year, from: start)
        periods = knownBirthYear.map { Self.draftPeriods(birthYear: $0, through: currentYear) } ?? []
        months = calendar.monthSymbols
        shortMonths = calendar.shortMonthSymbols
        weekdays = calendar.weekdaySymbols
        lastIndices = Dictionary(uniqueKeysWithValues: levels.map { ($0, index(of: today, at: $0)) })
    }

    var levels: [Level] { periods.isEmpty ? [.year, .month, .week, .day] : Level.allCases }

    static func draftPeriods(birthYear: Int, through currentYear: Int) -> [Period] {
        guard birthYear > 0, birthYear <= currentYear else { return [] }
        let chapters = [
            (0, 5, "Early childhood"),
            (6, 11, "School years"),
            (12, 17, "Teenage years"),
            (18, 21, "College years"),
            (22, 25, "First jobs")
        ]
        let age = currentYear - birthYear
        var periods = chapters.compactMap { first, last, title in
            first <= age ? Period(title: title, startYear: birthYear + first, endYear: birthYear + min(last, age)) : nil
        }
        for first in stride(from: 26, through: age, by: 4) {
            let last = min(first + 3, age)
            let title = first == last ? "Age \(first)" : "Ages \(first)–\(last)"
            periods.append(Period(title: title, startYear: birthYear + first, endYear: birthYear + last))
        }
        return periods
    }

    func clamp(_ date: Date) -> Date { min(today, max(start, date)) }

    func index(of date: Date, at level: Level) -> Int {
        let date = clamp(date)
        switch level {
        case .day:
            return calendar.dateComponents([.day], from: start, to: date).day!
        case .week:
            let week = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            return calendar.dateComponents([.day], from: firstWeek, to: week).day! / 7
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!.start
            return calendar.dateComponents([.month], from: firstMonth, to: month).month!
        case .year:
            return calendar.component(.year, from: date) - firstYear
        case .period:
            let year = calendar.component(.year, from: date)
            return periods.firstIndex { year <= $0.endYear } ?? 0
        }
    }

    func lastIndex(at level: Level) -> Int { lastIndices[level] ?? 0 }

    func selection(at level: Level, position: Double) -> Selection {
        Selection(level: level, index: Int(floor(clamp(position, at: level))))
    }

    func clamp(_ position: Double, at level: Level) -> Double {
        min(Double(lastIndex(at: level)) + 0.5, max(0.5, position))
    }

    func range(of selection: Selection) -> Range<Date>? {
        guard let unit = unitRange(of: selection) else { return nil }
        return max(start, unit.lowerBound)..<min(end, unit.upperBound)
    }

    private func unitRange(of selection: Selection) -> Range<Date>? {
        let index = selection.index
        guard index >= 0, index <= lastIndex(at: selection.level) else { return nil }
        switch selection.level {
        case .day:
            return dates(from: start, adding: .day, offsets: index..<(index + 1))
        case .week:
            return dates(from: firstWeek, adding: .day, offsets: (index * 7)..<((index + 1) * 7))
        case .month:
            return dates(from: firstMonth, adding: .month, offsets: index..<(index + 1))
        case .year:
            return yearStart(firstYear + index)..<yearStart(firstYear + index + 1)
        case .period:
            guard periods.indices.contains(index) else { return nil }
            return yearStart(periods[index].startYear)..<yearStart(periods[index].endYear + 1)
        }
    }

    private func dates(from base: Date, adding component: Calendar.Component, offsets: Range<Int>) -> Range<Date> {
        let start = calendar.date(byAdding: component, value: offsets.lowerBound, to: base)!
        let end = calendar.date(byAdding: component, value: offsets.upperBound, to: base)!
        return start..<end
    }

    private func yearStart(_ year: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
    }

    func centerTime(of selection: Selection) -> Date {
        guard let range = unitRange(of: selection) else { return today }
        return clamp(range.lowerBound + range.upperBound.timeIntervalSince(range.lowerBound) / 2)
    }

    func zoom(from selection: Selection, towardFiner: Bool) -> Selection? {
        guard let current = levels.firstIndex(of: selection.level) else { return nil }
        let next = current + (towardFiner ? 1 : -1)
        guard levels.indices.contains(next) else { return nil }
        let level = levels[next]
        let containsToday = range(of: selection)?.contains(today) == true
        let date = towardFiner && containsToday ? today : centerTime(of: selection)
        return Selection(level: level, index: index(of: date, at: level))
    }

    func labels(for selection: Selection) -> Labels {
        guard let range = unitRange(of: selection) else { return Labels(title: "", subtitle: "") }
        let date = range.lowerBound
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let year = parts.year!, month = parts.month! - 1, day = parts.day!
        switch selection.level {
        case .day:
            let title = date == today ? "Today" : weekdays[parts.weekday! - 1]
            return Labels(title: title, subtitle: "\(months[month]) \(day), \(year)")
        case .week:
            let lastDay = componentsOfLastDay(in: range)
            let lastMonth = lastDay.month! - 1
            let last = month == lastMonth ? "\(lastDay.day!)" : "\(shortMonths[lastMonth]) \(lastDay.day!)"
            let subtitle = year == lastDay.year! ? "\(year)" : "\(year) – \(lastDay.year!)"
            return Labels(title: "\(shortMonths[month]) \(day) – \(last)", subtitle: subtitle)
        case .month:
            return Labels(title: months[month], subtitle: "\(year)")
        case .year:
            guard let birthYear else { return Labels(title: "\(year)", subtitle: "") }
            return Labels(title: "\(year)", subtitle: year == birthYear ? "The year you were born" : "Age \(year - birthYear)")
        case .period:
            let period = periods[selection.index]
            let last = selection.index == periods.count - 1 ? "today" : "\(period.endYear)"
            return Labels(title: period.title, subtitle: "\(period.startYear) – \(last)")
        }
    }

    /// A label also marks a major detent. Use the full week here so a week
    /// straddling the next month keeps its mark as today's date advances.
    func tickLabel(for selection: Selection) -> String? {
        guard let range = unitRange(of: selection) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: range.lowerBound)
        let year = parts.year!, month = parts.month!
        switch selection.level {
        case .day:
            return parts.day == 1 ? (month == 1 ? String(year) : shortMonths[month - 1]) : nil
        case .week:
            let last = componentsOfLastDay(in: range)
            guard parts.day == 1 || month != last.month else { return nil }
            return last.month == 1 ? String(last.year!) : shortMonths[last.month! - 1]
        case .month:
            return month == 1 ? String(year) : nil
        case .year:
            return year.isMultiple(of: 5) ? String(year) : nil
        case .period:
            return String(year)
        }
    }

    private func componentsOfLastDay(in range: Range<Date>) -> DateComponents {
        let date = calendar.date(byAdding: .day, value: -1, to: range.upperBound)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func pickPicture(from candidates: [PictureCandidate], for selection: Selection) -> UUID? {
        guard let priority = candidates.map(\.kind.rawValue).min() else { return nil }
        let ids = candidates.filter { $0.kind.rawValue == priority }.map { $0.id.uuidString }.sorted()
        // FNV-1a, like the prototype. Swift's Hasher is seeded per process.
        let key = "\(selection.level.name)\(selection.index)"
        let hash = key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return UUID(uuidString: ids[Int(hash) % ids.count])
    }
}
