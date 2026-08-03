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

enum TranscriptionJobRunnerError: Error, LocalizedError, Equatable {
    case jobNotFound
    case storyNotFound
    case audioAssetNotFound
    case audioFileMissing
    case jobNotReady
    case jobCancelled

    var errorDescription: String? {
        switch self {
        case .jobNotFound:
            return "Lore could not find the saved transcription job."
        case .storyNotFound:
            return "Lore could not find the saved recording for this transcription job."
        case .audioAssetNotFound, .audioFileMissing:
            return "Lore could not find the locally saved audio for this transcription job."
        case .jobNotReady:
            return "This transcription job is not ready to run yet."
        case .jobCancelled:
            return "This transcription job was cancelled."
        }
    }
}

private enum RemoteWorkAvailability: Equatable {
    case permitted
    case waitingForConsent
    case waitingForNetwork
}

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
    private let networkConnectionProvider: any SpeechNetworkConnectionProviding
    private let localeIdentifier: String
    private let deviceHardwareIdentifier: String
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
    private var transcriptionRecoveryTask: Task<Void, Never>?
    private var dailyEntryRecoveryTask: Task<Void, Never>?
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
        networkConnectionProvider: (any SpeechNetworkConnectionProviding)? = nil,
        localeIdentifier: String = Locale.current.identifier,
        deviceHardwareIdentifier: String = CurrentSpeechDevice.hardwareIdentifier,
        supportsLocalGenerationRuntime: Bool = LocalModelRuntimeAvailability.isAvailable
    ) {
        self.metadataService = metadataService
        self.transcriptionPolicy = transcriptionPolicy
        self.remoteDailyEntryGenerator = remoteDailyEntryGenerator
        self.remoteTranscriber = remoteTranscriber
        self.networkConnectionProvider = networkConnectionProvider ?? SystemSpeechNetworkMonitor()
        self.localeIdentifier = localeIdentifier
        self.deviceHardwareIdentifier = deviceHardwareIdentifier

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

        self.networkConnectionProvider.observeChanges { [weak self] _ in
            guard let self, self.userProfile != nil else { return }
            self.refreshRemoteProcessingPolicy()
        }

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
        refreshRemoteProcessingPolicy(resumeJobs: false)

        guard !hasLoadedStories else {
            return
        }

        cleanupExpiredAudioAssets()
        loadStories()
        hasLoadedStories = true

        Task { [weak self] in
            await self?.resumePendingTranscriptionJobs()
            await self?.resumePendingDailyEntryJobs()
        }
    }

    /// Re-evaluates every remote boundary after the user changes privacy or
    /// cellular settings. Revocation cancels an in-flight upload and leaves its
    /// durable audio/job available for an explicit future retry.
    func refreshRemoteProcessingPolicy() {
        refreshRemoteProcessingPolicy(resumeJobs: true)
    }

    private func refreshRemoteProcessingPolicy(resumeJobs: Bool) {
        transcriptionRoute = resolvedCaptureRoute()
        currentCaptureRoute = transcriptionRoute
        refreshAuthorizationState()

        if isAwaitingRemoteTranscription,
           remoteWorkAvailability(requiresAudioUpload: true) != .permitted {
            pendingSaveTask?.cancel()
        }

        guard resumeJobs else { return }
        Task { [weak self] in
            await self?.resumePendingTranscriptionJobs()
            await self?.resumePendingDailyEntryJobs()
        }
    }

    /// Relaunch recovery entry point for queued work and interrupted leases.
    /// It is safe to call repeatedly; completed transcript commits are idempotent.
    func resumePendingTranscriptionJobs(now: Date = Date()) async {
        guard let modelContext else { return }

        transcriptionRecoveryTask?.cancel()
        transcriptionRecoveryTask = nil

        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .transcription }
                .sorted { $0.createdAt < $1.createdAt }

            for job in jobs {
                if job.state != .succeeded {
                    switch remoteWorkAvailability(requiresAudioUpload: true) {
                    case .permitted:
                        if job.state == .waitingForConsent || job.state == .waitingForNetwork {
                            job.state = .queued
                            job.nextAttemptAt = now
                            try modelContext.save()
                        }
                    case .waitingForConsent:
                        if job.state != .cancelled && job.state != .failed {
                            job.state = .waitingForConsent
                            job.nextAttemptAt = nil
                            job.leaseExpiresAt = nil
                            try modelContext.save()
                        }
                        continue
                    case .waitingForNetwork:
                        if job.state != .cancelled && job.state != .failed {
                            job.state = .waitingForNetwork
                            job.nextAttemptAt = nil
                            job.leaseExpiresAt = nil
                            try modelContext.save()
                        }
                        continue
                    }
                }

                let shouldFinishDeletion = job.state == .succeeded && job.outputReferenceId != nil
                let shouldAttempt = job.state == .queued && job.isReadyForAttempt(at: now)
                let shouldRecoverLease = job.state == .running
                    && job.leaseExpiresAt.map { $0 <= now } == true
                guard shouldFinishDeletion || shouldAttempt || shouldRecoverLease else {
                    continue
                }

                do {
                    let story = try await Self.runTranscriptionJob(
                        jobID: job.id,
                        remoteTranscriber: remoteTranscriber,
                        localeIdentifier: localeIdentifier,
                        modelContext: modelContext,
                        now: now
                    )
                    if job.state == .succeeded,
                       story.biographyProse == nil,
                       !story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await processCapturedStory(story)
                    }
                } catch TranscriptionJobRunnerError.jobNotReady {
                    continue
                } catch {
                    // The runner has already persisted retry/failure state and retained audio.
                    print("Deferred transcription job \(job.id) did not complete: \(error)")
                }
            }
            loadStories()
            scheduleNextTranscriptionRecovery()
        } catch {
            print("Failed to recover transcription jobs: \(error)")
            scheduleNextTranscriptionRecovery()
        }
    }

    /// Arms the next durable retry while Lore stays open. Relaunch recovery remains the
    /// fallback if iOS suspends the process before this task wakes.
    private func scheduleNextTranscriptionRecovery(now: Date = Date()) {
        guard let modelContext else { return }

        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .transcription }
            let queuedRetryDates = jobs
                .filter {
                    $0.state == .queued
                        && $0.attemptCount < $0.maximumAttempts
                }
                .compactMap(\.nextAttemptAt)
            let interruptedLeaseDates = jobs
                .filter { $0.state == .running }
                .compactMap(\.leaseExpiresAt)
            guard let nextRetryAt = (queuedRetryDates + interruptedLeaseDates).min() else {
                return
            }

            let delay = max(0, nextRetryAt.timeIntervalSince(now))
            transcriptionRecoveryTask?.cancel()
            transcriptionRecoveryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.resumePendingTranscriptionJobs()
            }
        } catch {
            print("Failed to schedule the next transcription retry: \(error)")
        }
    }

    /// Recovers queued or interrupted Fireworks journal-writing jobs without
    /// allowing a stale job to bypass current consent or network policy.
    func resumePendingDailyEntryJobs(now: Date = Date()) async {
        guard let modelContext, let userProfile else { return }

        dailyEntryRecoveryTask?.cancel()
        dailyEntryRecoveryTask = nil

        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .dailyEntry }
                .sorted { $0.createdAt < $1.createdAt }

            for job in jobs where job.state != .succeeded && job.state != .cancelled && job.state != .failed {
                switch remoteWorkAvailability(requiresAudioUpload: false) {
                case .permitted:
                    if job.state == .waitingForConsent || job.state == .waitingForNetwork {
                        job.state = .queued
                        job.nextAttemptAt = now
                        try modelContext.save()
                    }
                case .waitingForConsent:
                    job.state = .waitingForConsent
                    job.nextAttemptAt = nil
                    job.leaseExpiresAt = nil
                    try modelContext.save()
                    continue
                case .waitingForNetwork:
                    job.state = .waitingForNetwork
                    job.nextAttemptAt = nil
                    job.leaseExpiresAt = nil
                    try modelContext.save()
                    continue
                }

                let shouldAttempt = job.state == .queued && job.isReadyForAttempt(at: now)
                let shouldRecoverLease = job.state == .running
                    && job.leaseExpiresAt.map { $0 <= now } == true
                guard shouldAttempt || shouldRecoverLease else { continue }

                do {
                    _ = try await DailyEntryJobRunner.run(
                        jobID: job.id,
                        userProfile: userProfile,
                        generator: remoteDailyEntryGenerator,
                        in: modelContext,
                        now: now
                    )
                } catch DailyEntryJobRunnerError.jobNotReady {
                    continue
                } catch {
                    // The runner already persisted a retryable or terminal state.
                    print("Deferred daily-entry job \(job.id) did not complete: \(error)")
                }
            }
            loadStories()
            scheduleNextDailyEntryRecovery()
        } catch {
            print("Failed to recover daily-entry jobs: \(error)")
            scheduleNextDailyEntryRecovery()
        }
    }

    private func scheduleNextDailyEntryRecovery(now: Date = Date()) {
        guard let modelContext else { return }
        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .dailyEntry }
            let wakeDates = jobs.compactMap { job -> Date? in
                switch job.state {
                case .queued:
                    return job.attemptCount < job.maximumAttempts ? job.nextAttemptAt : nil
                case .running:
                    return job.leaseExpiresAt
                default:
                    return nil
                }
            }
            guard let wakeDate = wakeDates.min() else { return }
            let delay = max(0, wakeDate.timeIntervalSince(now))
            dailyEntryRecoveryTask?.cancel()
            dailyEntryRecoveryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.resumePendingDailyEntryJobs()
            }
        } catch {
            print("Failed to schedule the next daily-entry retry: \(error)")
        }
    }

    static func cancelTranscriptionJob(
        jobID: UUID,
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws {
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        guard let job = jobs.first(where: { $0.id == jobID && $0.kind == .transcription }) else {
            throw TranscriptionJobRunnerError.jobNotFound
        }
        guard job.state != .succeeded else { return }
        job.cancel(at: date)
        if let storyID = job.storyId {
            let stories = try modelContext.fetch(FetchDescriptor<Story>())
            if let story = stories.first(where: { $0.id == storyID }) {
                story.processingStatus = "transcriptionCancelled"
                story.updatedAt = date
            }
        }
        try modelContext.save()
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
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        let committedAudioAssetIds = Set(artifacts.compactMap { artifact -> UUID? in
            guard versions.contains(where: { $0.transcriptArtifactId == artifact.id }) else {
                return nil
            }
            return artifact.audioAssetId
        })
        let expiredAssets = allAssets.filter { asset in
            !asset.isDeleted
                && asset.expiresAt <= now
                && committedAudioAssetIds.contains(asset.id)
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

        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        guard let artifact = artifacts.first(where: { $0.storyId == story.id }) else {
            return 0
        }
        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        guard versions.contains(where: { $0.transcriptArtifactId == artifact.id }) else {
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

    private func speechCapabilities() -> SpeechTranscriptionCapabilities {
        SpeechTranscriptionCapabilities(
            hardwareIdentifier: deviceHardwareIdentifier,
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            supportsOnDeviceRecognition: speechRecognizer?.supportsOnDeviceRecognition == true
        )
    }

    private func resolvedCaptureRoute() -> SpeechTranscriptionRoute {
        guard let userProfile else {
            let capabilityRoute = transcriptionPolicy.route(for: speechCapabilities())
            return capabilityRoute == .onDevice
                ? .onDevice
                : .deferred(reason: .remoteTextConsentRequired)
        }

        return transcriptionPolicy.route(
            for: SpeechTranscriptionRoutingInput(
                capabilities: speechCapabilities(),
                preferences: RemoteProcessingPreferences(userProfile: userProfile),
                networkConnection: networkConnectionProvider.currentConnection,
                localRecognizerIsAvailable: speechRecognizer?.isAvailable == true
            )
        )
    }

    private func remoteWorkAvailability(requiresAudioUpload: Bool) -> RemoteWorkAvailability {
        guard let userProfile,
              userProfile.processingMode == .adaptive,
              userProfile.hasRemoteTextProcessingConsent,
              !requiresAudioUpload || userProfile.hasRemoteAudioUploadConsent else {
            return .waitingForConsent
        }

        switch networkConnectionProvider.currentConnection {
        case .wifi:
            return .permitted
        case .cellular:
            return userProfile.allowsCellularRemoteProcessing ? .permitted : .waitingForNetwork
        case .unavailable, .unknown:
            return .waitingForNetwork
        }
    }

    private func message(for reason: SpeechTranscriptionDeferralReason) -> String {
        switch reason {
        case .deviceOnlyRequiresLocalTranscription:
            return "This iPhone needs Adaptive processing for accurate transcription. You can enable it in Settings."
        case .remoteTextConsentRequired:
            return "Allow private remote text processing in Settings before using Adaptive transcription."
        case .remoteAudioConsentRequired:
            return "Allow temporary audio upload in Settings before using Adaptive transcription."
        case .cellularProcessingDisabled:
            return "Connect to Wi-Fi or allow mobile data for Adaptive processing in Settings."
        case .networkUnavailable, .networkUnknown:
            return "Lore is offline. Your recording will stay on this iPhone until a permitted connection is available."
        case .remoteFallbackConfirmationRequired:
            return "Confirm Adaptive transcription before sending this recording for remote processing."
        }
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

        let resolvedRoute = resolvedCaptureRoute()
        if case let .deferred(reason) = resolvedRoute {
            transcriptionRoute = resolvedRoute
            currentCaptureRoute = resolvedRoute
            setError(message(for: reason))
            return
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
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: audioFileURL.path
        )
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
        let transcript = transcribedText
        let audioFileURL = currentRecordingAudioFileURL
        let captureRoute = currentCaptureRoute
        let story: Story

        if captureRoute.usesRemoteService {
            guard let modelContext, let audioFileURL else {
                pendingSaveTask = nil
                setError("Lore could not secure this recording locally. The audio was kept on this iPhone.")
                return
            }

            let job: ProcessingJob
            do {
                (story, job) = try Self.persistRemoteCaptureForTranscription(
                    startTime: startTime,
                    endTime: endTime,
                    audioFileURL: audioFileURL,
                    modelContext: modelContext
                )
            } catch {
                pendingSaveTask = nil
                setError("Failed to save the recording before transcription. The audio was kept on this iPhone: \(error.localizedDescription)")
                return
            }

            clearFinishedCaptureState(keepPendingTask: true)
            loadStories()
            Task {
                await enrichCaptureMetadata(for: story, captureDate: startTime)
            }

            isAwaitingRemoteTranscription = true
            do {
                let transcribedStory = try await Self.runTranscriptionJob(
                    jobID: job.id,
                    remoteTranscriber: remoteTranscriber,
                    localeIdentifier: localeIdentifier,
                    modelContext: modelContext
                )
                isAwaitingRemoteTranscription = false
                pendingSaveTask = nil
                loadStories()
                Task {
                    await processCapturedStory(transcribedStory)
                }
            } catch {
                isAwaitingRemoteTranscription = false
                pendingSaveTask = nil
                setError(error.localizedDescription)
                loadStories()
                scheduleNextTranscriptionRecovery()
            }
            return
        }

        if let modelContext {
            do {
                story = try Self.persistCapturedStoryImmediately(
                    transcript: transcript,
                    startTime: startTime,
                    endTime: endTime,
                    audioFileURL: audioFileURL,
                    transcriptSource: .appleSpeech,
                    languageCode: localeIdentifier,
                    modelContext: modelContext
                )
                clearFinishedCaptureState()
                _ = try Self.deleteAudioAfterSuccessfulTranscription(for: story, in: modelContext)
                loadStories()
                Task {
                    await enrichCaptureMetadata(for: story, captureDate: startTime)
                }
                Task {
                    await processCapturedStory(story)
                }
            } catch {
                pendingSaveTask = nil
                setError("Failed to save the transcript. The audio was kept on this iPhone: \(error.localizedDescription)")
                return
            }
        } else {
            story = Self.makeStory(transcript: transcript, startTime: startTime, endTime: endTime)
            stories.append(story)
            clearFinishedCaptureState()
        }

        let displayText = story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No voice found in story"
            : String(story.text.prefix(50)) + (story.text.count > 50 ? "..." : "")
        print("Story saved: \(story.formattedDuration) - \(displayText)")
    }

    private func clearFinishedCaptureState(keepPendingTask: Bool = false) {
        if !keepPendingTask {
            pendingSaveTask = nil
        }
        transcribedText = ""
        recordingStartTime = nil
        currentRecordingAudioFileURL = nil
        recognitionTask?.cancel()
        recognitionTask = nil
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

    /// Commits the capture envelope before any provider request is allowed to start.
    /// Story, real audio metadata, and queued work are one SwiftData transaction.
    static func persistRemoteCaptureForTranscription(
        startTime: Date,
        endTime: Date,
        audioFileURL: URL,
        modelContext: ModelContext
    ) throws -> (story: Story, job: ProcessingJob) {
        guard audioFileURL.isFileURL,
              FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw TranscriptionJobRunnerError.audioFileMissing
        }
        let metadata = makePendingCaptureMetadata(captureDate: startTime)
        let story = makeStory(
            transcript: "",
            startTime: startTime,
            endTime: endTime,
            metadataId: metadata.id
        )
        story.processingStatus = "transcriptionPending"
        let audioAsset = makeAudioAsset(
            storyID: story.id,
            fileURL: audioFileURL,
            createdAt: endTime,
            duration: story.duration
        )
        let job = ProcessingJob(
            idempotencyKey: "transcription:\(story.id.uuidString)",
            storyId: story.id,
            kind: .transcription,
            state: .queued,
            route: .remote
        )

        modelContext.insert(story)
        modelContext.insert(metadata)
        modelContext.insert(audioAsset)
        modelContext.insert(job)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return (story, job)
    }

    /// Runs one durable transcription attempt. The `running` transition is saved before
    /// the network call, and the transcript artifact/version are saved before audio deletion.
    @discardableResult
    static func runTranscriptionJob(
        jobID: UUID,
        remoteTranscriber: any RemoteSpeechTranscribing,
        localeIdentifier: String,
        modelContext: ModelContext,
        now: Date = Date(),
        leaseDuration: TimeInterval = 120
    ) async throws -> Story {
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        guard let job = jobs.first(where: { $0.id == jobID && $0.kind == .transcription }) else {
            throw TranscriptionJobRunnerError.jobNotFound
        }
        guard let storyID = job.storyId else {
            throw TranscriptionJobRunnerError.storyNotFound
        }
        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        guard let story = stories.first(where: { $0.id == storyID }) else {
            throw TranscriptionJobRunnerError.storyNotFound
        }

        if job.state == .succeeded {
            // Relaunch may happen after the transcript commit but before file deletion.
            _ = try? deleteAudioAfterSuccessfulTranscription(for: story, in: modelContext)
            return story
        }
        guard job.state != .cancelled else {
            throw TranscriptionJobRunnerError.jobCancelled
        }

        _ = job.recoverExpiredLease(at: now)
        guard job.isReadyForAttempt(at: now) else {
            throw TranscriptionJobRunnerError.jobNotReady
        }

        let audioAssets = try modelContext.fetch(FetchDescriptor<AudioAsset>())
        guard let audioAsset = audioAssets.first(where: { $0.id == storyID && !$0.isDeleted }) else {
            job.markFailed(errorCode: "audio_asset_missing", at: now)
            try modelContext.save()
            throw TranscriptionJobRunnerError.audioAssetNotFound
        }
        guard let audioFileURL = URL(string: audioAsset.fileURL),
              audioFileURL.isFileURL,
              FileManager.default.fileExists(atPath: audioFileURL.path) else {
            job.markFailed(errorCode: "audio_file_missing", at: now)
            try modelContext.save()
            throw TranscriptionJobRunnerError.audioFileMissing
        }

        job.beginAttempt(at: now, leaseDuration: leaseDuration)
        story.processingStatus = "transcribing"
        story.updatedAt = now
        do {
            // This save is the ordering barrier: no provider receives bytes unless
            // the capture envelope and running attempt are already durable.
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        do {
            let response = try await remoteTranscriber.transcribe(
                audioFileURL: audioFileURL,
                localeIdentifier: localeIdentifier
            )
            try Task.checkCancellation()
            let committedStory = try commitRemoteTranscription(
                response,
                for: story,
                audioAsset: audioAsset,
                job: job,
                localeIdentifier: localeIdentifier,
                modelContext: modelContext,
                at: Date()
            )
            // Failure here cannot lose the source transcript: both immutable rows and
            // the succeeded job have already committed. Recovery will retry deletion.
            _ = try? deleteAudioAfterSuccessfulTranscription(
                for: committedStory,
                in: modelContext
            )
            return committedStory
        } catch is CancellationError {
            modelContext.rollback()
            job.cancel(at: Date())
            story.processingStatus = "transcriptionCancelled"
            story.updatedAt = Date()
            try modelContext.save()
            throw CancellationError()
        } catch {
            modelContext.rollback()
            guard job.state == .running else {
                throw error
            }

            let terminal = isTerminalTranscriptionError(error)
                || job.attemptCount >= job.maximumAttempts
            let failureDate = Date()
            let retryAt = terminal ? nil : failureDate.addingTimeInterval(
                transcriptionRetryDelay(afterAttempt: job.attemptCount)
            )
            job.markFailed(
                errorCode: transcriptionErrorCode(error),
                retryAt: retryAt,
                at: failureDate
            )
            story.processingStatus = terminal ? "transcriptionFailed" : "transcriptionPending"
            story.updatedAt = failureDate
            try modelContext.save()
            throw error
        }
    }

    /// Idempotently installs the immutable provider output. Replaying the same job
    /// returns the already committed artifact and never appends duplicate versions.
    @discardableResult
    static func commitRemoteTranscription(
        _ response: RemoteSpeechTranscription,
        for story: Story,
        audioAsset: AudioAsset,
        job: ProcessingJob,
        localeIdentifier: String,
        modelContext: ModelContext,
        at date: Date = Date()
    ) throws -> Story {
        let cleanedTranscript = response.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else {
            throw RemoteSpeechTranscriptionError.emptyTranscript
        }
        guard job.state != .cancelled else {
            throw TranscriptionJobRunnerError.jobCancelled
        }

        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        let artifact: TranscriptArtifact
        if let committedArtifact = artifacts.first(where: { $0.storyId == story.id }) {
            artifact = committedArtifact
        } else {
            artifact = TranscriptArtifact(
                storyId: story.id,
                audioAssetId: audioAsset.id,
                rawText: response.transcript,
                source: .remoteProvider,
                languageCode: localeIdentifier,
                providerId: response.provider,
                providerModelId: response.model,
                providerRequestId: response.requestID,
                sourceSegmentsJSON: encodeRemoteAuditJSON(response.segments),
                providerProvenanceJSON: encodeRemoteAuditJSON(response.provenance),
                capturedAt: story.date,
                transcribedAt: date,
                audioDuration: story.duration,
                createdAt: date
            )
            modelContext.insert(artifact)
        }

        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
        if !versions.contains(where: { $0.transcriptArtifactId == artifact.id }) {
            modelContext.insert(
                TranscriptVersion(
                    transcriptArtifactId: artifact.id,
                    storyId: story.id,
                    revision: 1,
                    text: artifact.rawText,
                    kind: .sourceSnapshot,
                    author: .source,
                    createdAt: date
                )
            )
        }

        story.text = artifact.rawText
        story.processingStatus = "awaitingModel"
        story.updatedAt = date
        job.providerId = artifact.providerId
        job.providerModelId = artifact.providerModelId
        job.markSucceeded(
            outputReferenceId: artifact.id,
            transcriptArtifactId: artifact.id,
            resultSchemaVersion: "1.0",
            at: date
        )

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return story
    }

    private static func encodeRemoteAuditJSON<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isTerminalTranscriptionError(_ error: Error) -> Bool {
        if let runnerError = error as? TranscriptionJobRunnerError {
            return runnerError == .audioAssetNotFound || runnerError == .audioFileMissing
        }
        guard let remoteError = error as? RemoteSpeechTranscriptionError else {
            return false
        }
        return remoteError == .notConfigured || remoteError == .audioFileMissing
    }

    private static func transcriptionErrorCode(_ error: Error) -> String {
        switch error {
        case RemoteSpeechTranscriptionError.notConfigured:
            return "remote_not_configured"
        case RemoteSpeechTranscriptionError.audioFileMissing,
             TranscriptionJobRunnerError.audioFileMissing,
             TranscriptionJobRunnerError.audioAssetNotFound:
            return "audio_file_missing"
        case RemoteSpeechTranscriptionError.emptyTranscript:
            return "empty_remote_transcript"
        default:
            return "remote_transcription_failed"
        }
    }

    private static func transcriptionRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        min(300, 15 * pow(2, Double(max(0, attempt - 1))))
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
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
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
        let dailyEntryResults = try modelContext.fetch(FetchDescriptor<DailyEntryResultArtifact>())
            .filter { $0.storyId == story.id }
        let fragments = try modelContext.fetch(FetchDescriptor<BiographyFragment>())
            .filter { $0.storyId == story.id }

        dailyEntryResults.forEach(modelContext.delete)
        versions.forEach(modelContext.delete)
        artifacts.forEach(modelContext.delete)
        jobs.forEach(modelContext.delete)
        fragments.forEach(modelContext.delete)

        return dailyEntryResults.count + versions.count + artifacts.count + jobs.count + fragments.count
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
                await processRemoteDailyEntry(for: story, userProfile: userProfile)
                loadStories()
                return
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

    private func processRemoteDailyEntry(
        for story: Story,
        userProfile: UserProfile
    ) async {
        guard let modelContext else {
            story.processingStatus = "failed"
            story.updatedAt = Date()
            setError(RemoteGenerationRequestFactoryError.missingTranscriptArtifact.localizedDescription)
            return
        }

        let availability = remoteWorkAvailability(requiresAudioUpload: false)
        let initialState: ProcessingJobState
        switch availability {
        case .permitted:
            initialState = .queued
        case .waitingForConsent:
            initialState = .waitingForConsent
        case .waitingForNetwork:
            initialState = .waitingForNetwork
        }

        do {
            let prepared = try DailyEntryJobRunner.prepare(
                story: story,
                userProfile: userProfile,
                initialState: initialState,
                in: modelContext
            )

            guard availability == .permitted else {
                prepared.job.state = initialState
                prepared.job.nextAttemptAt = nil
                prepared.job.leaseExpiresAt = nil
                story.processingStatus = initialState == .waitingForConsent
                    ? "waitingForConsent"
                    : "waitingForNetwork"
                story.updatedAt = Date()
                try modelContext.save()
                return
            }

            if prepared.job.state == .waitingForConsent || prepared.job.state == .waitingForNetwork {
                prepared.job.state = .queued
                prepared.job.nextAttemptAt = Date()
                try modelContext.save()
            }
            _ = try await DailyEntryJobRunner.run(
                jobID: prepared.job.id,
                userProfile: userProfile,
                generator: remoteDailyEntryGenerator,
                in: modelContext
            )
        } catch is CancellationError {
            return
        } catch {
            setError(error.localizedDescription)
            scheduleNextDailyEntryRecovery()
        }
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
