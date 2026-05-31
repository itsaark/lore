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
    private let metadataService: any MetadataService
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isStoppedByUser = false
    private var lastWordTime: Date?
    private var previousWordCount = 0
    private var fadeTimer: Timer?
    private var recordingStartTime: Date?
    private var currentRecordingAudioFileURL: URL?
    private var audioLevelTimer: Timer?
    private var audioLevelBuffer: [Float] = []
    private var pendingSaveTask: Task<Void, Never>?
    private var modelContext: ModelContext?
    private var generationService: (any GenerationService)?
    private var userProfile: UserProfile?
    private var hasLoadedStories = false
    private static let audioRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let placeholderAudioScheme = "lore-audio-placeholder"
    
    // MARK: - Initialization
    init(metadataService: any MetadataService = LocalMetadataService()) {
        self.metadataService = metadataService

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
    func configure(
        modelContext: ModelContext,
        generationService: any GenerationService,
        userProfile: UserProfile
    ) {
        self.modelContext = modelContext
        self.generationService = generationService
        self.userProfile = userProfile

        guard !hasLoadedStories else {
            return
        }

        cleanupExpiredAudioAssets()
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
        stories[index].biographyProse = nil
        stories[index].processingStatus = "awaitingModel"
        stories[index].updatedAt = Date()
        let storyToRegenerate = stories[index]
        saveContext()
        Task {
            await processCapturedStory(storyToRegenerate)
        }
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
            if let modelContext {
                do {
                    try Self.deleteAudioAssets(for: story, in: modelContext)
                    try Self.deleteStoryMetadata(for: story, in: modelContext)
                } catch {
                    setError("Failed to delete story support data: \(error.localizedDescription)")
                    print("Failed to delete story support data: \(error)")
                }
                modelContext.delete(story)
            }
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

    /// Marks expired audio metadata deleted and removes the backing file when one exists.
    func cleanupExpiredAudioAssets(now: Date = Date()) {
        guard let modelContext else { return }

        do {
            _ = try Self.cleanupExpiredAudioAssets(in: modelContext, now: now)
        } catch {
            print("Failed to clean up expired audio assets: \(error)")
        }
    }

    @discardableResult
    static func cleanupExpiredAudioAssets(
        in modelContext: ModelContext,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Int {
        let allAssets = try modelContext.fetch(FetchDescriptor<AudioAsset>())
        let expiredAssets = allAssets.filter { asset in
            !asset.isDeleted && asset.expiresAt <= now
        }

        for asset in expiredAssets {
            try removeAudioFileIfPresent(at: asset.fileURL, fileManager: fileManager)
            asset.isDeleted = true
        }

        if !expiredAssets.isEmpty {
            try modelContext.save()
        }

        return expiredAssets.count
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
        stopRecording(shouldSave: false, waitForFinalTranscript: false)
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
            discardCurrentAudioFile()
            recordingStartTime = nil
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
                        self.stopRecording(waitForFinalTranscript: false)
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
                    if Self.shouldIgnoreRecognitionError(
                        error,
                        isStoppedByUser: self.isStoppedByUser,
                        hasTranscript: !self.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        print("ℹ️ Ignoring benign recognition error: \(error)")
                        return
                    }
                    
                    self.setError("Recognition error: \(error.localizedDescription)")
                    print("❌ Recognition error: \(error)")
                    self.stopRecording(waitForFinalTranscript: false)
                }
            }
        }
        
        // Configure audio tap with enhanced buffer processing for audio level detection
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let audioFileURL = try Self.makeAudioFileURL(forStoryID: UUID())
        let audioFile = try AVAudioFile(forWriting: audioFileURL, settings: recordingFormat.settings)
        currentRecordingAudioFileURL = audioFileURL

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, weak recognitionRequest, audioFile] buffer, _ in
            recognitionRequest?.append(buffer)
            do {
                try audioFile.write(from: buffer)
            } catch {
                DispatchQueue.main.async {
                    self?.setError("Failed to save recording audio: \(error.localizedDescription)")
                }
            }
            
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
    private func stopRecording(
        shouldSave: Bool = true,
        waitForFinalTranscript: Bool = true
    ) {
        print("🛑 Stopping recording...")
        
        // Set flag to indicate this is intentional
        isStoppedByUser = true
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // End recognition request gracefully
        recognitionRequest?.endAudio()
        if !waitForFinalTranscript {
            recognitionTask?.cancel()
        }
        
        speechConfidence = 0.0
        isProcessingAudio = false
        
        // Stop audio level monitoring
        stopAudioLevelTimer()
        currentAudioLevel = 0.0
        
        // Stop audio engine
        audioEngine.stop()

        if shouldSave {
            pendingSaveTask = Task { [weak self] in
                if waitForFinalTranscript {
                    do {
                        try await Task.sleep(for: .milliseconds(800))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.saveCurrentRecording()
            }
        } else {
            discardCurrentAudioFile()
            recordingStartTime = nil
        }

        // Clean up word display and streaming state
        fadeTimer?.invalidate()
        fadeTimer = nil
        currentWord = ""
        wordOpacity = 0.0
        previousWordCount = 0
        speechConfidence = 0.0
        isProcessingAudio = false
        currentAudioLevel = 0.0
        
        // Clean up
        recognitionRequest = nil
        if !waitForFinalTranscript {
            recognitionTask = nil
        }
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
    private func saveCurrentRecording() async {
        guard let startTime = recordingStartTime else { return }
        
        let endTime = Date()
        let transcript = transcribedText
        let audioFileURL = currentRecordingAudioFileURL
        let story: Story

        pendingSaveTask = nil
        transcribedText = ""
        recordingStartTime = nil
        currentRecordingAudioFileURL = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        if let modelContext {
            do {
                story = try await Self.persistCapturedStory(
                    transcript: transcript,
                    startTime: startTime,
                    endTime: endTime,
                    audioFileURL: audioFileURL,
                    metadataService: metadataService,
                    modelContext: modelContext
                )
            } catch {
                discardAudioFile(at: audioFileURL)
                setError("Failed to save story: \(error.localizedDescription)")
                print("Failed to save story and audio metadata: \(error)")
                return
            }

            loadStories()
            if !story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task {
                    await processCapturedStory(story)
                }
            }
        } else {
            story = Self.makeStory(transcript: transcript, startTime: startTime, endTime: endTime)
            stories.append(story)
            discardAudioFile(at: audioFileURL)
        }
        
        let displayText = story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                         "No voice found in story" : 
                         String(story.text.prefix(50)) + (story.text.count > 50 ? "..." : "")
        print("Story saved: \(story.formattedDuration) - \(displayText)")
    }

    @discardableResult
    static func persistCapturedStory(
        transcript: String,
        startTime: Date,
        endTime: Date,
        audioFileURL: URL? = nil,
        metadataService: any MetadataService = LocalMetadataService(),
        modelContext: ModelContext
    ) async throws -> Story {
        let metadata = await metadataService.makeCaptureMetadata(captureDate: startTime)
        let story = makeStory(
            transcript: transcript,
            startTime: startTime,
            endTime: endTime,
            metadataId: metadata.id
        )
        let audioAsset = audioFileURL.map {
            makeAudioAsset(storyID: story.id, fileURL: $0, createdAt: endTime, duration: story.duration)
        } ?? makePlaceholderAudioAsset(storyID: story.id, createdAt: endTime, duration: story.duration)

        modelContext.insert(story)
        modelContext.insert(metadata)
        modelContext.insert(audioAsset)
        try modelContext.save()

        return story
    }

    static func makeAudioAsset(
        storyID: UUID,
        fileURL: URL,
        createdAt: Date,
        duration: TimeInterval
    ) -> AudioAsset {
        AudioAsset(
            id: storyID,
            fileURL: fileURL.absoluteString,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(audioRetentionInterval),
            duration: duration,
            isDeleted: false
        )
    }

    static func makePlaceholderAudioAsset(
        storyID: UUID,
        createdAt: Date,
        duration: TimeInterval
    ) -> AudioAsset {
        AudioAsset(
            id: storyID,
            fileURL: placeholderAudioURL(forStoryID: storyID).absoluteString,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(audioRetentionInterval),
            duration: duration,
            isDeleted: false
        )
    }

    static func placeholderAudioURL(forStoryID storyID: UUID) -> URL {
        // The current AVAudioEngine path feeds Speech directly and does not persist audio bytes yet.
        // This metadata-only URL is intentionally non-file so cleanup will not pretend audio exists.
        URL(string: "\(placeholderAudioScheme)://metadata-only/stories/\(storyID.uuidString)")!
    }

    static func isPlaceholderAudioURL(_ fileURL: String) -> Bool {
        URL(string: fileURL)?.scheme == placeholderAudioScheme
    }

    static func makeAudioFileURL(
        forStoryID storyID: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try audioStorageDirectory(fileManager: fileManager)
        return directory.appendingPathComponent("\(storyID.uuidString).caf")
    }

    static func audioStorageDirectory(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Lore", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func deleteAudioAssets(
        for story: Story,
        in modelContext: ModelContext,
        fileManager: FileManager = .default
    ) throws -> Int {
        let allAssets = try modelContext.fetch(FetchDescriptor<AudioAsset>())
        let linkedAssets = allAssets.filter { $0.id == story.id }

        for asset in linkedAssets {
            try removeAudioFileIfPresent(at: asset.fileURL, fileManager: fileManager)
            modelContext.delete(asset)
        }

        return linkedAssets.count
    }

    @discardableResult
    static func deleteStoryMetadata(
        for story: Story,
        in modelContext: ModelContext
    ) throws -> Int {
        guard let metadataId = story.metadataId else {
            return 0
        }

        let allMetadata = try modelContext.fetch(FetchDescriptor<StoryMetadata>())
        let linkedMetadata = allMetadata.filter { $0.id == metadataId }

        for metadata in linkedMetadata {
            modelContext.delete(metadata)
        }

        return linkedMetadata.count
    }

    private static func makeStory(
        transcript: String,
        startTime: Date,
        endTime: Date,
        metadataId: UUID? = nil
    ) -> Story {
        Story(
            text: transcript,
            date: startTime,
            duration: endTime.timeIntervalSince(startTime),
            rawTranscriptExpiresAt: startTime.addingTimeInterval(120 * 24 * 60 * 60),
            metadataId: metadataId,
            createdAt: endTime,
            updatedAt: endTime
        )
    }

    private static func removeAudioFileIfPresent(
        at fileURL: String,
        fileManager: FileManager
    ) throws {
        let candidateURL: URL

        if let url = URL(string: fileURL), url.scheme != nil {
            candidateURL = url
        } else {
            candidateURL = URL(fileURLWithPath: fileURL)
        }

        guard candidateURL.isFileURL else {
            return
        }

        if fileManager.fileExists(atPath: candidateURL.path) {
            try fileManager.removeItem(at: candidateURL)
        }
    }

    private func discardCurrentAudioFile() {
        discardAudioFile(at: currentRecordingAudioFileURL)
        self.currentRecordingAudioFileURL = nil
    }

    private func discardAudioFile(at audioFileURL: URL?) {
        guard let audioFileURL else { return }

        try? Self.removeAudioFileIfPresent(
            at: audioFileURL.absoluteString,
            fileManager: .default
        )
    }

    private func processCapturedStory(_ story: Story) async {
        guard let generationService, let userProfile else {
            story.processingStatus = "awaitingModel"
            story.updatedAt = Date()
            saveContext()
            loadStories()
            return
        }
        defer {
            generationService.releaseResources()
        }

        story.processingStatus = "processing"
        story.updatedAt = Date()
        saveContext()

        do {
            story.biographyProse = try await generationService.writeBiographyProse(
                from: story,
                userProfile: userProfile
            )
            let graphJSON = try await generationService.extractMemoryGraph(
                from: story,
                userProfile: userProfile
            )
            if let modelContext {
                try MemoryGraphService.persistExtractionJSON(graphJSON, for: story, in: modelContext)
            }
            story.processingStatus = "processed"
        } catch GenerationError.localModelNotReady {
            story.processingStatus = "awaitingModel"
        } catch {
            story.processingStatus = "failed"
            setError(error.localizedDescription)
        }

        story.updatedAt = Date()
        saveContext()
        loadStories()
    }
    
    /// Sets error message and logs it
    private func setError(_ message: String) {
        errorMessage = message
        print("❌ Error: \(message)")
    }

    nonisolated static func shouldIgnoreRecognitionError(
        _ error: Error,
        isStoppedByUser: Bool,
        hasTranscript: Bool
    ) -> Bool {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        let isAssistantError = nsError.domain == "kAFAssistantErrorDomain"

        if isAssistantError && nsError.code == 216 {
            return true
        }

        if isStoppedByUser && (description.contains("cancelled") || description.contains("canceled")) {
            return true
        }

        if isAssistantError && nsError.code == 1110 && (isStoppedByUser || hasTranscript) {
            return true
        }

        if isStoppedByUser && description.contains("no speech detected") {
            return true
        }

        return false
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
