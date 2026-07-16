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

    var repositoryID: String {
        switch self {
        case .standard4B:
            return "prism-ml/Ternary-Bonsai-4B-mlx-2bit"
        case .bestWriting8B:
            return "prism-ml/Ternary-Bonsai-8B-mlx-2bit"
        case .lightweight17B:
            return "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit"
        }
    }
}

enum LocalGenerationTask: String, Equatable {
    case biographyProse
    case memoryGraphExtraction

    var maxGeneratedTokens: Int {
        switch self {
        case .biographyProse:
            return 700
        case .memoryGraphExtraction:
            return 700
        }
    }

    var samplingTemperature: Float {
        switch self {
        case .biographyProse:
            return 0.55
        case .memoryGraphExtraction:
            return 0.1
        }
    }
}

struct LocalGenerationRequest: Equatable {
    var task: LocalGenerationTask
    var prompt: String
}

enum LocalModelRuntimeError: Error, LocalizedError {
    case deviceNotEligible
    case modelNotReady
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotEligible:
            return "On-device biography processing requires iPhone 17 or newer."
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

    func download(tier: LocalModelTier) async throws
    func load(tier: LocalModelTier) async throws
    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String
    func unload()
    func delete(tier: LocalModelTier) throws
}

enum LocalModelRuntimeAvailability {
    static var isAvailable: Bool {
#if canImport(MLXLLM) && canImport(MLXLMCommon)
        true
#else
        false
#endif
    }
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
    let isLocalGenerationEligible: Bool

    private let userDefaults: UserDefaults
    private let runtime: any LocalModelRuntime
    private let selectedTierKey = "LoreSelectedLocalModelTier"
    private let downloadedTierKey = "LoreDownloadedLocalModelTier"

    init(
        userDefaults: UserDefaults = .standard,
        runtime: (any LocalModelRuntime)? = nil,
        isLocalGenerationEligible: Bool? = nil
    ) {
        self.userDefaults = userDefaults
        let eligible = isLocalGenerationEligible ?? (runtime != nil || Self.productionEligibility())
        self.isLocalGenerationEligible = eligible
        self.runtime = runtime ?? (eligible ? Self.makeDefaultRuntime() : UnavailableLocalModelRuntime())

        let selectedTier = userDefaults.string(forKey: selectedTierKey)
            .flatMap(LocalModelTier.init(rawValue:)) ?? .lightweight17B
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
        guard isLocalGenerationEligible else { return }
        guard status.state != .downloading, status.state != .loading else {
            return
        }

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
        guard isLocalGenerationEligible else {
            status.state = .failed
            status.message = LocalModelRuntimeError.deviceNotEligible.localizedDescription
            return
        }
        guard status.state != .downloading, status.state != .loading else {
            return
        }

        let tier = status.tier
        status.state = .downloading
        status.progress = 0.05
        status.message = "Preparing local model files."

        do {
            try await runtime.download(tier: tier)
            userDefaults.set(tier.rawValue, forKey: selectedTierKey)
            userDefaults.set(tier.rawValue, forKey: downloadedTierKey)
            status.progress = 1.0
            try await loadDownloadedModel(tier: tier)
        } catch {
            status.state = .failed
            status.progress = 0.0
            status.message = error.localizedDescription
        }
    }

    func loadSelectedModel() async {
        guard isLocalGenerationEligible else {
            status.state = .failed
            status.message = LocalModelRuntimeError.deviceNotEligible.localizedDescription
            return
        }
        guard status.state == .downloaded || status.state == .loaded else {
            status.state = .failed
            status.message = "Download a local model before loading it."
            return
        }

        guard status.state != .loaded else {
            return
        }

        status.state = .loading
        do {
            try await loadDownloadedModel(tier: status.tier)
        } catch {
            status.state = .failed
            status.message = error.localizedDescription
        }
    }

    func generate(_ request: LocalGenerationRequest) async throws -> String {
        guard isLocalGenerationEligible else {
            throw LocalModelRuntimeError.deviceNotEligible
        }
        if !status.isReady {
            guard isSelectedTierDownloaded else {
                throw LocalModelRuntimeError.modelNotReady
            }

            try await loadDownloadedModel(tier: status.tier)
        }

        guard status.isReady else {
            throw LocalModelRuntimeError.modelNotReady
        }

        return try await runtime.generate(request, tier: status.tier)
    }

    func unloadModel(message: String? = "Local model unloaded to free memory.") {
        guard status.state == .loaded else {
            return
        }

        runtime.unload()

        status.state = isSelectedTierDownloaded ? .downloaded : .notDownloaded
        status.progress = isSelectedTierDownloaded ? 1.0 : 0.0
        status.message = message
    }

    func forgetDownloadedModel() {
        runtime.unload()
        do {
            try runtime.delete(tier: status.tier)
        } catch {
            status.state = .failed
            status.message = "Lore could not remove the downloaded model: \(error.localizedDescription)"
            return
        }
        userDefaults.removeObject(forKey: downloadedTierKey)
        status.state = .notDownloaded
        status.progress = 0.0
        status.message = nil
    }

    private static func makeDefaultRuntime() -> any LocalModelRuntime {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return MLXLocalModelRuntime()
        #else
        return UnavailableLocalModelRuntime()
        #endif
    }

    private static func productionEligibility() -> Bool {
        let capabilities = BiographyGenerationCapabilities(
            hardwareIdentifier: CurrentSpeechDevice.hardwareIdentifier,
            supportsLocalRuntime: LocalModelRuntimeAvailability.isAvailable
        )
        return BiographyGenerationPolicy.production().route(for: capabilities).usesLocalModel
    }

    private func loadDownloadedModel(tier: LocalModelTier) async throws {
        status.state = .loading
        status.message = "Loading local model into memory."

        try await runtime.load(tier: tier)

        status.state = .loaded
        status.progress = 1.0
        status.message = runtime.isMLXBacked
            ? "Local generation is ready."
            : "Local generation fallback is ready."
    }

    private var isSelectedTierDownloaded: Bool {
        userDefaults.string(forKey: downloadedTierKey)
            .flatMap(LocalModelTier.init(rawValue:)) == status.tier
    }
}

struct UnavailableLocalModelRuntime: LocalModelRuntime {
    let displayName = "Unavailable local runtime"
    let isMLXBacked = false

    func download(tier: LocalModelTier) async throws {
        throw LocalModelRuntimeError.modelNotReady
    }

    func load(tier: LocalModelTier) async throws {
        throw LocalModelRuntimeError.modelNotReady
    }

    func generate(_ request: LocalGenerationRequest, tier: LocalModelTier) async throws -> String {
        throw LocalModelRuntimeError.modelNotReady
    }

    func unload() {}

    func delete(tier: LocalModelTier) throws {}
}
