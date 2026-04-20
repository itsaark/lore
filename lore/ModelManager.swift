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
    private let selectedTierKey = "LoreSelectedLocalModelTier"
    private let downloadedTierKey = "LoreDownloadedLocalModelTier"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

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
        try? await Task.sleep(for: .milliseconds(120))
        status.state = .loaded
        status.progress = 1.0
        status.message = "Local generation is ready."
    }

    func forgetDownloadedModel() {
        userDefaults.removeObject(forKey: downloadedTierKey)
        status.state = .notDownloaded
        status.progress = 0.0
        status.message = nil
    }
}
