import Foundation

enum SpeechTranscriptionDeferralReason: String, Equatable, Sendable {
    case remoteProcessingConsentRequired
    case networkUnavailable
    case networkUnknown
}

enum SpeechTranscriptionRoute: Equatable, Sendable {
    /// Fluid Speech Mini on this iPhone. Needs no network and no remote
    /// processing consent; nothing leaves the device.
    case onDevice
    case remote
    case deferred(reason: SpeechTranscriptionDeferralReason)

    var usesRemoteService: Bool {
        self == .remote
    }

    /// Whether a new recording can be captured and transcribed right now.
    var allowsCapture: Bool {
        switch self {
        case .onDevice, .remote:
            return true
        case .deferred:
            return false
        }
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
    /// Normalized codes from `SpokenLanguageSupport.effectiveLanguageCodes`.
    let spokenLanguageCodes: [String]
    let isOnDeviceModelReady: Bool

    init(
        preferences: RemoteProcessingPreferences,
        networkConnection: SpeechNetworkConnection,
        spokenLanguageCodes: [String] = [],
        isOnDeviceModelReady: Bool = false
    ) {
        self.preferences = preferences
        self.networkConnection = networkConnection
        self.spokenLanguageCodes = spokenLanguageCodes
        self.isOnDeviceModelReady = isOnDeviceModelReady
    }
}

/// Chooses where a new recording is transcribed.
///
/// On device comes first: when every language the person speaks is supported
/// and the model is installed, transcription runs locally, offline and
/// without remote-processing consent, because no audio or text leaves the
/// iPhone. Consent still gates every remote step (the remote fallback and the
/// later journal entry), which enforce it themselves.
///
/// Otherwise recordings use the authenticated request-ephemeral backend, and
/// wait locally while offline or before consent.
struct SpeechTranscriptionPolicy: Equatable, Sendable {
    static let production = Self()

    func route(for input: SpeechTranscriptionRoutingInput) -> SpeechTranscriptionRoute {
        if input.isOnDeviceModelReady,
           SpokenLanguageSupport.allowsOnDeviceTranscription(for: input.spokenLanguageCodes) {
            return .onDevice
        }

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
