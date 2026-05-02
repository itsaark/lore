import Foundation
import SwiftData

struct MemoryGraphPersistenceSummary: Equatable {
    var lifeEvents: Int
    var people: Int
    var places: Int
    var themes: Int
}

enum MemoryGraphServiceError: Error, LocalizedError {
    case invalidExtractionJSON

    var errorDescription: String? {
        switch self {
        case .invalidExtractionJSON:
            return "Lore could not read the local memory graph extraction."
        }
    }
}

enum MemoryGraphService {
    static func parseExtractionJSON(_ json: String) throws -> MemoryGraphExtractionResult {
        let payload = extractJSONObject(from: json)
        guard let data = payload.data(using: .utf8) else {
            throw MemoryGraphServiceError.invalidExtractionJSON
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(MemoryGraphExtractionResult.self, from: data)
        } catch {
            throw MemoryGraphServiceError.invalidExtractionJSON
        }
    }

    @discardableResult
    static func persistExtractionJSON(
        _ json: String,
        for story: Story,
        in modelContext: ModelContext
    ) throws -> MemoryGraphPersistenceSummary {
        let extraction = try parseExtractionJSON(json)
        return try persist(extraction, for: story, in: modelContext)
    }

    @discardableResult
    static func persist(
        _ extraction: MemoryGraphExtractionResult,
        for story: Story,
        in modelContext: ModelContext
    ) throws -> MemoryGraphPersistenceSummary {
        let now = Date()
        let lifeEvents = try modelContext.fetch(FetchDescriptor<LifeEvent>())
        let people = try modelContext.fetch(FetchDescriptor<Person>())
        let places = try modelContext.fetch(FetchDescriptor<Place>())
        let themes = try modelContext.fetch(FetchDescriptor<Theme>())

        for candidate in extraction.lifeEvents {
            guard !normalized(candidate.title).isEmpty else { continue }
            let sourceStoryIds = sourceStoryIds(from: candidate.sourceStoryIds, fallback: story.id)

            if let existing = lifeEvents.first(where: { normalized($0.title) == normalized(candidate.title) }) {
                merge(candidate, into: existing, sourceStoryIds: sourceStoryIds, updatedAt: now)
            } else {
                modelContext.insert(LifeEvent(
                    title: candidate.title,
                    summary: candidate.summary,
                    eventDateKind: candidate.eventDateKind,
                    eventStartDate: candidate.eventStartDate,
                    eventEndDate: candidate.eventEndDate,
                    approximateLabel: candidate.approximateLabel,
                    confidence: candidate.confidence,
                    sourceStoryIds: sourceStoryIds,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        for candidate in extraction.people {
            guard !normalized(candidate.displayName).isEmpty else { continue }
            let sourceStoryIds = sourceStoryIds(from: candidate.sourceStoryIds, fallback: story.id)

            if let existing = people.first(where: { person in
                normalized(person.displayName) == normalized(candidate.displayName)
                    || person.aliases.map(normalized).contains(normalized(candidate.displayName))
            }) {
                merge(candidate, into: existing, sourceStoryIds: sourceStoryIds, updatedAt: now)
            } else {
                modelContext.insert(Person(
                    displayName: candidate.displayName,
                    aliases: candidate.aliases,
                    relationshipToUser: candidate.relationshipToUser,
                    summary: candidate.summary,
                    confidence: candidate.confidence,
                    sourceStoryIds: sourceStoryIds,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        for candidate in extraction.places {
            guard !normalized(candidate.displayName).isEmpty else { continue }
            let sourceStoryIds = sourceStoryIds(from: candidate.sourceStoryIds, fallback: story.id)

            if let existing = places.first(where: { normalized($0.displayName) == normalized(candidate.displayName) }) {
                merge(candidate, into: existing, sourceStoryIds: sourceStoryIds, updatedAt: now)
            } else {
                modelContext.insert(Place(
                    displayName: candidate.displayName,
                    placeKind: candidate.placeKind,
                    locationHint: candidate.locationHint,
                    summary: candidate.summary,
                    confidence: candidate.confidence,
                    sourceStoryIds: sourceStoryIds,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        for candidate in extraction.themes {
            guard !normalized(candidate.name).isEmpty else { continue }
            let sourceStoryIds = sourceStoryIds(from: candidate.sourceStoryIds, fallback: story.id)

            if let existing = themes.first(where: { normalized($0.name) == normalized(candidate.name) }) {
                merge(candidate, into: existing, sourceStoryIds: sourceStoryIds, updatedAt: now)
            } else {
                modelContext.insert(Theme(
                    name: candidate.name,
                    summary: candidate.summary,
                    confidence: candidate.confidence,
                    sourceStoryIds: sourceStoryIds,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        try modelContext.save()

        return MemoryGraphPersistenceSummary(
            lifeEvents: extraction.lifeEvents.count,
            people: extraction.people.count,
            places: extraction.places.count,
            themes: extraction.themes.count
        )
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let startIndex = text.firstIndex(of: "{"),
              let endIndex = text.lastIndex(of: "}"),
              startIndex <= endIndex else {
            return text
        }

        return String(text[startIndex...endIndex])
    }

    private static func merge(
        _ candidate: LifeEventCandidate,
        into event: LifeEvent,
        sourceStoryIds: [UUID],
        updatedAt: Date
    ) {
        if candidate.confidence >= event.confidence {
            if !candidate.summary.isEmpty {
                event.summary = candidate.summary
            }
            event.eventDateKind = candidate.eventDateKind.rawValue
            event.eventStartDate = candidate.eventStartDate
            event.eventEndDate = candidate.eventEndDate
            event.approximateLabel = candidate.approximateLabel
        }

        event.confidence = max(event.confidence, candidate.confidence)
        event.sourceStoryIds = union(event.sourceStoryIds, sourceStoryIds)
        event.updatedAt = updatedAt
    }

    private static func merge(
        _ candidate: PersonCandidate,
        into person: Person,
        sourceStoryIds: [UUID],
        updatedAt: Date
    ) {
        person.aliases = union(person.aliases, candidate.aliases)
        if person.relationshipToUser == nil {
            person.relationshipToUser = candidate.relationshipToUser
        }
        if candidate.confidence >= person.confidence, !candidate.summary.isEmpty {
            person.summary = candidate.summary
        }
        person.confidence = max(person.confidence, candidate.confidence)
        person.sourceStoryIds = union(person.sourceStoryIds, sourceStoryIds)
        person.updatedAt = updatedAt
    }

    private static func merge(
        _ candidate: PlaceCandidate,
        into place: Place,
        sourceStoryIds: [UUID],
        updatedAt: Date
    ) {
        if place.placeKind == nil {
            place.placeKind = candidate.placeKind
        }
        if place.locationHint == nil {
            place.locationHint = candidate.locationHint
        }
        if candidate.confidence >= place.confidence, !candidate.summary.isEmpty {
            place.summary = candidate.summary
        }
        place.confidence = max(place.confidence, candidate.confidence)
        place.sourceStoryIds = union(place.sourceStoryIds, sourceStoryIds)
        place.updatedAt = updatedAt
    }

    private static func merge(
        _ candidate: ThemeCandidate,
        into theme: Theme,
        sourceStoryIds: [UUID],
        updatedAt: Date
    ) {
        if candidate.confidence >= theme.confidence, !candidate.summary.isEmpty {
            theme.summary = candidate.summary
        }
        theme.confidence = max(theme.confidence, candidate.confidence)
        theme.sourceStoryIds = union(theme.sourceStoryIds, sourceStoryIds)
        theme.updatedAt = updatedAt
    }

    private static func sourceStoryIds(from candidateStoryIds: [UUID], fallback storyId: UUID) -> [UUID] {
        union(candidateStoryIds, [storyId])
    }

    private static func union(_ left: [UUID], _ right: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []

        for id in left + right where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }

        return result
    }

    private static func union(_ left: [String], _ right: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in left + right {
            let key = normalized(value)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(value)
        }

        return result
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
