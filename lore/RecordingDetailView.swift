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
            VStack(alignment: .leading, spacing: 20) {
                // Story metadata
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.blue)
                        Text(story.formattedDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                        Text("Duration: \(story.formattedDuration)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                Divider()

                if let biographyProse = displayContent.biographyDetailText {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Journal Entry")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(biographyProse)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal)

                    Divider()
                }
                
                // Story content
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if isEditing {
                        // Edit mode - show text field
                        VStack(alignment: .trailing, spacing: 12) {
                            TextEditor(text: $editedText)
                                .focused($isTextFieldFocused)
                                .font(.body)
                                .lineSpacing(4)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.systemGray6))
                                        .stroke(Color(.systemGray4), lineWidth: 1)
                                )
                                .frame(minHeight: 120)
                            
                            // Edit action buttons
                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    editedText = currentStory.text
                                    isEditing = false
                                    isTextFieldFocused = false
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.systemGray5))
                                )
                                
                                Button("Save") {
                                    speechRecognizer.updateStory(story, withText: editedText)
                                    isEditing = false
                                    isTextFieldFocused = false
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue)
                                )
                            }
                        }
                    } else {
                        // View mode - show text
                        Text(transcriptDisplayText)
                            .font(.body)
                            .foregroundColor(displayContent.hasTranscript ? .primary : .secondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)

                        if canRetryTranscription {
                            Button("Retry Transcription") {
                                speechRecognizer.retryTranscription(for: currentStory)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Story")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
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
                .foregroundColor(.blue)
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
