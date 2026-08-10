import CryptoKit
import DeviceCheck
import Foundation
import Security

protocol LoreBackendAuthorizing: Sendable {
    func authorizationHeaderValue() async throws -> String
    func invalidateSession() async
}

extension LoreBackendAuthorizing {
    func invalidateSession() async {}
}

enum LoreAppAttestError: Error, LocalizedError, Equatable {
    case unsupported
    case keyStorageFailed
    case invalidKey
    case invalidInput
    case serverUnavailable
    case unknownSystemFailure
    case invalidChallenge
    case invalidResponse
    case rateLimited(retryAfterSeconds: Int?)
    case rejected(code: String, retryable: Bool, retryAfterSeconds: Int?)
    case unavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "This device cannot establish a secure Lore session."
        case .keyStorageFailed:
            "Lore could not secure this device's app identity."
        case .invalidKey:
            "Lore's secure app identity is no longer valid."
        case .invalidInput:
            "Lore could not prepare a valid secure session request."
        case .serverUnavailable:
            "Apple's secure app verification service is temporarily unavailable."
        case .unknownSystemFailure:
            "This iPhone could not complete secure app verification."
        case .invalidChallenge, .invalidResponse:
            "Lore's secure session service returned an invalid response."
        case .rateLimited:
            "Lore's secure session service is busy."
        case .rejected:
            "Lore's secure session request was rejected."
        case .unavailable:
            "Lore's secure session service is temporarily unavailable."
        case .cancelled:
            "Lore's secure session request was cancelled."
        }
    }
}

protocol LoreAppAttestServicing: Sendable {
    func isSupported() async -> Bool
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

actor LoreAppleAppAttestService: LoreAppAttestServicing {
    private let service = DCAppAttestService.shared

    func isSupported() -> Bool {
        service.isSupported
    }

    func generateKey() async throws -> String {
        do {
            return try await service.generateKey()
        } catch {
            throw Self.map(error)
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await service.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> LoreAppAttestError {
        if error is CancellationError {
            return .cancelled
        }
        let value = error as NSError
        guard value.domain == DCErrorDomain else {
            return .unavailable
        }
        switch value.code {
        case 0:
            return .unknownSystemFailure
        case 1:
            return .unsupported
        case 2:
            return .invalidInput
        case 3:
            // DCErrorInvalidKey. Keep this explicit because DeviceCheck has
            // used both NSError and Swift-struct overlays across SDK releases.
            return .invalidKey
        case 4:
            return .serverUnavailable
        default:
            return .unavailable
        }
    }
}

protocol LoreAppAttestKeyStoring: Sendable {
    func loadKeyId() async throws -> String?
    func saveKeyId(_ keyId: String) async throws
    func deleteKeyId() async throws
    func loadPendingEnrollment() async throws -> LoreAppAttestPendingEnrollment?
    func savePendingEnrollment(_ enrollment: LoreAppAttestPendingEnrollment) async throws
    func deletePendingEnrollment() async throws
}

struct LoreAppAttestPendingEnrollment: Codable, Equatable, Sendable {
    let keyId: String
    let challenge: LoreAppAttestChallenge
    var attestationObject: Data?
}

actor LoreKeychainAppAttestKeyStore: LoreAppAttestKeyStoring {
    private let service: String
    private let keyIdAccount = "app-attest-key-id"
    private let pendingEnrollmentAccount = "app-attest-pending-enrollment"

    init(service: String = "cascadianpines.lore.app-attest") {
        self.service = service
    }

    func loadKeyId() throws -> String? {
        guard let data = try loadData(account: keyIdAccount) else { return nil }
        guard let keyId = String(data: data, encoding: .utf8), !keyId.isEmpty else {
            throw LoreAppAttestError.keyStorageFailed
        }
        return keyId
    }

    func saveKeyId(_ keyId: String) throws {
        guard
            !keyId.isEmpty,
            !keyId.contains("\n"),
            !keyId.contains("\r"),
            let data = keyId.data(using: .utf8)
        else {
            throw LoreAppAttestError.keyStorageFailed
        }
        try saveData(data, account: keyIdAccount)
    }

    func deleteKeyId() throws {
        try deleteData(account: keyIdAccount)
    }

    func loadPendingEnrollment() throws -> LoreAppAttestPendingEnrollment? {
        guard let data = try loadData(account: pendingEnrollmentAccount) else { return nil }
        do {
            return try JSONDecoder().decode(LoreAppAttestPendingEnrollment.self, from: data)
        } catch {
            throw LoreAppAttestError.keyStorageFailed
        }
    }

    func savePendingEnrollment(_ enrollment: LoreAppAttestPendingEnrollment) throws {
        do {
            try saveData(JSONEncoder().encode(enrollment), account: pendingEnrollmentAccount)
        } catch let error as LoreAppAttestError {
            throw error
        } catch {
            throw LoreAppAttestError.keyStorageFailed
        }
    }

    func deletePendingEnrollment() throws {
        try deleteData(account: pendingEnrollmentAccount)
    }

    private func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard
            status == errSecSuccess,
            let data = result as? Data
        else {
            throw LoreAppAttestError.keyStorageFailed
        }
        return data
    }

    private func saveData(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LoreAppAttestError.keyStorageFailed
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw LoreAppAttestError.keyStorageFailed
        }
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LoreAppAttestError.keyStorageFailed
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum LoreAppAttestChallengePurpose: String, Codable, Sendable {
    case attestation
    case assertion
}

struct LoreAppAttestChallenge: Codable, Equatable, Sendable {
    let schemaVersion: String
    let challengeId: String
    let challenge: String
    let purpose: LoreAppAttestChallengePurpose
    let expiresAt: Date
}

struct LoreAppAttestSession: Codable, Equatable, Sendable {
    let schemaVersion: String
    let tokenType: String
    let sessionToken: String
    let expiresAt: Date
}

protocol LoreAppAttestAPIClient: Sendable {
    func challenge(
        purpose: LoreAppAttestChallengePurpose,
        keyId: String?
    ) async throws -> LoreAppAttestChallenge

    func submitAttestation(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        attestationObject: Data
    ) async throws -> LoreAppAttestSession

    func submitAssertion(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        assertion: Data,
        clientData: Data
    ) async throws -> LoreAppAttestSession
}

struct LoreAppAttestHTTPAPIClient: LoreAppAttestAPIClient, Sendable {
    private static let schemaVersion = "1.0"

    let baseURL: URL
    let transport: LoreBackendHTTPTransport
    let requestTimeout: TimeInterval

    init(
        baseURL: URL,
        transport: LoreBackendHTTPTransport = .ephemeral(),
        requestTimeout: TimeInterval = 30
    ) throws {
        guard
            baseURL.scheme?.lowercased() == "https",
            baseURL.host?.isEmpty == false,
            baseURL.user == nil,
            baseURL.password == nil,
            baseURL.query == nil,
            baseURL.fragment == nil,
            requestTimeout > 0
        else {
            throw LoreAppAttestError.invalidResponse
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = path.isEmpty ? "/" : "/\(path)/"
        guard let normalizedBaseURL = components?.url else {
            throw LoreAppAttestError.invalidResponse
        }
        self.baseURL = normalizedBaseURL
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    func challenge(
        purpose: LoreAppAttestChallengePurpose,
        keyId: String?
    ) async throws -> LoreAppAttestChallenge {
        let response: LoreAppAttestChallenge = try await post(
            path: "v1/auth/challenges",
            body: ChallengeRequest(
                schemaVersion: Self.schemaVersion,
                purpose: purpose,
                keyId: keyId
            )
        )
        guard
            response.schemaVersion == Self.schemaVersion,
            UUID(uuidString: response.challengeId) != nil,
            Self.base64URLDecode(response.challenge)?.count ?? 0 >= 16,
            response.purpose == purpose,
            response.expiresAt > Date()
        else {
            throw LoreAppAttestError.invalidChallenge
        }
        return response
    }

    func submitAttestation(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        attestationObject: Data
    ) async throws -> LoreAppAttestSession {
        try await post(
            path: "v1/auth/attestations",
            body: AttestationRequest(
                schemaVersion: Self.schemaVersion,
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                keyId: keyId,
                attestationObject: attestationObject.base64EncodedString()
            )
        )
    }

    func submitAssertion(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        assertion: Data,
        clientData: Data
    ) async throws -> LoreAppAttestSession {
        try await post(
            path: "v1/auth/sessions",
            body: AssertionRequest(
                schemaVersion: Self.schemaVersion,
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                keyId: keyId,
                assertionObject: assertion.base64EncodedString(),
                clientData: clientData.base64EncodedString()
            )
        )
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let requestId = "ios_auth_\(UUID().uuidString.lowercased())"
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw LoreAppAttestError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")
        do {
            request.httpBody = try Self.encoder.encode(body)
            let (data, rawResponse) = try await transport.send(request)
            try Task.checkCancellation()
            guard let response = rawResponse as? HTTPURLResponse else {
                throw LoreAppAttestError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                let error = try? Self.decoder.decode(AuthErrorEnvelope.self, from: data)
                let retryAfter = error?.retryAfterSeconds
                    ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                if response.statusCode == 429 {
                    throw LoreAppAttestError.rateLimited(retryAfterSeconds: retryAfter)
                }
                if error?.error.code == "app_attest_key_unknown" {
                    throw LoreAppAttestError.invalidKey
                }
                throw LoreAppAttestError.rejected(
                    code: error?.error.code ?? "auth_rejected",
                    retryable: error?.error.retryable ?? false,
                    retryAfterSeconds: retryAfter
                )
            }
            guard response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().contains("application/json") == true else {
                throw LoreAppAttestError.invalidResponse
            }
            let result: Response
            do {
                result = try Self.decoder.decode(Response.self, from: data)
            } catch {
                throw LoreAppAttestError.invalidResponse
            }
            if let session = result as? LoreAppAttestSession {
                try Self.validate(session)
            }
            return result
        } catch is CancellationError {
            throw LoreAppAttestError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LoreAppAttestError.cancelled
        } catch let error as LoreAppAttestError {
            throw error
        } catch {
            throw LoreAppAttestError.unavailable
        }
    }

    private static func validate(_ session: LoreAppAttestSession) throws {
        guard
            session.schemaVersion == schemaVersion,
            session.tokenType == "Bearer",
            session.sessionToken.count >= 40,
            !session.sessionToken.contains("\n"),
            !session.sessionToken.contains("\r"),
            session.expiresAt > Date()
        else {
            throw LoreAppAttestError.invalidResponse
        }
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp."
            )
        }
        return decoder
    }()

    private struct ChallengeRequest: Encodable {
        let schemaVersion: String
        let purpose: LoreAppAttestChallengePurpose
        let keyId: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case purpose
            case keyId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(purpose, forKey: .purpose)
            if let keyId {
                try container.encode(keyId, forKey: .keyId)
            } else {
                try container.encodeNil(forKey: .keyId)
            }
        }
    }

    private struct AttestationRequest: Encodable {
        let schemaVersion: String
        let challengeId: String
        let challenge: String
        let keyId: String
        let attestationObject: String
    }

    private struct AssertionRequest: Encodable {
        let schemaVersion: String
        let challengeId: String
        let challenge: String
        let keyId: String
        let assertionObject: String
        let clientData: String
    }

    private struct AuthErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: String
            let retryable: Bool
        }
        let error: Detail
        let retryAfterSeconds: Int?
    }
}

actor LoreAppAttestSessionAuthorizer: LoreBackendAuthorizing {
    private static let schemaVersion = "1.0"

    private let service: any LoreAppAttestServicing
    private let keyStore: any LoreAppAttestKeyStoring
    private let api: any LoreAppAttestAPIClient
    private let renewalLeeway: TimeInterval
    private let now: @Sendable () -> Date

    private var session: LoreAppAttestSession?
    private var renewalTask: Task<LoreAppAttestSession, Error>?

    init(
        service: any LoreAppAttestServicing = LoreAppleAppAttestService(),
        keyStore: any LoreAppAttestKeyStoring = LoreKeychainAppAttestKeyStore(),
        api: any LoreAppAttestAPIClient,
        renewalLeeway: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.keyStore = keyStore
        self.api = api
        self.renewalLeeway = max(0, renewalLeeway)
        self.now = now
    }

    func authorizationHeaderValue() async throws -> String {
        try Task.checkCancellation()
        guard await service.isSupported() else {
            throw LoreAppAttestError.unsupported
        }
        if let session, session.expiresAt.timeIntervalSince(now()) > renewalLeeway {
            return "Bearer \(session.sessionToken)"
        }
        if let renewalTask {
            let renewed = try await renewalTask.value
            try Task.checkCancellation()
            return "Bearer \(renewed.sessionToken)"
        }

        let task = Task { try await establishSession() }
        renewalTask = task
        do {
            let renewed = try await task.value
            renewalTask = nil
            session = renewed
            try Task.checkCancellation()
            return "Bearer \(renewed.sessionToken)"
        } catch {
            renewalTask = nil
            throw error
        }
    }

    func invalidateSession() {
        session = nil
    }

    private func establishSession() async throws -> LoreAppAttestSession {
        if let keyId = try await keyStore.loadKeyId() {
            do {
                let session = try await establishAssertionSession(keyId: keyId)
                try await keyStore.deletePendingEnrollment()
                return session
            } catch LoreAppAttestError.invalidKey {
                try await keyStore.deleteKeyId()
                try await keyStore.deletePendingEnrollment()
                return try await establishAttestedSession()
            }
        }
        return try await establishAttestedSession()
    }

    private func establishAttestedSession() async throws -> LoreAppAttestSession {
        var enrollment = try await keyStore.loadPendingEnrollment()
        if (enrollment?.challenge.expiresAt ?? .distantPast) <= now() {
            try await keyStore.deletePendingEnrollment()
            enrollment = nil
        }

        if enrollment == nil {
            let keyId = try await service.generateKey()
            let challenge = try await api.challenge(purpose: .attestation, keyId: nil)
            guard
                challenge.expiresAt > now(),
                !challenge.challenge.isEmpty
            else {
                throw LoreAppAttestError.invalidChallenge
            }
            enrollment = LoreAppAttestPendingEnrollment(
                keyId: keyId,
                challenge: challenge,
                attestationObject: nil
            )
            try await keyStore.savePendingEnrollment(enrollment!)
        }

        guard var enrollment else {
            throw LoreAppAttestError.keyStorageFailed
        }
        // The backend defines the base64url challenge string itself as the
        // one-time data value, so both sides hash its UTF-8 bytes.
        let clientDataHash = Data(SHA256.hash(data: Data(enrollment.challenge.challenge.utf8)))
        let attestation: Data
        if let savedAttestation = enrollment.attestationObject {
            attestation = savedAttestation
        } else {
            do {
                attestation = try await service.attestKey(
                    enrollment.keyId,
                    clientDataHash: clientDataHash
                )
            } catch LoreAppAttestError.serverUnavailable {
                // Apple requires a server-unavailable retry to reuse the exact
                // key and client-data hash so the device risk metric is stable.
                throw LoreAppAttestError.serverUnavailable
            } catch {
                // Apple recommends discarding the key identifier for every
                // attestation error other than server-unavailable.
                try await keyStore.deletePendingEnrollment()
                throw error
            }
            enrollment.attestationObject = attestation
            try await keyStore.savePendingEnrollment(enrollment)
        }

        let newSession = try await api.submitAttestation(
            challenge: enrollment.challenge,
            keyId: enrollment.keyId,
            attestationObject: attestation
        )
        try validate(newSession)
        try await keyStore.saveKeyId(enrollment.keyId)
        try await keyStore.deletePendingEnrollment()
        return newSession
    }

    private func establishAssertionSession(keyId: String) async throws -> LoreAppAttestSession {
        let challenge = try await api.challenge(purpose: .assertion, keyId: keyId)
        guard challenge.expiresAt > now() else {
            throw LoreAppAttestError.invalidChallenge
        }
        let clientData = try Self.canonicalClientData(challenge: challenge)
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let assertion = try await service.generateAssertion(
            keyId,
            clientDataHash: clientDataHash
        )
        let renewed = try await api.submitAssertion(
            challenge: challenge,
            keyId: keyId,
            assertion: assertion,
            clientData: clientData
        )
        try validate(renewed)
        return renewed
    }

    private func validate(_ session: LoreAppAttestSession) throws {
        guard
            session.schemaVersion == Self.schemaVersion,
            session.expiresAt > now(),
            session.tokenType == "Bearer",
            session.sessionToken.count >= 40,
            !session.sessionToken.contains("\n"),
            !session.sessionToken.contains("\r")
        else {
            throw LoreAppAttestError.invalidResponse
        }
    }

    static func canonicalClientData(challenge: LoreAppAttestChallenge) throws -> Data {
        struct ClientData: Encodable {
            let schemaVersion: String
            let action: String
            let challengeId: String
            let challenge: String
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(ClientData(
                schemaVersion: Self.schemaVersion,
                action: "create_session",
                challengeId: challenge.challengeId,
                challenge: challenge.challenge
            ))
        } catch {
            throw LoreAppAttestError.invalidChallenge
        }
    }
}
