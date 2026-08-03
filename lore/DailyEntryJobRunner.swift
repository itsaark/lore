import Foundation
import SwiftData

enum DailyEntryJobRunnerError: Error, LocalizedError, Equatable {
    case jobNotFound
    case storyNotFound
    case jobNotReady
    case jobCancelled

    var errorDescription: String? {
        switch self {
        case .jobNotFound:
            return "Lore could not find the saved journal-writing job."
        case .storyNotFound:
            return "Lore could not find the local note for this journal-writing job."
        case .jobNotReady:
            return "This journal-writing job is waiting before it can retry."
        case .jobCancelled:
            return "This journal-writing job was cancelled."
        }
    }
}

@MainActor
enum DailyEntryJobRunner {
    static func prepare(
        story: Story,
        userProfile: UserProfile,
        initialState: ProcessingJobState,
        in modelContext: ModelContext
    ) throws -> (job: ProcessingJob, request: DailyEntryGenerationRequest) {
        let provisionalRequest = try RemoteGenerationRequestFactory.makeRequest(
            for: story,
            userProfile: userProfile,
            in: modelContext
        )
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        let existing = jobs.first {
            $0.kind == .dailyEntry
                && $0.storyId == story.id
                && $0.transcriptArtifactId == provisionalRequest.transcriptArtifactId
                && $0.inputTranscriptVersionId == provisionalRequest.transcriptVersionId
                && $0.state != .cancelled
        }
        let job: ProcessingJob
        if let existing {
            job = existing
        } else {
            job = ProcessingJob(
                id: provisionalRequest.jobId,
                idempotencyKey: "daily-entry:\(story.id.uuidString):\(provisionalRequest.transcriptVersionId.uuidString)",
                storyId: story.id,
                transcriptArtifactId: provisionalRequest.transcriptArtifactId,
                inputTranscriptVersionId: provisionalRequest.transcriptVersionId,
                kind: .dailyEntry,
                state: initialState,
                route: .remote,
                deletionState: .notApplicable
            )
            modelContext.insert(job)
            try modelContext.save()
        }

        let request = try RemoteGenerationRequestFactory.makeRequest(
            for: story,
            userProfile: userProfile,
            in: modelContext,
            jobId: job.id
        )
        return (job, request)
    }

    @discardableResult
    static func run(
        jobID: UUID,
        userProfile: UserProfile,
        generator: any DailyEntryGenerationService,
        in modelContext: ModelContext,
        now: Date = Date(),
        leaseDuration: TimeInterval = 180
    ) async throws -> Story {
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        guard let job = jobs.first(where: { $0.id == jobID && $0.kind == .dailyEntry }) else {
            throw DailyEntryJobRunnerError.jobNotFound
        }
        guard let storyID = job.storyId else {
            throw DailyEntryJobRunnerError.storyNotFound
        }
        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        guard let story = stories.first(where: { $0.id == storyID }) else {
            throw DailyEntryJobRunnerError.storyNotFound
        }
        if job.state == .succeeded {
            return story
        }
        guard job.state != .cancelled else {
            throw DailyEntryJobRunnerError.jobCancelled
        }

        _ = job.recoverExpiredLease(at: now)
        guard job.isReadyForAttempt(at: now) else {
            throw DailyEntryJobRunnerError.jobNotReady
        }

        let request = try RemoteGenerationRequestFactory.makeRequest(
            for: story,
            userProfile: userProfile,
            in: modelContext,
            jobId: job.id
        )
        job.beginAttempt(at: now, leaseDuration: leaseDuration)
        story.processingStatus = "processing"
        story.updatedAt = now
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        do {
            let response = try await generator.generateDailyEntry(request)
            try Task.checkCancellation()
            _ = try DailyEntryResultPersister.persist(
                response: response,
                request: request,
                for: story,
                job: job,
                in: modelContext,
                at: Date()
            )
            return story
        } catch is CancellationError {
            modelContext.rollback()
            job.cancel(at: Date())
            story.processingStatus = "awaitingModel"
            story.updatedAt = Date()
            try modelContext.save()
            throw CancellationError()
        } catch LoreBackendProcessingError.cancelled {
            modelContext.rollback()
            job.cancel(at: Date())
            story.processingStatus = "awaitingModel"
            story.updatedAt = Date()
            try modelContext.save()
            throw CancellationError()
        } catch {
            modelContext.rollback()
            guard job.state == .running else { throw error }
            let terminal = isTerminal(error) || job.attemptCount >= job.maximumAttempts
            let failureDate = Date()
            job.markFailed(
                errorCode: errorCode(error),
                retryAt: terminal ? nil : failureDate.addingTimeInterval(retryDelay(job.attemptCount)),
                at: failureDate
            )
            story.processingStatus = terminal ? "failed" : "awaitingModel"
            story.updatedAt = failureDate
            try modelContext.save()
            throw error
        }
    }

    private static func isTerminal(_ error: Error) -> Bool {
        switch error {
        case LoreBackendProcessingError.notConfigured,
             LoreBackendProcessingError.invalidConfiguration,
             LoreBackendProcessingError.invalidRequest,
             LoreBackendProcessingError.payloadTooLarge:
            return true
        case let LoreBackendProcessingError.rejected(_, retryable, _):
            return !retryable
        case RemoteGenerationRequestFactoryError.missingTranscriptArtifact,
             RemoteGenerationRequestFactoryError.missingTranscriptVersion,
             GenerationError.emptyTranscript:
            return true
        default:
            return false
        }
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case LoreBackendProcessingError.notConfigured:
            return "remote_not_configured"
        case LoreBackendProcessingError.invalidConfiguration:
            return "remote_invalid_configuration"
        case LoreBackendProcessingError.invalidRequest:
            return "remote_invalid_request"
        case LoreBackendProcessingError.payloadTooLarge:
            return "remote_payload_too_large"
        case LoreBackendProcessingError.rateLimited:
            return "remote_rate_limited"
        case LoreBackendProcessingError.transportUnavailable:
            return "network_unavailable"
        case LoreBackendProcessingError.invalidResponse:
            return "invalid_remote_response"
        case let LoreBackendProcessingError.rejected(code, _, _):
            return code
        default:
            return "remote_daily_entry_failed"
        }
    }

    private static func retryDelay(_ attempt: Int) -> TimeInterval {
        min(600, 30 * pow(2, Double(max(0, attempt - 1))))
    }
}
