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

    @Environment(\.dismiss) private var dismiss
    @State private var noteToDelete: Story?
    @State private var isEditing = false
    @State private var editedText: String = ""
    @State private var editorFrame = CGRect.zero
    @State private var editSectionFrame = CGRect.zero
    @State private var saveButtonFrame = CGRect.zero
    @State private var saveWave: TranscriptSaveWave?
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
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }

                            // Edit action buttons
                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    editedText = currentStory.text
                                    isEditing = false
                                    isTextFieldFocused = false
                                }
                                .buttonStyle(.lorePillSecondary)

                                Button("Save") {
                                    saveTranscript(withWave: true)
                                }
                                .buttonStyle(.lorePill)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { saveButtonFrame = $0 }
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editSectionFrame = $0 }
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

                if !isEditing {
                    Button(role: .destructive) {
                        noteToDelete = currentStory
                    } label: {
                        Label("Delete Voice Note", systemImage: "trash")
                            .font(LoreTheme.label)
                            .foregroundStyle(LoreTheme.attention)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("deleteVoiceNoteButton")
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .overlay {
            if let saveWave {
                GeometryReader { geometry in
                    let origin = geometry.frame(in: .global).origin
                    DistortionWave(
                        isRevealing: true,
                        source: saveWave.button,
                        cornerRadius: LoreTheme.tileCornerRadius,
                        onFinish: { self.saveWave = nil }
                    ) {
                        saveWave.surface
                    }
                    .frame(width: saveWave.section.width, height: saveWave.section.height)
                    .offset(x: saveWave.section.minX - origin.x, y: saveWave.section.minY - origin.y)
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
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
                        saveTranscript(withWave: false)
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
        .voiceNoteDeletionConfirmation(for: $noteToDelete) { note in
            if speechRecognizer.deleteStory(note) { dismiss() }
        }
    }

    private func saveTranscript(withWave: Bool) {
        let changed = editedText != currentStory.text
        guard speechRecognizer.updateStory(story, withText: editedText) else { return }
        if withWave, changed, !editSectionFrame.isEmpty {
            saveWave = TranscriptSaveWave(
                text: editedText, section: editSectionFrame, editorHeight: editorFrame.height, button: saveButtonFrame
            )
        }
        isEditing = false
        isTextFieldFocused = false
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

private struct TranscriptSaveWave {
    let text: String
    let section: CGRect
    let editorHeight: CGFloat
    let button: CGRect

    @MainActor var surface: some View {
        LoreTheme.canvas.overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 14) {
                Text(text)
                    .font(LoreTheme.body)
                    .foregroundStyle(LoreTheme.ink)
                    .lineSpacing(4)
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: editorHeight, alignment: .topLeading)
                    .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius)
                            .strokeBorder(LoreTheme.hairline)
                    }
                    .clipped()

                HStack(spacing: 12) {
                    Button("Cancel") {}
                        .buttonStyle(.lorePillSecondary)
                    Button("Save") {}
                        .buttonStyle(.lorePill)
                }
            }
        }
    }
}

extension View {
    func voiceNoteDeleteActions(_ requestDeletion: @escaping () -> Void) -> some View {
        swipeActions(allowsFullSwipe: false) {
            Button(action: requestDeletion) {
                Label("Delete Voice Note", systemImage: "trash")
            }
            .tint(LoreTheme.attention)
            .accessibilityIdentifier("deleteVoiceNoteButton")
        }
        .contextMenu {
            Button(role: .destructive, action: requestDeletion) {
                Label("Delete Voice Note", systemImage: "trash")
            }
            .accessibilityIdentifier("deleteVoiceNoteButton")
        }
    }

    func voiceNoteDeletionConfirmation(
        for note: Binding<Story?>,
        onDelete: @escaping (Story) -> Void
    ) -> some View {
        confirmationDialog(
            "Delete this voice note?",
            isPresented: Binding(
                get: { note.wrappedValue != nil },
                set: { if !$0 { note.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: note.wrappedValue
        ) { story in
            Button("Delete Voice Note", role: .destructive) { onDelete(story) }
                .accessibilityIdentifier("confirmDeleteVoiceNoteButton")
            Button("Cancel", role: .cancel) {}
        } message: { story in
            if story.rememberedTime?.isCoarse == true {
                Text("This voice note, its memory, and its painting will be removed.")
            } else {
                Text("Its recording and transcript are removed, and this day's story is rewritten without it.")
            }
        }
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
