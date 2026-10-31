#if DEBUG
import Darwin
import Foundation
import UIKit

// MARK: - Persisted results

/// Everything written to `results.json` for one clip. The founder pulls the
/// whole `Documents/TranscriptionLab` folder off the phone, so this file has
/// to stand on its own without the app.
struct TranscriptionLabClipRecord: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    /// Folder name, `<timestamp>-<label>`.
    let id: String
    var label: String
    var names: [String]
    let createdAt: Date
    let audioFileName: String
    let audioDurationSeconds: Double
    let audioSampleRate: Double
    let audioChannelCount: Int
    let device: TranscriptionLabDeviceInfo
    var reference: TranscriptionLabReference?
    /// Every "Run all", oldest first. The UI shows the newest.
    var runs: [TranscriptionLabRun] = []

    var latestRun: TranscriptionLabRun? { runs.last }

    /// Re-scores every stored result against the current reference and names.
    mutating func rescore() {
        for runIndex in runs.indices {
            for resultIndex in runs[runIndex].results.indices {
                runs[runIndex].results[resultIndex].score(reference: reference?.text, names: names)
            }
        }
    }
}

struct TranscriptionLabReference: Codable, Equatable {
    var text: String
    /// Engine result the founder started from before correcting it.
    var derivedFromEngineID: String?
    var updatedAt: Date
}

struct TranscriptionLabRun: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    /// Device state for the run as a whole. Per-engine values are on each result.
    var device: TranscriptionLabDeviceInfo
    var results: [TranscriptionLabEngineResult]
}

struct TranscriptionLabEngineResult: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case succeeded
        case failed
        case skipped
    }

    /// Stable variant identifier, for example `fluidaudio.fluid-speech-mini.vocabulary`.
    let id: String
    let displayName: String
    let engine: String
    let model: String
    let modelVersion: String
    let sdkVersion: String
    let usesVocabulary: Bool
    let vocabulary: [String]
    var status: Status
    var error: String?
    var transcript: String?

    /// First load of the model in this app process (after any download).
    var coldLoadSeconds: Double?
    /// A second load right after releasing the first, when it can be measured.
    var warmLoadSeconds: Double?
    /// Wall time from handing audio to the engine until the transcript returns.
    var transcriptionSeconds: Double?
    let audioDurationSeconds: Double
    /// Processing time divided by audio duration; lower is faster.
    var realTimeFactor: Double? {
        guard let transcriptionSeconds, audioDurationSeconds > 0 else { return nil }
        return transcriptionSeconds / audioDurationSeconds
    }

    var footprintBeforeLoadBytes: UInt64?
    var peakFootprintBytes: UInt64?
    var footprintAfterReleaseBytes: UInt64?
    var thermalStateBefore: String
    var thermalStateAfter: String?
    var notes: [String] = []

    var wordErrorRate: TranscriptionLabMetrics.WordErrorRate?
    var nameRecall: TranscriptionLabMetrics.NameRecall?

    mutating func score(reference: String?, names: [String]) {
        guard status == .succeeded, let transcript else {
            wordErrorRate = nil
            nameRecall = nil
            return
        }
        wordErrorRate = reference.flatMap {
            TranscriptionLabMetrics.wordErrorRate(reference: $0, hypothesis: transcript)
        }
        nameRecall = TranscriptionLabMetrics.nameRecall(names: names, hypothesis: transcript)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, engine, model, modelVersion, sdkVersion, usesVocabulary, vocabulary
        case status, error, transcript, coldLoadSeconds, warmLoadSeconds, transcriptionSeconds
        case audioDurationSeconds, realTimeFactor, footprintBeforeLoadBytes, peakFootprintBytes
        case footprintAfterReleaseBytes, thermalStateBefore, thermalStateAfter, notes
        case wordErrorRate, nameRecall
    }

    init(
        variant: TranscriptionLabVariantDescriptor,
        audioDurationSeconds: Double,
        thermalStateBefore: String
    ) {
        id = variant.id
        displayName = variant.displayName
        engine = variant.engine
        model = variant.model
        modelVersion = variant.modelVersion
        sdkVersion = variant.sdkVersion
        usesVocabulary = variant.usesVocabulary
        vocabulary = variant.vocabulary
        status = .skipped
        self.audioDurationSeconds = audioDurationSeconds
        self.thermalStateBefore = thermalStateBefore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        engine = try container.decode(String.self, forKey: .engine)
        model = try container.decode(String.self, forKey: .model)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        sdkVersion = try container.decode(String.self, forKey: .sdkVersion)
        usesVocabulary = try container.decode(Bool.self, forKey: .usesVocabulary)
        vocabulary = try container.decode([String].self, forKey: .vocabulary)
        status = try container.decode(Status.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        coldLoadSeconds = try container.decodeIfPresent(Double.self, forKey: .coldLoadSeconds)
        warmLoadSeconds = try container.decodeIfPresent(Double.self, forKey: .warmLoadSeconds)
        transcriptionSeconds = try container.decodeIfPresent(Double.self, forKey: .transcriptionSeconds)
        audioDurationSeconds = try container.decode(Double.self, forKey: .audioDurationSeconds)
        footprintBeforeLoadBytes = try container.decodeIfPresent(UInt64.self, forKey: .footprintBeforeLoadBytes)
        peakFootprintBytes = try container.decodeIfPresent(UInt64.self, forKey: .peakFootprintBytes)
        footprintAfterReleaseBytes = try container.decodeIfPresent(UInt64.self, forKey: .footprintAfterReleaseBytes)
        thermalStateBefore = try container.decode(String.self, forKey: .thermalStateBefore)
        thermalStateAfter = try container.decodeIfPresent(String.self, forKey: .thermalStateAfter)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        wordErrorRate = try container.decodeIfPresent(TranscriptionLabMetrics.WordErrorRate.self, forKey: .wordErrorRate)
        nameRecall = try container.decodeIfPresent(TranscriptionLabMetrics.NameRecall.self, forKey: .nameRecall)
    }

    /// Writes the derived real-time factor too, so the JSON is analyzable
    /// without recomputing it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(engine, forKey: .engine)
        try container.encode(model, forKey: .model)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(usesVocabulary, forKey: .usesVocabulary)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encodeIfPresent(coldLoadSeconds, forKey: .coldLoadSeconds)
        try container.encodeIfPresent(warmLoadSeconds, forKey: .warmLoadSeconds)
        try container.encodeIfPresent(transcriptionSeconds, forKey: .transcriptionSeconds)
        try container.encode(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encodeIfPresent(realTimeFactor, forKey: .realTimeFactor)
        try container.encodeIfPresent(footprintBeforeLoadBytes, forKey: .footprintBeforeLoadBytes)
        try container.encodeIfPresent(peakFootprintBytes, forKey: .peakFootprintBytes)
        try container.encodeIfPresent(footprintAfterReleaseBytes, forKey: .footprintAfterReleaseBytes)
        try container.encode(thermalStateBefore, forKey: .thermalStateBefore)
        try container.encodeIfPresent(thermalStateAfter, forKey: .thermalStateAfter)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(wordErrorRate, forKey: .wordErrorRate)
        try container.encodeIfPresent(nameRecall, forKey: .nameRecall)
    }
}

struct TranscriptionLabDeviceInfo: Codable, Equatable {
    /// Hardware identifier such as `iPhone15,2`.
    let modelIdentifier: String
    let systemName: String
    let systemVersion: String
    let osBuild: String?
    let appVersion: String
    let appBuild: String
    let physicalMemoryBytes: UInt64
    let thermalState: String
    let lowPowerModeEnabled: Bool
    let isSimulator: Bool

    @MainActor
    static func current() -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        #if targetEnvironment(simulator)
        let isSimulator = true
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? TranscriptionLabProbes.sysctlString("hw.machine") ?? "unknown"
        #else
        let isSimulator = false
        let identifier = TranscriptionLabProbes.sysctlString("hw.machine") ?? "unknown"
        #endif
        return Self(
            modelIdentifier: identifier,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            osBuild: TranscriptionLabProbes.sysctlString("kern.osversion"),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalState: TranscriptionLabProbes.thermalStateName(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSimulator: isSimulator
        )
    }
}

// MARK: - Probes

enum TranscriptionLabProbes {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The figure jetsam uses to decide when to kill the app.
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    static func thermalStateName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += UInt64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

/// Samples `phys_footprint` on a background timer and keeps the maximum.
final class TranscriptionLabMemorySampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lore.transcription-lab.memory", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0

    func start(interval: DispatchTimeInterval = .milliseconds(25)) {
        queue.sync {
            peak = TranscriptionLabProbes.physFootprint() ?? 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self, let value = TranscriptionLabProbes.physFootprint() else { return }
                if value > self.peak { self.peak = value }
            }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops sampling and returns the peak seen since `start`.
    @discardableResult
    func stop() -> UInt64 {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let value = TranscriptionLabProbes.physFootprint(), value > peak { peak = value }
            return peak
        }
    }
}

// MARK: - Clip storage

/// Clip folders live in `Documents/TranscriptionLab/<timestamp>-<label>/` so
/// they can be pulled with `xcrun devicectl device copy from`.
struct TranscriptionLabClipStore {
    static let audioFileName = "audio.wav"
    static let resultsFileName = "results.json"

    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionLab", isDirectory: true)
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func folderURL(for clipID: String) -> URL {
        rootURL.appendingPathComponent(clipID, isDirectory: true)
    }

    func audioURL(for clipID: String) -> URL {
        folderURL(for: clipID).appendingPathComponent(Self.audioFileName)
    }

    static func makeClipID(label: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = label
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        let stamp = formatter.string(from: date)
        return slug.isEmpty ? "\(stamp)-clip" : "\(stamp)-\(slug)"
    }

    func loadAll() -> [TranscriptionLabClipRecord] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = Self.decoder
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent(Self.resultsFileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(TranscriptionLabClipRecord.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ record: TranscriptionLabClipRecord) throws {
        let folder = folderURL(for: record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(record)
        try data.write(to: folder.appendingPathComponent(Self.resultsFileName), options: .atomic)
    }

    func delete(_ clipID: String) throws {
        try FileManager.default.removeItem(at: folderURL(for: clipID))
    }

    /// Zips the whole lab folder for the share sheet. Uses the coordinated
    /// read's built-in directory zipping, so no archive dependency is needed.
    func exportArchive() throws -> URL {
        try ensureRoot()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionLab-\(Self.makeClipID(label: "export")).zip")
        try? FileManager.default.removeItem(at: destination)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: rootURL,
            options: .forUploading,
            error: &coordinationError
        ) { zippedURL in
            do {
                try FileManager.default.copyItem(at: zippedURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
