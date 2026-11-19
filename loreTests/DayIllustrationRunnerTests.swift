import Foundation
import SwiftData
import Testing
import UIKit
@testable import lore

@MainActor
struct DayIllustrationRunnerTests {
    @Test func generatesOnlyForFinishedRecentDaysWithProseAndNoPhotos() async throws {
        let fixture = try Fixture()
        fixture.addEntry("2026-11-19")
        fixture.addEntry("2026-11-18")
        fixture.addEntry("2026-11-17", prose: " \n ")
        fixture.addEntry("2026-11-16")
        fixture.addEntry("2026-11-15")
        fixture.addEntry("2026-10-19") // 30 days ago
        fixture.addEntry("2026-10-18")
        try fixture.addPhoto("2026-11-16")

        #expect(try await fixture.refresh() == 2)
        #expect(await fixture.generator.requests.map(\.dayKey) == ["2026-11-15", "2026-10-19"])
        let illustrations = try fixture.illustrations()
        #expect(Set(illustrations.map(\.dayKey)) == ["2026-11-15", "2026-10-19"])
        let illustration = try #require(illustrations.first)
        #expect(illustration.imageData?.isEmpty == false)
        #expect(illustration.thumbnailData?.isEmpty == false)
        #expect(illustration.pixelWidth == 32)
        #expect(illustration.pixelHeight == 48)
        #expect(illustration.sceneDescription == "Soft light on an open window.")
        #expect(illustration.providerModelId == "test-image-model")
    }

    @Test func memoriesShareTheRefreshLimitAndUseRecordingDateForEligibility() async throws {
        let fixture = try Fixture()
        let first = fixture.addMemory(start: "2003-01-01", recorded: "2026-11-18", prose: "A childhood scene.")
        let second = fixture.addMemory(start: "2003-01-01", recorded: "2026-11-18", prose: "Another scene that year.")
        fixture.addMemory(start: "2004-01-01", recorded: "2026-10-18", prose: "Captured too long ago.")
        fixture.addEntry("2026-11-17")
        fixture.addEntry("2026-11-16")

        #expect(try await fixture.refresh() == 3)
        let firstRequests = await fixture.generator.requests
        #expect(firstRequests.map(\.dayKey) == ["2003-01-01", "2003-01-01", "2026-11-17"])
        #expect(Set(firstRequests.prefix(2).map(\.prose)) == ["A childhood scene.", "Another scene that year."])
        #expect(Set(try fixture.illustrations().compactMap(\.memoryStoryId)) == [first.id, second.id])

        #expect(try await fixture.refresh() == 1)
        #expect(try await fixture.refresh() == 0)
        #expect(await fixture.generator.requests.last?.dayKey == "2026-11-16")
    }

    @Test func capsAttemptsAtThreeNewestFirstEvenWhenAnAttemptFails() async throws {
        let fixture = try Fixture()
        for day in ["2026-11-10", "2026-11-14", "2026-11-13", "2026-11-15"] {
            fixture.addEntry(day)
        }
        await fixture.generator.setFailure(.transportUnavailable, for: "2026-11-15")

        #expect(try await fixture.refresh() == 2)
        #expect(await fixture.generator.requests.map(\.dayKey) == ["2026-11-15", "2026-11-14", "2026-11-13"])
        #expect(Set(try fixture.illustrations().map(\.dayKey)) == ["2026-11-14", "2026-11-13"])
    }

    @Test func rewritesInPlaceOnlyWhenTheFingerprintChanges() async throws {
        let fixture = try Fixture()
        let day = "2026-11-17"
        let entry = fixture.addEntry(day, fingerprint: "first")

        #expect(try await fixture.refresh() == 1)
        let original = try #require(fixture.illustrations().first)
        let originalFingerprint = original.sourceFingerprint
        #expect(try await fixture.refresh() == 0)

        fixture.context.delete(entry)
        fixture.addEntry(day, fingerprint: "second")
        #expect(try await fixture.refresh() == 1)
        let values = try fixture.illustrations()
        #expect(values.count == 1)
        #expect(values.first?.id == original.id)
        #expect(values.first?.sourceFingerprint != originalFingerprint)
        #expect(await fixture.generator.requests.count == 2)
    }

    @Test func refusesToRetryARejectedFingerprintAndTriesTheChangedEntry() async throws {
        let fixture = try Fixture()
        let day = "2026-11-17"
        let entry = fixture.addEntry(day, fingerprint: "first")
        fixture.addEntry("2026-11-16")
        await fixture.generator.setFailure(.rejected(code: "generation_rejected", retryable: false, retryAfterSeconds: nil), for: day)

        #expect(try await fixture.refresh() == 1)
        #expect(try await fixture.refresh() == 0)
        #expect(await fixture.generator.requests.map(\.dayKey) == [day, "2026-11-16"])

        fixture.context.delete(entry)
        fixture.addEntry(day, fingerprint: "second")
        await fixture.generator.setFailure(nil, for: day)
        #expect(try await fixture.refresh() == 1)
        #expect(await fixture.generator.requests.map(\.dayKey) == [day, "2026-11-16", day])
    }

    @Test func stopsAfterThreeRetryableFailures() async throws {
        let fixture = try Fixture()
        let day = "2026-11-17"
        fixture.addEntry(day)
        await fixture.generator.setFailure(.transportUnavailable, for: day)

        for _ in 0..<4 { #expect(try await fixture.refresh() == 0) }
        #expect(await fixture.generator.requests.count == 3)
        #expect(try fixture.illustrations().isEmpty)
    }

    @Test func reportsGenerationPerKeyAndOnlyRegistersSavedPaintings() async throws {
        let fixture = try Fixture()
        let failed = "2026-11-17"
        let painted = "2026-11-16"
        fixture.addEntry(failed)
        fixture.addEntry(painted)
        try fixture.context.save()
        await fixture.generator.setFailure(.transportUnavailable, for: failed)
        var events: [String] = []
        let session = PaintingRevealSession()

        let count = try await DayIllustrationRunner.refresh(
            generator: fixture.generator,
            in: fixture.context,
            now: fixture.calendar.date(forDayKey: "2026-11-18")!,
            calendar: fixture.calendar,
            userDefaults: fixture.defaults,
            generationChanged: { key, active in events.append("\(key):\(active ? "start" : "end")") },
            didSavePainting: { key, revision in
                events.append("\(key):saved")
                session.register(revision, for: key)
            }
        )

        #expect(count == 1)
        #expect(events == ["\(failed):start", "\(failed):end", "\(painted):start", "\(painted):saved", "\(painted):end"])
        #expect(session.pendingRevision(for: failed) == nil)
        let illustration = try #require(fixture.illustrations().first)
        #expect(session.claim(illustration.paintingRevision, for: painted))
    }

    @Test func keepsPaintingsBehindPhotosAndDeletesOrphans() async throws {
        let fixture = try Fixture()
        let day = "2026-11-17"
        let entry = fixture.addEntry(day)
        let orphan = fixture.addEntry("2026-11-16")
        #expect(try await fixture.refresh() == 2)
        let keptID = try #require(fixture.illustrations().first { $0.dayKey == day }?.id)

        try fixture.addPhoto(day)
        fixture.context.delete(orphan)
        #expect(try await fixture.refresh() == 0)
        #expect(try fixture.illustrations().map(\.id) == [keptID])

        try DayPhotoStore.removeAllPhotos(for: day, in: fixture.context)
        #expect(try await fixture.refresh() == 0)
        #expect(try fixture.illustrations().map(\.id) == [keptID])

        try DailyBiographyJobRunner.deleteSupportData(containing: try #require(entry.sourceStoryIds.first), in: fixture.context)
        try fixture.context.save()
        #expect(try fixture.illustrations().isEmpty)
    }

    @Test func invalidJPEGIsNeverSaved() async throws {
        let fixture = try Fixture(jpeg: Data([0xFF, 0xD8, 0x00]))
        fixture.addEntry("2026-11-17")
        #expect(try await fixture.refresh() == 0)
        #expect(try fixture.illustrations().isEmpty)
    }

    @Test func requestContainsOnlyTheContractFieldsAndNoProfileName() async throws {
        let fixture = try Fixture()
        let name = "Private Test Name"
        fixture.context.insert(UserProfile(name: name, hometown: "Portland", birthYear: 1990))
        fixture.addEntry("2026-11-17", combinedTranscript: "My name is \(name).")
        #expect(try await fixture.refresh() == 1)

        let request = try #require(await fixture.generator.requests.first)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == [
            "schema_version", "prompt_version", "job_id", "day_key", "language_code", "title", "prose", "retention_policy"
        ])
        #expect(!String(decoding: data, as: UTF8.self).contains(name))
        #expect(json["prose"] as? String == "The window caught the afternoon light.")
        #expect((json["retention_policy"] as? [String: Any])?["mode"] as? String == "request_ephemeral")
    }

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let generator: RecordingIllustrationGenerator
        let suiteName = "DayIllustrationRunnerTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let calendar: JournalCalendar

        var context: ModelContext { container.mainContext }

        init(jpeg: Data? = nil) throws {
            container = try LoreModelContainer.make(inMemory: true)
            defaults = try #require(UserDefaults(suiteName: suiteName))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            calendar = JournalCalendar(calendar: utc)

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpegData = jpeg ?? UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48), format: format)
                .jpegData(withCompressionQuality: 0.9) { context in
                    UIColor.gray.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
                }
            generator = RecordingIllustrationGenerator(jpeg: jpegData)
        }

        deinit { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        @discardableResult
        func addEntry(
            _ day: String,
            fingerprint: String = "original",
            prose: String = "The window caught the afternoon light.",
            combinedTranscript: String = "Raw notes.",
            memoryStoryId: UUID? = nil
        ) -> DailyBiographyEntry {
            let entry = DailyBiographyEntry(
                dayKey: day,
                memoryStoryId: memoryStoryId,
                calendarDate: calendar.date(forDayKey: day)!,
                sourceStoryIds: [memoryStoryId ?? UUID()],
                sourceTranscriptArtifactIds: [UUID()],
                sourceTranscriptVersionIds: [UUID()],
                sourceFingerprint: fingerprint,
                timezoneIdentifiers: ["UTC"],
                title: "Afternoon light",
                prose: prose,
                combinedTranscript: combinedTranscript,
                provider: illustrationTestProvenance(providerID: "fireworks", alias: "day-entry-v1")
            )
            context.insert(entry)
            return entry
        }

        @discardableResult
        func addMemory(start: String, recorded: String, prose: String) -> Story {
            let note = Story(
                text: prose, date: calendar.date(forDayKey: recorded)!, duration: 10,
                rememberedTime: RememberedTime(
                    precision: .year, startDate: start, endDate: String(start.prefix(4)) + "-12-31"
                )
            )
            context.insert(note)
            addEntry(start, prose: prose, memoryStoryId: note.id)
            return note
        }

        func addPhoto(_ day: String) throws {
            let encoded = DayPhotoEncoder.Output(imageData: Data([1]), thumbnailData: Data([1]), pixelWidth: 3, pixelHeight: 4)
            try DayPhotoStore.addPhotos([encoded], for: day, in: context)
        }

        func refresh() async throws -> Int {
            try context.save()
            return try await DayIllustrationRunner.refresh(
                generator: generator,
                in: context,
                now: calendar.date(forDayKey: "2026-11-18")!,
                calendar: calendar,
                userDefaults: defaults
            )
        }

        func illustrations() throws -> [DayIllustration] {
            try context.fetch(FetchDescriptor<DayIllustration>())
        }
    }
}

private actor RecordingIllustrationGenerator: DailyEntryGenerationService {
    private let jpeg: Data
    private var failures: [String: LoreBackendProcessingError] = [:]
    private(set) var requests: [DayIllustrationGenerationRequest] = []

    init(jpeg: Data) { self.jpeg = jpeg }

    func setFailure(_ failure: LoreBackendProcessingError?, for dayKey: String) {
        failures[dayKey] = failure
    }

    func generateDailyEntry(_ request: DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.notConfigured
    }

    func generateDayIllustration(_ request: DayIllustrationGenerationRequest) async throws -> DayIllustrationGenerationResponse {
        requests.append(request)
        if let failure = failures[request.dayKey] { throw failure }
        return DayIllustrationGenerationResponse(
            schemaVersion: request.schemaVersion,
            promptVersion: request.promptVersion,
            jobId: request.jobId,
            requestId: "illustration-test",
            image: .init(mediaType: "image/jpeg", dataBase64: jpeg.base64EncodedString(), pixelWidth: 32, pixelHeight: 48),
            scene: .init(description: "Soft light on an open window."),
            sceneProvenance: illustrationTestProvenance(providerID: "fireworks", alias: "day-scene-v1"),
            provenance: illustrationTestProvenance(providerID: "openai", alias: "day-illustration-v1")
        )
    }
}

private func illustrationTestProvenance(providerID: String, alias: String) -> RemoteProcessingProvenance {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    return RemoteProcessingProvenance(
        providerId: providerID,
        modelAlias: alias,
        modelId: providerID == "openai" ? "test-image-model" : "test-text-model",
        modelPolicyVersion: "test-policy",
        providerRequestId: nil,
        processedAt: date,
        processingDurationMilliseconds: 25,
        retentionAttestation: .init(mode: .zeroDataRetention, maximumRetentionSeconds: 0, policyVersion: "test-policy", attestedAt: date)
    )
}
