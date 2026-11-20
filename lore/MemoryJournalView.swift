import SwiftData
import SwiftUI

/// A coarse memory and the voice note that anchors it.
struct MemoryJournalView: View {
    let storyIds: [UUID]
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DayIllustration.updatedAt, order: .reverse) private var illustrations: [DayIllustration]
    @State private var selected: UUID
    @State private var noteToDelete: Story?

    init(storyIds: [UUID], selected: UUID, speechRecognizer: SpeechRecognitionViewModel) {
        self.storyIds = storyIds
        self.speechRecognizer = speechRecognizer
        _selected = State(initialValue: selected)
    }

    private var stories: [Story] {
        storyIds.compactMap { id in speechRecognizer.stories.first { $0.id == id } }
    }

    var body: some View {
        let stories = stories
        let index = stories.firstIndex { $0.id == selected } ?? 0

        ScrollView {
            if stories.indices.contains(index) {
                memory(stories[index])
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .loreCanvas()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .toolbar {
            if stories.count > 1 {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        selected = stories[index - 1].id
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous memory")

                    Button {
                        selected = stories[index + 1].id
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index == stories.count - 1)
                    .accessibilityLabel("Next memory")
                }
            }
        }
        .voiceNoteDeletionConfirmation(for: $noteToDelete) { speechRecognizer.deleteStory($0) }
        .onChange(of: stories.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    private func memory(_ story: Story) -> some View {
        let entry = speechRecognizer.dailyBiographyEntries.first { $0.memoryStoryId == story.id }
        let key = BiographyIdentity.key(dayKey: "", memoryStoryId: story.id)
        let painting = illustrations.first { $0.memoryStoryId == story.id }
        let canRepaint = DayIllustrationRunner.canRepaint(painting, entry: entry, recordedAt: story.date)
        let isGenerating = speechRecognizer.generatingPaintingKeys.contains(key)
        return VStack(alignment: .leading, spacing: 24) {
            Text(entry?.title ?? "Still writing")
                .font(LoreTheme.display(32))
                .foregroundStyle(LoreTheme.ink)
                .accessibilityAddTraits(.isHeader)

            if painting != nil || isGenerating {
                JournalPaintingHero(
                    biographyKey: key,
                    cover: painting.map(DayCover.illustration),
                    isGenerating: isGenerating,
                    session: speechRecognizer.paintingReveals,
                    accessibilityLabel: "Painting inspired by this memory",
                    canRepaint: canRepaint,
                    repaint: { await speechRecognizer.repaintPainting(for: key) },
                    sceneDescription: painting?.sceneDescription
                )
                .id(key)
            }

            if let entry {
                Text(entry.prose)
                    .font(LoreTheme.body)
                    .foregroundStyle(LoreTheme.ink.opacity(0.9))
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(LoreTheme.hairline)
                .frame(height: 1)

            NavigationLink {
                StoryDetailView(story: story, speechRecognizer: speechRecognizer)
            } label: {
                TranscriptPreviewRow(story: story)
            }
            .buttonStyle(.plain)
            .voiceNoteDeleteActions { noteToDelete = story }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
