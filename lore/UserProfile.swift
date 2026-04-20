import Foundation
import SwiftData

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var hometown: String
    var birthYear: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        hometown: String,
        birthYear: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hometown = hometown
        self.birthYear = birthYear
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension UserProfile: Equatable {
    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.id == rhs.id
    }
}
