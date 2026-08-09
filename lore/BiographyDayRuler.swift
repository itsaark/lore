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
    let availableDays: [Date]
    let scrollOffset: CGFloat
    let maximumScrollOffset: CGFloat
    let onScrubToOffset: (CGFloat) -> Void
    let onSelectDay: (Date) -> Void

    @State private var dragStartOffset: CGFloat?
    @State private var lastFeedbackStep: Int?

    private let tickCount = 9
    private let rulerHeight: CGFloat = 116
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
        .frame(width: 44, height: rulerHeight, alignment: .trailing)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Biography date")
        .accessibilityValue(selectedDay.formatted(date: .complete, time: .omitted))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                select(indexOffset: 1, from: selectedIndex, withHaptic: true)
            case .decrement:
                select(indexOffset: -1, from: selectedIndex, withHaptic: true)
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("biographyDayRuler")
    }

    private var normalizedAvailableDays: [Date] {
        var seen = Set<Date>()
        return availableDays
            .map(normalized)
            .filter { seen.insert($0).inserted }
            .sorted(by: >)
    }

    private var selectedIndex: Int {
        let days = normalizedAvailableDays
        guard !days.isEmpty else { return 0 }
        if let exactIndex = days.firstIndex(where: {
            calendar.isDate($0, inSameDayAs: selectedDay)
        }) {
            return exactIndex
        }
        return days.indices.min(by: {
            abs(days[$0].timeIntervalSince(selectedDay)) < abs(days[$1].timeIntervalSince(selectedDay))
        }) ?? 0
    }

    private var visibleDays: [Date] {
        let days = normalizedAvailableDays
        guard days.count > tickCount else { return days }

        let half = tickCount / 2
        let maxStart = days.count - tickCount
        let start = min(max(selectedIndex - half, 0), maxStart)
        return Array(days[start..<(start + tickCount)])
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard maximumScrollOffset > 0 else { return }
                let start = dragStartOffset ?? scrollOffset
                if dragStartOffset == nil {
                    dragStartOffset = start
                    lastFeedbackStep = feedbackStep(for: start)
                }
                let proposedOffset = start
                    + (value.translation.height / rulerHeight) * maximumScrollOffset
                let offset = min(max(proposedOffset, 0), maximumScrollOffset)
                let step = feedbackStep(for: offset)
                if step != lastFeedbackStep {
                    BiographyRulerHaptics.shared.selectionChanged()
                    lastFeedbackStep = step
                }
                onScrubToOffset(offset)
            }
            .onEnded { _ in
                dragStartOffset = nil
                lastFeedbackStep = nil
            }
    }

    private func feedbackStep(for offset: CGFloat) -> Int {
        guard maximumScrollOffset > 0 else { return 0 }
        let progress = min(max(offset / maximumScrollOffset, 0), 1)
        return Int((progress * CGFloat(tickCount - 1)).rounded(.down))
    }

    private func select(indexOffset: Int, from start: Int, withHaptic: Bool) {
        let days = normalizedAvailableDays
        guard !days.isEmpty else { return }
        let index = min(max(start + indexOffset, days.startIndex), days.index(before: days.endIndex))
        let day = days[index]
        guard !calendar.isDate(day, inSameDayAs: selectedDay) else { return }
        selectedDay = day
        if withHaptic {
            BiographyRulerHaptics.shared.selectionChanged()
        }
        onSelectDay(day)
    }

    private func normalized(_ date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: 12, to: start) ?? date
    }
}
