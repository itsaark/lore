import SwiftUI

struct NotesHomeView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()

                    VoiceCaptureVisual(
                        isAvailable: speechRecognizer.isAuthorized,
                        isRecording: speechRecognizer.isRecording,
                        isProcessing: speechRecognizer.isAwaitingRemoteTranscription,
                        audioLevel: speechRecognizer.currentAudioLevel,
                        responseLevel: speechRecognizer.currentAudioResponseLevel
                    )

                    VStack {
                        Spacer()

                        if !speechRecognizer.isAuthorized {
                            Text("Microphone access is needed to record.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.horizontal, 28)
                                .transition(.opacity)
                                .accessibilityIdentifier("recordingSupportMessage")
                        }

                        VoiceCaptureButton(
                            containerWidth: geometry.size.width,
                            isAvailable: speechRecognizer.isAuthorized,
                            isRecording: speechRecognizer.isRecording,
                            isProcessing: speechRecognizer.isAwaitingRemoteTranscription,
                            action: speechRecognizer.toggleRecording
                        )
                    }
                    .padding(.bottom, 18)
                }
                .toolbar(.hidden, for: .navigationBar)
                .animation(.easeInOut(duration: 0.22), value: speechRecognizer.isAuthorized)
            }
        }
    }
}

struct BiographyHomeView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    @State private var visibleDayKey: String?
    @State private var selectedDay = Date()

    private var days: [BiographyTimelineDay] {
        BiographyTimelineDay.make(
            stories: speechRecognizer.stories,
            dailyEntries: speechRecognizer.dailyBiographyEntries,
            storyDayKeys: speechRecognizer.storyDayKeys
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView {
                        Label("Your biography starts here", systemImage: "book.closed")
                    } description: {
                        Text("Daily entries will appear as Lore turns your voice notes into faithful, readable stories.")
                    }
                } else {
                    ZStack(alignment: .leading) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(days) { day in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(day.formattedDate)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)

                                        ForEach(day.items) { item in
                                            BiographyTimelineLink(
                                                item: item,
                                                speechRecognizer: speechRecognizer
                                            )
                                        }
                                    }
                                    .id(day.id)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.leading, 40)
                            .padding(.trailing, 20)
                            .padding(.vertical, 20)
                        }
                        .scrollPosition(id: $visibleDayKey, anchor: .top)
                        .onChange(of: visibleDayKey) { _, newValue in
                            guard let day = days.first(where: { $0.id == newValue }) else { return }
                            selectedDay = day.date
                        }

                        BiographyDayRuler(
                            selectedDay: $selectedDay,
                            availableRange: rulerRange,
                            onSelectDay: scrollToNearestDay
                        )
                        .padding(.leading, 5)
                    }
                    .onAppear(perform: selectInitialDay)
                    .onChange(of: days.map(\.id)) { _, _ in selectInitialDay() }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Biography")
            .toolbar {
                if !speechRecognizer.stories.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            TranscriptArchiveView(speechRecognizer: speechRecognizer)
                        } label: {
                            Label("Source transcripts", systemImage: "quote.bubble")
                        }
                        .accessibilityIdentifier("biographySourceTranscriptsButton")
                    }
                }
            }
        }
    }

    private var rulerRange: ClosedRange<Date> {
        guard let oldest = days.last?.date, let newest = days.first?.date else {
            return selectedDay...selectedDay
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lower = calendar.dateInterval(of: .year, for: oldest)?.start ?? oldest
        let upperStart = calendar.dateInterval(of: .year, for: newest)?.start ?? newest
        let upper = calendar.date(byAdding: DateComponents(year: 1, second: -1), to: upperStart) ?? newest
        return lower...upper
    }

    private func selectInitialDay() {
        guard let first = days.first else {
            visibleDayKey = nil
            return
        }
        guard visibleDayKey == nil || !days.contains(where: { $0.id == visibleDayKey }) else { return }
        visibleDayKey = first.id
        selectedDay = first.date
    }

    private func scrollToNearestDay(_ date: Date) {
        guard let nearest = days.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            visibleDayKey = nearest.id
        }
    }
}

private struct BiographyTimelineDay: Identifiable {
    let id: String
    let date: Date
    let items: [BiographyTimelineItem]

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func make(
        stories: [Story],
        dailyEntries: [DailyBiographyEntry],
        storyDayKeys: [UUID: String]
    ) -> [Self] {
        let compiledStoryIds = Set(dailyEntries.flatMap(\.sourceStoryIds))
        var grouped: [String: [BiographyTimelineItem]] = [:]

        for entry in dailyEntries {
            grouped[entry.dayKey, default: []].append(.daily(entry))
        }
        for story in stories where !compiledStoryIds.contains(story.id) {
            guard !(story.biographyProse ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else { continue }
            grouped[storyDayKeys[story.id] ?? dayKey(for: story.date), default: []].append(.story(story))
        }

        return grouped.compactMap { dayKey, items in
            guard let date = calendarDate(for: dayKey) else { return nil }
            return Self(id: dayKey, date: date, items: items.sorted { $0.date > $1.date })
        }
        .sorted { $0.date > $1.date }
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func calendarDate(for dayKey: String) -> Date? {
        let values = dayKey.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = 12
        return components.date
    }
}

private enum BiographyTimelineItem: Identifiable {
    case daily(DailyBiographyEntry)
    case story(Story)

    var id: String {
        switch self {
        case let .daily(entry): "daily-\(entry.id.uuidString)"
        case let .story(story): "story-\(story.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case let .daily(entry): entry.calendarDate
        case let .story(story): story.date
        }
    }
}

private struct BiographyTimelineLink: View {
    let item: BiographyTimelineItem
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    var body: some View {
        switch item {
        case let .daily(entry):
            NavigationLink {
                DailyBiographyDetailView(entry: entry)
            } label: {
                BiographyEntryCard(title: entry.title, prose: entry.prose, noteCount: entry.noteCount)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dailyBiographyEntry_\(entry.dayKey)")

        case let .story(story):
            NavigationLink {
                StoryDetailView(story: story, speechRecognizer: speechRecognizer)
            } label: {
                BiographyEntryCard(
                    title: story.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? story.formattedDate,
                    prose: story.biographyProse ?? "",
                    noteCount: 1
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("biographyEntry_\(story.id.uuidString)")
        }
    }
}

struct TranscriptArchiveView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    private var stories: [Story] {
        Array(speechRecognizer.stories.reversed())
    }

    var body: some View {
        Group {
            if stories.isEmpty {
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "quote.bubble",
                    description: Text("Finish a voice note to create your first transcript.")
                )
            } else {
                List {
                    ForEach(stories) { story in
                        NavigationLink {
                            StoryDetailView(story: story, speechRecognizer: speechRecognizer)
                        } label: {
                            TranscriptPreviewRow(story: story)
                        }
                    }
                    .onDelete(perform: speechRecognizer.deleteStories)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Raw Transcripts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TranscriptPreviewRow: View {
    let story: Story

    private var transcript: String {
        let cleaned = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Transcript unavailable" : cleaned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(story.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(story.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(transcript)
                .font(.body)
                .foregroundStyle(story.text.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct BiographyEntryCard: View {
    let title: String
    let prose: String
    let noteCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(prose)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            Label(
                "Based on \(noteCount) voice \(noteCount == 1 ? "note" : "notes")",
                systemImage: "quote.bubble"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview("Notes") {
    NotesHomeView(
        speechRecognizer: SpeechRecognitionViewModel()
    )
}

#Preview("Biography") {
    BiographyHomeView(speechRecognizer: SpeechRecognitionViewModel())
}
