#if DEBUG
import AVFAudio
import CoreML
import FluidAudio
import Foundation
import Speech
import Voz

// MARK: - Shared types

/// One row in the results list: an engine run with or without vocabulary.
struct TranscriptionLabVariantDescriptor: Equatable {
    let id: String
    let displayName: String
    let engine: String
    let model: String
    let modelVersion: String
    let sdkVersion: String
    let usesVocabulary: Bool
    let vocabulary: [String]
}

struct TranscriptionLabTranscription {
    let text: String
    var notes: [String] = []
}

enum TranscriptionLabEngineError: LocalizedError {
    case notDownloaded(String)
    case unavailable(String)
    case notLoaded
    case emptyTranscript
    case download(String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let name): "\(name) is not downloaded. Download it in Models first."
        case .unavailable(let reason): reason
        case .notLoaded: "The model is not loaded."
        case .emptyTranscript: "The engine returned no text."
        case .download(let reason): reason
        }
    }
}

/// Versions recorded with every result.
enum TranscriptionLabVersions {
    static let fluidAudio = "0.18.0"
    static let desertAnt = VozModel.sdkVersion
    static let fluidSpeechMiniRevision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"
}

/// Where the lab keeps models it downloads itself. Application Support so the
/// OS does not purge them like Caches, excluded from iCloud backup.
enum TranscriptionLabModelDirectories {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionLab/Models", isDirectory: true)
    }

    static var fluidSpeechMini: URL { root.appendingPathComponent("fluid-speech-mini-coreml", isDirectory: true) }
    static var desertAnt: URL { root.appendingPathComponent("desert-ant", isDirectory: true) }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Model assets

/// Something the lab downloads before benchmarking, so download time never
/// lands in a load or inference measurement.
protocol TranscriptionLabModelAsset: AnyObject {
    var id: String { get }
    var title: String { get }
    var detail: String { get }
    /// Approximate download size, shown before the model is on disk.
    var expectedBytes: UInt64? { get }
    func isInstalled() async -> Bool
    func installedBytes() async -> UInt64?
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
}

final class FluidSpeechMiniAsset: TranscriptionLabModelAsset {
    let id = "fluid-speech-mini"
    let title = "Fluid Speech Mini"
    let detail = "FluidVoice-Labs/fluid-speech-mini-coreml · CC BY 4.0 · English"
    let expectedBytes: UInt64? = 253_000_000

    private static let repo = "FluidVoice-Labs/fluid-speech-mini-coreml"
    private static let completionMarker = ".lab-download-complete"

    func isInstalled() async -> Bool {
        FileManager.default.fileExists(
            atPath: TranscriptionLabModelDirectories.fluidSpeechMini.appendingPathComponent(Self.completionMarker).path
        )
    }

    func installedBytes() async -> UInt64? {
        await isInstalled() ? TranscriptionLabProbes.directorySize(TranscriptionLabModelDirectories.fluidSpeechMini) : nil
    }

    /// FluidAudio 0.18.0 has no downloader for this repo, so fetch the pinned
    /// revision's Core ML bundles and vocabulary straight from Hugging Face.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }
        let revision = TranscriptionLabVersions.fluidSpeechMiniRevision
        let treeURL = URL(string: "https://huggingface.co/api/models/\(Self.repo)/tree/\(revision)?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: treeURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscriptionLabEngineError.download("Hugging Face file list request failed.")
        }
        let files = try JSONDecoder().decode([TreeEntry].self, from: data).filter {
            $0.type == "file" && ($0.path.contains(".mlmodelc/") || $0.path.hasSuffix("vocab.json") || $0.path == "config.json")
        }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })

        let destination = TranscriptionLabModelDirectories.fluidSpeechMini
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("fluid-speech-mini-coreml.partial", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let remote = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(revision)/\(file.path)")!
            let local = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            try await TranscriptionLabDownloader.download(remote, to: local) { bytes in
                progress(Double(base + bytes) / Double(total))
            }
            completed += file.size ?? 0
            progress(Double(completed) / Double(total))
        }
        FileManager.default.createFile(atPath: staging.appendingPathComponent(Self.completionMarker).path, contents: Data(revision.utf8))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        TranscriptionLabModelDirectories.excludeFromBackup(TranscriptionLabModelDirectories.root)
    }
}

final class FluidAudioRepoAsset: TranscriptionLabModelAsset {
    let id: String
    let title: String
    let detail: String
    let expectedBytes: UInt64?
    let version: AsrModelVersion

    init(id: String, title: String, detail: String, expectedBytes: UInt64, version: AsrModelVersion) {
        self.id = id
        self.title = title
        self.detail = detail
        self.expectedBytes = expectedBytes
        self.version = version
    }

    func isInstalled() async -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    func installedBytes() async -> UInt64? {
        await isInstalled() ? TranscriptionLabProbes.directorySize(AsrModels.defaultCacheDirectory(for: version)) : nil
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        // FluidAudio compiles and loads each bundle while downloading, which
        // also pays the one-time Neural Engine specialization here.
        try await AsrModels.download(version: version) { progress($0.fractionCompleted) }
        TranscriptionLabModelDirectories.excludeFromBackup(MLModelConfigurationUtils.defaultModelsDirectory())
    }
}

final class FluidAudioCtcAsset: TranscriptionLabModelAsset {
    let id = "fluidaudio-ctc-110m"
    let title = "Parakeet CTC 110M (boosting)"
    let detail = "FluidInference/parakeet-ctc-110m-coreml · keyword spotter for FluidAudio vocabulary variants"
    let expectedBytes: UInt64? = 103_000_000

    private var directory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }
    private var tokenizerURL: URL { directory.appendingPathComponent("tokenizer.json") }

    func isInstalled() async -> Bool {
        CtcModels.modelsExist(at: directory) && FileManager.default.fileExists(atPath: tokenizerURL.path)
    }

    func installedBytes() async -> UInt64? {
        await isInstalled() ? TranscriptionLabProbes.directorySize(CtcModels.defaultCacheDirectory(for: .ctc110m)) : nil
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.05)
        try await CtcModels.download(variant: .ctc110m)
        // `VocabularyBoostingSession` tokenizes terms with the repo's
        // tokenizer.json, which the model download does not guarantee.
        if !FileManager.default.fileExists(atPath: tokenizerURL.path) {
            let remote = URL(string: "https://huggingface.co/\(Repo.parakeetCtc110m.rawValue)/resolve/main/tokenizer.json")!
            try await TranscriptionLabDownloader.download(remote, to: tokenizerURL) { _ in }
        }
        progress(1)
    }
}

final class VozModelAsset: TranscriptionLabModelAsset {
    let id = "desert-ant-voz"
    let title = "Desert Ant Voz"
    let detail = "desert-ant-labs/voz @ \(VozModel.revision) · 25 languages"
    let expectedBytes: UInt64? = 337_000_000

    private var cacheRoot: String { TranscriptionLabModelDirectories.desertAnt.path }

    func isInstalled() async -> Bool {
        Voz.isDownloaded(cacheRoot: cacheRoot)
    }

    func installedBytes() async -> UInt64? {
        await isInstalled() ? TranscriptionLabProbes.directorySize(TranscriptionLabModelDirectories.desertAnt) : nil
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: TranscriptionLabModelDirectories.desertAnt, withIntermediateDirectories: true)
        try await Voz.download(cacheRoot: cacheRoot) { progress($0.fraction) }
        TranscriptionLabModelDirectories.excludeFromBackup(TranscriptionLabModelDirectories.root)
    }
}

/// Apple's on-device speech assets are downloaded and stored by the system.
final class AppleSpeechAsset: TranscriptionLabModelAsset {
    let id = "apple-speech-transcriber"
    let title = "Apple SpeechTranscriber"
    let detail = "System-managed speech assets (iOS 26+)"
    let expectedBytes: UInt64? = nil

    func isInstalled() async -> Bool {
        guard #available(iOS 26, *) else { return false }
        guard let transcriber = await AppleSpeechLabEngine.makeTranscriber() else { return false }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    func installedBytes() async -> UInt64? { nil }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(iOS 26, *) else {
            throw TranscriptionLabEngineError.unavailable("SpeechTranscriber needs iOS 26 or later.")
        }
        guard let transcriber = await AppleSpeechLabEngine.makeTranscriber() else {
            throw TranscriptionLabEngineError.unavailable(AppleSpeechLabEngine.unavailableReason)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress(1)
            return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            progress(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }
}

/// URLSession download with byte progress, written to `destination`.
enum TranscriptionLabDownloader {
    private final class Box: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }

    static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let box = Box()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let temporaryURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.resume(throwing: TranscriptionLabEngineError.download("Download failed (HTTP \(status)) for \(url.lastPathComponent)."))
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

// MARK: - Engines

protocol TranscriptionLabEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var engineName: String { get }
    var modelName: String { get }
    var modelVersion: String { get }
    var sdkVersion: String { get }
    var supportsVocabulary: Bool { get }
    /// Whether a second load after release is meaningful to time.
    var measuresWarmLoad: Bool { get }
    /// Assets that must be on disk before the engine can run.
    var requiredAssetIDs: [String] { get }
    /// Nil when the engine can run on this device and build.
    func unavailableReason() async -> String?
    func load() async throws
    func transcribe(audioURL: URL, vocabulary: [String]) async throws -> TranscriptionLabTranscription
    /// Drops every model reference and cache the engine holds.
    func unload() async
}

extension TranscriptionLabEngine {
    func variants(names: [String]) -> [TranscriptionLabVariantDescriptor] {
        var variants = [
            TranscriptionLabVariantDescriptor(
                id: id, displayName: displayName, engine: engineName, model: modelName,
                modelVersion: modelVersion, sdkVersion: sdkVersion, usesVocabulary: false, vocabulary: []
            ),
        ]
        if supportsVocabulary, !names.isEmpty {
            variants.append(
                TranscriptionLabVariantDescriptor(
                    id: id + ".vocabulary", displayName: displayName + " + vocabulary", engine: engineName,
                    model: modelName, modelVersion: modelVersion, sdkVersion: sdkVersion,
                    usesVocabulary: true, vocabulary: names
                )
            )
        }
        return variants
    }
}

/// Parakeet-family TDT models through FluidAudio's `AsrManager`. The
/// vocabulary variant rescoring the same decode with FluidAudio's CTC
/// keyword spotter (`VocabularyBoostingSession`), the SDK's supported
/// boosting path for 0.6B TDT models.
final class FluidAudioLabEngine: TranscriptionLabEngine, @unchecked Sendable {
    enum Model {
        case fluidSpeechMini
        case parakeetUltra
        case parakeetV3
    }

    let model: Model
    let engineName = "FluidAudio"
    let sdkVersion = TranscriptionLabVersions.fluidAudio
    let supportsVocabulary = true
    let measuresWarmLoad = true

    private var manager: AsrManager?
    private var decoderLayers = 2
    private var boostingSession: VocabularyBoostingSession?
    private var boostingVocabulary: [String] = []

    init(model: Model) {
        self.model = model
    }

    var id: String {
        switch model {
        case .fluidSpeechMini: "fluidaudio.fluid-speech-mini"
        case .parakeetUltra: "fluidaudio.parakeet-ultra"
        case .parakeetV3: "fluidaudio.parakeet-tdt-v3"
        }
    }

    var displayName: String {
        switch model {
        case .fluidSpeechMini: "Fluid Speech Mini"
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetV3: "Parakeet TDT v3"
        }
    }

    var modelName: String {
        switch model {
        case .fluidSpeechMini: "FluidVoice-Labs/fluid-speech-mini-coreml"
        case .parakeetUltra: Repo.parakeetUltra.rawValue
        case .parakeetV3: Repo.parakeetV3.rawValue
        }
    }

    var modelVersion: String {
        switch model {
        case .fluidSpeechMini: TranscriptionLabVersions.fluidSpeechMiniRevision
        case .parakeetUltra, .parakeetV3: "main (FluidAudio \(TranscriptionLabVersions.fluidAudio) default)"
        }
    }

    var requiredAssetIDs: [String] {
        switch model {
        case .fluidSpeechMini: ["fluid-speech-mini"]
        case .parakeetUltra: ["fluidaudio-parakeet-ultra"]
        case .parakeetV3: ["fluidaudio-parakeet-v3"]
        }
    }

    func unavailableReason() async -> String? { nil }

    func load() async throws {
        let models: AsrModels
        switch model {
        case .fluidSpeechMini:
            models = try await Task.detached(priority: .userInitiated) {
                try Self.loadFluidSpeechMini(from: TranscriptionLabModelDirectories.fluidSpeechMini)
            }.value
        case .parakeetUltra:
            models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
        case .parakeetV3:
            models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        }
        let manager = AsrManager()
        try await manager.loadModels(models)
        decoderLayers = models.version.decoderLayers
        self.manager = manager
    }

    func transcribe(audioURL: URL, vocabulary: [String]) async throws -> TranscriptionLabTranscription {
        guard let manager else { throw TranscriptionLabEngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audioURL, decoderState: &state)
        var notes = [String(format: "sdkProcessingSeconds=%.3f", result.processingTime)]
        guard !vocabulary.isEmpty else {
            return TranscriptionLabTranscription(text: result.text, notes: notes)
        }

        if boostingSession == nil || boostingVocabulary != vocabulary {
            let started = Date()
            let ctcModels = try await CtcModels.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m), variant: .ctc110m
            )
            boostingSession = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) }),
                ctcModels: ctcModels
            )
            boostingVocabulary = vocabulary
            notes.append(String(format: "ctcSetupSeconds=%.3f (included in transcription time)", Date().timeIntervalSince(started)))
        }
        guard let boostingSession else { throw TranscriptionLabEngineError.notLoaded }
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let rescored = await boostingSession.rescore(
            text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples
        )
        if let rescored {
            let applied = rescored.replacements.filter(\.shouldReplace)
            notes.append("ctcReplacements=\(applied.count)")
            for replacement in applied {
                notes.append("replaced '\(replacement.originalWord)' -> '\(replacement.replacementWord ?? "")'")
            }
            if !rescored.detectedTerms.isEmpty {
                notes.append("ctcDetected=\(rescored.detectedTerms.joined(separator: ", "))")
            }
        } else {
            notes.append("ctcReplacements=0")
        }
        return TranscriptionLabTranscription(text: rescored?.text ?? result.text, notes: notes)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        boostingSession = nil
        boostingVocabulary = []
    }

    /// Fluid Speech Mini keeps Parakeet v3's input/output contract but ships
    /// its joint as `JointDecision.mlmodelc` (no top-K outputs), so the
    /// FluidAudio 0.18.0 `.ultra` loader's file names do not match. Build the
    /// same `AsrModels` from the repo's own files instead.
    private static func loadFluidSpeechMini(from directory: URL) throws -> AsrModels {
        let configuration = AsrModels.defaultConfiguration()
        func component(_ name: String, units: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AsrModelsError.modelNotFound(name, url)
            }
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = units
            return try MLModel(contentsOf: url, configuration: modelConfiguration)
        }

        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard let raw = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: String] else {
            throw AsrModelsError.loadingFailed("Fluid Speech Mini vocabulary is not a token dictionary")
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in raw {
            if let id = Int(key) { vocabulary[id] = value }
        }

        return AsrModels(
            encoder: try component("Encoder.mlmodelc", units: configuration.computeUnits),
            preprocessor: try component("Preprocessor.mlmodelc", units: .cpuOnly),
            decoder: try component("Decoder.mlmodelc", units: configuration.computeUnits),
            joint: try component("JointDecision.mlmodelc", units: configuration.computeUnits),
            configuration: configuration,
            vocabulary: vocabulary,
            version: .ultra
        )
    }
}

final class VozLabEngine: TranscriptionLabEngine, @unchecked Sendable {
    let id = "desertant.voz"
    let displayName = "Desert Ant Voz"
    let engineName = "Desert Ant Voz"
    let modelName = "desert-ant-labs/voz"
    let modelVersion = VozModel.revision
    let sdkVersion = TranscriptionLabVersions.desertAnt
    let supportsVocabulary = true
    let measuresWarmLoad = true
    let requiredAssetIDs = ["desert-ant-voz"]

    private var voz: Voz?

    func unavailableReason() async -> String? { nil }

    func load() async throws {
        voz = try await Voz(cacheRoot: TranscriptionLabModelDirectories.desertAnt.path)
    }

    func transcribe(audioURL: URL, vocabulary: [String]) async throws -> TranscriptionLabTranscription {
        guard let voz else { throw TranscriptionLabEngineError.notLoaded }
        let result = try await voz.transcribe(audioURL, vocabulary: vocabulary)
        return TranscriptionLabTranscription(
            text: result.text,
            notes: [String(format: "sdkProcessingSeconds=%.3f", result.processingTime)]
        )
    }

    func unload() async {
        voz = nil
    }
}

/// Apple's iOS 26 on-device transcriber. "Load" is creating the module and
/// preparing the analyzer; the model itself is owned by the system.
final class AppleSpeechLabEngine: TranscriptionLabEngine, @unchecked Sendable {
    let id = "apple.speech-transcriber"
    let displayName = "Apple SpeechTranscriber"
    let engineName = "Apple Speech"
    let modelName = "SpeechTranscriber (.transcription preset)"
    let sdkVersion: String = UIDeviceVersion.system
    let supportsVocabulary = true
    let measuresWarmLoad = false
    let requiredAssetIDs = ["apple-speech-transcriber"]

    static let unavailableReason = "SpeechTranscriber is unavailable on this device."

    var modelVersion: String { "system, \(UIDeviceVersion.system)" }

    private var prepared: AnyObject?

    static func locale() async -> Locale? {
        guard #available(iOS 26, *) else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    @available(iOS 26, *)
    static func makeTranscriber() async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable, let locale = await locale() else { return nil }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func unavailableReason() async -> String? {
        guard #available(iOS 26, *) else { return "SpeechTranscriber needs iOS 26 or later." }
        guard SpeechTranscriber.isAvailable else { return Self.unavailableReason }
        guard await Self.locale() != nil else { return "SpeechTranscriber has no English (US) locale here." }
        return nil
    }

    func load() async throws {
        guard #available(iOS 26, *) else { throw TranscriptionLabEngineError.unavailable("SpeechTranscriber needs iOS 26 or later.") }
        // Preparing one analyzer up front pays the system's model load, so the
        // per-variant analyzers below start warm.
        guard let transcriber = await Self.makeTranscriber() else {
            throw TranscriptionLabEngineError.unavailable(Self.unavailableReason)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        prepared = analyzer
    }

    func transcribe(audioURL: URL, vocabulary: [String]) async throws -> TranscriptionLabTranscription {
        guard #available(iOS 26, *) else { throw TranscriptionLabEngineError.unavailable("SpeechTranscriber needs iOS 26 or later.") }
        guard let transcriber = await Self.makeTranscriber() else {
            throw TranscriptionLabEngineError.unavailable(Self.unavailableReason)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        let collector = Task<String, Error> {
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                text += result.text
            }
            return String(text.characters)
        }

        do {
            let file = try AVAudioFile(forReading: audioURL)
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let text = try await collector.value
        return TranscriptionLabTranscription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: vocabulary.isEmpty ? [] : ["contextualStrings=\(vocabulary.count) (AnalysisContext .general)"]
        )
    }

    func unload() async {
        if #available(iOS 26, *), let analyzer = prepared as? SpeechAnalyzer {
            await analyzer.cancelAndFinishNow()
        }
        prepared = nil
    }
}

/// The production remote transcriber, used unchanged as a cloud baseline.
final class GroqRemoteLabEngine: TranscriptionLabEngine, @unchecked Sendable {
    let id = "remote.groq-whisper"
    let displayName = "Groq Whisper (remote)"
    let engineName = "Lore backend"
    let modelName = "whisper-large-v3-turbo via Groq"
    let modelVersion = "production backend"
    let sdkVersion = "LoreBackendRemoteSpeechTranscriber"
    let supportsVocabulary = false
    let measuresWarmLoad = false
    let requiredAssetIDs: [String] = []

    private var transcriber: (any RemoteSpeechTranscribing)?

    func unavailableReason() async -> String? {
        #if targetEnvironment(simulator)
        return "The Lore backend needs App Attest, which the Simulator lacks."
        #else
        return nil
        #endif
    }

    func load() async throws {
        transcriber = await MainActor.run { LoreRemoteServices.configuredForCurrentBuild().speechTranscriber }
    }

    func transcribe(audioURL: URL, vocabulary: [String]) async throws -> TranscriptionLabTranscription {
        guard let transcriber else { throw TranscriptionLabEngineError.notLoaded }
        let result = try await transcriber.transcribe(audioFileURL: audioURL, localeIdentifier: Locale.current.identifier)
        var notes = ["provider=\(result.provider)", "model=\(result.model)", "includesNetworkTime=true"]
        if let requestID = result.requestID { notes.append("requestID=\(requestID)") }
        return TranscriptionLabTranscription(text: result.transcript, notes: notes)
    }

    func unload() async {
        transcriber = nil
    }
}

enum UIDeviceVersion {
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
#endif
