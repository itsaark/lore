#if DEBUG
import AVFAudio
import FluidAudio
import Foundation
import UIKit

@MainActor
final class TranscriptionLabModel: ObservableObject {
    struct AssetState: Equatable {
        var isInstalled = false
        var installedBytes: UInt64?
        var downloadProgress: Double?
        var error: String?
    }

    @Published private(set) var clips: [TranscriptionLabClipRecord] = []
    @Published private(set) var assetStates: [String: AssetState] = [:]
    @Published private(set) var unavailableReasons: [String: String] = [:]
    @Published var enabledEngineIDs: Set<String>
    @Published private(set) var runningClipID: String?
    @Published private(set) var runStatus: String?
    @Published var errorMessage: String?

    @Published var draftLabel = ""
    @Published var draftNames = ""
    @Published private(set) var recordingClipID: String?

    let recorder = TranscriptionLabRecorder()
    let store = TranscriptionLabClipStore()
    let assets: [any TranscriptionLabModelAsset]
    let engines: [any TranscriptionLabEngine]

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var runTask: Task<Void, Never>?

    init() {
        assets = [
            FluidSpeechMiniAsset(),
            FluidAudioRepoAsset(
                id: "fluidaudio-parakeet-ultra", title: "Parakeet Ultra",
                detail: "\(Repo.parakeetUltra.rawValue) · 25 European languages",
                expectedBytes: 632_000_000, version: .ultra
            ),
            FluidAudioRepoAsset(
                id: "fluidaudio-parakeet-v3", title: "Parakeet TDT v3 (baseline)",
                detail: "\(Repo.parakeetV3.rawValue) · int8 encoder",
                expectedBytes: 483_000_000, version: .v3
            ),
            FluidAudioCtcAsset(),
            VozModelAsset(),
            AppleSpeechAsset(),
        ]
        engines = [
            FluidAudioLabEngine(model: .fluidSpeechMini),
            FluidAudioLabEngine(model: .parakeetUltra),
            FluidAudioLabEngine(model: .parakeetV3),
            VozLabEngine(),
            AppleSpeechLabEngine(),
            GroqRemoteLabEngine(),
        ]
        // On-device engines start on. An engine that uploads the clip starts
        // off in every Lab session (this model lives only as long as the Lab
        // screen) and is never persisted as on, so benchmark audio leaves the
        // phone only when the founder deliberately switches it on.
        enabledEngineIDs = Set(engines.filter { !$0.uploadsAudio }.map(\.id))
    }

    // MARK: - App Attest

    @Published private(set) var appAttestResetStatus: String?

    /// Clears the persisted 24 h server-refusal backoff and this launch's
    /// rotation allowance, so the next remote request may enroll again after a
    /// backend fix. It does not delete the App Attest key or any clip.
    func resetAppAttestBackoff() async {
        do {
            try await LoreKeychainAppAttestKeyStore().clearLastServerRejectionRotation()
            LoreAppAttestRotationBudget.currentLaunch.reset()
            appAttestResetStatus = "App Attest backoff cleared."
        } catch {
            appAttestResetStatus = "Could not clear the backoff: \(error.localizedDescription)"
        }
    }

    // MARK: - Lifecycle

    func onAppear() async {
        try? store.ensureRoot()
        clips = store.loadAll()
        await refreshAssets()
        for engine in engines {
            unavailableReasons[engine.id] = await engine.unavailableReason()
        }
    }

    func onDisappear() {
        if recorder.isRecording { stopRecording() }
        recorder.restoreSession()
    }

    func refreshAssets() async {
        for asset in assets {
            var state = assetStates[asset.id] ?? AssetState()
            state.isInstalled = await asset.isInstalled()
            state.installedBytes = await asset.installedBytes()
            assetStates[asset.id] = state
        }
    }

    // MARK: - Downloads

    func download(_ asset: any TranscriptionLabModelAsset) {
        guard downloadTasks[asset.id] == nil else { return }
        assetStates[asset.id, default: AssetState()].downloadProgress = 0
        assetStates[asset.id, default: AssetState()].error = nil
        let id = asset.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard self?.assetStates[id]?.downloadProgress != nil else { return }
                self?.assetStates[id]?.downloadProgress = min(1, max(0, fraction))
            }
        }
        downloadTasks[id] = Task { [weak self] in
            let started = Date()
            do {
                try await asset.download(progress: report)
                print("Transcription Lab: downloaded \(id) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            } catch {
                self?.assetStates[id]?.error = error.localizedDescription
            }
            self?.assetStates[id]?.downloadProgress = nil
            self?.downloadTasks[id] = nil
            await self?.refreshAssets()
        }
    }

    func cancelDownload(_ asset: any TranscriptionLabModelAsset) {
        downloadTasks[asset.id]?.cancel()
    }

    // MARK: - Recording

    var isRecording: Bool { recorder.isRecording }

    func toggleRecording() async {
        if recorder.isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard runningClipID == nil else { return }
        guard await recorder.requestPermission() else {
            errorMessage = "Microphone access is off. Allow it in iPhone Settings."
            return
        }
        let clipID = TranscriptionLabClipStore.makeClipID(label: draftLabel)
        do {
            try store.createClipFolder(clipID)
            try recorder.start(writingTo: store.audioURL(for: clipID))
            recordingClipID = clipID
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            try? FileManager.default.removeItem(at: store.folderURL(for: clipID))
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        let duration = recorder.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        guard let clipID = recordingClipID else { return }
        recordingClipID = nil
        guard duration > 0.3 else {
            try? store.delete(clipID)
            errorMessage = "That clip was too short to keep."
            return
        }
        let record = TranscriptionLabClipRecord(
            id: clipID,
            label: draftLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            names: TranscriptionLabMetrics.parseNames(draftNames),
            createdAt: Date(),
            audioFileName: TranscriptionLabClipStore.audioFileName,
            audioDurationSeconds: duration,
            audioSampleRate: TranscriptionLabRecorder.sampleRate,
            audioChannelCount: 1,
            device: .current()
        )
        persist(record)
    }

    // MARK: - Clips

    func clip(_ id: String) -> TranscriptionLabClipRecord? {
        clips.first { $0.id == id }
    }

    func updateNames(_ field: String, for clipID: String) {
        guard var record = clip(clipID) else { return }
        record.names = TranscriptionLabMetrics.parseNames(field)
        record.rescore()
        persist(record)
    }

    func updateLabel(_ label: String, for clipID: String) {
        guard var record = clip(clipID) else { return }
        record.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist(record)
    }

    func saveReference(_ text: String, derivedFrom engineID: String?, for clipID: String) {
        guard var record = clip(clipID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.reference = trimmed.isEmpty
            ? nil
            : TranscriptionLabReference(text: trimmed, derivedFromEngineID: engineID, updatedAt: Date())
        record.rescore()
        persist(record)
    }

    func delete(_ clipID: String) {
        try? store.delete(clipID)
        clips.removeAll { $0.id == clipID }
    }

    func exportArchive() -> URL? {
        do {
            return try store.exportArchive()
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func persist(_ record: TranscriptionLabClipRecord) {
        do {
            try store.save(record)
        } catch {
            errorMessage = "Couldn't save results.json: \(error.localizedDescription)"
        }
        if let index = clips.firstIndex(where: { $0.id == record.id }) {
            clips[index] = record
        } else {
            clips.insert(record, at: 0)
        }
    }

    // MARK: - Benchmark

    var isBusy: Bool { runningClipID != nil || recorder.isRecording }

    func runAll(_ clipID: String) {
        guard runTask == nil, let record = clip(clipID) else { return }
        runningClipID = clipID
        UIApplication.shared.isIdleTimerDisabled = true
        runTask = Task { [weak self] in
            await self?.performRun(record)
            self?.runTask = nil
            self?.runningClipID = nil
            self?.runStatus = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    private func performRun(_ initial: TranscriptionLabClipRecord) async {
        var record = initial
        let audioURL = store.audioURL(for: record.id)
        var run = TranscriptionLabRun(id: UUID(), startedAt: Date(), device: .current(), results: [])
        record.runs.append(run)
        let runIndex = record.runs.count - 1

        func publish(_ run: TranscriptionLabRun) {
            record.runs[runIndex] = run
            persist(record)
        }

        for engine in engines where enabledEngineIDs.contains(engine.id) {
            if Task.isCancelled { break }
            runStatus = "Running \(engine.displayName)…"
            let results = await benchmark(engine, audioURL: audioURL, record: record)
            run.results.append(contentsOf: results)
            publish(run)
        }
        run.finishedAt = Date()
        publish(run)
        print("Transcription Lab: run finished for \(record.id), footprint \(TranscriptionLabProbes.formatBytes(TranscriptionLabProbes.physFootprint()))")
    }

    /// Loads one engine, runs each variant, releases it, then times a second
    /// load. One model is resident at a time.
    private func benchmark(
        _ engine: any TranscriptionLabEngine,
        audioURL: URL,
        record: TranscriptionLabClipRecord
    ) async -> [TranscriptionLabEngineResult] {
        let thermalBefore = TranscriptionLabProbes.thermalStateName()
        var results = engine.variants(names: record.names).map {
            TranscriptionLabEngineResult(
                variant: $0, audioDurationSeconds: record.audioDurationSeconds, thermalStateBefore: thermalBefore
            )
        }
        func finish(_ status: TranscriptionLabEngineResult.Status, error: String) -> [TranscriptionLabEngineResult] {
            results.map {
                var result = $0
                result.status = status
                result.error = error
                result.thermalStateAfter = TranscriptionLabProbes.thermalStateName()
                return result
            }
        }

        if let reason = await engine.unavailableReason() {
            return finish(.skipped, error: reason)
        }
        for assetID in engine.requiredAssetIDs {
            if let asset = assets.first(where: { $0.id == assetID }), await !asset.isInstalled() {
                return finish(.skipped, error: TranscriptionLabEngineError.notDownloaded(asset.title).localizedDescription)
            }
        }
        if results.contains(where: \.usesVocabulary), engine is FluidAudioLabEngine,
           assetStates["fluidaudio-ctc-110m"]?.isInstalled != true {
            if let index = results.firstIndex(where: \.usesVocabulary) {
                results[index].status = .skipped
                results[index].error = "Parakeet CTC 110M (boosting) is not downloaded."
            }
        }

        let footprintBefore = TranscriptionLabProbes.physFootprint()
        let sampler = TranscriptionLabMemorySampler()
        sampler.start()

        var coldLoad: Double?
        var loadError: String?
        let loadStarted = Date()
        do {
            try await engine.load()
            coldLoad = Date().timeIntervalSince(loadStarted)
        } catch {
            loadError = "Load failed: \(error.localizedDescription)"
        }

        for index in results.indices where loadError == nil && results[index].error == nil {
            if Task.isCancelled {
                results[index].error = "Cancelled."
                continue
            }
            runStatus = "Running \(results[index].displayName)…"
            let started = Date()
            do {
                let output = try await engine.transcribe(audioURL: audioURL, vocabulary: results[index].vocabulary)
                results[index].transcriptionSeconds = Date().timeIntervalSince(started)
                results[index].transcript = output.text
                results[index].notes.append(contentsOf: output.notes)
                results[index].status = output.text.isEmpty ? .failed : .succeeded
                if output.text.isEmpty {
                    results[index].error = TranscriptionLabEngineError.emptyTranscript.localizedDescription
                }
            } catch {
                results[index].status = .failed
                results[index].error = error.localizedDescription
            }
        }

        let peak = sampler.stop()
        await engine.unload()
        let footprintAfterRelease = await Self.settledFootprint()
        print("Transcription Lab: released \(engine.displayName), footprint \(TranscriptionLabProbes.formatBytes(footprintAfterRelease)) (peak \(TranscriptionLabProbes.formatBytes(peak)))")

        var warmLoad: Double?
        var warmNote: String?
        if loadError == nil, engine.measuresWarmLoad, !Task.isCancelled {
            runStatus = "Timing warm load of \(engine.displayName)…"
            let started = Date()
            do {
                try await engine.load()
                warmLoad = Date().timeIntervalSince(started)
            } catch {
                warmNote = "Warm load failed: \(error.localizedDescription)"
            }
            await engine.unload()
            let afterWarm = await Self.settledFootprint()
            print("Transcription Lab: released \(engine.displayName) after warm load, footprint \(TranscriptionLabProbes.formatBytes(afterWarm))")
        }

        let thermalAfter = TranscriptionLabProbes.thermalStateName()
        for index in results.indices {
            if let loadError, results[index].error == nil {
                results[index].status = .failed
                results[index].error = loadError
            }
            results[index].coldLoadSeconds = coldLoad
            results[index].warmLoadSeconds = warmLoad
            results[index].footprintBeforeLoadBytes = footprintBefore
            results[index].peakFootprintBytes = peak
            results[index].footprintAfterReleaseBytes = footprintAfterRelease
            results[index].thermalStateAfter = thermalAfter
            if let warmNote { results[index].notes.append(warmNote) }
            results[index].score(reference: record.reference?.text, names: record.names)
        }
        return results
    }

    /// Gives Core ML a moment to drop released buffers before sampling.
    private static func settledFootprint() async -> UInt64? {
        try? await Task.sleep(for: .milliseconds(400))
        return TranscriptionLabProbes.physFootprint()
    }
}
#endif
