//
//  RecordingsView.swift
//  lore
//
//  Created by AI Assistant
//

import SwiftUI

/// View displaying list of all recordings
struct RecordingsView: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            if speechRecognizer.recordings.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("No Recordings Yet")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Start recording to see your transcriptions here")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                // Recordings list
                List {
                    ForEach(speechRecognizer.recordings.reversed()) { recording in
                        NavigationLink(destination: RecordingDetailView(recording: recording)) {
                            RecordingRowView(recording: recording)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color(.systemGray6))
                    }
                    .onDelete(perform: deleteRecordings)
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
            }
        }
        .navigationTitle("Recordings")
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
    
    private func deleteRecordings(offsets: IndexSet) {
        let reversedRecordings = speechRecognizer.recordings.reversed()
        let recordingsArray = Array(reversedRecordings)
        
        for index in offsets {
            if let originalIndex = speechRecognizer.recordings.firstIndex(where: { $0.id == recordingsArray[index].id }) {
                speechRecognizer.recordings.remove(at: originalIndex)
            }
        }
    }
}

/// Individual row view for recordings list
struct RecordingRowView: View {
    let recording: Recording
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                     "No voice found in recording" : recording.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                Text(recording.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(recording.formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

#Preview {
    RecordingsView(speechRecognizer: SpeechRecognitionViewModel())
}