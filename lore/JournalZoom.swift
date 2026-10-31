import CoreGraphics
import Foundation

/// The home's detail levels, from most zoomed out to most zoomed in. Pinching
/// moves continuously along this scale; releasing snaps to one of the cases.
enum JournalDensity: Int, CaseIterable, Comparable {
    case month
    case week
    case dayTitles
    case dayPreview
    case dayFull

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var zoom: Double { Double(rawValue) }

    var layout: JournalLayout {
        switch self {
        case .month: .month
        case .week: .week
        case .dayTitles, .dayPreview, .dayFull: .days
        }
    }

    var accessibilityName: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        case .dayTitles: "Days, titles only"
        case .dayPreview: "Days with a preview"
        case .dayFull: "Days in full"
        }
    }
}

/// The three structurally different arrangements of the home.
enum JournalLayout: CaseIterable {
    case month
    case week
    case days

    var title: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        case .days: "Day"
        }
    }

    /// The density a tap on this layout's segment lands on.
    var defaultDensity: JournalDensity {
        switch self {
        case .month: .month
        case .week: .week
        case .days: .dayPreview
        }
    }
}

/// Pure mapping from pinch magnification to the continuous zoom value, and
/// from zoom to snapping, layout, and how much of each day is revealed.
enum JournalZoom {
    static let range: ClosedRange<Double> = 0...Double(JournalDensity.dayFull.rawValue)
    /// Detail levels travelled when the fingers double their spread.
    static let levelsPerDoubling = 1.6
    /// How far past the starting level a pinch must travel to commit a step.
    static let commitThreshold = 0.3
    /// Maximum visual overshoot past either end of the scale.
    static let maximumOvershoot = 0.3

    /// Live zoom for a pinch that started at `base`. Spreading the fingers
    /// (magnification above 1) zooms in toward full days.
    static func zoom(base: Double, magnification: CGFloat) -> Double {
        let raw = base + log2(Double(max(magnification, 0.01))) * levelsPerDoubling
        return rubberBanded(raw)
    }

    /// Compresses travel beyond the ends so the scale resists rather than stops.
    static func rubberBanded(_ raw: Double) -> Double {
        if raw < range.lowerBound {
            return range.lowerBound - resistance(range.lowerBound - raw)
        }
        if raw > range.upperBound {
            return range.upperBound + resistance(raw - range.upperBound)
        }
        return raw
    }

    private static func resistance(_ distance: Double) -> Double {
        maximumOvershoot * (1 - 1 / (distance / maximumOvershoot * 0.55 + 1))
    }

    /// The level nearest a live zoom value; crossing one fires a haptic tick.
    static func nearestLevel(_ zoom: Double) -> JournalDensity {
        let clamped = min(max(zoom, range.lowerBound), range.upperBound)
        return JournalDensity(rawValue: Int(clamped.rounded())) ?? .week
    }

    /// Layout shown at a live zoom value. It switches halfway between levels.
    static func layout(at zoom: Double) -> JournalLayout {
        nearestLevel(zoom).layout
    }

    /// Where a released pinch settles. A short pinch past `commitThreshold`
    /// already commits one step in its direction, so small gestures register.
    static func snapTarget(base: JournalDensity, zoom: Double) -> JournalDensity {
        let delta = zoom - base.zoom
        let steps: Int
        if delta >= 0 {
            steps = Int((delta + 1 - commitThreshold).rounded(.down))
        } else {
            steps = -Int((-delta + 1 - commitThreshold).rounded(.down))
        }
        let target = min(max(base.rawValue + steps, 0), JournalDensity.dayFull.rawValue)
        return JournalDensity(rawValue: target) ?? base
    }

    /// Height of a day's prose shown at `zoom`: nothing at titles, up to a
    /// short preview at `.dayPreview`, the whole text at `.dayFull`.
    static func proseRevealHeight(zoom: Double, fullHeight: CGFloat, previewHeight: CGFloat) -> CGFloat {
        let preview = min(fullHeight, previewHeight)
        let titles = JournalDensity.dayTitles.zoom
        let middle = JournalDensity.dayPreview.zoom
        if zoom <= titles { return 0 }
        if zoom <= middle {
            return preview * CGFloat(zoom - titles)
        }
        let progress = CGFloat(min(zoom - middle, 1))
        return preview + (fullHeight - preview) * progress
    }

    /// 0 → 1 progress of the photo thumbnail between preview and full.
    static func thumbnailProgress(zoom: Double) -> CGFloat {
        CGFloat(min(max(zoom - JournalDensity.dayPreview.zoom, 0), 1))
    }

    /// Prose fades in over the first part of the way from titles to preview.
    static func proseOpacity(zoom: Double) -> Double {
        min(max((zoom - JournalDensity.dayTitles.zoom) / 0.45, 0), 1)
    }
}

/// Scroll identities on the home and how the reading position carries across
/// layouts. Every list on the home runs newest first.
enum JournalScrollID {
    /// Ids for the header and hero; any id without a day key counts as the top.
    static let top = "top"
    static let hero = "hero"

    static func day(_ dayKey: String) -> String { "day-\(dayKey)" }
    static func week(_ week: JournalWeek) -> String { "week-\(week.id)" }
    static func month(_ month: JournalMonth) -> String { "month-\(month.id)" }

    /// The day the reader is looking at, from the scroll targets on screen.
    /// Returns nil while the top of the home is visible, so zooming there
    /// leaves the scroll at the top. Keeps `previous` when it still falls in
    /// the visible week or month, so zooming out and back returns to it.
    static func anchorDayKey(
        visibleIDs: some Sequence<String>,
        previous: String?,
        calendar: JournalCalendar
    ) -> String? {
        var newest: (kind: Substring, key: Substring)?
        for id in visibleIDs {
            // Header and hero ids carry no day key.
            guard let dash = id.firstIndex(of: "-") else { return nil }
            let kind = id[..<dash]
            guard kind == "day" || kind == "week" || kind == "month" else { continue }
            let key = id[id.index(after: dash)...]
            if newest == nil || key > newest!.key { newest = (kind, key) }
        }
        guard let newest else { return previous }
        let key = String(newest.key)

        switch newest.kind {
        case "week":
            guard let start = calendar.date(forDayKey: key) else { return key }
            let week = calendar.week(containing: start)
            if let previous, week.days.contains(where: { $0.dayKey == previous }) { return previous }
            return week.days.last?.dayKey ?? key
        case "month":
            if let previous, previous.hasPrefix(key + "-") { return previous }
            guard let first = calendar.date(forDayKey: key + "-01") else { return nil }
            return calendar.month(containing: first).days.last?.dayKey
        default:
            return key
        }
    }

    /// The scroll target that shows `anchor` in `layout`. In the day list
    /// that is the anchor's row or the next older day that has one.
    static func target(
        for anchor: String,
        in layout: JournalLayout,
        dayRowKeys: [String],
        calendar: JournalCalendar
    ) -> String {
        switch layout {
        case .days:
            guard let key = dayRowKeys.first(where: { $0 <= anchor }) ?? dayRowKeys.last else { return top }
            return day(key)
        case .week:
            guard let date = calendar.date(forDayKey: anchor) else { return top }
            return week(calendar.week(containing: date))
        case .month:
            return "month-\(anchor.prefix(7))"
        }
    }
}
