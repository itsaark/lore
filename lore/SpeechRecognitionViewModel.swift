//
//  SpeechRecognitionViewModel.swift
//  lore
//
//  Created by AI Assistant
//

import Foundation
import Speech
import AVFoundation
import SwiftUI
import Accelerate
import SwiftData

/// ViewModel for handling speech recognition functionality with word-by-word display
@MainActor
class SpeechRecognitionViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var transcribedText = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var isAuthorized = false
    @Published var currentWord = ""
    @Published var wordOpacity: Double = 0.0
    @Published var stories: [Story] = []
    @Published var speechConfidence: Float = 0.0
    @Published var streamingText = ""
    @Published var isProcessingAudio = false
    @Published var currentAudioLevel: Float = 0.0
    
    // MARK: - Private Properties
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isStoppedByUser = false
    private var lastWordTime: Date?
    private var previousWordCount = 0
    private var fadeTimer: Timer?
    private var recordingStartTime: Date?
    private var audioLevelTimer: Timer?
    private var audioLevelBuffer: [Float] = []
    private var modelContext: ModelContext?
    private var hasLoadedStories = false
    
    // MARK: - Initialization
    init() {
        Task {
            await requestPermissions()
        }
    }
    
    // MARK: - Public Methods
    
    /// Toggles recording state
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    /// Clears transcribed text and any error messages
    func clearText() {
        transcribedText = ""
        streamingText = ""
        currentWord = ""
        wordOpacity = 0.0
        speechConfidence = 0.0
        isProcessingAudio = false
        errorMessage = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        currentAudioLevel = 0.0
        stopAudioLevelTimer()
    }

    /// Connects the view model to SwiftData once the view receives its environment context.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext

        guard !hasLoadedStories else {
            return
        }

        loadStories()
        hasLoadedStories = true
    }
    
    /// Updates the text of an existing story.
    func updateStory(_ story: Story, withText newText: String) {
        guard let index = stories.firstIndex(where: { $0.id == story.id }) else {
            print("Story not found for update")
            return
        }
        
        stories[index].text = newText
        stories[index].updatedAt = Date()
        saveContext()
        loadStories()
        print("Story updated successfully")
    }

    /// Deletes stories and persists the updated list.
    func deleteStories(atOffsets offsets: IndexSet) {
        let newestFirstStories = Array(stories.reversed())
        
        for index in offsets {
            guard newestFirstStories.indices.contains(index),
                  let originalIndex = stories.firstIndex(where: { $0.id == newestFirstStories[index].id }) else {
                continue
            }
            
            let story = stories.remove(at: originalIndex)
            modelContext?.delete(story)
        }
        
        saveContext()
        loadStories()
    }
    
    /// Saves pending SwiftData changes.
    private func saveContext() {
        guard let modelContext else { return }

        do {
            try modelContext.save()
        } catch {
            print("Failed to save stories: \(error)")
        }
    }
    
    /// Loads stories from SwiftData.
    private func loadStories() {
        guard let modelContext else { return }
        
        do {
            let descriptor = FetchDescriptor<Story>(
                sortBy: [SortDescriptor(\.date, order: .forward)]
            )
            stories = try modelContext.fetch(descriptor)
        } catch {
            print("Failed to load stories: \(error)")
            stories = []
        }
    }

    // MARK: - Private Methods
    
    /// Requests both speech recognition and microphone permissions
    private func requestPermissions() async {
        // Request Speech Recognition Permission
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                DispatchQueue.main.async {
                    switch authStatus {
                case .authorized:
                    self?.isAuthorized = true
                    self?.errorMessage = nil
                    print("✅ Speech recognition authorized")
                case .denied:
                    self?.isAuthorized = false
                    self?.errorMessage = "Speech recognition access denied. Please enable in Settings > Privacy & Security > Speech Recognition."
                    print("❌ Speech recognition denied")
                case .restricted:
                    self?.isAuthorized = false
                    self?.errorMessage = "Speech recognition is restricted on this device."
                    print("⚠️ Speech recognition restricted")
                case .notDetermined:
                    self?.isAuthorized = false
                    self?.errorMessage = "Speech recognition permission not determined."
                    print("⏳ Speech recognition not determined")
                @unknown default:
                    self?.isAuthorized = false
                    self?.errorMessage = "Unknown speech recognition authorization status."
                    print("❓ Unknown speech recognition status")
                }
                    continuation.resume()
                }
            }
        }
        
        // Request Microphone Permission
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Microphone access granted")
                    } else {
                        self.errorMessage = "Microphone access denied. Please enable in Settings > Privacy & Security > Microphone."
                        print("❌ Microphone access denied")
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    /// Starts speech recognition
    private func startRecording() {
        print("🎤 Attempting to start recording...")
        
        // Reset any previous state
        stopRecording()
        clearText()
        isStoppedByUser = false
        
        // Validate prerequisites
        guard isAuthorized else {
            setError("Speech recognition not authorized. Please check Settings.")
            return
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            setError("Speech recognizer not available for your language/region.")
            return
        }

        guard speechRecognizer.supportsOnDeviceRecognition else {
            setError("On-device speech recognition is not available for your language or device.")
            return
        }
        
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            setError("Microphone access required. Please check Settings.")
            return
        }
        
        do {
            try setupAudioSession()
            try startSpeechRecognition()
            print("✅ Recording started successfully")
        } catch {
            setError("Failed to start recording: \(error.localizedDescription)")
            print("❌ Recording failed to start: \(error)")
        }
    }
    
    /// Configures the audio session for recording
    private func setupAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        print("✅ Audio session configured")
    }
    
    /// Sets up and starts the speech recognition process
    private func startSpeechRecognition() throws {
        // Record start time for duration calculation
        recordingStartTime = Date()
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechRecognitionError.recognitionRequestFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        
        // Get audio input node
        let inputNode = audioEngine.inputNode
        
        // Create recognition task with enhanced streaming support
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let result = result {
                    let newText = result.bestTranscription.formattedString
                    
                    // Update both regular text and streaming text
                    self.transcribedText = newText
                    self.streamingText = newText
                    
                    // Extract confidence from segments
                    if let lastSegment = result.bestTranscription.segments.last {
                        self.speechConfidence = lastSegment.confidence
                        self.isProcessingAudio = true
                    }
                    
                    // Process words for legacy display (keeping for compatibility)
                    self.processNewWords(newText)
                    
                    // Auto-stop if final result (only if not stopped by user)
                    if result.isFinal && !self.isStoppedByUser {
                        print("✅ Recognition completed naturally")
                        self.stopRecording()
                    }
                } else {
                    // No result means silence or processing pause
                    self.isProcessingAudio = false
                    if self.speechConfidence > 0 {
                        // Gradually decrease confidence during silence
                        self.speechConfidence = max(0, self.speechConfidence - 0.1)
                    }
                }
                
                if let error = error {
                    // Check if this is just a cancellation error from user stopping
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        print("ℹ️ Recognition task was cancelled (normal when stopping)")
                        return
                    }
                    
                    if nsError.localizedDescription.lowercased().contains("cancelled") ||
                       nsError.localizedDescription.lowercased().contains("canceled") {
                        if self.isStoppedByUser {
                            print("ℹ️ Recognition cancelled by user action (normal)")
                            return
                        }
                    }
                    
                    self.setError("Recognition error: \(error.localizedDescription)")
                    print("❌ Recognition error: \(error)")
                    self.stopRecording()
                }
            }
        }
        
        // Configure audio tap with enhanced buffer processing for audio level detection
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, weak recognitionRequest] buffer, _ in
            recognitionRequest?.append(buffer)
            
            // Calculate audio level from buffer
            self?.processAudioBuffer(buffer)
            
            // Update audio processing state on main thread
            DispatchQueue.main.async {
                self?.isProcessingAudio = true
            }
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
        
        // Start audio level monitoring
        startAudioLevelTimer()
        
        isRecording = true
        print("🎤 Audio engine started, recording in progress")
    }
    
    /// Processes new words and updates the display
    private func processNewWords(_ text: String) {
        let words = text.split(separator: " ").map(String.init)
        let currentWordCount = words.count
        
        // Check if we have a new word
        if currentWordCount > previousWordCount {
            let newWord = words.last ?? ""
            displayNewWord(newWord)
            previousWordCount = currentWordCount
        }
    }
    
    /// Displays a new word with appropriate fade timing
    private func displayNewWord(_ word: String) {
        // Cancel any existing fade timer
        fadeTimer?.invalidate()
        
        // Calculate time since last word for fade duration
        let timeSinceLastWord = Date().timeIntervalSince(lastWordTime ?? Date())
        lastWordTime = Date()
        
        // Set the new word and show it immediately
        currentWord = word
        wordOpacity = 1.0
        
        // Calculate fade duration based on speech speed
        // Faster speech (shorter intervals) = faster fade
        // Slower speech (longer intervals) = slower fade
        let baseFadeDuration: TimeInterval = 1.5
        let speedMultiplier = min(max(timeSinceLastWord / 2.0, 0.3), 3.0) // Clamp between 0.3x and 3x
        let fadeDuration = baseFadeDuration * speedMultiplier
        
        print("📝 New word: '\(word)', fade duration: \(fadeDuration)s")
        
        // Start fade timer
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Gradual fade over the calculated duration
            let fadeStep = 0.1 / fadeDuration
            self.wordOpacity = max(0.0, self.wordOpacity - fadeStep)
            
            if self.wordOpacity <= 0.0 {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }
    
    /// Process the audio buffer and update the currentAudioLevel
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Calculate RMS (Root Mean Square) for audio level
        var rms: Float = 0.0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
        
        // Convert to decibels and normalize to 0-1 range
        let decibels = 20 * log10(rms + Float.leastNonzeroMagnitude) // Avoid log(0)
        let normalizedLevel = max(0.0, min(1.0, (decibels + 80) / 80)) // Map -80dB to 0dB → 0.0 to 1.0
        
        // Add to buffer for smoothing
        audioLevelBuffer.append(normalizedLevel)
        if audioLevelBuffer.count > 10 {
            audioLevelBuffer.removeFirst()
        }
    }
    
    /// Starts audio level monitoring timer
    private func startAudioLevelTimer() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Calculate smoothed audio level
            if !self.audioLevelBuffer.isEmpty {
                let smoothedLevel = self.audioLevelBuffer.reduce(0, +) / Float(self.audioLevelBuffer.count)
                
                DispatchQueue.main.async {
                    self.currentAudioLevel = smoothedLevel
                }
            }
        }
    }
    
    /// Stops audio level monitoring timer
    private func stopAudioLevelTimer() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        audioLevelBuffer.removeAll()
    }
    
    /// Stops recording and cleans up resources
    private func stopRecording() {
        print("🛑 Stopping recording...")
        
        // Set flag to indicate this is intentional
        isStoppedByUser = true
        
        // Save the current recording if there's text
        saveCurrentRecording()
        
        // Clean up word display and streaming state
        fadeTimer?.invalidate()
        fadeTimer = nil
        currentWord = ""
        wordOpacity = 0.0
        previousWordCount = 0
        speechConfidence = 0.0
        isProcessingAudio = false
        currentAudioLevel = 0.0
        stopAudioLevelTimer()
        
        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // End recognition request gracefully
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        speechConfidence = 0.0
        isProcessingAudio = false
        
        // Stop audio level monitoring
        stopAudioLevelTimer()
        currentAudioLevel = 0.0
        
        // Stop audio engine
        audioEngine.stop()
        
        // Clean up
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        
        print("✅ Recording stopped and cleaned up")
        
        // Clear any cancellation-related error messages
        if let errorMessage = errorMessage, 
           (errorMessage.lowercased().contains("cancelled") || 
            errorMessage.lowercased().contains("canceled")) {
            self.errorMessage = nil
        }
    }
    
    /// Saves the current recording session
    private func saveCurrentRecording() {
        guard let startTime = recordingStartTime else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        let story = Story(
            text: transcribedText,
            date: startTime,
            duration: duration,
            rawTranscriptExpiresAt: Calendar.current.date(
                byAdding: .day,
                value: 120,
                to: startTime
            )
        )
        
        if let modelContext {
            modelContext.insert(story)
            saveContext()
            loadStories()
        } else {
            stories.append(story)
        }
        
        let displayText = story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                         "No voice found in story" : 
                         String(story.text.prefix(50)) + (story.text.count > 50 ? "..." : "")
        print("Story saved: \(story.formattedDuration) - \(displayText)")
        
        // Reset for next recording
        transcribedText = ""
        recordingStartTime = nil
    }
    
    /// Sets error message and logs it
    private func setError(_ message: String) {
        errorMessage = message
        print("❌ Error: \(message)")
    }
}

// MARK: - Supporting Types

/// Custom errors for speech recognition
enum SpeechRecognitionError: Error, LocalizedError {
    case recognitionRequestFailed
    case audioEngineError
    case permissionDenied
    case speechRecognizerUnavailable
    
    var errorDescription: String? {
        switch self {
        case .recognitionRequestFailed:
            return "Failed to create speech recognition request"
        case .audioEngineError:
            return "Audio engine configuration failed"
        case .permissionDenied:
            return "Required permissions not granted"
        case .speechRecognizerUnavailable:
            return "Speech recognizer is not available"
        }
    }
}
