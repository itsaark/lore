import Foundation
import SwiftData
import Testing
@testable import lore

@MainActor
struct DayPhotoStoreTests {
    private let day = "2026-11-16"

    private func makeContext() throws -> ModelContext {
        ModelContext(try LoreModelContainer.make(inMemory: true))
    }

    private func output(_ tag: UInt8) -> DayPhotoEncoder.Output {
        DayPhotoEncoder.Output(imageData: Data([tag]), thumbnailData: Data([tag]), pixelWidth: 3, pixelHeight: 4)
    }

    private func tags(_ photos: [DayPhoto]) -> [UInt8] {
        photos.compactMap { $0.imageData?.first }
    }

    @Test func addsPhotosInPickedOrderAfterExistingOnes() throws {
        let context = try makeContext()
        try DayPhotoStore.addPhotos([output(1)], for: day, in: context)
        try DayPhotoStore.addPhotos([output(2), output(3)], for: day, in: context)

        let photos = DayPhotoStore.photos(for: day, in: context)
        #expect(tags(photos) == [1, 2, 3])
        #expect(photos.map(\.position) == [0, 1, 2])
        #expect(DayPhotoStore.photo(for: day, in: context)?.imageData == Data([1]))
    }

    @Test func keepsAtMostFivePhotosPerDay() throws {
        let context = try makeContext()
        try DayPhotoStore.addPhotos((1...3).map(output), for: day, in: context)
        let added = try DayPhotoStore.addPhotos((4...7).map(output), for: day, in: context)

        #expect(added.count == 2)
        #expect(tags(DayPhotoStore.photos(for: day, in: context)) == [1, 2, 3, 4, 5])
        #expect(try DayPhotoStore.addPhotos([output(9)], for: day, in: context).isEmpty)
    }

    @Test func daysKeepSeparatePhotos() throws {
        let context = try makeContext()
        try DayPhotoStore.addPhotos((1...5).map(output), for: day, in: context)
        try DayPhotoStore.addPhotos([output(6)], for: "2026-11-15", in: context)

        #expect(DayPhotoStore.photos(for: "2026-11-15", in: context).count == 1)
        let covers = try context.fetch(FetchDescriptor<DayPhoto>()).coversByDay()
        #expect(covers[day]?.imageData == Data([1]))
        #expect(covers["2026-11-15"]?.imageData == Data([6]))
    }

    @Test func makeCoverMovesPhotoToFrontAndKeepsTheRestInOrder() throws {
        let context = try makeContext()
        let photos = try DayPhotoStore.addPhotos((1...4).map(output), for: day, in: context)
        try DayPhotoStore.makeCover(photos[2], in: context)

        let ordered = DayPhotoStore.photos(for: day, in: context)
        #expect(tags(ordered) == [3, 1, 2, 4])
        #expect(ordered.map(\.position) == [0, 1, 2, 3])
    }

    @Test func removingClosesTheGapAndFreesASlot() throws {
        let context = try makeContext()
        let photos = try DayPhotoStore.addPhotos((1...5).map(output), for: day, in: context)
        try DayPhotoStore.remove(photos[0], in: context)

        let ordered = DayPhotoStore.photos(for: day, in: context)
        #expect(tags(ordered) == [2, 3, 4, 5])
        #expect(ordered.map(\.position) == [0, 1, 2, 3])
        #expect(try DayPhotoStore.addPhotos([output(6)], for: day, in: context).count == 1)
    }

    @Test func replaceKeepsThePhotosPlace() throws {
        let context = try makeContext()
        let photos = try DayPhotoStore.addPhotos((1...3).map(output), for: day, in: context)
        try DayPhotoStore.replace(photos[1], with: output(8), in: context)

        #expect(tags(DayPhotoStore.photos(for: day, in: context)) == [1, 8, 3])
    }

    @Test func photosFromBeforeMultiplePhotosStayTheCover() throws {
        let context = try makeContext()
        // A photo saved by an older build has the default position of 0.
        context.insert(DayPhoto(dayKey: day, encoded: output(1), now: Date(timeIntervalSince1970: 0)))
        try context.save()
        try DayPhotoStore.addPhotos([output(2)], for: day, in: context)

        #expect(tags(DayPhotoStore.photos(for: day, in: context)) == [1, 2])
    }
}
