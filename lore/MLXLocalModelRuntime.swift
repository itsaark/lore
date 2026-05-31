import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon

@MainActor
final class MLXLocalModelRuntime: LocalModelRuntime {
    let displayName = "MLX Swift"
    let isMLXBacked = true

    private var loadedTier: LocalModelTier?
    private var modelContainer: MLXLMCommon.ModelContainer?

    func download(tier: LocalModelTier) async throws {
        try await load(tier: tier)
    }

    func load(tier: LocalModelTier) async throws {
        if loadedTier == tier, modelContainer != nil {
            return
        }

        modelContainer = try await loadModelContainer(
            configuration: ModelConfiguration(id: tier.repositoryID)
        )
        loadedTier = tier
    }

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        guard let modelContainer else {
            throw LocalModelRuntimeError.modelNotReady
        }

        let parameters = GenerateParameters(
            maxTokens: request.task.maxGeneratedTokens,
            temperature: request.task.samplingTemperature,
            topP: 0.9,
            repetitionPenalty: 1.05,
            repetitionContextSize: 128
        )
        let session = ChatSession(modelContainer, generateParameters: parameters)
        let output = try await session.respond(to: request.prompt)
        let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedOutput.isEmpty else {
            throw LocalModelRuntimeError.generationFailed("The local model returned an empty response.")
        }

        return cleanedOutput
    }
}
#endif
