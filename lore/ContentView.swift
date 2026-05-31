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
    @State private var glowAnimation = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                // Recording glow overlay when recording
                if speechRecognizer.isRecording {
                    RecordingGlowOverlay(
                        isAnimating: $glowAnimation, 
                        audioLevel: speechRecognizer.currentAudioLevel
                    )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .onAppear {
                            glowAnimation = true
                        }
                        .onDisappear {
                            glowAnimation = false
                        }
                }
                
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
                        // Header - only show when not recording
                        if !speechRecognizer.isRecording {
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
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(speechRecognizer.isRecording ? .red : .primary)
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

// MARK: - Recording Glow Overlay
struct RecordingGlowOverlay: View {
    @Binding var isAnimating: Bool
    let audioLevel: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Calculate glow intensity based on audio level
                let glowIntensity = Double(audioLevel)
                let baseIntensity: Double = 0.15 // Minimum glow when silent
                let maxIntensity: Double = 0.8   // Maximum glow when speaking loudly
                let currentIntensity = baseIntensity + (glowIntensity * (maxIntensity - baseIntensity))
                
                // Calculate blur intensity
                let baseBlur: Double = 15
                let maxBlur: Double = 50
                let currentBlur = baseBlur + (glowIntensity * (maxBlur - baseBlur))
                
                // Calculate scale effect
                let baseScale: Double = 0.8
                let maxScale: Double = 1.3
                let currentScale = baseScale + (glowIntensity * (maxScale - baseScale))
                
                // Top edge glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.red.opacity(currentIntensity * 1.2),
                                Color.orange.opacity(currentIntensity * 0.8),
                                Color.clear
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 120 + (glowIntensity * 80))
                    .position(x: geometry.size.width / 2, y: 0)
                    .blur(radius: currentBlur)
                    .scaleEffect(x: currentScale, y: 1.0)
                
                // Bottom edge glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.pink.opacity(currentIntensity * 0.9),
                                Color.red.opacity(currentIntensity * 0.7)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 120 + (glowIntensity * 70))
                    .position(x: geometry.size.width / 2, y: geometry.size.height)
                    .blur(radius: currentBlur * 0.9)
                    .scaleEffect(x: currentScale, y: 1.0)
                
                // Left edge glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.purple.opacity(currentIntensity * 0.8),
                                Color.pink.opacity(currentIntensity * 0.6),
                                Color.clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 100 + (glowIntensity * 60))
                    .position(x: 0, y: geometry.size.height / 2)
                    .blur(radius: currentBlur * 0.8)
                    .scaleEffect(x: 1.0, y: currentScale)
                
                // Right edge glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.orange.opacity(currentIntensity * 0.7),
                                Color.red.opacity(currentIntensity * 0.9)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 100 + (glowIntensity * 60))
                    .position(x: geometry.size.width, y: geometry.size.height / 2)
                    .blur(radius: currentBlur * 0.8)
                    .scaleEffect(x: 1.0, y: currentScale)
                
                // Corner accents that react more dramatically to audio
                ForEach(0..<4, id: \.self) { corner in
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.red.opacity(currentIntensity * 1.5),
                                    Color.orange.opacity(currentIntensity * 1.0),
                                    Color.clear
                                ]),
                                center: .center,
                                startRadius: 20,
                                endRadius: 100 + (glowIntensity * 100)
                            )
                        )
                        .frame(width: 200, height: 200)
                        .position(
                            x: corner % 2 == 0 ? -50 : geometry.size.width + 50,
                            y: corner < 2 ? -50 : geometry.size.height + 50
                        )
                        .blur(radius: currentBlur * (0.6 + Double(corner) * 0.1))
                        .scaleEffect(currentScale + Double(corner) * 0.1)
                        .opacity(0.7 + (glowIntensity * 0.3))
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: audioLevel) // Fast response to audio changes
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
