import Foundation

struct UserProfile: Codable, Equatable {
    var name: String
    var hometown: String
    var birthYear: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        hometown: String,
        birthYear: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.hometown = hometown
        self.birthYear = birthYear
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum UserProfileStore {
    private static let storageKey = "UserProfile"

    static func load() -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    static func save(_ profile: UserProfile) {
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
