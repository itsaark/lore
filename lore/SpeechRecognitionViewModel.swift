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

/// ViewModel for handling speech recognition functionality with comprehensive error handling
@MainActor
class SpeechRecognitionViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var transcribedText = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var isAuthorized = false
    
    // MARK: - Private Properties
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isStoppedByUser = false  // Track if we're intentionally stopping
    
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
        errorMessage = nil
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
        isStoppedByUser = false  // Reset the flag
        
        // Validate prerequisites
        guard isAuthorized else {
            setError("Speech recognition not authorized. Please check Settings.")
            return
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            setError("Speech recognizer not available for your language/region.")
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
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechRecognitionError.recognitionRequestFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false // Use server-based for better accuracy
        
        // Get audio input node
        let inputNode = audioEngine.inputNode
        
        // Create recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let result = result {
                    self.transcribedText = result.bestTranscription.formattedString
                    print("📝 Transcribed: \(result.bestTranscription.formattedString)")
                    
                    // Auto-stop if final result (only if not stopped by user)
                    if result.isFinal && !self.isStoppedByUser {
                        print("✅ Recognition completed naturally")
                        self.stopRecording()
                    }
                }
                
                if let error = error {
                    // Check if this is just a cancellation error from user stopping
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        // This is a cancellation error, which is normal when user stops recording
                        print("ℹ️ Recognition task was cancelled (normal when stopping)")
                        return
                    }
                    
                    // Check for other common "normal" cancellation scenarios
                    if nsError.localizedDescription.lowercased().contains("cancelled") ||
                       nsError.localizedDescription.lowercased().contains("canceled") {
                        if self.isStoppedByUser {
                            print("ℹ️ Recognition cancelled by user action (normal)")
                            return
                        }
                    }
                    
                    // This is a real error we should show to the user
                    self.setError("Recognition error: \(error.localizedDescription)")
                    print("❌ Recognition error: \(error)")
                    self.stopRecording()
                }
            }
        }
        
        // Configure audio tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak recognitionRequest] buffer, _ in
            recognitionRequest?.append(buffer)
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecording = true
        print("🎤 Audio engine started, recording in progress")
    }
    
    /// Stops recording and cleans up resources
    private func stopRecording() {
        print("🛑 Stopping recording...")
        
        // Set flag to indicate this is intentional
        isStoppedByUser = true
        
        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // End recognition request gracefully
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
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