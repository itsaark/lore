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
                                    editedText = story.text
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
                        Text(getCurrentText().isEmpty ? "Story with no transcript" : getCurrentText())
                            .font(.body)
                            .foregroundColor(getCurrentText().isEmpty ? .secondary : .primary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
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
                        editedText = getCurrentText()
                        isEditing = true
                        isTextFieldFocused = true
                    }
                }
                .foregroundColor(.blue)
            }
        }
        .onAppear {
            editedText = story.text
        }
    }
    
    /// Gets the current text to display (updated text if available)
    private func getCurrentText() -> String {
        // Find the updated story from the speech recognizer.
        if let updatedStory = speechRecognizer.stories.first(where: { $0.id == story.id }) {
            return updatedStory.text
        }
        return story.text
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
