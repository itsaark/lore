//
//  RecordingsView.swift
//  lore
//
//  Created by AI Assistant
//

import SwiftUI

/// View displaying list of all stories.
struct StoriesView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    @Environment(\.presentationMode) var presentationMode

    private var storiesByCaptureDateNewestFirst: [Story] {
        Array(speechRecognizer.stories.reversed())
    }
    
    var body: some View {
        VStack {
            if speechRecognizer.stories.isEmpty {
                // Empty state
                VStack(spacing: 18) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .accessibilityHidden(true)

                    Text("No Stories Yet")
                        .font(LoreTheme.title(.title))
                        .foregroundStyle(LoreTheme.ink)

                    Text("Speak your first story to begin your biography")
                        .font(LoreTheme.caption(.body))
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Stories list
                List {
                    ForEach(storiesByCaptureDateNewestFirst) { story in
                        NavigationLink(destination: StoryDetailView(story: story, speechRecognizer: speechRecognizer)) {
                            StoryRowView(story: story)
                        }
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                        .listRowBackground(LoreTheme.canvas)
                        .listRowSeparatorTint(LoreTheme.hairline)
                    }
                    .onDelete(perform: speechRecognizer.deleteStories)
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden)
            }
        }
        .loreCanvas()
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Stories")
                    .font(LoreTheme.title(.headline))
                    .foregroundStyle(LoreTheme.ink)
            }
        }
    }
}

/// Individual row view for stories list.
struct StoryRowView: View {
    let story: Story

    private var displayContent: StoryDisplayContent {
        StoryDisplayContent(story: story)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                LoreSectionHeader(story.formattedDate)

                Text(displayContent.primaryPreview)
                    .font(LoreTheme.body)
                    .foregroundStyle(displayContent.hasTranscript || displayContent.hasBiographyDraft ? LoreTheme.ink : LoreTheme.secondaryInk)
                    .lineSpacing(3)
                    .lineLimit(displayContent.hasBiographyDraft ? 3 : 2)

                if let sourceTranscriptPreview = displayContent.sourceTranscriptPreview {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Source transcript")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(LoreTheme.secondaryInk)

                        Text(sourceTranscriptPreview)
                            .font(LoreTheme.caption(.caption))
                            .foregroundStyle(LoreTheme.secondaryInk)
                            .lineLimit(1)
                    }
                }

                Text(story.formattedDuration)
                    .font(LoreTheme.caption(.caption))
                    .foregroundStyle(LoreTheme.secondaryInk)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct StoryDisplayContent {
    let biographyProse: String
    let transcript: String
    let processingStatus: String

    init(story: Story) {
        biographyProse = Self.cleaned(story.biographyProse ?? "")
        transcript = Self.cleaned(story.text)
        processingStatus = story.processingStatus
    }

    var hasBiographyDraft: Bool {
        !biographyProse.isEmpty
    }

    var hasTranscript: Bool {
        !transcript.isEmpty
    }

    var primaryPreview: String {
        if hasBiographyDraft {
            return biographyProse
        }

        return transcriptText
    }

    var sourceTranscriptPreview: String? {
        guard hasBiographyDraft else {
            return nil
        }

        return hasTranscript ? transcript : "No source transcript saved."
    }

    var biographyDetailText: String? {
        hasBiographyDraft ? biographyProse : nil
    }

    var transcriptText: String {
        guard !hasTranscript else { return transcript }
        switch processingStatus {
        case "transcriptionPending", "transcribing":
            return "Transcription in progress…"
        case "transcriptionFailed", "transcriptionCancelled":
            return "Transcription needs attention"
        default:
            return "Story with no transcript"
        }
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    StoriesView(speechRecognizer: SpeechRecognitionViewModel())
}
