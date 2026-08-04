import SwiftUI

struct NotesHomeView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    var body: some View {
        NavigationStack {
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

struct BiographyHomeView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    private var entries: [Story] {
        speechRecognizer.stories
            .filter { !($0.biographyProse ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Your biography starts here", systemImage: "book.closed")
                    } description: {
                        Text("Daily entries will appear as Lore turns your voice notes into faithful, readable stories.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(entries) { story in
                                NavigationLink {
                                    StoryDetailView(story: story, speechRecognizer: speechRecognizer)
                                } label: {
                                    BiographyEntryCard(story: story)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("biographyEntry_\(story.id.uuidString)")
                            }
                        }
                        .padding(20)
                    }
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
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(story.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? story.formattedDate)
                .font(.headline)

            Text(story.biographyProse ?? "")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            Label("Based on 1 voice note", systemImage: "quote.bubble")
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
