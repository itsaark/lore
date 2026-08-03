import Foundation
import SwiftData

enum GenerationError: Error, LocalizedError {
    case localModelNotReady
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .localModelNotReady:
            return "Local AI is not ready yet."
        case .emptyTranscript:
            return "There is no transcript to turn into biography prose."
        }
    }
}

@MainActor
protocol GenerationService {
    func writeBiographyProse(from story: Story, userProfile: UserProfile) async throws -> String
    func extractMemoryGraph(from story: Story, userProfile: UserProfile) async throws -> String
    func releaseResources()
}

/// Provider-neutral structured journal generation. The app talks only to a
/// Lore backend implementation; it does not know which inference provider is
/// selected and never embeds provider credentials.
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

protocol RemoteTranscriptionService: Sendable {
    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse
}

struct BackendRemoteTranscriptionService: RemoteTranscriptionService {
    let backend: any LoreBackendProcessingClient

    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse {
        try await backend.transcribe(request)
    }
}

struct LocalGenerationService: GenerationService {
    let modelManager: ModelManager

    func writeBiographyProse(from story: Story, userProfile: UserProfile) async throws -> String {
        try await generate(
            task: .biographyProse,
            story: story,
            userProfile: userProfile,
            prompt: GenerationPromptFactory.makeBiographyProsePrompt(
                story: story,
                userProfile: userProfile
            )
        )
    }

    func extractMemoryGraph(from story: Story, userProfile: UserProfile) async throws -> String {
        try await generate(
            task: .memoryGraphExtraction,
            story: story,
            userProfile: userProfile,
            prompt: GenerationPromptFactory.makeMemoryGraphExtractionPrompt(
                story: story,
                userProfile: userProfile
            )
        )
    }

    private func generate(
        task: LocalGenerationTask,
        story: Story,
        userProfile: UserProfile,
        prompt: String
    ) async throws -> String {
        let transcript = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw GenerationError.emptyTranscript
        }

        let request = LocalGenerationRequest(
            task: task,
            prompt: prompt
        )

        do {
            return try await modelManager.generate(request)
        } catch LocalModelRuntimeError.modelNotReady {
            throw GenerationError.localModelNotReady
        }
    }

    func releaseResources() {
        modelManager.unloadModel()
    }
}

enum GenerationPromptFactory {
    static func makeBiographyProsePrompt(story: Story, userProfile: UserProfile) -> String {
        let transcript = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are Lore, a private local biographer. Rewrite the source transcript into warm, literary, third-person biography prose.

        Rules:
        - Keep all personal material local to this device.
        - Do not invent facts, exact dates, relationships, places, or motivations.
        - Preserve uncertainty when the speaker is unsure.
        - Write in third person using the user's profile.
        - Return only polished prose.

        User profile:
        Name: \(userProfile.name)
        Hometown: \(userProfile.hometown)
        Birth year: \(userProfile.birthYear)

        Story metadata:
        Source story id: \(story.id.uuidString)
        Capture date: \(Self.iso8601DateString(story.date))

        Source transcript:
        \(transcript)
        """
    }

    static func makeMemoryGraphExtractionPrompt(story: Story, userProfile: UserProfile) -> String {
        let transcript = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are Lore's local memory graph extractor. Extract only source-grounded candidates from the transcript.

        Return strict JSON with these top-level arrays:
        - people
        - places
        - themes
        - lifeEvents
        - memoryFacts

        Rules:
        - Keep every candidate traceable to the source story id.
        - Preserve temporal uncertainty with eventDateKind: exact, approximate, range, or unknown.
        - Do not infer facts that are not supported by the transcript.
        - Use confidence from 0.0 to 1.0.
        - Return only JSON.

        User profile:
        Name: \(userProfile.name)
        Hometown: \(userProfile.hometown)
        Birth year: \(userProfile.birthYear)

        Story metadata:
        Source story id: \(story.id.uuidString)
        Capture date: \(Self.iso8601DateString(story.date))

        Source transcript:
        \(transcript)
        """
    }

    private static func iso8601DateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
