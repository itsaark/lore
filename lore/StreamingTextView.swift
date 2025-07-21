//
//  StreamingTextView.swift
//  lore
//
//  Created by AI Assistant
//

import SwiftUI

/// A clean, minimal streaming text view for speech recognition
struct StreamingTextView: View {
    let text: String
    let isRecording: Bool
    let speechConfidence: Float
    
    @State private var displayedText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Text Display Area
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray6).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                isRecording ? Color.black.opacity(0.1) : Color.clear,
                                lineWidth: 1
                            )
                    )
                
                // Content
                Group {
                    if isRecording && !displayedText.isEmpty {
                        // Active transcription
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(displayedText)
                                .font(.title2)
                                .fontWeight(.regular)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                    } else if isRecording {
                        // Listening state
                        VStack(spacing: 16) {
                            // Pulse animation for microphone
                            Circle()
                                .fill(Color.red.opacity(0.1))
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Image(systemName: "mic.fill")
                                        .font(.title2)
                                        .foregroundColor(.red)
                                )
                                .scaleEffect(speechConfidence > 0.3 ? 1.1 : 1.0)
                                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: speechConfidence)
                            
                            Text("Listening...")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        // Idle state
                        VStack(spacing: 16) {
                            Image(systemName: "waveform")
                                .font(.title)
                                .foregroundColor(.secondary.opacity(0.6))
                            
                            Text("Tap to start recording")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: isRecording ? 300 : 200)
            .animation(.easeInOut(duration: 0.3), value: isRecording)
        }
        .onChange(of: text) { oldValue, newValue in
            updateDisplayedText(from: oldValue, to: newValue)
        }
        .onChange(of: isRecording) { _, newValue in
            if !newValue {
                displayedText = text
            }
        }
    }
    
    private func updateDisplayedText(from oldText: String, to newText: String) {
        guard isRecording else {
            displayedText = newText
            return
        }
        
        // Smooth text updates
        withAnimation(.easeOut(duration: 0.1)) {
            displayedText = newText
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        StreamingTextView(
            text: "This is a sample transcription that demonstrates the clean, minimal design.",
            isRecording: true,
            speechConfidence: 0.7
        )
        
        StreamingTextView(
            text: "",
            isRecording: false,
            speechConfidence: 0.0
        )
    }
    .padding()
}