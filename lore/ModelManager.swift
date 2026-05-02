import Foundation

enum LocalModelTier: String, CaseIterable, Identifiable {
    case standard4B = "Ternary-Bonsai-4B-mlx-2bit"
    case bestWriting8B = "Ternary-Bonsai-8B-mlx-2bit"
    case lightweight17B = "Ternary-Bonsai-1.7B-mlx-2bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard4B:
            return "Standard"
        case .bestWriting8B:
            return "Best Writing"
        case .lightweight17B:
            return "Lightweight"
        }
    }

    var detail: String {
        switch self {
        case .standard4B:
            return "Ternary Bonsai 4B for balanced local writing."
        case .bestWriting8B:
            return "Ternary Bonsai 8B for richer prose on newer devices."
        case .lightweight17B:
            return "Ternary Bonsai 1.7B for faster local processing."
        }
    }
}

enum LocalGenerationTask: String, Equatable {
    case biographyProse
    case memoryGraphExtraction
}

struct LocalGenerationFallbackContext: Equatable {
    var storyID: UUID
    var transcript: String
    var userName: String
    var hometown: String
    var birthYear: Int
    var captureDate: Date
}

struct LocalGenerationRequest: Equatable {
    var task: LocalGenerationTask
    var prompt: String
    var fallbackContext: LocalGenerationFallbackContext
}

enum LocalModelRuntimeError: Error, LocalizedError {
    case modelNotReady
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Local AI is not ready yet."
        case .generationFailed(let message):
            return message
        }
    }
}

@MainActor
protocol LocalModelRuntime {
    var displayName: String { get }
    var isMLXBacked: Bool { get }

    func load(tier: LocalModelTier) async throws
    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String
}

enum LocalModelState: String {
    case notDownloaded
    case downloading
    case downloaded
    case loading
    case loaded
    case failed
}

struct LocalModelStatus: Equatable {
    var tier: LocalModelTier
    var state: LocalModelState
    var progress: Double
    var message: String?

    var isReady: Bool {
        state == .loaded
    }

    var statusText: String {
        switch state {
        case .notDownloaded:
            return "Not downloaded"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Downloaded"
        case .loading:
            return "Loading"
        case .loaded:
            return "Ready"
        case .failed:
            return "Needs attention"
        }
    }
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var status: LocalModelStatus

    private let userDefaults: UserDefaults
    private let runtime: any LocalModelRuntime
    private let selectedTierKey = "LoreSelectedLocalModelTier"
    private let downloadedTierKey = "LoreDownloadedLocalModelTier"

    init(
        userDefaults: UserDefaults = .standard,
        runtime: (any LocalModelRuntime)? = nil
    ) {
        self.userDefaults = userDefaults
        self.runtime = runtime ?? DeterministicLocalModelRuntime()

        let selectedTier = userDefaults.string(forKey: selectedTierKey)
            .flatMap(LocalModelTier.init(rawValue:)) ?? .standard4B
        let downloadedTier = userDefaults.string(forKey: downloadedTierKey)
            .flatMap(LocalModelTier.init(rawValue:))
        let state: LocalModelState = selectedTier == downloadedTier ? .downloaded : .notDownloaded

        status = LocalModelStatus(
            tier: selectedTier,
            state: state,
            progress: state == .downloaded ? 1.0 : 0.0,
            message: nil
        )
    }

    func select(_ tier: LocalModelTier) {
        guard tier != status.tier else {
            return
        }

        userDefaults.set(tier.rawValue, forKey: selectedTierKey)

        let downloadedTier = userDefaults.string(forKey: downloadedTierKey)
            .flatMap(LocalModelTier.init(rawValue:))
        status = LocalModelStatus(
            tier: tier,
            state: tier == downloadedTier ? .downloaded : .notDownloaded,
            progress: tier == downloadedTier ? 1.0 : 0.0,
            message: nil
        )
    }

    func downloadSelectedModel() async {
        guard status.state != .downloading, status.state != .loading else {
            return
        }

        status.state = .downloading
        status.progress = 0.0
        status.message = "Preparing local model files."

        for progress in [0.2, 0.45, 0.7, 1.0] {
            try? await Task.sleep(for: .milliseconds(120))
            status.progress = progress
        }

        userDefaults.set(status.tier.rawValue, forKey: selectedTierKey)
        userDefaults.set(status.tier.rawValue, forKey: downloadedTierKey)
        status.state = .downloaded
        status.message = "Model files are ready to load."
    }

    func loadSelectedModel() async {
        guard status.state == .downloaded || status.state == .loaded else {
            status.state = .failed
            status.message = "Download a local model before loading it."
            return
        }

        guard status.state != .loaded else {
            return
        }

        status.state = .loading
        status.message = "Loading local model into memory."
        do {
            try await runtime.load(tier: status.tier)
            status.state = .loaded
            status.progress = 1.0
            status.message = runtime.isMLXBacked
                ? "Local generation is ready."
                : "Local generation fallback is ready."
        } catch {
            status.state = .failed
            status.message = error.localizedDescription
        }
    }

    func generate(_ request: LocalGenerationRequest) async throws -> String {
        guard status.isReady else {
            throw LocalModelRuntimeError.modelNotReady
        }

        return try await runtime.generate(request, tier: status.tier)
    }

    func forgetDownloadedModel() {
        userDefaults.removeObject(forKey: downloadedTierKey)
        status.state = .notDownloaded
        status.progress = 0.0
        status.message = nil
    }
}

struct DeterministicLocalModelRuntime: LocalModelRuntime {
    let displayName = "Deterministic local fallback"
    let isMLXBacked = false

    func load(tier: LocalModelTier) async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        try await Task.sleep(for: .milliseconds(20))

        switch request.task {
        case .biographyProse:
            return makeBiographyProse(from: request.fallbackContext)
        case .memoryGraphExtraction:
            return try makeMemoryGraphJSON(from: request.fallbackContext)
        }
    }

    private func makeBiographyProse(from context: LocalGenerationFallbackContext) -> String {
        let cleanedTranscript = context.transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")

        return """
        \(context.userName), who began life in \(context.hometown), remembered this moment with the plain texture of lived experience. \(cleanedTranscript)
        """
    }

    private func makeMemoryGraphJSON(from context: LocalGenerationFallbackContext) throws -> String {
        let cleanedTranscript = context.transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        let summary = String(cleanedTranscript.prefix(220))
        let payload = DeterministicMemoryGraphPayload(
            people: [],
            places: [
                DeterministicPlaceCandidate(
                    displayName: context.hometown,
                    placeKind: "hometown",
                    locationHint: context.hometown,
                    summary: "Hometown from the local user profile.",
                    confidence: 0.35,
                    sourceStoryIds: [context.storyID.uuidString]
                )
            ],
            themes: [
                DeterministicThemeCandidate(
                    name: "reflection",
                    summary: "A locally generated fallback theme for a captured personal story.",
                    confidence: 0.2,
                    sourceStoryIds: [context.storyID.uuidString]
                )
            ],
            lifeEvents: [
                DeterministicLifeEventCandidate(
                    title: "Captured personal memory",
                    summary: summary,
                    eventDateKind: "unknown",
                    eventStartDate: nil,
                    eventEndDate: nil,
                    approximateLabel: nil,
                    confidence: 0.2,
                    sourceStoryIds: [context.storyID.uuidString]
                )
            ],
            memoryFacts: [
                DeterministicMemoryFactCandidate(
                    text: summary,
                    confidence: 0.2,
                    sourceStoryId: context.storyID.uuidString
                )
            ],
            modelName: displayName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalModelRuntimeError.generationFailed("Unable to encode memory graph fallback.")
        }

        return json
    }
}

private struct DeterministicMemoryGraphPayload: Encodable {
    var people: [DeterministicPersonCandidate]
    var places: [DeterministicPlaceCandidate]
    var themes: [DeterministicThemeCandidate]
    var lifeEvents: [DeterministicLifeEventCandidate]
    var memoryFacts: [DeterministicMemoryFactCandidate]
    var modelName: String
}

private struct DeterministicPersonCandidate: Encodable {}

private struct DeterministicPlaceCandidate: Encodable {
    var displayName: String
    var placeKind: String
    var locationHint: String
    var summary: String
    var confidence: Double
    var sourceStoryIds: [String]
}

private struct DeterministicThemeCandidate: Encodable {
    var name: String
    var summary: String
    var confidence: Double
    var sourceStoryIds: [String]
}

private struct DeterministicLifeEventCandidate: Encodable {
    var title: String
    var summary: String
    var eventDateKind: String
    var eventStartDate: String?
    var eventEndDate: String?
    var approximateLabel: String?
    var confidence: Double
    var sourceStoryIds: [String]
}

private struct DeterministicMemoryFactCandidate: Encodable {
    var text: String
    var confidence: Double
    var sourceStoryId: String
}
