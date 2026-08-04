import Foundation
import SwiftData

enum GenerationError: Error, LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        "There is no transcript to turn into biography prose."
    }
}

/// Provider-neutral structured journal generation. The app talks only to a
/// Lore backend implementation and never embeds provider credentials.
protocol DailyEntryGenerationService: Sendable {
    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse
}

struct RemoteDailyEntryGenerationService: DailyEntryGenerationService {
    let backend: any LoreBackendProcessingClient

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        try await backend.generateDailyEntry(request)
    }
}

protocol RemoteTranscriptionService: Sendable {
    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse
}

struct BackendRemoteTranscriptionService: RemoteTranscriptionService {
    let backend: any LoreBackendProcessingClient

    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse {
        try await backend.transcribe(request)
    }
}

enum RemoteGenerationRequestFactoryError: Error, LocalizedError, Equatable {
    case missingTranscriptArtifact
    case missingTranscriptVersion

    var errorDescription: String? {
        switch self {
        case .missingTranscriptArtifact:
            return "Lore could not find the source transcript for remote processing."
        case .missingTranscriptVersion:
            return "Lore could not find the current transcript revision for remote processing."
        }
    }
}

@MainActor
enum RemoteGenerationRequestFactory {
    static func makeRequest(
        for story: Story,
        userProfile: UserProfile,
        in modelContext: ModelContext,
        jobId: UUID = UUID(),
        locale: Locale = .current
    ) throws -> DailyEntryGenerationRequest {
        let artifacts = try modelContext.fetch(FetchDescriptor<TranscriptArtifact>())
        guard let artifact = artifacts.first(where: { $0.storyId == story.id }) else {
            throw RemoteGenerationRequestFactoryError.missingTranscriptArtifact
        }

        let versions = try modelContext.fetch(FetchDescriptor<TranscriptVersion>())
            .filter { $0.transcriptArtifactId == artifact.id }
            .sorted { $0.revision < $1.revision }
        guard let currentVersion = versions.last else {
            throw RemoteGenerationRequestFactoryError.missingTranscriptVersion
        }

        let transcript = currentVersion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw GenerationError.emptyTranscript
        }

        let segment = TranscriptSourceSegment(
            id: currentVersion.id.uuidString,
            startMilliseconds: 0,
            endMilliseconds: max(0, Int(story.duration * 1_000)),
            text: transcript,
            confidence: nil,
            speakerLabel: nil
        )

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return DailyEntryGenerationRequest(
            jobId: jobId,
            noteId: story.id,
            transcriptArtifactId: artifact.id,
            transcriptVersionId: currentVersion.id,
            capturedLocalDate: dateFormatter.string(from: story.date),
            languageCode: artifact.languageCode ?? locale.identifier,
            subject: JournalSubject(displayName: userProfile.name, pronouns: []),
            sourceSegments: [segment]
        )
    }
}
