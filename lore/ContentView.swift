//
//  ContentView.swift
//  lore
//
//  Created by Aark Koduru on 7/18/25.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    let userProfile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @StateObject private var modelManager = ModelManager()
    @StateObject private var speechRecognizer = SpeechRecognitionViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Top Navigation Bar
                    HStack {
                        NavigationLink(destination: StoriesView(speechRecognizer: speechRecognizer)) {
                            Image(systemName: "doc.text")
                                .font(.title3)
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        NavigationLink(destination: LocalAISetupView(modelManager: modelManager)) {
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
                        if speechRecognizer.isRecording {
                            VStack(spacing: 24) {
                                CloudWaveOrb(
                                    state: .listening,
                                    audioLevel: speechRecognizer.currentAudioLevel
                                )

                                Text("Listening…")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                        } else {
                            VStack(spacing: 8) {
                                Text("Speak your story")
                                    .font(.largeTitle)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)

                                Text("Lore is listening, \(userProfile.name).")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 20)
                    .animation(.smooth(duration: 0.45), value: speechRecognizer.isRecording)
                    
                    Spacer()
                    
                    // Bottom Controls
                    VStack(spacing: 20) {
                        // Main Record Button
                        Button(action: {
                            speechRecognizer.toggleRecording()
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                                    .font(.headline)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(speechRecognizer.isRecording ? "Stop" : "Start Story")
                                    .font(.headline)
                                    .fontWeight(.medium)
                                    .contentTransition(.opacity)
                            }
                            .fontWeight(.semibold)
                        }
                        .buttonStyle(StoryRecordButtonStyle(isRecording: speechRecognizer.isRecording))
                        .disabled(!speechRecognizer.isAuthorized)
                        .scaleEffect(speechRecognizer.isRecording ? 1.02 : 1.0)
                        .animation(.smooth(duration: 0.3), value: speechRecognizer.isRecording)
                        .sensoryFeedback(.impact(weight: .medium), trigger: speechRecognizer.isRecording)
                        
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
            }
            .navigationBarHidden(true)
            .onAppear {
                speechRecognizer.configure(
                    modelContext: modelContext,
                    generationService: LocalGenerationService(modelManager: modelManager),
                    userProfile: userProfile
                )
            }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                modelManager.unloadModel(message: "Local model unloaded after a memory warning.")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                modelManager.unloadModel(message: "Local model unloaded while Lore is in the background.")
            }
#endif
        }
    }
}

private struct StoryRecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return Color(.systemGray4)
        }

        if isRecording {
            return .red
        }

        return colorScheme == .dark ? .white : .black
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return Color(.secondaryLabel)
        }

        if isRecording {
            return .white
        }

        return colorScheme == .dark ? .black : .white
    }
}

#Preview {
    ContentView(
        userProfile: UserProfile(
            name: "Aark",
            hometown: "Hyderabad",
            birthYear: 1994
        )
    )
    .modelContainer(LoreModelContainer.preview)
}
