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
                    ForEach(speechRecognizer.stories.reversed()) { story in
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
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                     "Story with no transcript" : story.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                Text(story.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(story.formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

#Preview {
    StoriesView(speechRecognizer: SpeechRecognitionViewModel())
}
