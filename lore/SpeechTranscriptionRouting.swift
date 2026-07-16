import Foundation

enum RemoteTranscriptionReason: String, Equatable, Sendable {
    case hardwareNotValidated
    case onDeviceRecognitionUnsupported
    case localRecognizerUnavailable
}

enum SpeechTranscriptionRoute: Equatable, Sendable {
    case onDevice
    case remote(reason: RemoteTranscriptionReason)

    var usesRemoteService: Bool {
        if case .remote = self {
            return true
        }
        return false
    }
}

struct SpeechTranscriptionCapabilities: Equatable, Sendable {
    let hardwareIdentifier: String
    let osMajorVersion: Int
    let supportsOnDeviceRecognition: Bool
}

/// Routes local transcription only to hardware that has passed Lore's own quality benchmark.
/// OS availability is treated as a capability signal, never as proof of transcription quality.
struct SpeechTranscriptionPolicy: Equatable, Sendable {
    static let validatedHardwareDefaultsKey = "LoreValidatedLocalSpeechHardwareIdentifiers"

    let validatedLocalHardwareIdentifiers: Set<String>
    let minimumEligibleIPhoneHardwareGeneration: Int

    init(
        validatedLocalHardwareIdentifiers: Set<String>,
        minimumEligibleIPhoneHardwareGeneration: Int = 18
    ) {
        self.validatedLocalHardwareIdentifiers = validatedLocalHardwareIdentifiers
        self.minimumEligibleIPhoneHardwareGeneration = minimumEligibleIPhoneHardwareGeneration
    }

    static func production(userDefaults: UserDefaults = .standard) -> Self {
        let identifiers = userDefaults.stringArray(forKey: validatedHardwareDefaultsKey) ?? []
        return Self(
            validatedLocalHardwareIdentifiers: Set(identifiers),
            // Apple's iPhone18,* hardware class is the marketed iPhone 17 family. This is only
            // an eligibility gate; the on-device capability check and Lore benchmarks still apply.
            minimumEligibleIPhoneHardwareGeneration: 18
        )
    }

    func route(for capabilities: SpeechTranscriptionCapabilities) -> SpeechTranscriptionRoute {
        let isInEligibleIPhoneFamily = DeviceHardware.iPhoneIdentifierMajor(
            from: capabilities.hardwareIdentifier
        ).map { $0 >= minimumEligibleIPhoneHardwareGeneration } ?? false
        let passesValidationAllowlist = validatedLocalHardwareIdentifiers.isEmpty
            || validatedLocalHardwareIdentifiers.contains(capabilities.hardwareIdentifier)

        guard isInEligibleIPhoneFamily, passesValidationAllowlist else {
            return .remote(reason: .hardwareNotValidated)
        }

        guard capabilities.supportsOnDeviceRecognition else {
            return .remote(reason: .onDeviceRecognitionUnsupported)
        }

        return .onDevice
    }

}

enum BiographyGenerationRoute: Equatable, Sendable {
    case local
    case remote

    var usesLocalModel: Bool {
        self == .local
    }
}

struct BiographyGenerationCapabilities: Equatable, Sendable {
    let hardwareIdentifier: String
    let supportsLocalRuntime: Bool
}

/// Keeps downloadable Bonsai inference off devices outside Lore's measured hardware policy.
/// The package is linked into one App Store binary, so this runtime gate must be checked before
/// showing model controls or loading any weights.
struct BiographyGenerationPolicy: Equatable, Sendable {
    static let validatedHardwareDefaultsKey = "LoreValidatedLocalGenerationHardwareIdentifiers"

    let validatedLocalHardwareIdentifiers: Set<String>
    let minimumEligibleIPhoneHardwareGeneration: Int

    init(
        validatedLocalHardwareIdentifiers: Set<String> = [],
        minimumEligibleIPhoneHardwareGeneration: Int = 18
    ) {
        self.validatedLocalHardwareIdentifiers = validatedLocalHardwareIdentifiers
        self.minimumEligibleIPhoneHardwareGeneration = minimumEligibleIPhoneHardwareGeneration
    }

    static func production(userDefaults: UserDefaults = .standard) -> Self {
        Self(
            validatedLocalHardwareIdentifiers: Set(
                userDefaults.stringArray(forKey: validatedHardwareDefaultsKey) ?? []
            )
        )
    }

    func route(for capabilities: BiographyGenerationCapabilities) -> BiographyGenerationRoute {
        guard capabilities.supportsLocalRuntime else {
            return .remote
        }

        let identifierMajor = DeviceHardware.iPhoneIdentifierMajor(
            from: capabilities.hardwareIdentifier
        )
        let passesHardwareFloor = identifierMajor.map {
            $0 >= minimumEligibleIPhoneHardwareGeneration
        } == true
        let passesValidationAllowlist = validatedLocalHardwareIdentifiers.isEmpty
            || validatedLocalHardwareIdentifiers.contains(capabilities.hardwareIdentifier)
        return passesHardwareFloor && passesValidationAllowlist
            ? .local
            : .remote
    }
}

enum DeviceHardware {
    static func iPhoneIdentifierMajor(from identifier: String) -> Int? {
        guard identifier.hasPrefix("iPhone") else { return nil }
        let generation = identifier
            .dropFirst("iPhone".count)
            .prefix { $0.isNumber }
        return Int(generation)
    }
}

enum CurrentSpeechDevice {
    static var hardwareIdentifier: String {
#if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
#else
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
#endif
    }
}

struct RemoteSpeechTranscription: Equatable, Sendable {
    let transcript: String
    let provider: String
    let model: String
    let requestID: String?

    init(transcript: String, provider: String, model: String, requestID: String? = nil) {
        self.transcript = transcript
        self.provider = provider
        self.model = model
        self.requestID = requestID
    }
}

protocol RemoteSpeechTranscribing: Sendable {
    func transcribe(audioFileURL: URL, localeIdentifier: String) async throws -> RemoteSpeechTranscription
}

enum RemoteSpeechTranscriptionError: Error, LocalizedError, Equatable {
    case notConfigured
    case audioFileMissing
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Remote transcription is not configured yet. The recording was kept on this iPhone for retry."
        case .audioFileMissing:
            return "Lore could not find the recorded audio to transcribe."
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
