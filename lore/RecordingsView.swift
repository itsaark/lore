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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(story.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer(minLength: 8)

                    StoryStatusBadge(content: displayContent)
                }

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

private struct StoryStatusBadge: View {
    let content: StoryDisplayContent

    var body: some View {
        Label(content.listStatusText, systemImage: content.statusIconName)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(content.statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(content.statusColor.opacity(0.12))
            )
            .lineLimit(1)
    }
}

struct StoryDisplayContent {
    let biographyProse: String
    let transcript: String
    let processingStatus: StoryProcessingDisplayStatus

    init(story: Story) {
        biographyProse = Self.cleaned(story.biographyProse ?? "")
        transcript = Self.cleaned(story.text)
        processingStatus = StoryProcessingDisplayStatus(rawValue: story.processingStatus)
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
        hasTranscript ? transcript : "Story with no transcript"
    }

    var listStatusText: String {
        processingStatus.listText(hasBiographyDraft: hasBiographyDraft)
    }

    var detailStatusText: String {
        processingStatus.detailText(hasBiographyDraft: hasBiographyDraft)
    }

    var statusIconName: String {
        processingStatus.iconName(hasBiographyDraft: hasBiographyDraft)
    }

    var statusColor: Color {
        processingStatus.color(hasBiographyDraft: hasBiographyDraft)
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum StoryProcessingDisplayStatus: Equatable {
    case captured
    case awaitingModel
    case processing
    case processed
    case failed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "captured":
            self = .captured
        case "awaitingModel":
            self = .awaitingModel
        case "processing":
            self = .processing
        case "processed":
            self = .processed
        case "failed":
            self = .failed
        default:
            self = .unknown(rawValue)
        }
    }

    func listText(hasBiographyDraft: Bool) -> String {
        switch self {
        case .failed:
            return "Draft Failed"
        case .processing:
            return "Writing Draft"
        case .processed:
            return hasBiographyDraft ? "Draft Ready" : "Draft Missing"
        case .awaitingModel:
            return hasBiographyDraft ? "Draft Ready" : "Waiting for Local AI"
        case .captured:
            return hasBiographyDraft ? "Draft Ready" : "Pending Draft"
        case .unknown(let rawValue):
            return rawValue.isEmpty ? "Pending Draft" : rawValue
        }
    }

    func detailText(hasBiographyDraft: Bool) -> String {
        switch self {
        case .captured:
            return hasBiographyDraft ? "Biography draft is ready." : "Ready for local biography generation."
        case .awaitingModel:
            return hasBiographyDraft ? "Biography draft is ready." : "Load the local AI model to generate this draft."
        case .processing:
            return "Writing biography prose and updating memory on device."
        case .processed:
            return hasBiographyDraft ? "Biography draft is ready." : "Lore marked this story processed, but no biography draft was saved."
        case .failed:
            return "Lore could not finish local processing for this story."
        case .unknown:
            return hasBiographyDraft ? "Biography draft is ready." : "Waiting for local processing."
        }
    }

    func iconName(hasBiographyDraft: Bool) -> String {
        switch self {
        case .failed:
            return "exclamationmark.triangle"
        case .processing:
            return "hourglass"
        case .processed:
            return hasBiographyDraft ? "checkmark.seal" : "exclamationmark.circle"
        case .awaitingModel:
            return hasBiographyDraft ? "checkmark.seal" : "sparkles"
        case .captured:
            return hasBiographyDraft ? "checkmark.seal" : "sparkles"
        case .unknown:
            return hasBiographyDraft ? "checkmark.seal" : "sparkles"
        }
    }

    func color(hasBiographyDraft: Bool) -> Color {
        switch self {
        case .failed:
            return .red
        case .processing:
            return .blue
        case .processed:
            return hasBiographyDraft ? .green : .orange
        case .awaitingModel:
            return hasBiographyDraft ? .green : .blue
        case .captured:
            return hasBiographyDraft ? .green : .secondary
        case .unknown:
            return hasBiographyDraft ? .green : .secondary
        }
    }
}

#Preview {
    StoriesView(speechRecognizer: SpeechRecognitionViewModel())
}
