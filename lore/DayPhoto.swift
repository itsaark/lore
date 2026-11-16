import Foundation
import SwiftData
import UIKit

/// One of up to five photos a person chose for a journal day; the one at the
/// lowest `position` is the day's cover. Photos are picked by
/// the user, re-encoded on device (which drops EXIF and GPS metadata), kept in
/// the private archive, and never sent to Lore's API.
@Model
final class DayPhoto {
    private(set) var id: UUID = UUID()
    /// Matches `DailyBiographyEntry.dayKey` (`yyyy-MM-dd`).
    @Attribute(.allowsCloudEncryption) private(set) var dayKey: String = ""
    @Attribute(.externalStorage) private(set) var imageData: Data?
    @Attribute(.externalStorage) private(set) var thumbnailData: Data?
    private(set) var pixelWidth: Int = 0
    private(set) var pixelHeight: Int = 0
    /// Order within the day, starting at 0 for the cover. Photos saved before
    /// days held several default to 0, which makes them the cover.
    fileprivate(set) var position: Int = 0
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    init(dayKey: String, encoded: DayPhotoEncoder.Output, position: Int = 0, now: Date = Date()) {
        self.dayKey = dayKey
        self.position = position
        imageData = encoded.imageData
        thumbnailData = encoded.thumbnailData
        pixelWidth = encoded.pixelWidth
        pixelHeight = encoded.pixelHeight
        createdAt = now
        updatedAt = now
    }

    func replace(with encoded: DayPhotoEncoder.Output, now: Date = Date()) {
        imageData = encoded.imageData
        thumbnailData = encoded.thumbnailData
        pixelWidth = encoded.pixelWidth
        pixelHeight = encoded.pixelHeight
        updatedAt = now
    }

    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 3.0 / 4.0 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

enum DayPhotoEncoder {
    struct Output {
        let imageData: Data
        let thumbnailData: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static let maximumPixelLength: CGFloat = 2048
    static let thumbnailPixelLength: CGFloat = 360

    /// Downscales and re-encodes picked photo data. Returns nil when the data
    /// is not a decodable image.
    static func encode(_ data: Data) -> Output? {
        guard let image = UIImage(data: data) else { return nil }
        let full = resized(image, maximumPixelLength: maximumPixelLength)
        let thumbnail = resized(image, maximumPixelLength: thumbnailPixelLength)
        guard let imageData = full.jpegData(compressionQuality: 0.84),
              let thumbnailData = thumbnail.jpegData(compressionQuality: 0.78) else {
            return nil
        }
        return Output(
            imageData: imageData,
            thumbnailData: thumbnailData,
            pixelWidth: Int(full.size.width * full.scale),
            pixelHeight: Int(full.size.height * full.scale)
        )
    }

    private static func resized(_ image: UIImage, maximumPixelLength: CGFloat) -> UIImage {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maximumPixelLength ? maximumPixelLength / longest : 1
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing into a fresh context normalizes orientation and strips metadata.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

@MainActor
enum DayPhotoStore {
    /// How many photos one journal day can hold.
    static let maximumPhotosPerDay = 5

    /// The day's photos in display order; the first is the cover.
    static func photos(for dayKey: String, in context: ModelContext) -> [DayPhoto] {
        let photos = (try? context.fetch(FetchDescriptor<DayPhoto>(
            predicate: #Predicate { $0.dayKey == dayKey }
        ))) ?? []
        return photos.inDayOrder()
    }

    /// The cover photo for `dayKey`, if the day has any.
    static func photo(for dayKey: String, in context: ModelContext) -> DayPhoto? {
        photos(for: dayKey, in: context).first
    }

    /// Appends photos to the day, after any it already has. Only as many as
    /// fit under `maximumPhotosPerDay` are kept; returns the ones added.
    @discardableResult
    static func addPhotos(
        _ encoded: [DayPhotoEncoder.Output],
        for dayKey: String,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [DayPhoto] {
        let existing = photos(for: dayKey, in: context)
        let room = max(maximumPhotosPerDay - existing.count, 0)
        let nextPosition = (existing.map(\.position).max() ?? -1) + 1
        let added = encoded.prefix(room).enumerated().map { offset, output in
            // Stagger creation times so photos picked together keep their order.
            DayPhoto(
                dayKey: dayKey,
                encoded: output,
                position: nextPosition + offset,
                now: now.addingTimeInterval(Double(offset) * 0.001)
            )
        }
        added.forEach(context.insert)
        try context.save()
        return added
    }

    /// Swaps the image of one photo, keeping its place in the day.
    static func replace(_ photo: DayPhoto, with encoded: DayPhotoEncoder.Output, in context: ModelContext) throws {
        photo.replace(with: encoded)
        try context.save()
    }

    /// Deletes one photo and closes the gap it leaves in the order.
    static func remove(_ photo: DayPhoto, in context: ModelContext) throws {
        let dayKey = photo.dayKey
        context.delete(photo)
        renumber(photos(for: dayKey, in: context).filter { $0.id != photo.id })
        try context.save()
    }

    /// Moves a photo to the front so the calendar shows it for the day.
    static func makeCover(_ photo: DayPhoto, in context: ModelContext) throws {
        let others = photos(for: photo.dayKey, in: context).filter { $0.id != photo.id }
        renumber([photo] + others)
        try context.save()
    }

    static func removeAllPhotos(for dayKey: String, in context: ModelContext) throws {
        try context.delete(model: DayPhoto.self, where: #Predicate { $0.dayKey == dayKey })
        try context.save()
    }

    private static func renumber(_ ordered: [DayPhoto]) {
        for (index, photo) in ordered.enumerated() where photo.position != index {
            photo.position = index
        }
    }
}

extension Sequence where Element == DayPhoto {
    /// Display order within a day: position, then the order photos were added.
    /// Ties can appear when two devices add photos before iCloud merges them.
    func inDayOrder() -> [DayPhoto] {
        sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Each day's cover photo, keyed by day.
    func coversByDay() -> [String: DayPhoto] {
        Dictionary(grouping: self, by: \.dayKey).compactMapValues { $0.inDayOrder().first }
    }
}
