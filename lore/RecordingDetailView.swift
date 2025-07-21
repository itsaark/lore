//
//  RecordingDetailView.swift
//  lore
//
//  Created by AI Assistant
//

import SwiftUI

/// Detail view for displaying individual recording content
struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    
    @State private var isEditing = false
    @State private var editedText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Recording metadata
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.blue)
                        Text(recording.formattedDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                        Text("Duration: \(recording.formattedDuration)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                Divider()
                
                // Recording content
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription")
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
                                    editedText = recording.text
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
                                    speechRecognizer.updateRecording(recording, withText: editedText)
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
                        Text(getCurrentText().isEmpty ? "No voice found in recording" : getCurrentText())
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
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        // Save changes when done
                        speechRecognizer.updateRecording(recording, withText: editedText)
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
            editedText = recording.text
        }
    }
    
    /// Gets the current text to display (updated text if available)
    private func getCurrentText() -> String {
        // Find the updated recording from the speech recognizer
        if let updatedRecording = speechRecognizer.recordings.first(where: { $0.id == recording.id }) {
            return updatedRecording.text
        }
        return recording.text
    }
}

#Preview {
    NavigationView {
        RecordingDetailView(
            recording: Recording(
                text: "This is a sample recording text that shows how the detail view will look with actual content from a speech recognition session.",
                date: Date(),
                duration: 45
            ),
            speechRecognizer: SpeechRecognitionViewModel()
        )
    }
}