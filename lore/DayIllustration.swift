import CryptoKit
import Foundation
import SwiftData

struct DayIllustrationGenerationRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let currentPromptVersion = "day-illustration-v1"
    static let maximumTitleLength = 200
    static let maximumProseLength = 20_000

    var schemaVersion: String = Self.currentSchemaVersion
    var promptVersion: String = Self.currentPromptVersion
    var jobId: UUID
    var dayKey: String
    var languageCode: String
    var title: String
    var prose: String
    var retentionPolicy = RemoteRetentionPolicy()
}

struct DayIllustrationGenerationResponse: Codable, Equatable, Sendable {
    struct Image: Codable, Equatable, Sendable {
        var mediaType: String
        var dataBase64: String
        var pixelWidth: Int
        var pixelHeight: Int
    }

    struct Scene: Codable, Equatable, Sendable {
        var description: String
    }

    var schemaVersion: String
    var promptVersion: String
    var jobId: UUID
    var requestId: String
    var image: Image
    var scene: Scene
    var sceneProvenance: RemoteProcessingProvenance
    var provenance: RemoteProcessingProvenance
}

/// A replaceable painting derived from a day or memory biography.
@Model
final class DayIllustration {
    private(set) var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) private(set) var dayKey: String = ""
    private(set) var memoryStoryId: UUID?

    var biographyKey: String { BiographyIdentity.key(dayKey: dayKey, memoryStoryId: memoryStoryId) }
    var paintingRevision: PaintingRevision {
        PaintingRevision(id: id, updatedAt: updatedAt, fingerprint: sourceFingerprint)
    }
    @Attribute(.externalStorage) private(set) var imageData: Data? = nil
    @Attribute(.externalStorage) private(set) var thumbnailData: Data? = nil
    private(set) var pixelWidth: Int = 0
    private(set) var pixelHeight: Int = 0
    @Attribute(.allowsCloudEncryption) private(set) var sceneDescription: String = ""
    private(set) var sourceFingerprint: String = ""
    private(set) var providerModelId: String = ""
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    init(dayKey: String, memoryStoryId: UUID? = nil, at date: Date) {
        self.dayKey = dayKey
        self.memoryStoryId = memoryStoryId
        createdAt = date
        updatedAt = date
    }

    convenience init(copying value: DayIllustration) {
        self.init(dayKey: value.dayKey, memoryStoryId: value.memoryStoryId, at: value.createdAt)
        id = value.id
        imageData = value.imageData
        thumbnailData = value.thumbnailData
        pixelWidth = value.pixelWidth
        pixelHeight = value.pixelHeight
        sceneDescription = value.sceneDescription
        sourceFingerprint = value.sourceFingerprint
        providerModelId = value.providerModelId
        updatedAt = value.updatedAt
    }

    func replace(
        with encoded: DayPhotoEncoder.Output,
        sceneDescription: String,
        sourceFingerprint: String,
        providerModelId: String,
        at date: Date
    ) {
        imageData = encoded.imageData
        thumbnailData = encoded.thumbnailData
        pixelWidth = encoded.pixelWidth
        pixelHeight = encoded.pixelHeight
        self.sceneDescription = sceneDescription
        self.sourceFingerprint = sourceFingerprint
        self.providerModelId = providerModelId
        updatedAt = date
    }

    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 3.0 / 4.0 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

@MainActor
enum DayIllustrationRunner {
    private static let failureCountsKey = "LoreDayIllustrationFailureCounts"
    private static let generationLimit = 3
    private static let failureLimit = 3

    private struct Candidate {
        let dayKey: String
        let memoryStoryId: UUID?
        let eligibleDate: String
        var biographyKey: String { BiographyIdentity.key(dayKey: dayKey, memoryStoryId: memoryStoryId) }
    }

    @discardableResult
    static func refresh(
        generator: any DailyEntryGenerationService,
        in modelContext: ModelContext,
        now: Date = Date(),
        calendar: JournalCalendar = JournalCalendar(),
        userDefaults: UserDefaults = .standard,
        generationChanged: @MainActor (String, Bool) -> Void = { _, _ in },
        didSavePainting: @MainActor (String, PaintingRevision) -> Void = { _, _ in }
    ) async throws -> Int {
        try Task.checkCancellation()
        let todayKey = calendar.dayKey(for: now)
        let earliestDate = calendar.calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let earliestKey = calendar.dayKey(for: earliestDate)
        let entries = try modelContext.fetch(FetchDescriptor<DailyBiographyEntry>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        let entriesByKey = Dictionary(entries.map { ($0.biographyKey, $0) }, uniquingKeysWith: { latest, _ in latest })
        let illustrations = try modelContext.fetch(FetchDescriptor<DayIllustration>())
        let orphaned = illustrations.filter { entriesByKey[$0.biographyKey] == nil }
        if !orphaned.isEmpty {
            orphaned.forEach(modelContext.delete)
            try save(modelContext)
        }

        let stories = try modelContext.fetch(FetchDescriptor<Story>())
        let recordedDates = Dictionary(stories.map { ($0.id, $0.date) }, uniquingKeysWith: min)
        let eligible = entriesByKey.values.compactMap { entry -> Candidate? in
            if let memoryStoryId = entry.memoryStoryId {
                guard let recorded = recordedDates[memoryStoryId], recorded >= earliestDate, recorded <= now else {
                    return nil
                }
                return Candidate(dayKey: entry.dayKey, memoryStoryId: memoryStoryId, eligibleDate: calendar.dayKey(for: recorded))
            }
            guard entry.dayKey >= earliestKey, entry.dayKey < todayKey else { return nil }
            return Candidate(dayKey: entry.dayKey, memoryStoryId: nil, eligibleDate: entry.dayKey)
        }
        let candidates = eligible.sorted { ($0.eligibleDate, $0.biographyKey) > ($1.eligibleDate, $1.biographyKey) }
        let recentPairs = Set(candidates.compactMap { entriesByKey[$0.biographyKey].map(failureKey(for:)) })
        let storedFailures = userDefaults.dictionary(forKey: failureCountsKey) as? [String: Int] ?? [:]
        var failures = storedFailures.filter { recentPairs.contains($0.key) }
        if failures != storedFailures { userDefaults.set(failures, forKey: failureCountsKey) }

        var attempted = 0
        var written = 0
        print("[DayIllustration] today \(todayKey); eligible entries: \(candidates.count)")
        for candidate in candidates {
            guard attempted < generationLimit else { break }
            try Task.checkCancellation()

            let biographyKey = candidate.biographyKey
            var pair: String?
            do {
                guard let entry = try entry(for: candidate, in: modelContext),
                      !entry.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let fingerprint = fingerprint(for: entry)
                let key = failureKey(biographyKey: biographyKey, fingerprint: fingerprint)
                guard failures[key, default: 0] < failureLimit else {
                    print("[DayIllustration] \(biographyKey): skipped after \(failures[key, default: 0]) failures")
                    continue
                }
                guard try illustration(for: candidate, in: modelContext)?.sourceFingerprint != fingerprint else {
                    print("[DayIllustration] \(biographyKey): already painted")
                    continue
                }
                guard try entry.memoryStoryId != nil || !hasPhoto(for: entry.dayKey, in: modelContext) else {
                    print("[DayIllustration] \(biographyKey): has a photo")
                    continue
                }
                print("[DayIllustration] \(biographyKey): requesting a painting")

                let request = makeRequest(for: entry)
                pair = key
                attempted += 1
                generationChanged(biographyKey, true)
                defer { generationChanged(biographyKey, false) }
                let response = try await generator.generateDayIllustration(request)
                let encoded = try await validatedImage(from: response, for: request)
                try Task.checkCancellation()

                // The entry may have changed or been deleted while the image was being painted.
                guard let current = try self.entry(for: candidate, in: modelContext),
                      !current.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      self.fingerprint(for: current) == fingerprint else { continue }
                let existing = try illustration(for: candidate, in: modelContext)
                if existing?.sourceFingerprint != fingerprint {
                    let value = existing ?? DayIllustration(dayKey: current.dayKey, memoryStoryId: current.memoryStoryId, at: now)
                    value.replace(
                        with: encoded,
                        sceneDescription: response.scene.description,
                        sourceFingerprint: fingerprint,
                        providerModelId: response.provenance.modelId,
                        at: now
                    )
                    if existing == nil { modelContext.insert(value) }
                    try save(modelContext)
                    didSavePainting(biographyKey, value.paintingRevision)
                    written += 1
                }
                if failures.removeValue(forKey: key) != nil {
                    userDefaults.set(failures, forKey: failureCountsKey)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch LoreBackendProcessingError.cancelled {
                throw CancellationError()
            } catch let error where isServerUnconfigured(error) {
                // The server is missing its image provider; that is not this
                // day's fault, so stop without counting a failure and retry
                // on a later refresh.
                print("Day illustrations are not available on the server yet.")
                break
            } catch {
                if let pair {
                    failures[pair] = isNonRetryable(error) ? failureLimit : failures[pair, default: 0] + 1
                    userDefaults.set(failures, forKey: failureCountsKey)
                }
                print("[DayIllustration] \(biographyKey): did not complete: \(error)")
            }
        }
        return written
    }

    private static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func entry(for candidate: Candidate, in context: ModelContext) throws -> DailyBiographyEntry? {
        let dayKey = candidate.dayKey
        let memoryStoryId = candidate.memoryStoryId
        var descriptor = FetchDescriptor<DailyBiographyEntry>(
            predicate: #Predicate { $0.dayKey == dayKey && $0.memoryStoryId == memoryStoryId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func illustration(for candidate: Candidate, in context: ModelContext) throws -> DayIllustration? {
        let dayKey = candidate.dayKey
        let memoryStoryId = candidate.memoryStoryId
        var descriptor = FetchDescriptor<DayIllustration>(
            predicate: #Predicate { $0.dayKey == dayKey && $0.memoryStoryId == memoryStoryId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func hasPhoto(for dayKey: String, in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<DayPhoto>(predicate: #Predicate { $0.dayKey == dayKey })
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private static func fingerprint(for entry: DailyBiographyEntry) -> String {
        let source = "\(DayIllustrationGenerationRequest.currentPromptVersion)|\(entry.sourceFingerprint)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureKey(for entry: DailyBiographyEntry) -> String {
        failureKey(biographyKey: entry.biographyKey, fingerprint: fingerprint(for: entry))
    }

    private static func failureKey(biographyKey: String, fingerprint: String) -> String {
        "\(biographyKey)|\(fingerprint)"
    }

    private static func makeRequest(for entry: DailyBiographyEntry) -> DayIllustrationGenerationRequest {
        let prose = entry.prose.trimmingCharacters(in: .whitespacesAndNewlines)
        return DayIllustrationGenerationRequest(
            jobId: UUID(),
            dayKey: entry.dayKey,
            languageCode: Locale.current.identifier,
            title: String(decoding: entry.title.utf16.prefix(DayIllustrationGenerationRequest.maximumTitleLength), as: UTF16.self),
            prose: String(decoding: prose.utf16.prefix(DayIllustrationGenerationRequest.maximumProseLength), as: UTF16.self)
        )
    }

    private static func validatedImage(
        from response: DayIllustrationGenerationResponse,
        for request: DayIllustrationGenerationRequest
    ) async throws -> DayPhotoEncoder.Output {
        guard response.schemaVersion == request.schemaVersion,
              response.promptVersion == request.promptVersion,
              response.jobId == request.jobId,
              response.image.mediaType == "image/jpeg",
              let data = Data(base64Encoded: response.image.dataBase64),
              data.starts(with: [0xFF, 0xD8]),
              let encoded = await DayPhotoStore.encodeInBackground(data) else {
            throw LoreBackendProcessingError.invalidResponse(requestId: response.requestId)
        }
        return encoded
    }

    private static func isServerUnconfigured(_ error: Error) -> Bool {
        if case .rejected(code: "provider_policy_unverified", retryable: _, retryAfterSeconds: _) =
            error as? LoreBackendProcessingError {
            return true
        }
        return false
    }

    private static func isNonRetryable(_ error: Error) -> Bool {
        switch error as? LoreBackendProcessingError {
        case .rejected(_, false, _), .notConfigured, .invalidConfiguration, .invalidRequest, .payloadTooLarge:
            return true
        default:
            return false
        }
    }
}
