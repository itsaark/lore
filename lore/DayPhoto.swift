import Foundation
import SwiftData
import UIKit

/// The single photo a person chose for one journal day. Photos are picked by
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
    private(set) var createdAt: Date = Date()
    private(set) var updatedAt: Date = Date()

    init(dayKey: String, encoded: DayPhotoEncoder.Output, now: Date = Date()) {
        self.dayKey = dayKey
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
    static func photo(for dayKey: String, in context: ModelContext) -> DayPhoto? {
        var descriptor = FetchDescriptor<DayPhoto>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Sets or replaces the one photo for `dayKey`. Duplicate rows that can
    /// appear after an iCloud merge are collapsed to the newest.
    @discardableResult
    static func setPhoto(_ data: Data, for dayKey: String, in context: ModelContext) throws -> DayPhoto? {
        guard let encoded = DayPhotoEncoder.encode(data) else { return nil }
        let existing = try context.fetch(FetchDescriptor<DayPhoto>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        let photo: DayPhoto
        if let newest = existing.first {
            newest.replace(with: encoded)
            existing.dropFirst().forEach(context.delete)
            photo = newest
        } else {
            photo = DayPhoto(dayKey: dayKey, encoded: encoded)
            context.insert(photo)
        }
        try context.save()
        return photo
    }

    static func removePhoto(for dayKey: String, in context: ModelContext) throws {
        try context.delete(model: DayPhoto.self, where: #Predicate { $0.dayKey == dayKey })
        try context.save()
    }
}
