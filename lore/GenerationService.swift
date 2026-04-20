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
}

struct LocalGenerationService: GenerationService {
    let modelManager: ModelManager

    func writeBiographyProse(from story: Story, userProfile: UserProfile) async throws -> String {
        guard modelManager.status.isReady else {
            throw GenerationError.localModelNotReady
        }

        let transcript = story.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw GenerationError.emptyTranscript
        }

        try? await Task.sleep(for: .milliseconds(80))
        return BiographyProseDraftWriter.writeStubProse(
            transcript: transcript,
            userProfile: userProfile
        )
    }
}

enum BiographyProseDraftWriter {
    static func writeStubProse(transcript: String, userProfile: UserProfile) -> String {
        let cleanedTranscript = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        \(userProfile.name), who began life in \(userProfile.hometown), remembered this moment with the plain texture of lived experience. \(cleanedTranscript)
        """
    }
}
