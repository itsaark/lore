import SwiftUI

struct TranscriptArchiveView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    private var stories: [Story] {
        Array(speechRecognizer.stories.reversed())
    }

    var body: some View {
        Group {
            if stories.isEmpty {
                VStack(spacing: 10) {
                    Text("No transcripts yet")
                        .font(LoreTheme.title())
                        .foregroundStyle(LoreTheme.ink)
                    Text("Finish a voice note to create your first transcript.")
                        .font(LoreTheme.caption(.body))
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                    }
                    .onDelete(perform: speechRecognizer.deleteStories)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .loreCanvas()
        .navigationTitle("Raw Transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .accessibilityIdentifier("transcriptArchive")
    }
}

struct TranscriptPreviewRow: View {
    let story: Story

    private var transcript: String {
        let cleaned = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty else { return cleaned }
        switch story.processingStatus {
        case "transcriptionPending", "transcribing":
            return "Transcription in progress…"
        case "transcriptionFailed", "transcriptionCancelled":
            return "Transcription needs attention"
        default:
            return "Transcript unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(story.formattedDate)
                    .font(LoreTheme.eyebrow)
                    .foregroundStyle(LoreTheme.secondaryInk)

                Spacer(minLength: 8)

                Text(story.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LoreTheme.tertiaryInk)
            }

            Text(transcript)
                .font(story.text.isEmpty ? LoreTheme.caption(.body) : LoreTheme.body)
                .foregroundStyle(story.text.isEmpty ? LoreTheme.secondaryInk : LoreTheme.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                .fill(LoreTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                .strokeBorder(LoreTheme.hairline)
        )
    }
}

#Preview("Transcripts") {
    NavigationStack {
        TranscriptArchiveView(speechRecognizer: SpeechRecognitionViewModel())
    }
}
