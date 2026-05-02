import Foundation

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
            prompt: prompt,
            fallbackContext: LocalGenerationFallbackContext(
                storyID: story.id,
                transcript: transcript,
                userName: userProfile.name,
                hometown: userProfile.hometown,
                birthYear: userProfile.birthYear,
                captureDate: story.date
            )
        )

        do {
            return try await modelManager.generate(request)
        } catch LocalModelRuntimeError.modelNotReady {
            throw GenerationError.localModelNotReady
        }
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
