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
    @Published var currentAudioResponseLevel: Float = 0.0
    @Published private(set) var transcriptionRoute: SpeechTranscriptionRoute = .remote(reason: .hardwareNotValidated)
    @Published private(set) var biographyGenerationRoute: BiographyGenerationRoute = .remote
    @Published private(set) var isAwaitingRemoteTranscription = false
    
    // MARK: - Private Properties
    private let speechRecognizer: SFSpeechRecognizer?
    private let metadataService: any MetadataService
    private let transcriptionPolicy: SpeechTranscriptionPolicy
    private let remoteDailyEntryGenerator: any DailyEntryGenerationService
    private let remoteTranscriber: any RemoteSpeechTranscribing
    private let localeIdentifier: String
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
    private var audioLevelEnvelope = AudioLevelEnvelope()
    private var pendingSaveTask: Task<Void, Never>?
    private var modelContext: ModelContext?
    private var generationService: (any GenerationService)?
    private var userProfile: UserProfile?
    private var hasLoadedStories = false
    private var currentCaptureRoute: SpeechTranscriptionRoute = .remote(reason: .hardwareNotValidated)
    private var speechPermissionGranted = false
    private var microphonePermissionGranted = false
    private static let audioRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let placeholderAudioScheme = "lore-audio-placeholder"
    
    // MARK: - Initialization
    init(
        metadataService: any MetadataService = LocalMetadataService(),
        transcriptionPolicy: SpeechTranscriptionPolicy = .production(),
        biographyGenerationPolicy: BiographyGenerationPolicy = .production(),
        remoteDailyEntryGenerator: any DailyEntryGenerationService = RemoteDailyEntryGenerationService(
            backend: UnconfiguredLoreBackendProcessingClient()
        ),
        remoteTranscriber: any RemoteSpeechTranscribing = UnavailableRemoteSpeechTranscriber(),
        localeIdentifier: String = Locale.current.identifier,
        deviceHardwareIdentifier: String = CurrentSpeechDevice.hardwareIdentifier,
        supportsLocalGenerationRuntime: Bool = LocalModelRuntimeAvailability.isAvailable
    ) {
        self.metadataService = metadataService
        self.transcriptionPolicy = transcriptionPolicy
        self.remoteDailyEntryGenerator = remoteDailyEntryGenerator
        self.remoteTranscriber = remoteTranscriber
        self.localeIdentifier = localeIdentifier

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        self.speechRecognizer = recognizer
        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: deviceHardwareIdentifier,
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition == true
        )
        let initialRoute = transcriptionPolicy.route(for: capabilities)
        self.transcriptionRoute = initialRoute
        self.currentCaptureRoute = initialRoute
        self.biographyGenerationRoute = biographyGenerationPolicy.route(
            for: BiographyGenerationCapabilities(
                hardwareIdentifier: deviceHardwareIdentifier,
                supportsLocalRuntime: supportsLocalGenerationRuntime
            )
        )

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
        isAwaitingRemoteTranscription = false
        errorMessage = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        currentAudioLevel = 0.0
        currentAudioResponseLevel = 0.0
        stopAudioLevelTimer()
        audioLevelEnvelope.reset()
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

        guard stories[index].text != newText else { return }
        guard let modelContext else {
            setError("Lore could not save this correction because the local archive is unavailable.")
            return
        }

        do {
            try Self.applyUserCorrection(
                newText,
                to: stories[index],
                in: modelContext
            )
        } catch {
            setError("Lore could not save this transcript correction: \(error.localizedDescription)")
            return
        }

        let storyToRegenerate = stories[index]
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
                    try Self.deleteTranscriptSupportData(for: story, in: modelContext)
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

    /// Deletes audio only after a non-empty transcript has already been committed to SwiftData.
    @discardableResult
    static func deleteAudioAfterSuccessfulTranscription(
        for story: Story,
        in modelContext: ModelContext,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard !story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }

        let allAssets = try modelContext.fetch(FetchDescriptor<AudioAsset>())
        let retainedAssets = allAssets.filter { $0.id == story.id && !$0.isDeleted }

        for asset in retainedAssets {
            try removeAudioFileIfPresent(at: asset.fileURL, fileManager: fileManager)
            modelContext.delete(asset)
        }

        if !retainedAssets.isEmpty {
            try modelContext.save()
        }

        return retainedAssets.count
    }

    // MARK: - Private Methods
    
    /// Requests both speech recognition and microphone permissions
    private func requestPermissions() async {
        if transcriptionRoute == .onDevice {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                    DispatchQueue.main.async {
                        guard let self else {
                            continuation.resume()
                            return
                        }

                        self.speechPermissionGranted = authStatus == .authorized
                        switch authStatus {
                        case .authorized:
                            self.errorMessage = nil
                            print("✅ Speech recognition authorized")
                        case .denied:
                            self.errorMessage = "Speech recognition access denied. Please enable it in Settings."
                        case .restricted:
                            self.errorMessage = "Speech recognition is restricted on this device."
                        case .notDetermined:
                            self.errorMessage = "Speech recognition permission not determined."
                        @unknown default:
                            self.errorMessage = "Unknown speech recognition authorization status."
                        }
                        self.refreshAuthorizationState()
                        continuation.resume()
                    }
                }
            }
        } else {
            // Remote transcription only needs microphone access; avoid requesting unrelated Speech access.
            speechPermissionGranted = false
        }
        
        // Request Microphone Permission
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.microphonePermissionGranted = granted
                    if granted {
                        print("✅ Microphone access granted")
                    } else {
                        self.errorMessage = "Microphone access denied. Please enable in Settings > Privacy & Security > Microphone."
                        print("❌ Microphone access denied")
                    }
                    self.refreshAuthorizationState()
                    continuation.resume()
                }
            }
        }
    }

    private func refreshAuthorizationState() {
        let routePermissionGranted = transcriptionRoute.usesRemoteService || speechPermissionGranted
        isAuthorized = microphonePermissionGranted && routePermissionGranted
    }
    
    /// Starts speech recognition
    private func startRecording() {
        print("🎤 Attempting to start recording...")

        guard pendingSaveTask == nil && !isAwaitingRemoteTranscription else {
            setError("Lore is still securing the previous recording. Please wait a moment.")
            return
        }
        
        // Reset any previous state
        stopRecording(shouldSave: false, waitForFinalTranscript: false)
        clearText()
        isStoppedByUser = false
        
        guard AVAudioApplication.shared.recordPermission == .granted else {
            setError("Microphone access required. Please check Settings.")
            return
        }

        let capabilities = SpeechTranscriptionCapabilities(
            hardwareIdentifier: CurrentSpeechDevice.hardwareIdentifier,
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            supportsOnDeviceRecognition: speechRecognizer?.supportsOnDeviceRecognition == true
        )
        var resolvedRoute = transcriptionPolicy.route(for: capabilities)

        if resolvedRoute == .onDevice && speechRecognizer?.isAvailable != true {
            resolvedRoute = .remote(reason: .localRecognizerUnavailable)
        }

        if resolvedRoute == .onDevice && !speechPermissionGranted {
            setError("Speech recognition access is required for on-device transcription. Please check Settings.")
            return
        }

        transcriptionRoute = resolvedRoute
        currentCaptureRoute = resolvedRoute
        refreshAuthorizationState()
        
        do {
            try setupAudioSession()
            try startAudioCapture(using: resolvedRoute)
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
    
    /// Starts audio capture and, when policy permits, streams buffers to on-device Speech.
    private func startAudioCapture(using route: SpeechTranscriptionRoute) throws {
        // Record start time for duration calculation
        recordingStartTime = Date()

        if route == .onDevice {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                throw SpeechRecognitionError.recognitionRequestFailed
            }

            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = true
            startLocalRecognitionTask(with: recognitionRequest)
        } else {
            recognitionRequest = nil
            recognitionTask = nil
        }
        
        // Get audio input node
        let inputNode = audioEngine.inputNode

        // Configure audio tap with enhanced buffer processing for audio level detection
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let audioFileURL = try Self.makeAudioFileURL(forStoryID: UUID())
        let audioFile = try AVAudioFile(forWriting: audioFileURL, settings: recordingFormat.settings)
        currentRecordingAudioFileURL = audioFileURL
        let activeRecognitionRequest = recognitionRequest

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, weak activeRecognitionRequest, audioFile] buffer, _ in
            activeRecognitionRequest?.append(buffer)
            do {
                try audioFile.write(from: buffer)
            } catch {
                DispatchQueue.main.async {
                    self?.setError("Failed to save recording audio: \(error.localizedDescription)")
                }
            }

            // Meter the same microphone buffer used for recording. RMS follows the
            // perceived body of speech while peak magnitude catches quiet consonants
            // and short transients that would otherwise disappear.
            if let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let sampleCount = vDSP_Length(buffer.frameLength)
                var rms: Float = 0
                var peak: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, sampleCount)
                vDSP_maxmgv(channelData, 1, &peak, sampleCount)
                let frameDuration = Double(buffer.frameLength) / recordingFormat.sampleRate
                let decibels = 20 * log10(rms + Float.leastNonzeroMagnitude)
                let legacyLevel = max(0, min(1, (decibels + 80) / 80))

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.audioLevelBuffer.append(legacyLevel)
                    if self.audioLevelBuffer.count > 10 {
                        self.audioLevelBuffer.removeFirst()
                    }

                    if self.isRecording {
                        self.currentAudioResponseLevel = self.audioLevelEnvelope.process(
                            rms: rms,
                            peak: peak,
                            frameDuration: frameDuration
                        )
                    }
                }
            }

            // Update audio processing state on main thread
            DispatchQueue.main.async {
                self?.isProcessingAudio = true
            }
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        startAudioLevelTimer()
        isRecording = true
        print("🎤 Audio engine started, recording in progress")
    }

    private func startLocalRecognitionTask(with recognitionRequest: SFSpeechAudioBufferRecognitionRequest) {
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
            Task { @MainActor [weak self, weak timer] in
                guard let self, let timer else { return }

                let fadeStep = 0.1 / fadeDuration
                self.wordOpacity = max(0.0, self.wordOpacity - fadeStep)

                if self.wordOpacity <= 0.0 {
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
    }

    /// Preserves the original, slower-smoothed signal used by CloudWaveOrb so
    /// the animation inside the circle keeps its existing behavior.
    private func startAudioLevelTimer() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.audioLevelBuffer.isEmpty else { return }
                self.currentAudioLevel = self.audioLevelBuffer.reduce(0, +) / Float(self.audioLevelBuffer.count)
            }
        }
    }

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
        
        // Reset both visual meters so the next recording starts from silence.
        stopAudioLevelTimer()
        audioLevelEnvelope.reset()
        currentAudioLevel = 0.0
        currentAudioResponseLevel = 0.0
        
        // Stop audio engine
        audioEngine.stop()

        if shouldSave {
            let shouldWaitForLocalFinalTranscript = waitForFinalTranscript && currentCaptureRoute == .onDevice
            pendingSaveTask = Task { [weak self] in
                if shouldWaitForLocalFinalTranscript {
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
        currentAudioResponseLevel = 0.0
        
        // Clean up
        recognitionRequest = nil
        if !waitForFinalTranscript || currentCaptureRoute.usesRemoteService {
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
        var transcript = transcribedText
        let audioFileURL = currentRecordingAudioFileURL
        let captureRoute = currentCaptureRoute
        var transcriptionFailure: Error?
        var remoteTranscription: RemoteSpeechTranscription?
        let story: Story

        if captureRoute.usesRemoteService {
            isAwaitingRemoteTranscription = true
            do {
                guard let audioFileURL else {
                    throw RemoteSpeechTranscriptionError.audioFileMissing
                }

                let response = try await remoteTranscriber.transcribe(
                    audioFileURL: audioFileURL,
                    localeIdentifier: localeIdentifier
                )
                let cleanedTranscript = response.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedTranscript.isEmpty else {
                    throw RemoteSpeechTranscriptionError.emptyTranscript
                }
                transcript = response.transcript
                remoteTranscription = response
            } catch {
                transcriptionFailure = error
                transcript = ""
            }
            isAwaitingRemoteTranscription = false
        }

        pendingSaveTask = nil
        transcribedText = ""
        recordingStartTime = nil
        currentRecordingAudioFileURL = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        if let modelContext {
            do {
                story = try Self.persistCapturedStoryImmediately(
                    transcript: transcript,
                    startTime: startTime,
                    endTime: endTime,
                    audioFileURL: audioFileURL,
                    transcriptSource: captureRoute.usesRemoteService ? .remoteProvider : .appleSpeech,
                    languageCode: localeIdentifier,
                    providerId: remoteTranscription?.provider,
                    providerModelId: remoteTranscription?.model,
                    providerRequestId: remoteTranscription?.requestID,
                    modelContext: modelContext
                )
            } catch {
                // The audio is the only recoverable source when persistence fails. Never delete it here.
                setError("Failed to save the transcript. The audio was kept on this iPhone: \(error.localizedDescription)")
                print("Failed to save story and audio metadata: \(error)")
                return
            }

            let hasUsableTranscript = !story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasUsableTranscript {
                do {
                    _ = try Self.deleteAudioAfterSuccessfulTranscription(
                        for: story,
                        in: modelContext
                    )
                } catch {
                    setError("Transcript saved, but Lore could not delete its audio yet: \(error.localizedDescription)")
                }
            } else {
                story.processingStatus = "transcriptionPending"
                story.updatedAt = Date()
                let pendingJob = Self.makePendingTranscriptionJob(
                    for: story,
                    route: captureRoute,
                    failure: transcriptionFailure
                )
                modelContext.insert(pendingJob)
                do {
                    try modelContext.save()
                } catch {
                    setError("The recording was kept, but Lore could not schedule transcription retry: \(error.localizedDescription)")
                }
            }

            loadStories()
            Task {
                await enrichCaptureMetadata(for: story, captureDate: startTime)
            }
            if hasUsableTranscript {
                Task {
                    await processCapturedStory(story)
                }
            }
        } else {
            story = Self.makeStory(transcript: transcript, startTime: startTime, endTime: endTime)
            stories.append(story)
        }

        if let transcriptionFailure {
            setError(transcriptionFailure.localizedDescription)
        }
        
        let displayText = story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                         "No voice found in story" : 
                         String(story.text.prefix(50)) + (story.text.count > 50 ? "..." : "")
        print("Story saved: \(story.formattedDuration) - \(displayText)")
    }

    static func applyUserCorrection(
        _ newText: String,
        to story: Story,
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws {
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let artifact: TranscriptArtifact

        if let existingArtifact = artifacts.first(where: { $0.storyId == story.id }) {
            artifact = existingArtifact
        } else {
            artifact = TranscriptArtifact(
                storyId: story.id,
                rawText: story.text,
                source: .legacyStory,
                capturedAt: story.date,
                transcribedAt: story.createdAt,
                audioDuration: story.duration,
                createdAt: story.createdAt
            )
            modelContext.insert(artifact)
        }

        let allVersions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        var artifactVersions = allVersions
            .filter { $0.transcriptArtifactId == artifact.id }
            .sorted { $0.revision < $1.revision }

        if artifactVersions.isEmpty {
            let sourceVersion = TranscriptVersion(
                transcriptArtifactId: artifact.id,
                storyId: story.id,
                revision: 1,
                text: artifact.rawText,
                kind: .sourceSnapshot,
                author: .source,
                createdAt: artifact.createdAt
            )
            modelContext.insert(sourceVersion)
            artifactVersions.append(sourceVersion)
        }

        let previousVersion = artifactVersions.last
        let correction = TranscriptVersion(
            transcriptArtifactId: artifact.id,
            storyId: story.id,
            supersedesVersionId: previousVersion?.id,
            revision: (previousVersion?.revision ?? 0) + 1,
            text: newText,
            kind: .userCorrection,
            author: .user,
            editSummary: "User corrected transcript",
            createdAt: date
        )
        modelContext.insert(correction)

        story.text = newText
        story.biographyProse = nil
        story.processingStatus = "awaitingModel"
        story.updatedAt = date
        try modelContext.save()
    }

    static func makePendingTranscriptionJob(
        for story: Story,
        route: SpeechTranscriptionRoute,
        failure: Error?
    ) -> ProcessingJob {
        let state: ProcessingJobState
        let errorCode: String

        switch failure as? RemoteSpeechTranscriptionError {
        case .notConfigured:
            state = .failed
            errorCode = "remote_not_configured"
        case .audioFileMissing:
            state = .failed
            errorCode = "audio_file_missing"
        case .emptyTranscript:
            state = .failed
            errorCode = "empty_remote_transcript"
        case nil:
            state = .failed
            errorCode = route.usesRemoteService ? "remote_transcription_failed" : "empty_local_transcript"
        }

        return ProcessingJob(
            idempotencyKey: "transcription:\(story.id.uuidString)",
            storyId: story.id,
            kind: .transcription,
            state: state,
            route: route.usesRemoteService ? .remote : .local,
            lastErrorCode: errorCode
        )
    }

    @discardableResult
    static func persistCapturedStory(
        transcript: String,
        startTime: Date,
        endTime: Date,
        audioFileURL: URL? = nil,
        transcriptSource: TranscriptSource = .appleSpeech,
        languageCode: String? = nil,
        providerId: String? = nil,
        providerModelId: String? = nil,
        providerRequestId: String? = nil,
        metadataService: any MetadataService = LocalMetadataService(),
        modelContext: ModelContext
    ) async throws -> Story {
        let metadata = await metadataService.makeCaptureMetadata(captureDate: startTime)
        return try persistCapturedStory(
            transcript: transcript,
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            transcriptSource: transcriptSource,
            languageCode: languageCode,
            providerId: providerId,
            providerModelId: providerModelId,
            providerRequestId: providerRequestId,
            metadata: metadata,
            modelContext: modelContext
        )
    }

    @discardableResult
    static func persistCapturedStoryImmediately(
        transcript: String,
        startTime: Date,
        endTime: Date,
        audioFileURL: URL? = nil,
        transcriptSource: TranscriptSource = .appleSpeech,
        languageCode: String? = nil,
        providerId: String? = nil,
        providerModelId: String? = nil,
        providerRequestId: String? = nil,
        modelContext: ModelContext
    ) throws -> Story {
        try persistCapturedStory(
            transcript: transcript,
            startTime: startTime,
            endTime: endTime,
            audioFileURL: audioFileURL,
            transcriptSource: transcriptSource,
            languageCode: languageCode,
            providerId: providerId,
            providerModelId: providerModelId,
            providerRequestId: providerRequestId,
            metadata: makePendingCaptureMetadata(captureDate: startTime),
            modelContext: modelContext
        )
    }

    private static func persistCapturedStory(
        transcript: String,
        startTime: Date,
        endTime: Date,
        audioFileURL: URL? = nil,
        transcriptSource: TranscriptSource,
        languageCode: String?,
        providerId: String?,
        providerModelId: String?,
        providerRequestId: String?,
        metadata: StoryMetadata,
        modelContext: ModelContext
    ) throws -> Story {
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

        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let artifact = TranscriptArtifact(
                storyId: story.id,
                audioAssetId: audioAsset.id,
                rawText: transcript,
                source: transcriptSource,
                languageCode: languageCode,
                providerId: providerId,
                providerModelId: providerModelId,
                providerRequestId: providerRequestId,
                capturedAt: startTime,
                transcribedAt: endTime,
                audioDuration: story.duration,
                createdAt: endTime
            )
            let sourceVersion = TranscriptVersion(
                transcriptArtifactId: artifact.id,
                storyId: story.id,
                revision: 1,
                text: transcript,
                kind: .sourceSnapshot,
                author: .source,
                createdAt: endTime
            )
            modelContext.insert(artifact)
            modelContext.insert(sourceVersion)
        }
        try modelContext.save()

        return story
    }

    private static func makePendingCaptureMetadata(captureDate: Date) -> StoryMetadata {
        let snapshot = MetadataPermissionSnapshot(
            locationAuthorizationStatus: "pending",
            locationCaptureStatus: MetadataLocationCaptureStatus.unavailable.rawValue,
            weatherStatus: "pending"
        )

        return StoryMetadata(
            captureDate: captureDate,
            timezone: TimeZone.current.identifier,
            permissionSnapshot: snapshot.encodedString
        )
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

    @discardableResult
    static func deleteTranscriptSupportData(
        for story: Story,
        in modelContext: ModelContext
    ) throws -> Int {
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
            .filter { $0.storyId == story.id }
        let artifactIds = Set(artifacts.map(\.id))
        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
            .filter { $0.storyId == story.id || artifactIds.contains($0.transcriptArtifactId) }
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
            .filter { $0.storyId == story.id }
        let fragments = try modelContext.fetch(FetchDescriptor<BiographyFragment>())
            .filter { $0.storyId == story.id }

        versions.forEach(modelContext.delete)
        artifacts.forEach(modelContext.delete)
        jobs.forEach(modelContext.delete)
        fragments.forEach(modelContext.delete)

        return versions.count + artifacts.count + jobs.count + fragments.count
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
            rawTranscriptExpiresAt: nil,
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

    private func enrichCaptureMetadata(for story: Story, captureDate: Date) async {
        guard let modelContext, let metadataId = story.metadataId else {
            return
        }

        let enrichedMetadata = await metadataService.makeCaptureMetadata(captureDate: captureDate)

        do {
            let allMetadata = try modelContext.fetch(FetchDescriptor<StoryMetadata>())
            guard let metadata = allMetadata.first(where: { $0.id == metadataId }) else {
                return
            }

            metadata.captureDate = enrichedMetadata.captureDate
            metadata.timezone = enrichedMetadata.timezone
            metadata.locationName = enrichedMetadata.locationName
            metadata.latitude = enrichedMetadata.latitude
            metadata.longitude = enrichedMetadata.longitude
            metadata.weatherSummary = enrichedMetadata.weatherSummary
            metadata.temperature = enrichedMetadata.temperature
            metadata.weatherSource = enrichedMetadata.weatherSource
            metadata.permissionSnapshot = enrichedMetadata.permissionSnapshot
            try modelContext.save()
        } catch {
            print("Failed to enrich story metadata: \(error)")
        }
    }

    private func processCapturedStory(_ story: Story) async {
        guard let userProfile else {
            story.processingStatus = "failed"
            story.updatedAt = Date()
            saveContext()
            loadStories()
            return
        }

        story.processingStatus = "processing"
        story.updatedAt = Date()
        saveContext()

        do {
            switch biographyGenerationRoute {
            case .local:
                guard let generationService else {
                    throw GenerationError.localModelNotReady
                }
                defer { generationService.releaseResources() }

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

            case .remote:
                guard let modelContext else {
                    throw RemoteGenerationRequestFactoryError.missingTranscriptArtifact
                }
                let request = try RemoteGenerationRequestFactory.makeRequest(
                    for: story,
                    userProfile: userProfile,
                    in: modelContext
                )
                let response = try await remoteDailyEntryGenerator.generateDailyEntry(request)
                story.biographyProse = response.entry.prose
                story.title = response.entry.title
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

/// Converts raw microphone power into a stable visual response. A logarithmic
/// curve preserves quiet speech, while separate attack and release times let the
/// visual react immediately without flickering between audio buffers.
struct AudioLevelEnvelope {
    private(set) var value: Float = 0

    mutating func process(
        rms: Float,
        peak: Float,
        frameDuration: TimeInterval
    ) -> Float {
        let rmsDecibels = Self.decibels(for: rms)
        let peakDecibels = Self.decibels(for: peak) - 10
        let speechEnergy = max(rmsDecibels, peakDecibels)

        // This threshold is intentionally sensitive enough for nearby whispers.
        // The power curve lifts quiet input without pinning loud phrases at 1.0.
        let linearLevel = min(max((speechEnergy + 62) / 50, 0), 1)
        let target = pow(linearLevel, 0.55)
        let timeConstant: TimeInterval = target > value ? 0.028 : 0.17
        let duration = min(max(frameDuration, 1.0 / 240.0), 0.1)
        let coefficient = Float(1 - exp(-duration / timeConstant))

        value += (target - value) * coefficient
        if value < 0.002, target == 0 {
            value = 0
        }

        return value
    }

    mutating func reset() {
        value = 0
    }

    private static func decibels(for amplitude: Float) -> Float {
        20 * log10(max(amplitude, 0.000_001))
    }
}

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
