import Foundation
import SwiftData

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var hometown: String
    var birthYear: Int
    var remoteProcessingConsentedAt: Date?

    // Retained only so existing pre-remote-only stores migrate without losing
    // their prior permission state. These are not product settings anymore.
    var processingModeValue: String = "remote"
    var remoteTextProcessingConsentedAt: Date?
    var remoteAudioUploadConsentedAt: Date?
    var allowsCellularRemoteProcessing: Bool = true
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        hometown: String,
        birthYear: Int,
        remoteProcessingConsentedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hometown = hometown
        self.birthYear = birthYear
        self.remoteProcessingConsentedAt = remoteProcessingConsentedAt
        self.remoteTextProcessingConsentedAt = nil
        self.remoteAudioUploadConsentedAt = nil
        self.allowsCellularRemoteProcessing = true
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var hasRemoteProcessingConsent: Bool {
        remoteProcessingConsentedAt != nil
            || (remoteTextProcessingConsentedAt != nil && remoteAudioUploadConsentedAt != nil)
    }

    func grantRemoteProcessingConsent(at date: Date = Date()) {
        remoteProcessingConsentedAt = date
        processingModeValue = "remote"
        allowsCellularRemoteProcessing = true
        updatedAt = date
    }

    func revokeRemoteProcessingConsent(at date: Date = Date()) {
        remoteProcessingConsentedAt = nil
        remoteTextProcessingConsentedAt = nil
        remoteAudioUploadConsentedAt = nil
        updatedAt = date
    }
}

extension UserProfile: Equatable {
    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.id == rhs.id
    }
}
