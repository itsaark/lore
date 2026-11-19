import PhotosUI
import SwiftData
import SwiftUI

/// The journal page for one day: its photos, the written entry, and the voice
/// notes it was built from. Empty days still accept photos.
struct DayJournalView: View {
    private enum NotesDestination: Hashable {
        case list
        case detail(Story)
    }

    let dayKey: String
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [DayPhoto]
    @Query private var illustrations: [DayIllustration]
    @State private var addItems: [PhotosPickerItem] = []
    @State private var showsAddPicker = false
    @State private var replaceItem: PhotosPickerItem?
    @State private var replacingPhotoID: UUID?
    @State private var selectedPhotoID: UUID?
    @State private var showsViewer = false
    @State private var isSavingPhoto = false
    @State private var photoError: String?
    @State private var savedPhotoCount = 0
    @State private var notesDestination: NotesDestination?

    private let journalCalendar = JournalCalendar()

    init(dayKey: String, speechRecognizer: SpeechRecognitionViewModel) {
        self.dayKey = dayKey
        self.speechRecognizer = speechRecognizer
        _photos = Query(filter: #Predicate<DayPhoto> { $0.dayKey == dayKey })
        _illustrations = Query(
            filter: #Predicate<DayIllustration> { $0.dayKey == dayKey && $0.memoryStoryId == nil },
            sort: \DayIllustration.updatedAt,
            order: .reverse
        )
    }

    private var orderedPhotos: [DayPhoto] { photos.inDayOrder() }

    /// The photo on screen in the pager; the cover until the reader swipes.
    private var currentPhoto: DayPhoto? {
        let ordered = orderedPhotos
        return ordered.first { $0.id == selectedPhotoID } ?? ordered.first
    }

    private var remainingPhotoSlots: Int {
        max(DayPhotoStore.maximumPhotosPerDay - photos.count, 0)
    }

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

                photoSection(for: content?.entry)
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
        .navigationDestination(item: $notesDestination) { destination in
            switch destination {
            case .list:
                DayNotesView(dayKey: dayKey, date: date, speechRecognizer: speechRecognizer)
            case .detail(let story):
                StoryDetailView(story: story, speechRecognizer: speechRecognizer)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .toolbar {
            if let currentPhoto {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        photoMenuItems(for: currentPhoto)
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
        .photosPicker(
            isPresented: $showsAddPicker,
            selection: $addItems,
            maxSelectionCount: max(remainingPhotoSlots, 1),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(from: items) }
        }
        .fullScreenCover(isPresented: $showsViewer) {
            DayPhotoViewer(photos: orderedPhotos, startingAt: currentPhoto?.id)
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
    private func photoSection(for entry: DailyBiographyEntry?) -> some View {
        let ordered = orderedPhotos
        Group {
            if ordered.isEmpty {
                if let illustration = illustrations.first,
                   dayKey < journalCalendar.dayKey(for: Date()),
                   let entry,
                   !entry.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let cover = DayCover.illustration(illustration)
                    VStack(alignment: .leading, spacing: 14) {
                        DayPhotoImage(cover: cover, variant: .full)
                            .aspectRatio(min(max(cover.aspectRatio, 3.0 / 4.0), 4.0 / 3.0), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1))
                            }
                            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                            .overlay {
                                if isSavingPhoto { savingIndicator }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Painting inspired by this day")
                            .accessibilityAddTraits(.isImage)

                        photoControls(for: ordered)
                    }
                } else {
                    addPhotoPlaceholder
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        if ordered.count == 1, let only = ordered.first {
                            SettlingPhotoCard(photo: only) { showsViewer = true }
                                .contextMenu { photoMenuItems(for: only) }
                        } else {
                            DayPhotoPager(photos: ordered, selection: $selectedPhotoID) { showsViewer = true } menu: { photo in
                                photoMenuItems(for: photo)
                            }
                        }
                    }
                    .overlay {
                        if isSavingPhoto { savingIndicator }
                    }

                    photoControls(for: ordered)
                }
            }
        }
        .photosPicker(isPresented: Binding(
            get: { replacingPhotoID != nil && replaceItem == nil },
            set: { if !$0, replaceItem == nil { replacingPhotoID = nil } }
        ), selection: $replaceItem, matching: .images)
        .onChange(of: replaceItem) { _, item in
            guard let item, let photoID = replacingPhotoID else { return }
            Task { await replacePhoto(photoID, from: item) }
        }
    }

    private var addPhotoPlaceholder: some View {
        Button {
            showsAddPicker = true
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
                Text("Add photos for this day")
                    .font(LoreTheme.caption(.body))
                    .foregroundStyle(LoreTheme.secondaryInk)
                Text("Up to \(DayPhotoStore.maximumPhotosPerDay)")
                    .font(LoreTheme.label.weight(.regular))
                    .foregroundStyle(LoreTheme.tertiaryInk)
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

    /// Page dots for several photos, and a compact add button while the day
    /// has room for more.
    private func photoControls(for ordered: [DayPhoto]) -> some View {
        HStack(spacing: 12) {
            if ordered.isEmpty {
                Text("Painted from your day")
                    .font(LoreTheme.caption(.caption))
                    .foregroundStyle(LoreTheme.tertiaryInk)
            } else if ordered.count > 1 {
                let current = currentPhoto?.id
                HStack(spacing: 6) {
                    ForEach(ordered) { photo in
                        Circle()
                            .fill(photo.id == current ? LoreTheme.ink : LoreTheme.tertiaryInk.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                }
                .animation(.snappy, value: current)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photo \((ordered.firstIndex { $0.id == current } ?? 0) + 1) of \(ordered.count)")
            }

            Spacer(minLength: 0)

            if remainingPhotoSlots > 0 {
                Button {
                    showsAddPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                        Text("Add photo")
                        if !ordered.isEmpty {
                            Text("\(ordered.count)/\(DayPhotoStore.maximumPhotosPerDay)")
                                .foregroundStyle(LoreTheme.tertiaryInk)
                                .monospacedDigit()
                        }
                    }
                    .font(LoreTheme.label)
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(LoreTheme.surface))
                    .overlay(Capsule().strokeBorder(LoreTheme.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingPhoto)
                .accessibilityLabel("Add photo, \(ordered.count) of \(DayPhotoStore.maximumPhotosPerDay)")
                .accessibilityIdentifier("addMoreDayPhotosButton")
            }
        }
    }

    @ViewBuilder
    private func photoMenuItems(for photo: DayPhoto) -> some View {
        if remainingPhotoSlots > 0 {
            Button {
                showsAddPicker = true
            } label: {
                Label("Add Photos", systemImage: "plus")
            }
            .accessibilityIdentifier("addDayPhotosMenuButton")
        }

        if photos.count > 1, orderedPhotos.first?.id != photo.id {
            Button {
                makeCover(photo)
            } label: {
                Label("Make Cover", systemImage: "rectangle.stack")
            }
            .accessibilityIdentifier("makeCoverDayPhotoButton")
        }

        Button {
            replaceItem = nil
            replacingPhotoID = photo.id
        } label: {
            Label("Replace Photo", systemImage: "photo.on.rectangle")
        }
        .accessibilityIdentifier("replaceDayPhotoButton")

        Button(role: .destructive) {
            removePhoto(photo)
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

    private func addPhotos(from items: [PhotosPickerItem]) async {
        isSavingPhoto = true
        defer {
            isSavingPhoto = false
            addItems = []
        }
        var encoded: [DayPhotoEncoder.Output] = []
        var failures = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let output = await DayPhotoStore.encodeInBackground(data) else {
                failures += 1
                continue
            }
            encoded.append(output)
        }
        do {
            let added = try DayPhotoStore.addPhotos(encoded, for: dayKey, in: modelContext)
            if let first = added.first {
                selectedPhotoID = first.id
                savedPhotoCount += 1
            }
        } catch {
            photoError = error.localizedDescription
            return
        }
        if failures > 0 {
            photoError = failures == 1
                ? "One photo couldn't be loaded from your library."
                : "\(failures) photos couldn't be loaded from your library."
        }
    }

    private func replacePhoto(_ photoID: UUID, from item: PhotosPickerItem) async {
        isSavingPhoto = true
        defer {
            isSavingPhoto = false
            replaceItem = nil
            replacingPhotoID = nil
        }
        guard let photo = photos.first(where: { $0.id == photoID }) else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoError = "The photo couldn't be loaded from your library."
                return
            }
            guard let encoded = await DayPhotoStore.encodeInBackground(data) else {
                photoError = "That file isn't an image Lore can read."
                return
            }
            try DayPhotoStore.replace(photo, with: encoded, in: modelContext)
            savedPhotoCount += 1
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func makeCover(_ photo: DayPhoto) {
        do {
            try DayPhotoStore.makeCover(photo, in: modelContext)
            selectedPhotoID = photo.id
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func removePhoto(_ photo: DayPhoto) {
        let ordered = orderedPhotos
        if let index = ordered.firstIndex(where: { $0.id == photo.id }) {
            let neighbor = ordered.indices.contains(index + 1) ? ordered[index + 1] : (index > 0 ? ordered[index - 1] : nil)
            selectedPhotoID = neighbor?.id
        }
        do {
            try DayPhotoStore.remove(photo, in: modelContext)
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

            Button {
                if content.stories.count == 1, let story = content.stories.first {
                    notesDestination = .detail(story)
                } else {
                    notesDestination = .list
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

/// Several photos as a sideways pager of equal cards; the first wears a
/// small "Cover" tag because it is the one the calendar shows.
private struct DayPhotoPager<Menu: View>: View {
    let photos: [DayPhoto]
    @Binding var selection: UUID?
    let open: () -> Void
    @ViewBuilder let menu: (DayPhoto) -> Menu

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button(action: open) {
                        DayPhotoImage(photo: photo, variant: .full)
                            .aspectRatio(4.0 / 5.0, contentMode: .fit)
                            .clipShape(shape)
                            .contentShape(shape)
                            .overlay(alignment: .topLeading) {
                                if index == 0 {
                                    Text("Cover")
                                        .font(LoreTheme.label)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(.black.opacity(0.45)))
                                        .padding(12)
                                        .accessibilityHidden(true)
                                }
                            }
                            .overlay { shape.strokeBorder(Color.white.opacity(0.1)) }
                            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(photo) }
                    .containerRelativeFrame(.horizontal)
                    .accessibilityLabel(index == 0 ? "Cover photo, \(index + 1) of \(photos.count)" : "Photo \(index + 1) of \(photos.count)")
                    .accessibilityHint("Opens the photo full screen")
                    .accessibilityIdentifier("dayPhotoCard_\(index)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// All voice notes captured on one day.
private struct DayNotesView: View {
    let dayKey: String
    let date: Date
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var noteToDelete: Story?

    private var stories: [Story] {
        let calendar = JournalCalendar()
        return speechRecognizer.stories.filter {
            $0.effectiveDayKey(
                recordedDayKey: speechRecognizer.storyDayKeys[$0.id] ?? calendar.dayKey(for: $0.date)
            ) == dayKey
        }
    }

    var body: some View {
        List {
            ForEach(stories) { story in
                NavigationLink {
                    StoryDetailView(story: story, speechRecognizer: speechRecognizer)
                } label: {
                    TranscriptPreviewRow(story: story)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .voiceNoteDeleteActions { noteToDelete = story }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .loreCanvas()
        .navigationTitle(date.formatted(.dateTime.day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .voiceNoteDeletionConfirmation(for: $noteToDelete) { speechRecognizer.deleteStory($0) }
        .onChange(of: stories.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}

#Preview("Empty day") {
    NavigationStack {
        DayJournalView(dayKey: "2026-10-30", speechRecognizer: SpeechRecognitionViewModel())
    }
    .modelContainer(LoreModelContainer.preview)
}
