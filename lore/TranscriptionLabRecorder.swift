#if DEBUG
import AVFAudio
import Foundation

/// Records lab clips as 16 kHz mono 16-bit WAV, the native input of every
/// on-device engine in the lab. Owns its audio session changes and puts the
/// previous category back when the lab closes.
@MainActor
final class TranscriptionLabRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0...1, from the RMS level of the latest input buffer.
    @Published private(set) var level: Float = 0

    static let sampleRate: Double = 16_000

    private struct SavedSession {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private let session = AVAudioSession.sharedInstance()
    private var savedSession: SavedSession?
    private var engine: AVAudioEngine?
    private var writer: TapWriter?
    private var timer: Timer?
    private var startedAt: Date?

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        if savedSession == nil {
            savedSession = SavedSession(category: session.category, mode: session.mode, options: session.categoryOptions)
        }
        // Same category and mode as production capture, so clips match what
        // the real pipeline hears.
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TranscriptionLabEngineError.unavailable("No microphone input is available.")
        }
        let writer = try TapWriter(url: url, inputFormat: inputFormat, sampleRate: Self.sampleRate) { [weak self] level in
            DispatchQueue.main.async { self?.level = level }
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            writer.append(buffer)
        }
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.writer = writer
        startedAt = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Stops and closes the file. Returns the written duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let duration = writer?.finish() ?? 0
        writer = nil
        isRecording = false
        level = 0
        startedAt = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    /// Puts back whatever audio session category was active before the lab.
    func restoreSession() {
        stop()
        guard let savedSession else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(savedSession.category, mode: savedSession.mode, options: savedSession.options)
        self.savedSession = nil
    }
}

/// Converts tap buffers to the lab format and appends them to the WAV file.
/// Runs on the audio tap thread only.
private final class TapWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onLevel: (Float) -> Void
    private let lock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var isFinished = false

    init(url: URL, inputFormat: AVAudioFormat, sampleRate: Double, onLevel: @escaping (Float) -> Void) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionLabEngineError.unavailable("Could not build the 16 kHz converter.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.converter = converter
        self.outputFormat = outputFormat
        self.onLevel = onLevel
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        do {
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            print("Transcription Lab: failed to write audio: \(error)")
        }
    }

    func finish() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        return Double(framesWritten) / outputFormat.sampleRate
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += channel[index] * channel[index]
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (decibels + 60) / 60))
    }
}
#endif
