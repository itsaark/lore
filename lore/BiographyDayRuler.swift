import SwiftUI
import UIKit

@MainActor
private final class BiographyRulerHaptics {
    static let shared = BiographyRulerHaptics()

    private let generator = UISelectionFeedbackGenerator()

    private init() {
        generator.prepare()
    }

    func selectionChanged() {
        generator.selectionChanged()
        generator.prepare()
    }
}

struct BiographyDayRuler: View {
    @Binding var selectedDay: Date
    let availableRange: ClosedRange<Date>
    let onSelectDay: (Date) -> Void

    @State private var dragStartDay: Date?
    @State private var lastFeedbackDay: Date?

    private let tickCount = 9
    private let pointsPerDay: CGFloat = 9
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(visibleDays.enumerated()), id: \.element) { _, day in
                let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                Capsule()
                    .fill(Color.primary.opacity(isSelected ? 0.62 : 0.2))
                    .frame(width: isSelected ? 12 : 10, height: 3)
                    .animation(.easeOut(duration: 0.12), value: isSelected)
            }
        }
        .frame(width: 14)
        .frame(width: 44, height: 116, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Biography date")
        .accessibilityValue(selectedDay.formatted(date: .complete, time: .omitted))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                select(dayOffset: 1, from: selectedDay, withHaptic: true)
            case .decrement:
                select(dayOffset: -1, from: selectedDay, withHaptic: true)
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("biographyDayRuler")
    }

    private var visibleDays: [Date] {
        let selected = normalized(selectedDay)
        let lower = normalized(availableRange.lowerBound)
        let upper = normalized(availableRange.upperBound)
        let half = tickCount / 2
        var start = calendar.date(byAdding: .day, value: -half, to: selected) ?? selected
        var end = calendar.date(byAdding: .day, value: tickCount - 1, to: start) ?? selected

        if start < lower {
            start = lower
            end = calendar.date(byAdding: .day, value: tickCount - 1, to: start) ?? upper
        }
        if end > upper {
            end = upper
            start = calendar.date(byAdding: .day, value: -(tickCount - 1), to: end) ?? lower
            if start < lower { start = lower }
        }

        var result: [Date] = []
        var day = start
        while day <= end && result.count < tickCount {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartDay ?? selectedDay
                if dragStartDay == nil {
                    dragStartDay = normalized(start)
                    lastFeedbackDay = normalized(selectedDay)
                }
                let offset = Int((-value.translation.height / pointsPerDay).rounded(.towardZero))
                select(dayOffset: offset, from: start, withHaptic: true)
            }
            .onEnded { _ in
                dragStartDay = nil
                lastFeedbackDay = nil
            }
    }

    private func select(dayOffset: Int, from start: Date, withHaptic: Bool) {
        guard let proposed = calendar.date(byAdding: .day, value: dayOffset, to: normalized(start)) else {
            return
        }
        let day = min(max(proposed, availableRange.lowerBound), availableRange.upperBound)
        guard !calendar.isDate(day, inSameDayAs: selectedDay) else { return }
        selectedDay = day
        if withHaptic,
           lastFeedbackDay.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true {
            BiographyRulerHaptics.shared.selectionChanged()
            lastFeedbackDay = day
        }
        onSelectDay(day)
    }

    private func normalized(_ date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: 12, to: start) ?? date
    }
}
