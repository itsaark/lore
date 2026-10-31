import PhotosUI
import SwiftData
import SwiftUI

/// The journal page for one day: its photo, the written entry, and the voice
/// notes it was built from. Empty days still accept a photo.
struct DayJournalView: View {
    let dayKey: String
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [DayPhoto]
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsPicker = false
    @State private var showsViewer = false
    @State private var isSavingPhoto = false
    @State private var photoError: String?
    @State private var savedPhotoCount = 0

    private let journalCalendar = JournalCalendar()

    init(dayKey: String, speechRecognizer: SpeechRecognitionViewModel) {
        self.dayKey = dayKey
        self.speechRecognizer = speechRecognizer
        _photos = Query(
            filter: #Predicate<DayPhoto> { $0.dayKey == dayKey },
            sort: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    private var photo: DayPhoto? { photos.first }

    private var content: JournalDayContent? {
        JournalDayContent.index(
            stories: speechRecognizer.stories,
            dailyEntries: speechRecognizer.dailyBiographyEntries,
            storyDayKeys: speechRecognizer.storyDayKeys,
            calendar: journalCalendar
        )[dayKey]
    }

    private var date: Date {
        journalCalendar.date(forDayKey: dayKey) ?? Date()
    }

    private var isToday: Bool {
        dayKey == journalCalendar.dayKey(for: Date())
    }

    var body: some View {
        let content = content

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(LoreTheme.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .accessibilityIdentifier("dayJournalDate")

                    Text(title(for: content))
                        .font(LoreTheme.display(32))
                        .foregroundStyle(LoreTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("dayJournalTitle")
                }
                .padding(.bottom, 24)

                photoSection
                    .padding(.bottom, 30)

                entryBody(for: content)

                if let content, content.hasNotes {
                    notesFooter(for: content)
                        .padding(.top, 34)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .loreCanvas()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .toolbar {
            if photo != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        photoMenuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LoreTheme.ink)
                    }
                    .accessibilityLabel("Photo options")
                    .accessibilityIdentifier("dayPhotoMenuButton")
                }
            }
        }
        .photosPicker(isPresented: $showsPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await savePhoto(from: item) }
        }
        .fullScreenCover(isPresented: $showsViewer) {
            if let photo {
                DayPhotoViewer(photo: photo)
            }
        }
        .alert(
            "Photo not saved",
            isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: savedPhotoCount)
        .accessibilityIdentifier("dayJournal_\(dayKey)")
    }

    // MARK: Photo

    @ViewBuilder
    private var photoSection: some View {
        if let photo {
            SettlingPhotoCard(photo: photo) {
                showsViewer = true
            }
            .contextMenu { photoMenuItems }
            .overlay {
                if isSavingPhoto { savingIndicator }
            }
        } else {
            Button {
                showsPicker = true
            } label: {
                VStack(spacing: 10) {
                    if isSavingPhoto {
                        ProgressView()
                            .tint(LoreTheme.ink)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(LoreTheme.secondaryInk)
                    }
                    Text("Add a photo for this day")
                        .font(LoreTheme.caption(.body))
                        .foregroundStyle(LoreTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .background(
                    RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                        .fill(LoreTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                        .strokeBorder(LoreTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                )
                .contentShape(RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSavingPhoto)
            .accessibilityIdentifier("addDayPhotoButton")
        }
    }

    @ViewBuilder
    private var photoMenuItems: some View {
        Button {
            showsPicker = true
        } label: {
            Label("Replace Photo", systemImage: "photo.on.rectangle")
        }
        .accessibilityIdentifier("replaceDayPhotoButton")

        Button(role: .destructive) {
            removePhoto()
        } label: {
            Label("Remove Photo", systemImage: "trash")
        }
        .accessibilityIdentifier("removeDayPhotoButton")
    }

    private var savingIndicator: some View {
        ProgressView()
            .tint(.white)
            .padding(14)
            .background(Circle().fill(.black.opacity(0.5)))
    }

    private func savePhoto(from item: PhotosPickerItem) async {
        isSavingPhoto = true
        defer {
            isSavingPhoto = false
            pickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoError = "The photo couldn't be loaded from your library."
                return
            }
            guard try await DayPhotoStore.setPhoto(decodingInBackground: data, for: dayKey, in: modelContext) != nil else {
                photoError = "That file isn't an image Lore can read."
                return
            }
            savedPhotoCount += 1
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func removePhoto() {
        do {
            try DayPhotoStore.removePhoto(for: dayKey, in: modelContext)
        } catch {
            photoError = error.localizedDescription
        }
    }

    // MARK: Entry

    private func title(for content: JournalDayContent?) -> String {
        if let title = content?.title { return title }
        if content?.hasNotes == true { return "Still writing" }
        return isToday ? "Today" : "A quiet day"
    }

    @ViewBuilder
    private func entryBody(for content: JournalDayContent?) -> some View {
        if let entry = content?.entry {
            prose(entry.prose)
        } else if let drafts = content?.draftStories, !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(drafts) { story in
                    prose(story.biographyProse ?? "")
                }
            }
        } else if let content, content.hasNotes {
            quietNote("Lore is still turning \(noteCountText(content.noteCount)) into this day's page.")
        } else if isToday {
            quietNote("Nothing written yet. Tap record on the home screen and tell Lore about today.")
        } else {
            quietNote("No voice notes from this day. You can still give it a photo.")
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(LoreTheme.body)
            .foregroundStyle(LoreTheme.ink.opacity(0.9))
            .lineSpacing(7)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("dayJournalProse")
    }

    private func quietNote(_ text: String) -> some View {
        Text(text)
            .font(LoreTheme.caption(.body))
            .foregroundStyle(LoreTheme.tertiaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notesFooter(for content: JournalDayContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LoreTheme.hairline)
                .frame(height: 1)
                .padding(.bottom, 14)

            NavigationLink {
                if content.stories.count == 1, let story = content.stories.first {
                    StoryDetailView(story: story, speechRecognizer: speechRecognizer)
                } else {
                    DayNotesView(date: date, stories: content.stories, speechRecognizer: speechRecognizer)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .foregroundStyle(LoreTheme.secondaryInk)
                    Text(content.hasEntry ? "Based on \(noteCountText(content.noteCount))" : "Voice notes: \(content.stories.count)")
                        .font(LoreTheme.label)
                        .foregroundStyle(LoreTheme.secondaryInk)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LoreTheme.tertiaryInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dayJournalNotesLink")
        }
    }

    private func noteCountText(_ count: Int) -> String {
        "\(count) voice \(count == 1 ? "note" : "notes")"
    }
}

/// The day's photo as a hero card that lands with a small rotate-and-settle.
private struct SettlingPhotoCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: DayPhoto
    let open: () -> Void

    @State private var isSettled = false

    private var aspectRatio: CGFloat {
        min(max(photo.aspectRatio, 3.0 / 4.0), 4.0 / 3.0)
    }

    var body: some View {
        Button(action: open) {
            DayPhotoImage(photo: photo, variant: .full)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1))
                }
                .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(isSettled || reduceMotion ? 0 : -6))
        .scaleEffect(isSettled || reduceMotion ? 1 : 0.92)
        .accessibilityLabel("Photo for this day")
        .accessibilityHint("Opens the photo full screen")
        .accessibilityIdentifier("dayPhotoCard")
        .onAppear(perform: settle)
        .onChange(of: photo.updatedAt) { _, _ in
            isSettled = false
            settle()
        }
    }

    private func settle() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.62).delay(0.08)) {
            isSettled = true
        }
    }
}

/// All voice notes captured on one day.
private struct DayNotesView: View {
    let date: Date
    let stories: [Story]
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(stories) { story in
                    NavigationLink {
                        StoryDetailView(story: story, speechRecognizer: speechRecognizer)
                    } label: {
                        TranscriptPreviewRow(story: story)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .loreCanvas()
        .navigationTitle(date.formatted(.dateTime.day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Empty day") {
    NavigationStack {
        DayJournalView(dayKey: "2026-10-30", speechRecognizer: SpeechRecognitionViewModel())
    }
    .modelContainer(LoreModelContainer.preview)
}
