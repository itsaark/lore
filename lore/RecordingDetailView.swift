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
                    
                    Text(recording.text.isEmpty ? "No voice found in recording" : recording.text)
                        .font(.body)
                        .foregroundColor(recording.text.isEmpty ? .secondary : .primary)
                        .lineSpacing(4)
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
                Button("Edit") {
                    // Placeholder for edit functionality
                }
                .foregroundColor(.blue)
            }
        }
    }
}

#Preview {
    NavigationView {
        RecordingDetailView(recording: Recording(
            text: "This is a sample recording text that shows how the detail view will look with actual content from a speech recognition session.",
            date: Date(),
            duration: 45
        ))
    }
}