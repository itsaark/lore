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
    private static let productionOrigin = "https://lore-tan.vercel.app"

    let dailyEntryGenerator: any DailyEntryGenerationService
    let speechTranscriber: any RemoteSpeechTranscribing

    @MainActor
    static func configuredForCurrentBuild(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        bundle _: Bundle = .main
    ) -> Self {
#if targetEnvironment(simulator)
        // App Attest is unavailable in Simulator. Keep simulator runs local so
        // a simulated client can never consume production inference credits.
        return unconfigured
#else
        guard let baseURL = URL(string: productionOrigin) else {
            return unconfigured
        }

        do {
            let configuration = try LoreBackendHTTPClientConfiguration(
                baseURL: baseURL
            )
            let transport = LoreBackendHTTPTransport.ephemeral()
            let authAPI = try LoreAppAttestHTTPAPIClient(
                baseURL: configuration.baseURL,
                transport: transport
            )
            let authorizer = LoreAppAttestSessionAuthorizer(api: authAPI)
            let backend = LoreBackendHTTPClient(
                configuration: configuration,
                transport: transport,
                productionAuthorizer: authorizer
            )
            return Self(
                dailyEntryGenerator: RemoteDailyEntryGenerationService(backend: backend),
                speechTranscriber: LoreBackendRemoteSpeechTranscriber(backend: backend)
            )
        } catch {
            return unconfigured
        }
#endif
    }

    private static var unconfigured: Self {
        let backend = UnconfiguredLoreBackendProcessingClient()
        return Self(
            dailyEntryGenerator: RemoteDailyEntryGenerationService(backend: backend),
            speechTranscriber: UnavailableRemoteSpeechTranscriber()
        )
    }

}
