import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) var name: String = ""
    @Attribute(.allowsCloudEncryption) var hometown: String = ""
    @Attribute(.allowsCloudEncryption) var birthYear: Int = 0
    var remoteProcessingConsentedAt: Date?

    // Retained only so existing pre-remote-only stores migrate without losing
    // their prior permission state. These are not product settings anymore.
    var processingModeValue: String = "remote"
    var remoteTextProcessingConsentedAt: Date?
    var remoteAudioUploadConsentedAt: Date?
    var allowsCellularRemoteProcessing: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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
