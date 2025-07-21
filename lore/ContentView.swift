//
//  ContentView.swift
//  lore
//
//  Created by Aark Koduru on 7/18/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognitionViewModel()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Top Navigation Bar
                HStack {
                    Button(action: {
                        // Folder/Archive action - placeholder for now
                        print("Folder tapped")
                    }) {
                        Image(systemName: "folder")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        // Settings action - placeholder for now
                        print("Settings tapped")
                    }) {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                // Header
                VStack(spacing: 10) {
                    Text("Speech to Text")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Powered by iOS Speech Recognition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top)
                
                // Microphone Visual Indicator
                VStack {
                    Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 80))
                        .foregroundColor(speechRecognizer.isRecording ? .red : .blue)
                        .scaleEffect(speechRecognizer.isRecording ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: speechRecognizer.isRecording)
                    
                    if speechRecognizer.isRecording {
                        Text("Listening...")
                            .font(.headline)
                            .foregroundColor(.red)
                            .padding(.top, 5)
                    }
                }
                .padding(.vertical)
                
                // Dynamic Word Display
                VStack {
                    Text("Words")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(speechRecognizer.isRecording ? Color.red : Color.clear, lineWidth: 2)
                            )
                            .frame(height: 120)
                        
                        if speechRecognizer.isRecording && !speechRecognizer.currentWord.isEmpty {
                            Text(speechRecognizer.currentWord)
                                .font(.title)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .opacity(speechRecognizer.wordOpacity)
                                .animation(.easeInOut(duration: 0.1), value: speechRecognizer.wordOpacity)
                        } else if !speechRecognizer.isRecording {
                            Text("Start speaking to see words appear here...")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                }
                .padding(.horizontal)
                
                // Transcription Display
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Transcription:")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        if !speechRecognizer.transcribedText.isEmpty {
                            Button("Clear") {
                                speechRecognizer.clearText()
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    }
                    
                    ScrollView {
                        Text(speechRecognizer.transcribedText.isEmpty ? 
                             "Your speech will appear here in real-time..." : 
                             speechRecognizer.transcribedText)
                            .font(.body)
                            .foregroundColor(speechRecognizer.transcribedText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .animation(.easeInOut(duration: 0.3), value: speechRecognizer.transcribedText)
                    }
                    .frame(minHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(speechRecognizer.isRecording ? Color.red : Color.clear, lineWidth: 2)
                            )
                    )
                }
                .padding(.horizontal)
                
                // Control Buttons
                VStack(spacing: 15) {
                    // Main Record Button
                    Button(action: {
                        speechRecognizer.toggleRecording()
                    }) {
                        HStack {
                            Image(systemName: speechRecognizer.isRecording ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                            Text(speechRecognizer.isRecording ? "Stop Recording" : "Start Recording")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 15)
                        .background(
                            speechRecognizer.isRecording ? 
                            Color.red : (speechRecognizer.isAuthorized ? Color.blue : Color.gray)
                        )
                        .cornerRadius(25)
                    }
                    .disabled(!speechRecognizer.isAuthorized)
                    .animation(.easeInOut(duration: 0.2), value: speechRecognizer.isRecording)
                    
                    // Authorization Status
                    HStack {
                        Image(systemName: speechRecognizer.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(speechRecognizer.isAuthorized ? .green : .orange)
                        
                        Text(speechRecognizer.isAuthorized ? 
                             "Speech Recognition Authorized" : 
                             "Please authorize Speech Recognition in Settings")
                            .font(.caption)
                            .foregroundColor(speechRecognizer.isAuthorized ? .green : .orange)
                    }
                }
                .padding(.horizontal)
                
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
                
                Spacer()
            }
            .padding()
            .navigationBarHidden(true)
        }
    }
}

#Preview {
    ContentView()
}