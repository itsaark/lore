//
//  SpeechRecognitionViewModel.swift
//  lore
//
//  Created by AI Assistant
//

import Foundation
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
    @Published var isRecording = false
    /// Diagnostic context for tests and logs. Background processing failures
    /// must never drive the focused recording surface directly.
    private(set) var errorMessage: String?
    @Published var isAuthorized = false
    @Published var stories: [Story] = []
    @Published private(set) var dailyBiographyEntries: [DailyBiographyEntry] = []
    @Published private(set) var storyDayKeys: [UUID: String] = [:]
    @Published var isProcessingAudio = false
    @Published var currentAudioLevel: Float = 0.0
    @Published var currentAudioResponseLevel: Float = 0.0
    @Published private(set) var transcriptionRoute: SpeechTranscriptionRoute = .deferred(reason: .networkUnknown)
    @Published private(set) var isAwaitingRemoteTranscription = false
    
    // MARK: - Private Properties
    private let metadataService: any MetadataService
    private let transcriptionPolicy: SpeechTranscriptionPolicy
    private let remoteDailyEntryGenerator: any DailyEntryGenerationService
    private let remoteTranscriber: any RemoteSpeechTranscribing
    private let networkConnectionProvider: any SpeechNetworkConnectionProviding
    private let localeIdentifier: String
    private let audioEngine = AVAudioEngine()
    private var recordingStartTime: Date?
    private var currentRecordingAudioFileURL: URL?
    private var audioLevelTimer: Timer?
    private var audioLevelBuffer: [Float] = []
    private var audioLevelEnvelope = AudioLevelEnvelope()
    private var pendingSaveTask: Task<Void, Never>?
    private var transcriptionRecoveryTask: Task<Void, Never>?
    private var dailyEntryRecoveryTask: Task<Void, Never>?
    private var dailyBiographyRecoveryTask: Task<Void, Never>?
    private var dailyBoundaryTask: Task<Void, Never>?
    private var isRecoveringTranscriptionJobs = false
    private var isRecoveringDailyEntryJobs = false
    private var isRecoveringDailyBiographyJobs = false
    private var modelContext: ModelContext?
    private var userProfile: UserProfile?
    private var hasLoadedStories = false
    private var microphonePermissionGranted = false
    private static let audioRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let placeholderAudioScheme = "lore-audio-placeholder"
    
    // MARK: - Initialization
    init(
        metadataService: any MetadataService = LocalMetadataService(),
        transcriptionPolicy: SpeechTranscriptionPolicy = .production,
        remoteDailyEntryGenerator: any DailyEntryGenerationService = RemoteDailyEntryGenerationService(
            backend: UnconfiguredLoreBackendProcessingClient()
        ),
        remoteTranscriber: any RemoteSpeechTranscribing = UnavailableRemoteSpeechTranscriber(),
        networkConnectionProvider: (any SpeechNetworkConnectionProviding)? = nil,
        localeIdentifier: String = Locale.current.identifier,
        requestsMicrophonePermissionOnInit: Bool = true
    ) {
        self.metadataService = metadataService
        self.transcriptionPolicy = transcriptionPolicy
        self.remoteDailyEntryGenerator = remoteDailyEntryGenerator
        self.remoteTranscriber = remoteTranscriber
        self.networkConnectionProvider = networkConnectionProvider ?? SystemSpeechNetworkMonitor()
        self.localeIdentifier = localeIdentifier

        self.networkConnectionProvider.observeChanges { [weak self] _ in
            guard let self, self.userProfile != nil else { return }
            self.refreshRemoteProcessingPolicy()
        }

        if requestsMicrophonePermissionOnInit {
            Task {
                await requestPermissions()
            }
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
        isProcessingAudio = false
        isAwaitingRemoteTranscription = false
        errorMessage = nil
        currentAudioLevel = 0.0
        currentAudioResponseLevel = 0.0
        stopAudioLevelTimer()
        audioLevelEnvelope.reset()
    }

    /// Connects the view model to SwiftData once the view receives its environment context.
    func configure(
        modelContext: ModelContext,
        userProfile: UserProfile
    ) {
        self.modelContext = modelContext
        self.userProfile = userProfile
        refreshRemoteProcessingPolicy(resumeJobs: false)

        guard !hasLoadedStories else {
            return
        }

        cleanupExpiredAudioAssets()
        loadStories()
        hasLoadedStories = true
        scheduleNextDailyBoundary()

        Task { [weak self] in
            await self?.resumePendingTranscriptionJobs()
            await self?.resumePendingDailyEntryJobs()
            await self?.resumePendingDailyBiographyJobs()
        }
    }

    /// Rechecks durable work whenever the app becomes active. Completed-day
    /// consolidation remains asynchronous and never blocks the launch surface.
    func resumeBackgroundProcessing() {
        scheduleNextDailyBoundary()
        Task { [weak self] in
            await self?.resumePendingTranscriptionJobs()
            await self?.resumePendingDailyEntryJobs()
            await self?.resumePendingDailyBiographyJobs()
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
        refreshAuthorizationState()

        if isAwaitingRemoteTranscription,
           remoteWorkAvailability(requiresAudioUpload: true) != .permitted {
            pendingSaveTask?.cancel()
        }

        guard resumeJobs else { return }
        Task { [weak self] in
            await self?.resumePendingTranscriptionJobs()
            await self?.resumePendingDailyEntryJobs()
            await self?.resumePendingDailyBiographyJobs()
        }
    }

    /// Relaunch recovery entry point for queued work and interrupted leases.
    /// It is safe to call repeatedly; completed transcript commits are idempotent.
    func resumePendingTranscriptionJobs(now: Date = Date()) async {
        guard let modelContext else { return }

        transcriptionRecoveryTask?.cancel()
        transcriptionRecoveryTask = nil
        guard !isRecoveringTranscriptionJobs else { return }
        isRecoveringTranscriptionJobs = true
        defer { isRecoveringTranscriptionJobs = false }

        do {
            let allJobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
            let jobs = allJobs
                .filter { $0.kind == .transcription }
                .sorted { $0.createdAt < $1.createdAt }
            let storiesWithDailyEntryJobs = Set(allJobs.compactMap { job -> UUID? in
                job.kind == .dailyEntry ? job.storyId : nil
            })
            let storiesWithPendingAudioDeletion = Set(
                try modelContext.fetch(FetchDescriptor<AudioAsset>())
                    .filter { !$0.isDeleted }
                    .map(\.id)
            )

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

                let shouldFinishDeletion = job.state == .succeeded
                    && job.storyId.map(storiesWithPendingAudioDeletion.contains) == true
                let shouldBootstrapDailyEntry = job.state == .succeeded
                    && job.outputReferenceId != nil
                    && job.storyId.map { !storiesWithDailyEntryJobs.contains($0) } == true
                let shouldAttempt = job.state == .queued && job.isReadyForAttempt(at: now)
                let shouldRecoverLease = job.state == .running
                    && job.leaseExpiresAt.map { $0 <= now } == true
                guard shouldFinishDeletion
                        || shouldBootstrapDailyEntry
                        || shouldAttempt
                        || shouldRecoverLease else {
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
                    if shouldBootstrapDailyEntry,
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
                guard let self else { return }
                // Clear the handle before entering recovery. Otherwise recovery's
                // normal "cancel the old timer" step cancels this currently running
                // task and can propagate cancellation into the provider request.
                self.transcriptionRecoveryTask = nil
                await self.resumePendingTranscriptionJobs()
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
        guard !isRecoveringDailyEntryJobs else { return }
        isRecoveringDailyEntryJobs = true
        defer { isRecoveringDailyEntryJobs = false }

        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .dailyEntry }
                .sorted { $0.createdAt < $1.createdAt }

            // Builds before the strict-null encoding fix sent daily-entry
            // source segments without nullable keys. Recover those known 400s
            // from the durable transcript, while preserving the attempt cap.
            let repairedStoryIDs = Set(jobs.compactMap { job -> UUID? in
                job.requeueFailedRequest(matchingErrorCode: "invalid_request", at: now)
                    ? job.storyId
                    : nil
            })
            if !repairedStoryIDs.isEmpty {
                let stories = try modelContext.fetch(FetchDescriptor<Story>())
                for story in stories where repairedStoryIDs.contains(story.id) {
                    story.processingStatus = "awaitingModel"
                    story.updatedAt = now
                }
                try modelContext.save()
            }

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
                guard let self else { return }
                // Do not let resumePendingDailyEntryJobs cancel the timer task that
                // just woke up; cancellation would otherwise poison the retry attempt.
                self.dailyEntryRecoveryTask = nil
                await self.resumePendingDailyEntryJobs()
            }
        } catch {
            print("Failed to schedule the next daily-entry retry: \(error)")
        }
    }

    /// Creates and resumes one replaceable biography entry for every completed
    /// local calendar day. The runner reads canonical transcript versions at
    /// execution time, so no transcript content is duplicated into job state.
    func resumePendingDailyBiographyJobs(now: Date = Date()) async {
        guard let modelContext, let userProfile else { return }

        dailyBiographyRecoveryTask?.cancel()
        dailyBiographyRecoveryTask = nil
        guard !isRecoveringDailyBiographyJobs else { return }
        isRecoveringDailyBiographyJobs = true
        defer { isRecoveringDailyBiographyJobs = false }

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
            _ = try DailyBiographyJobRunner.prepareCompletedDays(
                initialState: initialState,
                in: modelContext,
                now: now
            )
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .dailyBiography }
                .sorted { $0.createdAt < $1.createdAt }

            // A provider regression could previously mark a valid consolidation
            // response as terminal after one attempt. Requeue that known failure
            // while retaining the job's existing three-attempt ceiling.
            let repairedInvalidResponses = jobs.reduce(into: 0) { count, job in
                if job.requeueFailedRequest(
                    matchingErrorCode: "invalid_provider_response",
                    at: now
                ) {
                    count += 1
                }
            }
            if repairedInvalidResponses > 0 {
                try modelContext.save()
            }

            for job in jobs where job.state != .succeeded && job.state != .cancelled && job.state != .failed {
                switch availability {
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
                    _ = try await DailyBiographyJobRunner.run(
                        jobID: job.id,
                        userProfile: userProfile,
                        generator: remoteDailyEntryGenerator,
                        in: modelContext,
                        now: now
                    )
                } catch DailyBiographyJobRunnerError.jobNotReady {
                    continue
                } catch {
                    print("Deferred daily-biography job \(job.id) did not complete: \(error)")
                }
            }
            loadStories()
            scheduleNextDailyBiographyRecovery()
        } catch {
            print("Failed to recover daily-biography jobs: \(error)")
            scheduleNextDailyBiographyRecovery()
        }
    }

    private func scheduleNextDailyBiographyRecovery(now: Date = Date()) {
        guard let modelContext else { return }
        do {
            let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
                .filter { $0.kind == .dailyBiography }
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
            dailyBiographyRecoveryTask?.cancel()
            dailyBiographyRecoveryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.dailyBiographyRecoveryTask = nil
                await self.resumePendingDailyBiographyJobs()
            }
        } catch {
            print("Failed to schedule the next daily-biography retry: \(error)")
        }
    }

    /// If Lore remains active across midnight, roll up the day without waiting
    /// for another foreground transition. Suspension is still recovered by the
    /// normal launch/activation path.
    private func scheduleNextDailyBoundary(now: Date = Date()) {
        dailyBoundaryTask?.cancel()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let delay = max(1, nextDay.timeIntervalSince(now))
        dailyBoundaryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.dailyBoundaryTask = nil
            await self.resumePendingDailyBiographyJobs()
            self.scheduleNextDailyBoundary()
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
                    try DailyBiographyJobRunner.deleteSupportData(
                        containing: story.id,
                        in: modelContext
                    )
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
            let metadata = try modelContext.fetch(FetchDescriptor<StoryMetadata>())
            let metadataById = Dictionary(
                metadata.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            storyDayKeys = Dictionary(stories.map { story in
                let timezone = story.metadataId
                    .flatMap { metadataById[$0] }
                    .flatMap { TimeZone(identifier: $0.timezone) }
                    ?? .current
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timezone
                formatter.dateFormat = "yyyy-MM-dd"
                return (story.id, formatter.string(from: story.date))
            }, uniquingKeysWith: { current, _ in current })
            dailyBiographyEntries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>(
                sortBy: [SortDescriptor(\.calendarDate, order: .forward)]
            ))
        } catch {
            print("Failed to load stories: \(error)")
            stories = []
            dailyBiographyEntries = []
            storyDayKeys = [:]
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
    
    /// Requests the only system permission needed by remote-first capture.
    private func requestPermissions() async {
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
        isAuthorized = microphonePermissionGranted && transcriptionRoute.usesRemoteService
    }

    private func resolvedCaptureRoute() -> SpeechTranscriptionRoute {
        guard let userProfile else {
            return .deferred(reason: .remoteProcessingConsentRequired)
        }

        return transcriptionPolicy.route(
            for: SpeechTranscriptionRoutingInput(
                preferences: RemoteProcessingPreferences(userProfile: userProfile),
                networkConnection: networkConnectionProvider.currentConnection
            )
        )
    }

    private func remoteWorkAvailability(requiresAudioUpload _: Bool) -> RemoteWorkAvailability {
        guard let userProfile, userProfile.hasRemoteProcessingConsent else {
            return .waitingForConsent
        }

        switch networkConnectionProvider.currentConnection {
        case .wifi, .cellular:
            return .permitted
        case .unavailable, .unknown:
            return .waitingForNetwork
        }
    }

    private func message(for reason: SpeechTranscriptionDeferralReason) -> String {
        switch reason {
        case .remoteProcessingConsentRequired:
            return "Allow private processing before recording."
        case .networkUnavailable, .networkUnknown:
            return "Lore is offline. Connect to the internet to transcribe a new recording."
        }
    }
    
    /// Starts speech recognition
    private func startRecording() {
        print("🎤 Attempting to start recording...")

        guard pendingSaveTask == nil && !isAwaitingRemoteTranscription else {
            setError("Lore is still securing the previous recording. Please wait a moment.")
            return
        }
        
        stopRecording(shouldSave: false)
        clearText()
        
        guard AVAudioApplication.shared.recordPermission == .granted else {
            setError("Microphone access required. Please check Settings.")
            return
        }

        let resolvedRoute = resolvedCaptureRoute()
        if case let .deferred(reason) = resolvedRoute {
            transcriptionRoute = resolvedRoute
            setError(message(for: reason))
            return
        }

        transcriptionRoute = resolvedRoute
        refreshAuthorizationState()
        
        do {
            try setupAudioSession()
            try startAudioCapture()
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
    
    /// Starts capture to a protected local file that is uploaded after stop.
    private func startAudioCapture() throws {
        recordingStartTime = Date()
        
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, audioFile] buffer, _ in
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
    private func stopRecording(shouldSave: Bool = true) {
        print("🛑 Stopping recording...")
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        isProcessingAudio = false
        
        // Reset both visual meters so the next recording starts from silence.
        stopAudioLevelTimer()
        audioLevelEnvelope.reset()
        currentAudioLevel = 0.0
        currentAudioResponseLevel = 0.0
        
        // Stop audio engine
        audioEngine.stop()

        if shouldSave {
            pendingSaveTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.saveCurrentRecording()
            }
        } else {
            discardCurrentAudioFile()
            recordingStartTime = nil
        }

        isProcessingAudio = false
        currentAudioLevel = 0.0
        currentAudioResponseLevel = 0.0
        
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
        let audioFileURL = currentRecordingAudioFileURL
        guard let modelContext, let audioFileURL else {
            pendingSaveTask = nil
            setError("Lore could not secure this recording locally. The audio was kept on this iPhone.")
            return
        }

        let story: Story
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
        Task { await enrichCaptureMetadata(for: story, captureDate: startTime) }

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
            Task { await processCapturedStory(transcribedStory) }
        } catch {
            isAwaitingRemoteTranscription = false
            pendingSaveTask = nil
            setError(error.localizedDescription)
            loadStories()
            scheduleNextTranscriptionRecovery()
        }
    }

    private func clearFinishedCaptureState(keepPendingTask: Bool = false) {
        if !keepPendingTask {
            pendingSaveTask = nil
        }
        recordingStartTime = nil
        currentRecordingAudioFileURL = nil
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
            errorCode = "remote_transcription_failed"
        }

        return ProcessingJob(
            idempotencyKey: "transcription:\(story.id.uuidString)",
            storyId: story.id,
            kind: .transcription,
            state: state,
            route: .remote,
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

        await processRemoteDailyEntry(for: story, userProfile: userProfile)
        loadStories()
        await resumePendingDailyBiographyJobs()
    }

    private func processRemoteDailyEntry(
        for story: Story,
        userProfile: UserProfile
    ) async {
        guard let modelContext else {
            story.processingStatus = "failed"
            story.updatedAt = Date()
            print("Daily-entry processing could not access the local archive.")
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
        } catch DailyEntryJobRunnerError.jobNotReady {
            // A queued job with a future retry date (or an active lease) is expected
            // durable orchestration state. Launch recovery can reach this path after
            // re-checking a completed transcription, so it must not leak an internal
            // scheduler message into the recording UI.
            scheduleNextDailyEntryRecovery()
            return
        } catch DailyEntryJobRunnerError.jobCancelled {
            return
        } catch {
            // Journal generation is background work. Its durable Story/ProcessingJob
            // state is the user-visible source of truth; the recording surface should
            // remain focused on capture rather than displaying provider/debug errors.
            print("Daily-entry processing did not complete: \(error)")
            scheduleNextDailyEntryRecovery()
        }
    }
    
    /// Sets error message and logs it
    private func setError(_ message: String) {
        errorMessage = message
        print("❌ Error: \(message)")
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
