import CoreML
import FluidAudio
import Foundation
import UIKit

struct LocalSpeechTranscription: Equatable, Sendable {
    let transcript: String
    let providerId: String
    let modelId: String
    let languageCode: String
    let segments: [TranscriptSourceSegment]
    let audioDurationSeconds: TimeInterval

    init(
        transcript: String,
        providerId: String = OnDeviceSpeechModelManifest.providerId,
        modelId: String = OnDeviceSpeechModelManifest.providerModelId,
        languageCode: String = OnDeviceSpeechModelManifest.languageCode,
        segments: [TranscriptSourceSegment] = [],
        audioDurationSeconds: TimeInterval
    ) {
        self.transcript = transcript
        self.providerId = providerId
        self.modelId = modelId
        self.languageCode = languageCode
        self.segments = segments
        self.audioDurationSeconds = audioDurationSeconds
    }
}

/// Transcription that runs entirely on this iPhone.
protocol LocalSpeechTranscribing: Sendable {
    /// Starts loading the model without waiting for it. Call when recording
    /// starts so the cold load overlaps the recording.
    func prepare() async
    func transcribe(audioFileURL: URL) async throws -> LocalSpeechTranscription
    /// Releases the loaded model, e.g. after the model files are deleted.
    func unload() async
}

enum LocalSpeechTranscriptionError: Error, LocalizedError, Equatable {
    case modelNotInstalled
    case unusableTranscript

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "The on-device speech model isn't installed."
        case .unusableTranscript:
            return "On-device transcription returned no usable text."
        }
    }
}

/// Decides whether local output is good enough to commit, or should fall
/// back to the remote transcriber.
enum LocalTranscriptQuality {
    static func isUsable(_ transcript: String) -> Bool {
        let words = transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !words.isEmpty else { return false }

        // A decoder stuck in a loop repeats one token for the whole clip.
        if words.count >= 20 {
            let counts = Dictionary(grouping: words.map { $0.lowercased() }, by: { $0 }).mapValues(\.count)
            if let top = counts.values.max(), Double(top) / Double(words.count) > 0.8 {
                return false
            }
        }
        return true
    }
}

/// Fluid Speech Mini through FluidAudio's TDT `AsrManager`. The model is
/// loaded once and kept warm, then released after ten idle minutes or on a
/// memory warning.
///
/// FluidAudio's CTC vocabulary boosting is deliberately not used: in the
/// founder's benchmark it replaced common words with names ("like" → "Mike").
actor FluidAudioLocalSpeechTranscriber: LocalSpeechTranscribing {
    private let modelDirectory: URL
    private let idleUnloadInterval: Duration
    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var activeTranscriptions = 0
    private var unloadWhenIdle = false
    private var idleTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    init(modelDirectory: URL, idleUnloadInterval: Duration = .seconds(600)) {
        self.modelDirectory = modelDirectory
        self.idleUnloadInterval = idleUnloadInterval
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func prepare() async {
        observeMemoryWarningsIfNeeded()
        unloadWhenIdle = false
        guard manager == nil else {
            scheduleIdleUnload()
            return
        }
        startLoadIfNeeded()
        scheduleIdleUnload()
    }

    func transcribe(audioFileURL: URL) async throws -> LocalSpeechTranscription {
        observeMemoryWarningsIfNeeded()
        activeTranscriptions += 1
        idleTask?.cancel()
        do {
            let manager = try await loadedManager()
            var decoderState = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
            let result = try await manager.transcribe(audioFileURL, decoderState: &decoderState)
            finishTranscription()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalSpeechTranscription(
                transcript: text,
                segments: Self.segments(from: result.tokenTimings ?? []),
                audioDurationSeconds: result.duration
            )
        } catch {
            finishTranscription()
            throw error
        }
    }

    func unload() async {
        idleTask?.cancel()
        idleTask = nil
        loadTask?.cancel()
        loadTask = nil
        let manager = self.manager
        self.manager = nil
        await manager?.cleanup()
    }

    // MARK: - Lifecycle

    private func startLoadIfNeeded() {
        guard manager == nil, loadTask == nil else { return }
        let directory = modelDirectory
        // MLModel compilation and Neural Engine specialization are
        // synchronous and take ~13 s cold, so keep them off this actor.
        loadTask = Task.detached(priority: .userInitiated) {
            guard OnDeviceSpeechModelStore.isInstalled(at: directory) else {
                throw LocalSpeechTranscriptionError.modelNotInstalled
            }
            let started = Date()
            let models = try Self.loadFluidSpeechMini(from: directory)
            let manager = AsrManager()
            try await manager.loadModels(models)
            print(String(format: "On-device speech model loaded in %.2f s", Date().timeIntervalSince(started)))
            return manager
        }
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        startLoadIfNeeded()
        guard let loadTask else { throw LocalSpeechTranscriptionError.modelNotInstalled }
        do {
            let loaded = try await loadTask.value
            if self.loadTask == loadTask {
                self.loadTask = nil
            }
            manager = loaded
            return loaded
        } catch {
            if self.loadTask == loadTask {
                self.loadTask = nil
            }
            throw error
        }
    }

    private func finishTranscription() {
        activeTranscriptions -= 1
        guard activeTranscriptions == 0 else { return }
        if unloadWhenIdle {
            unloadWhenIdle = false
            Task { await self.unload() }
        } else {
            scheduleIdleUnload()
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let interval = idleUnloadInterval
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard activeTranscriptions == 0 else { return }
        await unload()
    }

    private func handleMemoryWarning() async {
        if activeTranscriptions == 0 {
            await unload()
        } else {
            unloadWhenIdle = true
        }
    }

    private func observeMemoryWarningsIfNeeded() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleMemoryWarning() }
        }
    }

    // MARK: - Model files

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

    /// Groups word timings into sentence-sized segments for the artifact's
    /// audit trail.
    static func segments(from tokenTimings: [TokenTiming]) -> [TranscriptSourceSegment] {
        let words = buildWordTimings(from: tokenTimings)
        var segments: [TranscriptSourceSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSourceSegment(
                    id: "local-\(segments.count)",
                    startMilliseconds: Int((first.startTime * 1_000).rounded()),
                    endMilliseconds: Int((last.endTime * 1_000).rounded()),
                    text: text,
                    confidence: nil,
                    speakerLabel: nil
                ))
            }
            current.removeAll()
        }

        for word in words {
            current.append(word)
            let trimmed = word.word.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, ".?!".contains(last) || current.count >= 40 {
                flush()
            }
        }
        flush()
        return segments
    }
}
