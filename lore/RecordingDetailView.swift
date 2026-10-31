//
//  RecordingDetailView.swift
//  lore
//
//  Created by AI Assistant
//

import SwiftUI

/// Detail view for displaying individual story content.
struct StoryDetailView: View {
    let story: Story
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    
    @State private var isEditing = false
    @State private var editedText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    private var displayContent: StoryDisplayContent {
        StoryDisplayContent(story: currentStory)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Story metadata
                VStack(alignment: .leading, spacing: 10) {
                    LoreSectionHeader(story.formattedDate)

                    Text(story.formattedDuration)
                        .font(LoreTheme.caption())
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .accessibilityLabel("Duration: \(story.formattedDuration)")
                }

                if let biographyProse = displayContent.biographyDetailText {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Journal Entry")
                            .font(LoreTheme.title())
                            .foregroundStyle(LoreTheme.ink)
                            .accessibilityAddTraits(.isHeader)

                        Text(biographyProse)
                            .font(.system(.title3, design: .serif))
                            .foregroundStyle(LoreTheme.ink)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }

                    LoreHairline()
                }

                // Story content
                VStack(alignment: .leading, spacing: 14) {
                    LoreSectionHeader("Transcript")

                    if isEditing {
                        // Edit mode - show text field
                        VStack(alignment: .trailing, spacing: 14) {
                            TextEditor(text: $editedText)
                                .focused($isTextFieldFocused)
                                .font(LoreTheme.body)
                                .foregroundStyle(LoreTheme.ink)
                                .lineSpacing(4)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .background(
                                    LoreTheme.surface,
                                    in: RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                                        .strokeBorder(LoreTheme.hairline)
                                }
                                .frame(minHeight: 160)

                            // Edit action buttons
                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    editedText = currentStory.text
                                    isEditing = false
                                    isTextFieldFocused = false
                                }
                                .buttonStyle(.lorePillSecondary)

                                Button("Save") {
                                    speechRecognizer.updateStory(story, withText: editedText)
                                    isEditing = false
                                    isTextFieldFocused = false
                                }
                                .buttonStyle(.lorePill)
                            }
                        }
                    } else {
                        // View mode - show text
                        LoreCard {
                            Text(transcriptDisplayText)
                                .font(displayContent.hasTranscript ? LoreTheme.body : LoreTheme.caption(.body))
                                .foregroundStyle(displayContent.hasTranscript ? LoreTheme.ink : LoreTheme.secondaryInk)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }

                        if canRetryTranscription {
                            Button("Retry Transcription") {
                                speechRecognizer.retryTranscription(for: currentStory)
                            }
                            .buttonStyle(.lorePill)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .loreCanvas()
        .navigationTitle("Story")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(LoreTheme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Story")
                    .font(LoreTheme.title(.headline))
                    .foregroundStyle(LoreTheme.ink)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        // Save changes when done
                        speechRecognizer.updateStory(story, withText: editedText)
                        isEditing = false
                        isTextFieldFocused = false
                    } else {
                        // Start editing
                        editedText = currentStory.text
                        isEditing = true
                        isTextFieldFocused = true
                    }
                }
                .fontWeight(isEditing ? .semibold : .regular)
                .foregroundStyle(LoreTheme.ink)
            }
        }
        .onAppear {
            editedText = currentStory.text
        }
    }

    private var currentStory: Story {
        speechRecognizer.stories.first(where: { $0.id == story.id }) ?? story
    }

    private var transcriptDisplayText: String {
        guard !displayContent.hasTranscript else { return displayContent.transcriptText }
        switch currentStory.processingStatus {
        case "transcriptionPending", "transcribing":
            return "Lore is securely connecting and transcribing this saved recording."
        case "transcriptionFailed", "transcriptionCancelled":
            return "Lore couldn’t transcribe this recording. The saved audio is still on this iPhone."
        default:
            return displayContent.transcriptText
        }
    }

    private var canRetryTranscription: Bool {
        !displayContent.hasTranscript
            && ["transcriptionFailed", "transcriptionCancelled"].contains(currentStory.processingStatus)
    }
}

#Preview {
    NavigationView {
        StoryDetailView(
            story: Story(
                text: "This is a sample story text that shows how the detail view will look with actual content from a speech recognition session.",
                date: Date(),
                duration: 45
            ),
            speechRecognizer: SpeechRecognitionViewModel()
        )
    }
}
