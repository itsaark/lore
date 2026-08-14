import Foundation

enum SpeechTranscriptionDeferralReason: String, Equatable, Sendable {
    case remoteProcessingConsentRequired
    case networkUnavailable
    case networkUnknown
}

enum SpeechTranscriptionRoute: Equatable, Sendable {
    case remote
    case deferred(reason: SpeechTranscriptionDeferralReason)

    var usesRemoteService: Bool {
        self == .remote
    }
}

enum SpeechNetworkConnection: Equatable, Sendable {
    case wifi
    case cellular
    case unavailable
    case unknown
}

struct RemoteProcessingPreferences: Equatable, Sendable {
    let hasConsent: Bool

    init(hasConsent: Bool) {
        self.hasConsent = hasConsent
    }

    init(userProfile: UserProfile) {
        self.init(hasConsent: userProfile.hasRemoteProcessingConsent)
    }
}

struct SpeechTranscriptionRoutingInput: Equatable, Sendable {
    let preferences: RemoteProcessingPreferences
    let networkConnection: SpeechNetworkConnection
}

/// Lore's MVP has one processing route. Recordings wait locally while offline,
/// then use the authenticated request-ephemeral backend when connectivity returns.
struct SpeechTranscriptionPolicy: Equatable, Sendable {
    static let production = Self()

    func route(for input: SpeechTranscriptionRoutingInput) -> SpeechTranscriptionRoute {
        guard input.preferences.hasConsent else {
            return .deferred(reason: .remoteProcessingConsentRequired)
        }

        switch input.networkConnection {
        case .wifi, .cellular:
            return .remote
        case .unavailable:
            return .deferred(reason: .networkUnavailable)
        case .unknown:
            return .deferred(reason: .networkUnknown)
        }
    }
}

struct RemoteSpeechTranscription: Equatable, Sendable {
    let transcript: String
    let provider: String
    let model: String
    let requestID: String?
    let segments: [TranscriptSourceSegment]
    let provenance: [RemoteProcessingProvenance]

    init(
        transcript: String,
        provider: String,
        model: String,
        requestID: String? = nil,
        segments: [TranscriptSourceSegment] = [],
        provenance: [RemoteProcessingProvenance] = []
    ) {
        self.transcript = transcript
        self.provider = provider
        self.model = model
        self.requestID = requestID
        self.segments = segments
        self.provenance = provenance
    }
}

protocol RemoteSpeechTranscribing: Sendable {
    func transcribe(audioFileURL: URL, localeIdentifier: String) async throws -> RemoteSpeechTranscription
}

enum RemoteSpeechTranscriptionError: Error, LocalizedError, Equatable {
    case notConfigured
    case audioFileMissing
    case audioFileUnreadable
    case audioTranscodeFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote transcription is not configured yet. The recording was kept on this iPhone for retry."
        case .audioFileMissing:
            return "Lore could not find the recorded audio to transcribe."
        case .audioFileUnreadable:
            return "Lore could not read the saved recording. Please record the story again."
        case .audioTranscodeFailed:
            return "Lore could not prepare the recording for transcription. The recording was kept on this iPhone for retry."
        case .emptyTranscript:
            return "Remote transcription returned no usable text. The recording was kept on this iPhone for retry."
        }
    }
}

struct UnavailableRemoteSpeechTranscriber: RemoteSpeechTranscribing {
    func transcribe(audioFileURL: URL, localeIdentifier: String) async throws -> RemoteSpeechTranscription {
        throw RemoteSpeechTranscriptionError.notConfigured
    }
}
