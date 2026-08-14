@preconcurrency import AVFoundation
import Foundation

enum ReflectionAudioError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case invalidFormat
    case captureUnavailable
    case playbackUnavailable
}

@MainActor
protocol ReflectionAudioControlling: AnyObject {
    var isCapturing: Bool { get }
    var isPlaying: Bool { get }

    func requestMicrophonePermission() async -> Bool
    func startCapture(
        recordingTo fileURL: URL,
        onPCMChunk: @escaping @Sendable (Data) -> Void
    ) throws
    func stopCapture() throws
    func replayProtectedCapture(
        at fileURL: URL,
        sendPCMChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws
    func enqueuePlaybackPCM(_ pcmS16LE: Data) throws
    func waitForPlaybackToFinish() async
    func stopPlayback()
    func tearDown()
}

/// Owns the mutually exclusive microphone and speaker phases of a reflection.
/// Soniox-facing audio is mono signed 16-bit little-endian PCM: 16 kHz for STT
/// and 24 kHz for TTS. Each captured turn is also retained in a protected CAF
/// file until its finalized transcript has been durably committed.
@MainActor
final class ReflectionAudioController: ReflectionAudioControlling {
    private let audioSession: AVAudioSession
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var capturePipeline: ReflectionAudioCapturePipeline?
    private var inputTapInstalled = false
    private var scheduledPlaybackBuffers = 0
    private var playbackWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var isCapturing = false
    private(set) var isPlaying = false

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.audioSession = audioSession
        self.engine = engine
    }

    static func makeProtectedTurnAudioURL(
        sessionID: UUID,
        turnID: UUID,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        directory
            .appendingPathComponent("reflection-\(sessionID.uuidString.lowercased())", isDirectory: true)
            .appendingPathComponent("turn-\(turnID.uuidString.lowercased())")
            .appendingPathExtension("caf")
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startCapture(
        recordingTo fileURL: URL,
        onPCMChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "caf" else {
            throw ReflectionAudioError.invalidFormat
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw ReflectionAudioError.microphonePermissionDenied
        }

        stopPlayback()
        stopEngineAndRemoveTap()
        try configureSession()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ReflectionAudioError.captureUnavailable
        }

        let pipeline = try ReflectionAudioCapturePipeline(
            inputFormat: inputFormat,
            recordingURL: fileURL,
            onPCMChunk: onPCMChunk
        )
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            pipeline.process(buffer)
        }
        inputTapInstalled = true
        capturePipeline = pipeline

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
        } catch {
            stopEngineAndRemoveTap()
            capturePipeline = nil
            throw ReflectionAudioError.captureUnavailable
        }
    }

    func stopCapture() throws {
        guard isCapturing || inputTapInstalled else { return }
        stopEngineAndRemoveTap()
        let pipeline = capturePipeline
        capturePipeline = nil
        isCapturing = false
        if pipeline?.encounteredWriteFailure == true {
            throw ReflectionAudioError.captureUnavailable
        }
    }

    func replayProtectedCapture(
        at fileURL: URL,
        sendPCMChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReflectionAudioError.captureUnavailable
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw ReflectionAudioError.captureUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw ReflectionAudioError.invalidFormat
        }

        let inputFrameCapacity: AVAudioFrameCount = 4_096
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: inputFrameCapacity
            ) else {
                throw ReflectionAudioError.invalidFormat
            }
            do {
                try file.read(into: input, frameCount: min(
                    inputFrameCapacity,
                    AVAudioFrameCount(file.length - file.framePosition)
                ))
            } catch {
                throw ReflectionAudioError.captureUnavailable
            }
            guard input.frameLength > 0 else { break }

            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw ReflectionAudioError.invalidFormat
            }
            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !suppliedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard
                status != .error,
                conversionError == nil,
                output.frameLength > 0,
                let samples = output.int16ChannelData?[0]
            else {
                throw ReflectionAudioError.invalidFormat
            }
            let pcm = Data(
                bytes: samples,
                count: Int(output.frameLength) * MemoryLayout<Int16>.size
            )
            try await sendPCMChunk(pcm)
            try await Task.sleep(for: .seconds(Double(output.frameLength) / outputFormat.sampleRate))
        }
    }

    func enqueuePlaybackPCM(_ pcmS16LE: Data) throws {
        guard !pcmS16LE.isEmpty else { return }
        guard pcmS16LE.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw ReflectionAudioError.invalidFormat
        }
        if isCapturing {
            try stopCapture()
        }
        try configureSession()

        let format = try Self.playbackFormat()
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw ReflectionAudioError.playbackUnavailable
            }
        }

        let frameCount = AVAudioFrameCount(pcmS16LE.count / MemoryLayout<Int16>.size)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let destination = buffer.int16ChannelData?[0]
        else {
            throw ReflectionAudioError.invalidFormat
        }
        buffer.frameLength = frameCount
        _ = pcmS16LE.copyBytes(
            to: UnsafeMutableBufferPointer(start: destination, count: Int(frameCount))
        )

        scheduledPlaybackBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.playbackBufferFinished()
            }
        }
        if !player.isPlaying {
            player.play()
        }
        isPlaying = true
    }

    func waitForPlaybackToFinish() async {
        guard scheduledPlaybackBuffers > 0 else { return }
        await withCheckedContinuation { continuation in
            playbackWaiters.append(continuation)
        }
    }

    func stopPlayback() {
        if player.isPlaying || scheduledPlaybackBuffers > 0 {
            player.stop()
        }
        scheduledPlaybackBuffers = 0
        isPlaying = false
        resumePlaybackWaiters()
    }

    func tearDown() {
        stopPlayback()
        stopEngineAndRemoveTap()
        capturePipeline = nil
        isCapturing = false
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSession() throws {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setPreferredIOBufferDuration(0.02)
            try audioSession.setActive(true)
        } catch {
            throw ReflectionAudioError.captureUnavailable
        }
    }

    private func stopEngineAndRemoveTap() {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        isCapturing = false
    }

    private func playbackBufferFinished() {
        scheduledPlaybackBuffers = max(0, scheduledPlaybackBuffers - 1)
        guard scheduledPlaybackBuffers == 0 else { return }
        isPlaying = false
        resumePlaybackWaiters()
    }

    private func resumePlaybackWaiters() {
        let waiters = playbackWaiters
        playbackWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func playbackFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ReflectionAudioError.invalidFormat
        }
        return format
    }
}

private final class ReflectionAudioCapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let recordingFile: AVAudioFile
    private let outputFormat: AVAudioFormat
    private let onPCMChunk: @Sendable (Data) -> Void
    private var writeFailed = false

    var encounteredWriteFailure: Bool {
        lock.withLock { writeFailed }
    }

    init(
        inputFormat: AVAudioFormat,
        recordingURL: URL,
        onPCMChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ReflectionAudioError.invalidFormat
        }

        do {
            try FileManager.default.createDirectory(
                at: recordingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            recordingFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: recordingURL.path
            )
        } catch {
            throw ReflectionAudioError.captureUnavailable
        }

        self.converter = converter
        self.outputFormat = outputFormat
        self.onPCMChunk = onPCMChunk
    }

    func process(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            do {
                try recordingFile.write(from: input)
            } catch {
                writeFailed = true
            }

            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                return
            }
            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !suppliedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard
                status != .error,
                conversionError == nil,
                output.frameLength > 0,
                let samples = output.int16ChannelData?[0]
            else {
                return
            }
            onPCMChunk(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
    }
}
