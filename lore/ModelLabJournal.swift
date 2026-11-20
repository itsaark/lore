#if DEBUG
import Foundation
import NaturalLanguage

// MARK: - Wire types for POST /v1/lab/daily-entries

/// A production daily-entry request plus the Lab's chosen writer. Encodes as
/// one flat JSON object, which is the shape the backend's lab schema expects.
struct LabDailyEntryRequest: Encodable, Sendable {
    var base: DailyEntryGenerationRequest
    var labModel: String

    private enum CodingKeys: String, CodingKey { case labModel }

    func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(labModel, forKey: .labModel)
    }
}

struct LabDailyEntryUsage: Codable, Equatable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
}

struct LabDailyEntryResponse: Decodable, Sendable {
    var base: DailyEntryGenerationResponse
    var labModel: String
    var usage: LabDailyEntryUsage

    private enum CodingKeys: String, CodingKey { case labModel, usage }

    init(from decoder: Decoder) throws {
        base = try DailyEntryGenerationResponse(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labModel = try container.decode(String.self, forKey: .labModel)
        usage = try container.decode(LabDailyEntryUsage.self, forKey: .usage)
    }
}

// MARK: - Candidates

/// A writer is a (model, prompt) pair. Every model is a cheap open-weight model
/// on Fireworks serverless (zero data retention by default). The aliases must
/// match the backend's allowlist in `backend/src/contracts/daily-entry.ts`.
struct LabJournalCandidate: Identifiable, Hashable, Sendable {
    let modelAlias: String
    let promptVersion: String
    let modelName: String
    let pricePerMillion: String

    var id: String { "\(modelAlias)|\(promptVersion)" }
    var promptLabel: String { promptVersion == "grounded-journal-v2" ? "Biographer v2" : "Current v1" }
    var displayName: String { "\(modelName) · \(promptLabel)" }

    static let all: [LabJournalCandidate] = [
        .init(modelAlias: "glm-5p3", promptVersion: "grounded-journal-v2", modelName: "GLM 5.3 (production)", pricePerMillion: "$1.40 / $4.40"),
        .init(modelAlias: "gpt-oss-120b", promptVersion: "grounded-journal-v2", modelName: "GPT-OSS 120B (production fallback)", pricePerMillion: "$0.15 / $0.60"),
        .init(modelAlias: "gpt-oss-120b", promptVersion: "grounded-journal-v1", modelName: "GPT-OSS 120B (old production)", pricePerMillion: "$0.15 / $0.60"),
        .init(modelAlias: "glm-5p3-flash", promptVersion: "grounded-journal-v2", modelName: "GLM 5.3 Flash", pricePerMillion: "$0.15 / $0.50"),
        .init(modelAlias: "deepseek-v4p1-flash", promptVersion: "grounded-journal-v2", modelName: "DeepSeek V4.1 Flash", pricePerMillion: "$0.30 / $1.20"),
        .init(modelAlias: "deepseek-v4-flash", promptVersion: "grounded-journal-v2", modelName: "DeepSeek V4 Flash", pricePerMillion: "$0.22 / $1.20"),
        .init(modelAlias: "minimax-m3", promptVersion: "grounded-journal-v2", modelName: "MiniMax M3", pricePerMillion: "$0.30 / $1.20")
    ]

    static let defaultSelection: Set<String> = [
        "gpt-oss-120b|grounded-journal-v1",
        "gpt-oss-120b|grounded-journal-v2",
        "glm-5p3|grounded-journal-v2"
    ]

    static func find(_ id: String) -> LabJournalCandidate? { all.first { $0.id == id } }
}

// MARK: - Records

struct LabJournalSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
}

struct LabJournalInput: Codable, Identifiable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum Source: String, Codable, Sendable {
        case transcriptionLabClip
        case journalNote
        case pasted
    }

    var schemaVersion = Self.currentSchemaVersion
    let id: UUID
    var label: String
    let source: Source
    /// Clip folder name or Story id, when the input came from one.
    let sourceReference: String?
    let text: String
    let capturedDate: Date
    let createdAt: Date
    /// The transcript split into sentences, so outputs can cite precisely.
    let segments: [LabJournalSegment]
    var runs: [LabJournalRun] = []

    var latestRun: LabJournalRun? { runs.last }
}

struct LabJournalRun: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    /// Models stay hidden behind A, B, C until the founder has scored.
    var revealed = false
    var outputs: [LabJournalOutput]
}

struct LabJournalSentence: Codable, Equatable, Sendable {
    let text: String
    let sourceReferences: [String]
}

struct LabJournalScores: Codable, Equatable, Sendable {
    /// 1–5. The founder's score is the one that decides.
    var faithfulness: Int?
    /// 1–5.
    var narrative: Int?
    var preferred = false
    /// Sentence indexes the founder marked as unsupported or invented.
    var inventedSentences: Set<Int> = []
    var note = ""

    var isComplete: Bool { faithfulness != nil && narrative != nil }
}

struct LabJournalOutput: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
    }

    let id: UUID
    let candidateID: String
    let blindLabel: String
    var status: Status
    var title: String?
    var sentences: [LabJournalSentence] = []
    var error: String?
    var latencyMilliseconds: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var modelID: String?
    var scores = LabJournalScores()

    var candidate: LabJournalCandidate? { LabJournalCandidate.find(candidateID) }
    var prose: String { sentences.map(\.text).joined(separator: " ") }
    var wordCount: Int { prose.split(whereSeparator: \.isWhitespace).count }

    /// Names in the output that never appear in the source: a cheap flag for
    /// invented people or places. Combines Apple's name tagger with a plain
    /// check for capitalised words that don't start a sentence. The
    /// founder's read is still what counts.
    func unsupportedNames(source: String, subject: String) -> [String] {
        let sourceLowercased = source.lowercased()
        let excluded = Set(subject.lowercased().split(separator: " ").map(String.init) + ["i"])
        var names: [String] = []
        func consider(_ candidate: String) {
            let name = candidate.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard name.count > 1, !excluded.contains(name.lowercased()),
                  !sourceLowercased.contains(name.lowercased()), !names.contains(name) else { return }
            names.append(name)
        }

        let text = prose
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                consider(String(text[range]))
            }
            return true
        }

        for sentence in sentences {
            let words = sentence.text.split(whereSeparator: \.isWhitespace).map(String.init)
            for word in words.dropFirst() where word.first?.isUppercase == true {
                consider(word)
            }
        }
        return names
    }
}

enum LabJournalSegmenter {
    static func segments(for text: String) -> [LabJournalSegment] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var segments: [LabJournalSegment] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                segments.append(LabJournalSegment(id: "s\(segments.count + 1)", text: sentence))
            }
            return true
        }
        if segments.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments = [LabJournalSegment(id: "s1", text: trimmed)] }
        }
        return segments
    }
}

// MARK: - Storage

/// Journal inputs live in `Documents/ModelLab/Journal/<id>.json`, excluded
/// from iCloud and device backups like the transcription clips. They hold
/// private transcripts and must not leave the phone except through an
/// explicit export.
struct LabJournalStore {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModelLab", isDirectory: true)
            .appendingPathComponent("Journal", isDirectory: true)
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try TranscriptionLabClipStore.excludeFromBackup(rootURL.deletingLastPathComponent())
        try TranscriptionLabClipStore.excludeFromBackup(rootURL)
    }

    func loadAll() -> [LabJournalInput] {
        let decoder = Self.decoder
        let files = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(LabJournalInput.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ input: LabJournalInput) throws {
        try ensureRoot()
        let data = try Self.encoder.encode(input)
        try data.write(to: url(for: input.id), options: [.atomic, .completeFileProtection])
    }

    func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// One JSON file with every input, its source, all outputs and scores, for
    /// a second-opinion review. Created only when the founder taps Export.
    func exportAll(_ inputs: [LabJournalInput]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-journal-lab-\(Int(Date().timeIntervalSince1970)).json")
        let data = try Self.encoder.encode(inputs)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func url(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Model

@MainActor
final class LabJournalModel: ObservableObject {
    @Published private(set) var inputs: [LabJournalInput] = []
    @Published var selectedCandidateIDs: Set<String> = LabJournalCandidate.defaultSelection
    @Published private(set) var runningInputIDs: Set<UUID> = []
    @Published var errorMessage: String?

    let store = LabJournalStore()
    /// The narrator's subject details from their profile, set by the view.
    var subject = JournalSubject(displayName: "the narrator", pronouns: [])
    private let backend: LoreBackendHTTPClient?

    init() {
        #if targetEnvironment(simulator)
        backend = nil
        #else
        backend = LoreRemoteServices.configuredForCurrentBuild().labBackend
        #endif
    }

    var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "Writers run on Lore's backend, which needs App Attest. The Simulator can't provide it."
        #else
        return backend == nil ? "Lore's backend isn't configured for this build." : nil
        #endif
    }

    func load() {
        inputs = store.loadAll()
    }

    @discardableResult
    func addInput(label: String, text: String, source: LabJournalInput.Source, reference: String?, capturedDate: Date) -> LabJournalInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let reference, let existing = inputs.first(where: { $0.sourceReference == reference && $0.text == trimmed }) {
            return existing
        }
        let input = LabJournalInput(
            id: UUID(),
            label: label.isEmpty ? "Untitled" : label,
            source: source,
            sourceReference: reference,
            text: trimmed,
            capturedDate: capturedDate,
            createdAt: Date(),
            segments: LabJournalSegmenter.segments(for: trimmed)
        )
        persist(input)
        return input
    }

    func delete(_ input: LabJournalInput) {
        try? store.delete(input.id)
        inputs.removeAll { $0.id == input.id }
    }

    func isRunning(_ input: LabJournalInput) -> Bool { runningInputIDs.contains(input.id) }

    /// Runs every selected candidate on the input, concurrently, behind
    /// shuffled blind labels.
    func run(_ inputID: UUID) {
        guard let backend, var input = inputs.first(where: { $0.id == inputID }), !isRunning(input) else { return }
        let candidates = LabJournalCandidate.all.filter { selectedCandidateIDs.contains($0.id) }.shuffled()
        guard !candidates.isEmpty else {
            errorMessage = "Choose at least one writer."
            return
        }
        let labels = (0..<candidates.count).map { String(UnicodeScalar(UInt8(65 + $0))) }
        let run = LabJournalRun(
            id: UUID(),
            startedAt: Date(),
            outputs: zip(candidates, labels).map { candidate, label in
                LabJournalOutput(id: UUID(), candidateID: candidate.id, blindLabel: label, status: .running)
            }
        )
        input.runs.append(run)
        persist(input)
        runningInputIDs.insert(inputID)

        let subject = self.subject
        Task {
            await withTaskGroup(of: (UUID, LabJournalOutput).self) { group in
                for output in run.outputs {
                    guard let candidate = output.candidate else { continue }
                    group.addTask {
                        var result = output
                        let started = Date()
                        do {
                            let response = try await backend.generateLabDailyEntry(
                                Self.request(for: input, candidate: candidate, subject: subject)
                            )
                            result.status = .succeeded
                            result.title = response.base.entry.title
                            result.sentences = response.base.entry.sentences.map {
                                LabJournalSentence(text: $0.text, sourceReferences: $0.sourceReferences)
                            }
                            result.promptTokens = response.usage.promptTokens
                            result.completionTokens = response.usage.completionTokens
                            result.modelID = response.base.provenance.modelId
                        } catch {
                            result.status = .failed
                            result.error = error.localizedDescription
                        }
                        result.latencyMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
                        return (output.id, result)
                    }
                }
                for await (outputID, result) in group {
                    self.updateOutput(inputID: inputID, runID: run.id, outputID: outputID) { $0 = result }
                }
            }
            self.updateRun(inputID: inputID, runID: run.id) { $0.finishedAt = Date() }
            self.runningInputIDs.remove(inputID)
        }
    }

    func updateScores(inputID: UUID, runID: UUID, outputID: UUID, _ change: (inout LabJournalScores) -> Void) {
        updateOutput(inputID: inputID, runID: runID, outputID: outputID) { change(&$0.scores) }
    }

    /// Only one output per run can be the preferred one.
    func setPreferred(inputID: UUID, runID: UUID, outputID: UUID) {
        updateRun(inputID: inputID, runID: runID) { run in
            for index in run.outputs.indices {
                run.outputs[index].scores.preferred = run.outputs[index].id == outputID
            }
        }
    }

    func reveal(inputID: UUID, runID: UUID) {
        updateRun(inputID: inputID, runID: runID) { $0.revealed = true }
    }

    func exportAll() -> URL? {
        do {
            return try store.exportAll(inputs)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Mean founder scores per candidate across every scored output.
    func leaderboard() -> [(candidate: LabJournalCandidate, faithfulness: Double?, narrative: Double?, preferred: Int, scored: Int)] {
        LabJournalCandidate.all.compactMap { candidate in
            let outputs = inputs.flatMap(\.runs).filter(\.revealed).flatMap(\.outputs).filter { $0.candidateID == candidate.id && $0.status == .succeeded }
            guard !outputs.isEmpty else { return nil }
            let faith = outputs.compactMap(\.scores.faithfulness)
            let narrative = outputs.compactMap(\.scores.narrative)
            return (
                candidate,
                faith.isEmpty ? nil : Double(faith.reduce(0, +)) / Double(faith.count),
                narrative.isEmpty ? nil : Double(narrative.reduce(0, +)) / Double(narrative.count),
                outputs.filter(\.scores.preferred).count,
                faith.count
            )
        }
    }

    // MARK: Private

    private nonisolated static func request(
        for input: LabJournalInput,
        candidate: LabJournalCandidate,
        subject: JournalSubject
    ) -> LabDailyEntryRequest {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let isV2 = candidate.promptVersion == "grounded-journal-v2"
        var offset = 0
        let segments = input.segments.enumerated().map { index, segment in
            let start = offset
            offset += max(1, segment.text.count * 60)
            return TranscriptSourceSegment(
                id: segment.id,
                chunkId: "lab-\(index)",
                startMilliseconds: start,
                endMilliseconds: offset,
                text: segment.text,
                confidence: nil,
                speakerLabel: nil
            )
        }
        return LabDailyEntryRequest(
            base: DailyEntryGenerationRequest(
                promptVersion: candidate.promptVersion,
                jobId: UUID(),
                noteId: input.id,
                transcriptArtifactId: input.id,
                transcriptVersionId: input.id,
                capturedLocalDate: formatter.string(from: input.capturedDate),
                languageCode: "en-US",
                subject: subject,
                // v1 keeps its original settings so it reproduces the old production voice.
                renderConfiguration: isV2
                    ? JournalRenderConfiguration(tone: "narrative_restrained", targetWords: 200)
                    : JournalRenderConfiguration(tone: "warm_restrained", targetWords: 130),
                sourceSegments: segments
            ),
            labModel: candidate.modelAlias
        )
    }

    private func persist(_ input: LabJournalInput) {
        if let index = inputs.firstIndex(where: { $0.id == input.id }) {
            inputs[index] = input
        } else {
            inputs.insert(input, at: 0)
        }
        do {
            try store.save(input)
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func updateRun(inputID: UUID, runID: UUID, _ change: (inout LabJournalRun) -> Void) {
        guard var input = inputs.first(where: { $0.id == inputID }),
              let runIndex = input.runs.firstIndex(where: { $0.id == runID }) else { return }
        change(&input.runs[runIndex])
        persist(input)
    }

    private func updateOutput(inputID: UUID, runID: UUID, outputID: UUID, _ change: (inout LabJournalOutput) -> Void) {
        updateRun(inputID: inputID, runID: runID) { run in
            guard let index = run.outputs.firstIndex(where: { $0.id == outputID }) else { return }
            change(&run.outputs[index])
        }
    }
}
#endif
