import Combine
import CryptoKit
import Foundation
import Network

/// One file of the pinned model revision, with the integrity data Hugging
/// Face's tree API reports for it: the LFS sha256 for large files, the git
/// blob SHA-1 for small ones.
struct OnDeviceSpeechModelFile: Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String?
    let gitBlobSHA1: String?

    init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.gitBlobSHA1 = nil
    }

    init(path: String, size: Int64, gitBlobSHA1: String) {
        self.path = path
        self.size = size
        self.sha256 = nil
        self.gitBlobSHA1 = gitBlobSHA1
    }
}

/// Fluid Speech Mini at one pinned revision. The file list is the Hugging
/// Face tree listing for that revision, embedded so a tampered listing or
/// mirror cannot change what Lore accepts. Moving to a new revision means
/// regenerating this list; the old install is then removed.
enum OnDeviceSpeechModelManifest {
    static let repository = "FluidVoice-Labs/fluid-speech-mini-coreml"
    static let revision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"
    static let providerId = "fluidaudio"
    static let languageCode = "en"

    static var providerModelId: String { "\(repository)@\(revision)" }

    static let files: [OnDeviceSpeechModelFile] = [
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d"),
        .init(path: "Decoder.mlmodelc/coremldata.bin", size: 491, sha256: "6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468"),
        .init(path: "Decoder.mlmodelc/metadata.json", size: 3373, gitBlobSHA1: "a79debb5125b7c1a6a81e6a4445912c96474c0ee"),
        .init(path: "Decoder.mlmodelc/model.mil", size: 13411, gitBlobSHA1: "428742162c9e8b2b1a020e4a47da87adb87e7af0"),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 11845120, sha256: "d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a"),
        .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9"),
        .init(path: "Encoder.mlmodelc/coremldata.bin", size: 427, sha256: "494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d"),
        .init(path: "Encoder.mlmodelc/metadata.json", size: 2906, gitBlobSHA1: "49b43277d5d42ac49af5a9e6bcec63195acbb76c"),
        .init(path: "Encoder.mlmodelc/model.mil", size: 712643, gitBlobSHA1: "69c0308b882eae9413bd787f757c80ee46a7f2bb"),
        .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 233096704, sha256: "cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131"),
        .init(path: "JointDecision.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69"),
        .init(path: "JointDecision.mlmodelc/coremldata.bin", size: 462, sha256: "284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d"),
        .init(path: "JointDecision.mlmodelc/metadata.json", size: 2790, gitBlobSHA1: "f838342b52059cd8b06bf6bedd185bb0c7ed1cac"),
        .init(path: "JointDecision.mlmodelc/model.mil", size: 7547, gitBlobSHA1: "18e706e2e2d4a78ad825a1a0542af639f52b3c62"),
        .init(path: "JointDecision.mlmodelc/weights/weight.bin", size: 6350284, sha256: "f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc"),
        .init(path: "LICENSE", size: 18657, gitBlobSHA1: "da6ab6cc8f333d7e89a99812866df8f24374d47c"),
        .init(path: "NOTICE", size: 690, gitBlobSHA1: "ab1383ddb9427e377b5752cea97d2a0a3411dbc9"),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, gitBlobSHA1: "06162c58cf2f5343a0e60f36f843bcdf3cc58527"),
        .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, gitBlobSHA1: "f987e2479228436c49189aa47edb376db74dcff5"),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        .init(path: "config.json", size: 314, gitBlobSHA1: "88cccfe091f2335ba8f3af8d91bf378a35314b93"),
        .init(path: "parakeet_vocab.json", size: 151122, gitBlobSHA1: "c684822ec3b671ebc449c433a7012398d39b8bb0"),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static func remoteURL(for file: OnDeviceSpeechModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }
}

enum OnDeviceSpeechModelStoreError: Error, LocalizedError, Equatable {
    case insufficientStorage
    case httpStatus(Int)
    case integrityMismatch(path: String)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            return "There isn't enough free space on this iPhone for the speech model."
        case .httpStatus:
            return "The speech model couldn't be downloaded. Lore will try again on Wi-Fi."
        case .integrityMismatch:
            return "The downloaded speech model didn't verify, so Lore discarded it."
        }
    }
}

/// Owns the on-device speech model files: download (Wi-Fi only by default),
/// verification, and readiness. UI observes `state`; the transcription
/// pipeline checks `state.isReady` before routing on device.
///
/// Files are staged in a `.partial` directory, verified one by one against
/// the pinned manifest, then the directory is renamed into place with a
/// completion marker already inside it, so an installed directory is always
/// complete. Verified staged files survive an app kill and are not
/// downloaded again.
@MainActor
final class OnDeviceSpeechModelStore: ObservableObject {
    static let shared = OnDeviceSpeechModelStore()

    @Published private(set) var state: OnDeviceSpeechModelState = .notDownloaded

    /// Approximate download size, for display before the model is on disk.
    let approximateDownloadBytes: Int64 = 253_000_000

    /// Human-readable model credit for About / third-party notices.
    let modelDisplayName = "Fluid Speech Mini"

    /// The installed model, valid only while `state` is `.ready`.
    nonisolated let installedModelDirectory: URL

    nonisolated private let rootDirectory: URL
    nonisolated private let stagingDirectory: URL
    nonisolated private static let completionMarkerName = ".lore-model-complete"

    private enum DownloadPath: Equatable {
        case unknown
        case unavailable
        /// Cellular, personal hotspot, or Low Data Mode.
        case expensive
        case wifi
    }

    private var wantsDownload = false
    private var allowsCellular = false
    private var downloadPath: DownloadPath = .unknown
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = 0
    private let pathMonitor: NWPathMonitor?

    init(rootDirectory: URL? = nil, monitorsNetwork: Bool = true) {
        let root = rootDirectory ?? Self.defaultRootDirectory
        self.rootDirectory = root
        installedModelDirectory = Self.installedModelDirectory(in: root)
        stagingDirectory = root.appendingPathComponent(
            installedModelDirectory.lastPathComponent + ".partial",
            isDirectory: true
        )
        pathMonitor = monitorsNetwork ? NWPathMonitor() : nil

        if Self.isInstalled(at: installedModelDirectory) {
            state = .ready
        } else {
            // A directory without a matching marker is never trusted.
            try? FileManager.default.removeItem(at: installedModelDirectory)
        }

        pathMonitor?.pathUpdateHandler = { [weak self] path in
            let downloadPath = Self.downloadPath(for: path)
            Task { @MainActor [weak self] in
                self?.updateDownloadPath(downloadPath)
            }
        }
        pathMonitor?.start(queue: DispatchQueue(label: "lore.speech-model-path", qos: .utility))
    }

    deinit {
        pathMonitor?.cancel()
    }

    nonisolated static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    nonisolated static func installedModelDirectory(in root: URL) -> URL {
        root.appendingPathComponent(
            "fluid-speech-mini-coreml-\(OnDeviceSpeechModelManifest.revision)",
            isDirectory: true
        )
    }

    /// True only when the directory carries a marker for the pinned revision.
    nonisolated static func isInstalled(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(completionMarkerName)
        guard let data = try? Data(contentsOf: marker) else { return false }
        return String(decoding: data, as: UTF8.self) == OnDeviceSpeechModelManifest.revision
    }

    /// Starts or resumes the download if the model isn't ready. Waits for
    /// Wi-Fi unless `allowsCellular` is true.
    func startDownloadIfNeeded(allowsCellular: Bool = false) {
        guard state != .ready else { return }
        wantsDownload = true
        self.allowsCellular = allowsCellular
        if case .failed = state { return }
        evaluate()
    }

    /// Retries after `.failed`.
    func retryDownload(allowsCellular: Bool = false) {
        guard state != .ready else { return }
        wantsDownload = true
        self.allowsCellular = allowsCellular
        if case .failed = state {
            state = .notDownloaded
        }
        evaluate()
    }

    /// Removes the model files; transcription falls back to remote.
    func deleteModel() {
        wantsDownload = false
        cancelDownload()
        try? FileManager.default.removeItem(at: installedModelDirectory)
        try? FileManager.default.removeItem(at: stagingDirectory)
        state = .notDownloaded
    }

    // MARK: - Download orchestration

    private var networkAllowsDownload: Bool {
        switch downloadPath {
        case .wifi:
            return true
        case .expensive:
            return allowsCellular
        case .unknown, .unavailable:
            return false
        }
    }

    private func updateDownloadPath(_ path: DownloadPath) {
        let previous = downloadPath
        downloadPath = path
        // A failure is retried once the network comes back, never in a loop
        // on the same connection.
        if case .failed = state, previous != path, networkAllowsDownload, wantsDownload {
            state = .notDownloaded
        }
        evaluate()
    }

    private func evaluate() {
        guard wantsDownload, state != .ready else { return }
        if case .failed = state { return }

        guard networkAllowsDownload else {
            cancelDownload()
            state = .waitingForWiFi
            return
        }
        guard downloadTask == nil else { return }

        downloadGeneration += 1
        let generation = downloadGeneration
        let staging = stagingDirectory
        let destination = installedModelDirectory
        let root = rootDirectory
        let allowsExpensiveNetwork = allowsCellular
        state = .downloading(progress: 0)

        downloadTask = Task { [weak self] in
            do {
                try await Self.download(
                    root: root,
                    staging: staging,
                    destination: destination,
                    allowsExpensiveNetwork: allowsExpensiveNetwork,
                    onVerifying: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadGeneration == generation else { return }
                            self.state = .verifying
                        }
                    },
                    progress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            self?.reportProgress(fraction, generation: generation)
                        }
                    }
                )
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                self.state = .ready
            } catch {
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                print("On-device speech model download failed: \(error)")
                if !self.networkAllowsDownload {
                    self.state = .waitingForWiFi
                } else {
                    self.state = .failed(
                        message: (error as? LocalizedError)?.errorDescription
                            ?? "The speech model couldn't be downloaded. Lore will try again on Wi-Fi."
                    )
                }
            }
        }
    }

    private func cancelDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func reportProgress(_ fraction: Double, generation: Int) {
        guard downloadGeneration == generation, case let .downloading(current) = state else { return }
        // Publishing every URLSession callback would redraw Settings constantly.
        if fraction >= 1 || fraction - current >= 0.005 {
            state = .downloading(progress: min(1, fraction))
        }
    }

    private nonisolated static func downloadPath(for path: NWPath) -> DownloadPath {
        guard path.status == .satisfied else { return .unavailable }
        if path.isExpensive || path.isConstrained { return .expensive }
        return .wifi
    }

    // MARK: - File work (off the main actor)

    private nonisolated static func download(
        root: URL,
        staging: URL,
        destination: URL,
        allowsExpensiveNetwork: Bool,
        onVerifying: @escaping @Sendable () -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        excludeFromBackup(root)
        removeOtherInstalls(in: root, keeping: [staging, destination])

        let total = OnDeviceSpeechModelManifest.totalBytes
        var pending: [OnDeviceSpeechModelFile] = []
        var completed: Int64 = 0
        // Files verified before an earlier interruption are kept.
        for file in OnDeviceSpeechModelManifest.files {
            try Task.checkCancellation()
            let local = staging.appendingPathComponent(file.path)
            if (try? verify(local, against: file)) == true {
                completed += file.size
            } else {
                try? fileManager.removeItem(at: local)
                pending.append(file)
            }
        }
        progress(Double(completed) / Double(total))

        let remaining = pending.reduce(Int64(0)) { $0 + $1.size }
        if remaining > 0, let available = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage, available < remaining + 100_000_000 {
            throw OnDeviceSpeechModelStoreError.insufficientStorage
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        configuration.allowsCellularAccess = allowsExpensiveNetwork
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for file in pending {
            try Task.checkCancellation()
            let local = staging.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            try await downloadFile(
                OnDeviceSpeechModelManifest.remoteURL(for: file),
                to: local,
                session: session
            ) { bytes in
                progress(Double(base + min(bytes, file.size)) / Double(total))
            }
            guard try verify(local, against: file) else {
                try? fileManager.removeItem(at: local)
                throw OnDeviceSpeechModelStoreError.integrityMismatch(path: file.path)
            }
            completed += file.size
            progress(Double(completed) / Double(total))
        }

        onVerifying()
        // Recheck the whole set before installing; a staged file could have
        // been altered between sessions.
        for file in OnDeviceSpeechModelManifest.files {
            try Task.checkCancellation()
            guard try verify(staging.appendingPathComponent(file.path), against: file) else {
                try? fileManager.removeItem(at: staging.appendingPathComponent(file.path))
                throw OnDeviceSpeechModelStoreError.integrityMismatch(path: file.path)
            }
        }

        try Data(OnDeviceSpeechModelManifest.revision.utf8)
            .write(to: staging.appendingPathComponent(completionMarkerName), options: .atomic)
        try? fileManager.removeItem(at: destination)
        // Same-volume directory rename: the install appears all at once.
        try fileManager.moveItem(at: staging, to: destination)
        excludeFromBackup(root)
    }

    nonisolated static func verify(_ url: URL, against file: OnDeviceSpeechModelFile) throws -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value == file.size else {
            return false
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = 4 * 1024 * 1024

        if let expected = file.sha256 {
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize()) == expected.lowercased()
        }
        if let expected = file.gitBlobSHA1 {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\u{0}".utf8))
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize()) == expected.lowercased()
        }
        return false
    }

    private nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Removes installs of other revisions so an update never keeps two
    /// copies of a 253 MB model.
    private nonisolated static func removeOtherInstalls(in root: URL, keeping: [URL]) {
        let keep = Set(keeping.map(\.standardizedFileURL.lastPathComponent))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("fluid-speech-mini-coreml")
            && !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private final class DownloadBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }

    private nonisolated static func downloadFile(
        _ url: URL,
        to destination: URL,
        session: URLSession,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url) { temporaryURL, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard let temporaryURL, status == 200 else {
                        continuation.resume(throwing: OnDeviceSpeechModelStoreError.httpStatus(status))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                box.observation = task.progress.observe(\.completedUnitCount) { value, _ in
                    progress(value.completedUnitCount)
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}
