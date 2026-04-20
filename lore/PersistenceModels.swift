import Foundation
import SwiftData

@Model
final class AudioAsset {
    @Attribute(.unique) var id: UUID
    var fileURL: String
    var createdAt: Date
    var expiresAt: Date
    var duration: TimeInterval
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        fileURL: String,
        createdAt: Date = Date(),
        expiresAt: Date,
        duration: TimeInterval,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.duration = duration
        self.isDeleted = isDeleted
    }
}
@Model
final class StoryMetadata {
    @Attribute(.unique) var id: UUID
    var captureDate: Date
    var timezone: String
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    var weatherSummary: String?
    var temperature: Double?
    var weatherSource: String?
    var permissionSnapshot: String?

    init(
        id: UUID = UUID(),
        captureDate: Date,
        timezone: String = TimeZone.current.identifier,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weatherSummary: String? = nil,
        temperature: Double? = nil,
        weatherSource: String? = nil,
        permissionSnapshot: String? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.timezone = timezone
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.weatherSummary = weatherSummary
        self.temperature = temperature
        self.weatherSource = weatherSource
        self.permissionSnapshot = permissionSnapshot
    }
}

@Model
final class BiographyFragment {
    @Attribute(.unique) var id: UUID
    var storyId: UUID
    var lifeEventIds: [UUID]
    var chapterId: UUID?
    var prose: String
    var style: String
    var modelName: String
    var modelVersion: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        storyId: UUID,
        lifeEventIds: [UUID] = [],
        chapterId: UUID? = nil,
        prose: String,
        style: String,
        modelName: String,
        modelVersion: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.storyId = storyId
        self.lifeEventIds = lifeEventIds
        self.chapterId = chapterId
        self.prose = prose
        self.style = style
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
