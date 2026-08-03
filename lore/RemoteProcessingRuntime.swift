import Foundation
import Network

@MainActor
protocol SpeechNetworkConnectionProviding {
    var currentConnection: SpeechNetworkConnection { get }
    func observeChanges(_ handler: @escaping @MainActor (SpeechNetworkConnection) -> Void)
}

@MainActor
final class SystemSpeechNetworkMonitor: SpeechNetworkConnectionProviding {
    private(set) var currentConnection: SpeechNetworkConnection = .unknown
    private var changeHandler: (@MainActor (SpeechNetworkConnection) -> Void)?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "lore.network-path", qos: .utility)

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = Self.connection(for: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentConnection = connection
                self.changeHandler?(connection)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func observeChanges(_ handler: @escaping @MainActor (SpeechNetworkConnection) -> Void) {
        changeHandler = handler
        handler(currentConnection)
    }

    private nonisolated static func connection(for path: NWPath) -> SpeechNetworkConnection {
        guard path.status == .satisfied else {
            return .unavailable
        }
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return .wifi
        }
        return .unknown
    }
}

@MainActor
final class FixedSpeechNetworkConnectionProvider: SpeechNetworkConnectionProviding {
    var currentConnection: SpeechNetworkConnection

    init(_ currentConnection: SpeechNetworkConnection) {
        self.currentConnection = currentConnection
    }

    func observeChanges(_ handler: @escaping @MainActor (SpeechNetworkConnection) -> Void) {
        handler(currentConnection)
    }
}

struct LoreRemoteServices {
    let dailyEntryGenerator: any DailyEntryGenerationService
    let speechTranscriber: any RemoteSpeechTranscribing

    @MainActor
    static func configuredForCurrentBuild(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Self {
        guard let baseURL = configuredBaseURL(environment: environment, bundle: bundle) else {
            return unconfigured
        }

#if DEBUG
        let deployment: LoreBackendHTTPClientConfiguration.Deployment = .preview
        let previewToken = environment["LORE_PREVIEW_BEARER_TOKEN"]
#else
        let deployment: LoreBackendHTTPClientConfiguration.Deployment = .production
        let previewToken: String? = nil
#endif

        do {
            let configuration = try LoreBackendHTTPClientConfiguration(
                baseURL: baseURL,
                deployment: deployment,
                previewBearerToken: previewToken
            )
            let backend = LoreBackendHTTPClient(configuration: configuration)
            return Self(
                dailyEntryGenerator: RemoteDailyEntryGenerationService(backend: backend),
                speechTranscriber: LoreBackendRemoteSpeechTranscriber(backend: backend)
            )
        } catch {
            return unconfigured
        }
    }

    private static var unconfigured: Self {
        let backend = UnconfiguredLoreBackendProcessingClient()
        return Self(
            dailyEntryGenerator: RemoteDailyEntryGenerationService(backend: backend),
            speechTranscriber: UnavailableRemoteSpeechTranscriber()
        )
    }

    private static func configuredBaseURL(
        environment: [String: String],
        bundle: Bundle
    ) -> URL? {
#if DEBUG
        if let value = environment["LORE_BACKEND_BASE_URL"],
           let url = validHTTPSURL(value) {
            return url
        }
#endif
        guard let value = bundle.object(forInfoDictionaryKey: "LoreBackendBaseURL") as? String else {
            return nil
        }
        return validHTTPSURL(value)
    }

    private static func validHTTPSURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
