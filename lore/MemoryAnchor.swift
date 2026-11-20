import Foundation
import SwiftData

enum MemoryAnchor: Decodable, Equatable, Sendable {
    enum LifeStage: String, Decodable, CaseIterable, Sendable {
        // The order matches the named periods in LifeDial.draftPeriods.
        case earlyChildhood = "early_childhood"
        case schoolYears = "school_years"
        case teenageYears = "teenage_years"
        case collegeYears = "college_years"
        case firstJobs = "first_jobs"
    }

    case none
    case year(start: Int, end: Int)
    case yearsAgo(min: Int, max: Int)
    case age(start: Int, end: Int)
    case lifeStage(LifeStage)

    private enum Kind: String, Decodable {
        case none, year, age
        case yearsAgo = "years_ago"
        case lifeStage = "life_stage"
    }

    private enum CodingKeys: String, CodingKey {
        case kind, startYear, endYear, minYears, maxYears, startAge, endAge, stage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .year:
            self = .year(start: try values.decode(Int.self, forKey: .startYear),
                         end: try values.decode(Int.self, forKey: .endYear))
        case .yearsAgo:
            self = .yearsAgo(min: try values.decode(Int.self, forKey: .minYears),
                             max: try values.decode(Int.self, forKey: .maxYears))
        case .age:
            self = .age(start: try values.decode(Int.self, forKey: .startAge),
                        end: try values.decode(Int.self, forKey: .endAge))
        case .lifeStage:
            self = .lifeStage(try values.decode(LifeStage.self, forKey: .stage))
        }
    }
}

enum MemoryAnchorResolver {
    struct Resolution: Equatable, Sendable {
        let time: RememberedTime
        let isPrivate: Bool
    }

    static func resolve(_ anchor: MemoryAnchor, recordedDay: String, birthYear: Int) -> Resolution? {
        guard let capturedYear = year(of: recordedDay) else { return nil }
        let start: Int
        let end: Int
        let isPrivate: Bool
        switch anchor {
        case .none:
            return nil
        case let .year(first, last):
            (start, end, isPrivate) = (first, last, false)
        case let .yearsAgo(minimum, maximum):
            guard minimum >= 0, minimum <= maximum, maximum < capturedYear else { return nil }
            (start, end, isPrivate) = (capturedYear - maximum, capturedYear - minimum, false)
        case let .age(first, last):
            guard (1...capturedYear).contains(birthYear),
                  first >= 0, first <= last, last < capturedYear - birthYear else { return nil }
            (start, end, isPrivate) = (birthYear + first, birthYear + last + 1, true)
        case let .lifeStage(stage):
            let periods = LifeDial.draftPeriods(birthYear: birthYear, through: capturedYear)
            guard let index = MemoryAnchor.LifeStage.allCases.firstIndex(of: stage),
                  periods.indices.contains(index) else { return nil }
            (start, end, isPrivate) = (periods[index].startYear, periods[index].endYear, true)
        }
        guard start >= max(1, birthYear), start <= end, end <= capturedYear else { return nil }
        let precision: RememberedTime.Precision = start == end && !isPrivate ? .year : .period
        let time = range(from: start, through: end, precision: precision)
        guard time.endDate <= recordedDay else { return nil }
        return Resolution(time: time, isPrivate: isPrivate)
    }

    static func year(of day: String) -> Int? {
        guard day.utf8.count == 10, let year = Int(day.prefix(4)), (1...9999).contains(year) else { return nil }
        return year
    }

    static func range(from start: Int, through end: Int, precision: RememberedTime.Precision) -> RememberedTime {
        RememberedTime(
            precision: precision,
            startDate: String(format: "%04d-01-01", start),
            endDate: String(format: "%04d-12-31", end)
        )
    }
}

enum MemoryTimeChoice: Equatable, Sendable {
    case today
    case period(LifeDial.Period)
    case year(Int)

    var isPrivate: Bool {
        if case .period = self { return true }
        return false
    }

    func rememberedTime(recordedDay: String) -> RememberedTime? {
        let range: RememberedTime
        switch self {
        case .today:
            return nil
        case let .period(period):
            range = MemoryAnchorResolver.range(from: period.startYear, through: period.endYear, precision: .period)
        case let .year(year):
            range = MemoryAnchorResolver.range(from: year, through: year, precision: .year)
        }
        guard range.startDate <= recordedDay else { return nil }
        return RememberedTime(precision: range.precision, startDate: range.startDate, endDate: min(range.endDate, recordedDay))
    }
}

@MainActor
enum MemoryAnchorInference {
    private static var inFlightStoryIDs: Set<UUID> = []

    /// Only new captures carry a pending marker. Either path that delivers a
    /// transcript leaves the immutable artifact here for day-story recovery.
    static func finishPending(
        in context: ModelContext,
        profile: UserProfile,
        backend: any LoreBackendProcessingClient,
        timeout: Duration = .seconds(15),
        isPermitted: @MainActor () -> Bool
    ) async throws {
        let pending = try context.fetch(FetchDescriptor<Story>())
            .filter { $0.memoryAnchorState == .pending }
            .sorted { $0.date < $1.date }
        guard !pending.isEmpty else { return }
        let artifacts = try context.fetch(FetchDescriptor<TranscriptArtifact>())
            .filter { $0.source == .onDevice || $0.source == .remoteProvider }
        let metadata = try context.fetch(FetchDescriptor<StoryMetadata>())

        for story in pending where story.modelContext != nil && !story.isDeleted {
            let storyID = story.id
            guard story.memoryAnchorState == .pending, inFlightStoryIDs.insert(storyID).inserted else { continue }
            defer { inFlightStoryIDs.remove(storyID) }
            let anchor: MemoryAnchor?
            let recordedDay: String
            if story.rememberedTime != nil || story.rememberedTimeSource == .user || story.sourceKind != .note {
                anchor = nil
                recordedDay = ""
            } else {
                guard let artifact = artifacts.first(where: { $0.storyId == storyID }) else { continue }
                let captureMetadata = metadata.first { $0.id == story.metadataId }
                recordedDay = JournalCalendar.recordedDayKey(for: story.date, timezone: captureMetadata?.timezone)
                let transcript = artifact.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty, !story.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   story.metadataId == nil || captureMetadata != nil,
                   isPermitted(), !Task.isCancelled {
                    // The note UUID survives relaunch and sync. Retries after a
                    // crash use the same route-scoped idempotency key and input.
                    let request = MemoryAnchorRequest(
                        jobId: storyID,
                        capturedLocalDate: recordedDay,
                        languageCode: artifact.languageCode ?? Locale.current.identifier,
                        transcript: transcript
                    )
                    anchor = await infer(request, backend: backend, timeout: timeout)
                } else {
                    anchor = nil
                }
            }
            guard story.modelContext != nil, !story.isDeleted, story.memoryAnchorState == .pending else { continue }
            let now = Date()
            if let anchor, !Task.isCancelled, isPermitted(), story.rememberedTime == nil,
               story.rememberedTimeSource != .user,
               let resolved = MemoryAnchorResolver.resolve(anchor, recordedDay: recordedDay, birthYear: profile.birthYear) {
                story.rememberedTime = resolved.time
                story.rememberedTimeSource = .inferred
                story.rememberedTimeIsPrivate = resolved.isPrivate
                story.rememberedTimeUpdatedAt = now
            }
            story.memoryAnchorState = .done
            story.updatedAt = now
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private nonisolated static func infer(
        _ request: MemoryAnchorRequest,
        backend: any LoreBackendProcessingClient,
        timeout: Duration
    ) async -> MemoryAnchor? {
        // A hard deadline includes authentication and connectivity waits.
        // Cancelling the losing task does not delay local filing.
        let (results, continuation) = AsyncStream<MemoryAnchor?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let lookup = Task {
            let response = try? await backend.inferMemoryAnchor(request)
            continuation.yield(response?.anchor)
            continuation.finish()
        }
        let deadline = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            lookup.cancel()
            deadline.cancel()
        }
        for await result in results { return result }
        return nil
    }
}
