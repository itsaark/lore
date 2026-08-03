import Foundation
import SwiftData

enum LoreProcessingMode: String, Codable, CaseIterable, Sendable {
    case deviceOnly
    case adaptive

    var title: String {
        switch self {
        case .deviceOnly:
            return "Device Only"
        case .adaptive:
            return "Adaptive"
        }
    }
}

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var hometown: String
    var birthYear: Int
    var processingModeValue: String = LoreProcessingMode.deviceOnly.rawValue
    var remoteTextProcessingConsentedAt: Date?
    var remoteAudioUploadConsentedAt: Date?
    var allowsCellularRemoteProcessing: Bool = false
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        hometown: String,
        birthYear: Int,
        processingMode: LoreProcessingMode = .deviceOnly,
        remoteTextProcessingConsentedAt: Date? = nil,
        remoteAudioUploadConsentedAt: Date? = nil,
        allowsCellularRemoteProcessing: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hometown = hometown
        self.birthYear = birthYear
        self.processingModeValue = processingMode.rawValue
        self.remoteTextProcessingConsentedAt = remoteTextProcessingConsentedAt
        self.remoteAudioUploadConsentedAt = remoteAudioUploadConsentedAt
        self.allowsCellularRemoteProcessing = allowsCellularRemoteProcessing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var processingMode: LoreProcessingMode {
        get { LoreProcessingMode(rawValue: processingModeValue) ?? .deviceOnly }
        set {
            processingModeValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var hasRemoteTextProcessingConsent: Bool {
        remoteTextProcessingConsentedAt != nil
    }

    var hasRemoteAudioUploadConsent: Bool {
        remoteAudioUploadConsentedAt != nil
    }

    func setRemoteTextProcessingConsent(_ isGranted: Bool, at date: Date = Date()) {
        remoteTextProcessingConsentedAt = isGranted ? date : nil
        if !isGranted {
            // Audio cannot be uploaded when the broader remote-processing disclosure is revoked.
            remoteAudioUploadConsentedAt = nil
        }
        updatedAt = date
    }

    func setRemoteAudioUploadConsent(_ isGranted: Bool, at date: Date = Date()) {
        // Audio consent is intentionally separate and cannot imply text-processing consent.
        remoteAudioUploadConsentedAt = isGranted && hasRemoteTextProcessingConsent ? date : nil
        updatedAt = date
    }
}

extension UserProfile: Equatable {
    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.id == rhs.id
    }
}
