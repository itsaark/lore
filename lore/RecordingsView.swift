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
                VStack(spacing: 20) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("No Stories Yet")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Speak your first story to begin your biography")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                // Stories list
                List {
                    ForEach(storiesByCaptureDateNewestFirst) { story in
                        NavigationLink(destination: StoryDetailView(story: story, speechRecognizer: speechRecognizer)) {
                            StoryRowView(story: story)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color(.systemGray6))
                    }
                    .onDelete(perform: speechRecognizer.deleteStories)
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
            }
        }
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") {
                    // Placeholder for edit mode
                }
                .foregroundColor(.blue)
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
                Text(story.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(displayContent.primaryPreview)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(displayContent.hasBiographyDraft ? 3 : 2)

                if let sourceTranscriptPreview = displayContent.sourceTranscriptPreview {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Source transcript")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        Text(sourceTranscriptPreview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(story.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
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
