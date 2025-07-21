//
//  ContentView.swift
//  lore
//
//  Created by Aark Koduru on 7/18/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognitionViewModel()
    @State private var showingRecordings = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top Navigation Bar
                HStack {
                    NavigationLink(destination: RecordingsView(speechRecognizer: speechRecognizer)) {
                        Image(systemName: "doc.text")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        // Settings action - placeholder for now
                        print("Settings tapped")
                    }) {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                Spacer()
                
                // Main Content
                VStack(spacing: 40) {
                    // Header - only show when not recording
                    if !speechRecognizer.isRecording {
                        VStack(spacing: 8) {
                            Text("Speak your story ")
                                .font(.largeTitle)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    
                    // Streaming Text Display
                    StreamingTextView(
                        text: speechRecognizer.streamingText,
                        isRecording: speechRecognizer.isRecording,
                        speechConfidence: speechRecognizer.speechConfidence
                    )
                    .animation(.easeInOut(duration: 0.3), value: speechRecognizer.isRecording)
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Bottom Controls
                VStack(spacing: 20) {
                    // Main Record Button
                    Button(action: {
                        speechRecognizer.toggleRecording()
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                                .font(.title2)
                            Text(speechRecognizer.isRecording ? "Stop" : "Start Recording")
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(
                            speechRecognizer.isRecording ? 
                            Color.red : (speechRecognizer.isAuthorized ? Color.black : Color.gray)
                        )
                        .clipShape(Capsule())
                    }
                    .disabled(!speechRecognizer.isAuthorized)
                    .scaleEffect(speechRecognizer.isRecording ? 1.05 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: speechRecognizer.isRecording)
                    
                    // Authorization Status - only show if not authorized
                    if !speechRecognizer.isAuthorized {
                        Text("Please authorize Speech Recognition in Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    // Error Display
                    if let errorMessage = speechRecognizer.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.red.opacity(0.1))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingRecordings) {
            RecordingsView(speechRecognizer: speechRecognizer)
        }
    }
}

#Preview {
    ContentView()
}
