import Accelerate
import AVFoundation
import QuartzCore
import os

/// Lore's recorder: one `AVAudioEngine` input tap feeds both the M4A file and
/// the recording glow.
///
/// Every microphone buffer is written to the file untouched (resampled to
/// the file's rate when the hardware differs), and the same samples land in
/// a small ring the glow analyses once per frame — the way voice apps drive
/// a live visual without a second microphone client or any compromise to
/// the recording itself.
final class VoiceCaptureEngine: @unchecked Sendable {
    enum CaptureError: Error {
        case microphoneUnavailable
    }

    /// The file Lore uploads: AAC in an M4A, mono, 44.1 kHz.
    nonisolated(unsafe) static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    private let engine = AVAudioEngine()
    private let writer: RecordingWriter
    private let ring = AnalysisRing(capacity: 1 << 15)
    private let analyser = SpectrumAnalyser(fftSize: 1024)
    private var configurationObserver: NSObjectProtocol?

    /// - Parameter file: an `AVAudioFile` opened for writing; the engine owns
    ///   it from here and closes it in ``stop()``.
    init(file: AVAudioFile) {
        writer = RecordingWriter(file: file)
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        try installTap()
        engine.prepare()
        try engine.start()
        // Plugging in headphones or switching to AirPods changes the input
        // format and stops the engine; pick the new input up and carry on
        // writing to the same file.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// Stops capture and finalizes the M4A. When this returns the file is
    /// closed and safe to inspect or upload.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
        ring.clear()
    }

    /// Raw analysis of the latest audio for the glow. Called every frame.
    func currentAudio() -> VoiceGlowAudio? {
        guard let window = ring.window(count: analyser.fftSize, now: CACurrentMediaTime()) else {
            return nil
        }
        let result = analyser.analyse(window.samples, sampleRate: window.sampleRate)
        return VoiceGlowAudio(rms: result.rms, bands: result.bands)
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }
        try writer.prepare(for: format)
        ring.reset(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [writer, ring] buffer, _ in
            writer.write(buffer)
            ring.write(buffer)
        }
    }

    private func restartAfterConfigurationChange() {
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            print("⚠️ Recording input changed and could not restart: \(error)")
        }
    }
}

// MARK: - File writing

/// Owns the open `AVAudioFile`. Writes arrive on the tap's thread and the
/// close on the main thread, so both go through one lock.
final class RecordingWriter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    init(file: AVAudioFile) {
        self.file = file
    }

    func prepare(for inputFormat: AVAudioFormat) throws {
        try lock.withLockUnchecked {
            guard let file else { return }
            let target = file.processingFormat
            if inputFormat.sampleRate == target.sampleRate,
               inputFormat.channelCount == target.channelCount,
               inputFormat.commonFormat == target.commonFormat {
                converter = nil
            } else if let converter = AVAudioConverter(from: inputFormat, to: target) {
                self.converter = converter
            } else {
                throw VoiceCaptureEngine.CaptureError.microphoneUnavailable
            }
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLockUnchecked {
            guard let file else { return }
            do {
                guard let converter else {
                    try file.write(from: buffer)
                    return
                }
                let target = file.processingFormat
                let ratio = target.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if status == .error {
                    print("⚠️ Recording conversion failed: \(String(describing: conversionError))")
                    return
                }
                if output.frameLength > 0 {
                    try file.write(from: output)
                }
            } catch {
                print("⚠️ Recording write failed: \(error)")
            }
        }
    }

    func close() {
        lock.withLockUnchecked {
            file?.close()
            file = nil
            converter = nil
        }
    }
}

// MARK: - Analysis ring

/// The latest mono samples, and a playhead that glides through each tap
/// buffer as it plays out. iOS often delivers tap buffers of ~100 ms; read
/// naively the glow would jump ten times a second. Reading the window that
/// ends where the playhead is now gives a fresh window every frame, at the
/// cost of one buffer of latency.
final class AnalysisRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffer: [Float]
    private var written = 0
    private var lastChunkFrames = 0
    private var lastChunkTime: CFTimeInterval = 0
    private var sampleRate: Double = 0

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: capacity)
    }

    func reset(sampleRate: Double) {
        lock.withLockUnchecked {
            self.sampleRate = sampleRate
            written = 0
            lastChunkFrames = 0
        }
    }

    func clear() {
        lock.withLockUnchecked {
            written = 0
            lastChunkFrames = 0
        }
    }

    func write(_ pcm: AVAudioPCMBuffer, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard let channel = pcm.floatChannelData?[0] else { return }
        write(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)), at: time)
    }

    func write(_ samples: UnsafeBufferPointer<Float>, at time: CFTimeInterval) {
        lock.withLockUnchecked {
            let capacity = buffer.count
            for sample in samples {
                buffer[written % capacity] = sample
                written += 1
            }
            lastChunkFrames = samples.count
            lastChunkTime = time
        }
    }

    func window(count: Int, now: CFTimeInterval) -> (samples: [Float], sampleRate: Double)? {
        lock.withLockUnchecked {
            guard sampleRate > 0 else { return nil }
            let elapsed = max(0, now - lastChunkTime)
            let advance = min(Int(elapsed * sampleRate), lastChunkFrames)
            let end = written - lastChunkFrames + advance
            guard end >= count else { return nil }
            let capacity = buffer.count
            let start = end - count
            return ((start..<end).map { buffer[$0 % capacity] }, sampleRate)
        }
    }
}

// MARK: - Spectrum

// Adapted from VoiceGlowKit's VoiceMeter (https://github.com/Jakubantalik/Libraries.dev,
// MIT, © 2026 Jakub Antalik). See ThirdPartyNotices.txt.

/// The web `AnalyserNode`'s numbers, which the glow is tuned for: RMS of the
/// time-domain window, and a Blackman-windowed FFT smoothed over time (τ 0.5)
/// and mapped from −100…−30 dB onto 0–1, averaged over three voice bands.
final class SpectrumAnalyser: @unchecked Sendable {
    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var smoothed: [Float]
    private let lock = OSAllocatedUnfairLock()

    /// Voice bands in Hz: fundamentals and chest, vowels and presence, sibilance.
    static let bands: [(Double, Double)] = [(80, 300), (300, 2000), (2000, 6000)]

    init(fftSize: Int) {
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // The Web Audio Blackman window (α = 0.16).
        window = (0..<fftSize).map { n in
            let a = 0.16, a0 = (1 - a) / 2, a1 = 0.5, a2 = a / 2
            let x = 2 * Double.pi * Double(n) / Double(fftSize)
            return Float(a0 - a1 * cos(x) + a2 * cos(2 * x))
        }
        smoothed = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func analyse(_ samples: [Float], sampleRate: Double) -> (rms: Double, bands: SIMD3<Double>) {
        lock.withLockUnchecked {
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(fftSize))

            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            let half = fftSize / 2
            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            var magnitudes = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip packs Nyquist into imag[0]; bin 0 is DC — neither is a voice band.
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            // zrip's output is 2× the DFT; the analyser divides by N.
            var scale = Float(0.5) / Float(fftSize)
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

            let binHz = sampleRate / Double(fftSize)
            var out = SIMD3<Double>(0, 0, 0)
            for (b, band) in Self.bands.enumerated() {
                let from = max(0, Int(floor(band.0 / binHz)))
                let to = min(half - 1, Int(ceil(band.1 / binHz)))
                var acc = 0.0
                if to >= from {
                    for i in from...to {
                        smoothed[i] = 0.5 * smoothed[i] + 0.5 * magnitudes[i]
                        let db = 20 * log10(Double(max(smoothed[i], 1e-12)))
                        acc += max(0, min(1, (db + 100) / 70))
                    }
                    out[b] = acc / Double(to - from + 1)
                }
            }
            return (Double(rms), out)
        }
    }
}
