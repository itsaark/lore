import CryptoKit
import Foundation
import Testing
@testable import lore

@Suite(.serialized)
struct LoreAppAttestAuthenticationTests {
    @Test func firstSessionAttestsNewKeyThenCachesBearerInMemory() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challengeBytes = Data(repeating: 0x2A, count: 32)
        let challenge = makeChallenge(
            id: "attestation-challenge",
            bytes: challengeBytes,
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let expectedSession = makeSession(
            token: "attested-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(generatedKeyId: "secure-key-1")
        let keyStore = FakeAppAttestKeyStore()
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: expectedSession,
            assertionSession: expectedSession
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now }
        )

        let first = try await authorizer.authorizationHeaderValue()
        let second = try await authorizer.authorizationHeaderValue()

        #expect(first == "Bearer attested-session-token-with-at-least-forty-characters")
        #expect(second == first)
        #expect(await keyStore.keyId == "secure-key-1")
        #expect(await service.generatedKeyCount == 1)
        #expect(await service.attestationHashes == [
            Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        ])
        #expect(await api.attestationSubmissions.count == 1)
        #expect(await api.assertionSubmissions.isEmpty)
        #expect(await keyStore.pendingEnrollment == nil)
    }

    @Test func serverUnavailableRetriesTheSamePendingKeyChallengeAndHash() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "retryable-attestation-challenge",
            bytes: Data(repeating: 0x4D, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let session = makeSession(
            token: "recovered-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(
            generatedKeyId: "pending-secure-key",
            attestationErrors: [.serverUnavailable]
        )
        let keyStore = FakeAppAttestKeyStore()
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: session,
            assertionSession: session
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now }
        )

        await #expect(throws: LoreAppAttestError.serverUnavailable) {
            _ = try await authorizer.authorizationHeaderValue()
        }
        let pendingAfterFailure = try #require(await keyStore.pendingEnrollment)
        let header = try await authorizer.authorizationHeaderValue()
        let expectedHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))

        #expect(header == "Bearer recovered-session-token-with-at-least-forty-characters")
        #expect(pendingAfterFailure.keyId == "pending-secure-key")
        #expect(pendingAfterFailure.challenge == challenge)
        #expect(await service.generatedKeyCount == 1)
        #expect(await service.attestationHashes == [expectedHash, expectedHash])
        #expect(await api.challengeRequests.count == 1)
        #expect(await keyStore.keyId == "pending-secure-key")
        #expect(await keyStore.pendingEnrollment == nil)
    }

    @Test func persistedKeyCreatesAssertionOverCanonicalClientData() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "assertion-challenge",
            bytes: Data(repeating: 0x7B, count: 32),
            purpose: .assertion,
            expiresAt: now.addingTimeInterval(300)
        )
        let expectedSession = makeSession(
            token: "asserted-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(generatedKeyId: "unused")
        let keyStore = FakeAppAttestKeyStore(keyId: "persisted-key")
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: expectedSession,
            assertionSession: expectedSession
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now }
        )

        let header = try await authorizer.authorizationHeaderValue()

        let submission = try #require(await api.assertionSubmissions.first)
        let clientObject = try #require(
            JSONSerialization.jsonObject(with: submission.clientData) as? [String: String]
        )
        #expect(header == "Bearer asserted-session-token-with-at-least-forty-characters")
        #expect(clientObject == [
            "schema_version": "1.0",
            "action": "create_session",
            "challenge_id": challenge.challengeId,
            "challenge": challenge.challenge
        ])
        #expect(await service.assertionHashes == [Data(SHA256.hash(data: submission.clientData))])
        #expect(await service.generatedKeyCount == 0)
    }

    @Test func sessionRequestsNewAssertionInsideExpiryLeeway() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "renewal-challenge",
            bytes: Data(repeating: 0x5C, count: 32),
            purpose: .assertion,
            expiresAt: now.addingTimeInterval(300)
        )
        let session = makeSession(
            token: "renewable-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(generatedKeyId: "unused")
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: session,
            assertionSession: session
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: FakeAppAttestKeyStore(keyId: "persisted-key"),
            api: api,
            renewalLeeway: 601,
            now: { now }
        )

        _ = try await authorizer.authorizationHeaderValue()
        _ = try await authorizer.authorizationHeaderValue()

        #expect(await api.assertionSubmissions.count == 2)
        #expect(await api.challengeRequests.count == 2)
        #expect(await service.assertionHashes.count == 2)
    }

    @Test func invalidPersistedKeyIsDeletedAndReattestedOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "replacement-challenge",
            bytes: Data(repeating: 0x11, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let session = makeSession(
            token: "replacement-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(
            generatedKeyId: "replacement-key",
            assertionError: .invalidKey
        )
        let keyStore = FakeAppAttestKeyStore(keyId: "invalid-key")
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: session,
            assertionSession: session
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now }
        )

        let header = try await authorizer.authorizationHeaderValue()

        #expect(header == "Bearer replacement-session-token-with-at-least-forty-characters")
        #expect(await keyStore.deleteCount == 1)
        #expect(await keyStore.keyId == "replacement-key")
        #expect(await service.generatedKeyCount == 1)
    }

    @Test func genericAssertionRejectionFailsClosedWithoutRotatingKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "rejected-assertion",
            bytes: Data(repeating: 0x31, count: 32),
            purpose: .assertion,
            expiresAt: now.addingTimeInterval(300)
        )
        let service = FakeAppAttestService(generatedKeyId: "unused")
        let keyStore = FakeAppAttestKeyStore(keyId: "diagnostic-key")
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: makeSession(
                token: "unused-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            ),
            assertionSession: makeSession(
                token: "unused-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            ),
            assertionError: .rejected(
                code: "assertion_invalid",
                retryable: false,
                retryAfterSeconds: nil
            )
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now }
        )

        await #expect(throws: LoreAppAttestError.rejected(
            code: "assertion_invalid",
            retryable: false,
            retryAfterSeconds: nil
        )) {
            _ = try await authorizer.authorizationHeaderValue()
        }
        #expect(await keyStore.keyId == "diagnostic-key")
        #expect(await keyStore.deleteCount == 0)
        #expect(await service.generatedKeyCount == 0)
    }

    @Test func unsupportedDeviceFailsClosedBeforeNetwork() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "unused",
            bytes: Data(repeating: 1, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let service = FakeAppAttestService(generatedKeyId: "unused", isSupported: false)
        let api = FakeAppAttestAPI(
            attestationChallenge: challenge,
            assertionChallenge: challenge,
            attestationSession: makeSession(
                token: "unused-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            ),
            assertionSession: makeSession(
                token: "unused-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            )
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: FakeAppAttestKeyStore(),
            api: api,
            now: { now }
        )

        await #expect(throws: LoreAppAttestError.unsupported) {
            _ = try await authorizer.authorizationHeaderValue()
        }
        #expect(await api.challengeRequests.isEmpty)
    }

    @Test func authHTTPAPIUsesFinalPathsExplicitNullAndCanonicalBase64Payloads() async throws {
        let capture = AuthRequestCapture()
        let future = "2099-08-03T12:00:00Z"
        let challengeValue = LoreAppAttestHTTPAPIClient.base64URLEncode(Data(repeating: 4, count: 32))
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            let path = request.url?.path
            let body: Data
            if path?.hasSuffix("/challenges") == true {
                let requestBody = try #require(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                )
                let purpose = try #require(requestBody["purpose"] as? String)
                body = Data("""
                {"schema_version":"1.0","challenge_id":"a80cfcac-4911-4e99-a1ea-228f3924f673","challenge":"\(challengeValue)","purpose":"\(purpose)","expires_at":"\(future)"}
                """.utf8)
            } else {
                body = Data("""
                {"schema_version":"1.0","token_type":"Bearer","session_token":"session-token-with-at-least-forty-characters-1234","expires_at":"\(future)"}
                """.utf8)
            }
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        let api = try LoreAppAttestHTTPAPIClient(
            baseURL: URL(string: "https://lore.example/api/")!,
            transport: transport
        )

        _ = try await api.challenge(purpose: .attestation, keyId: nil)
        let challenge = try await api.challenge(purpose: .assertion, keyId: "key-1")
        _ = try await api.submitAssertion(
            challenge: challenge,
            keyId: "key-1",
            assertion: Data([0xfb, 0xff]),
            clientData: Data("canonical".utf8)
        )

        let requests = await capture.requests
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/auth/challenges",
            "/api/v1/auth/challenges",
            "/api/v1/auth/sessions"
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let challengeBody = try #require(
            JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any]
        )
        let assertionChallengeBody = try #require(
            JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String]
        )
        let assertionBody = try #require(
            JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String]
        )
        #expect(challengeBody["purpose"] as? String == "attestation")
        #expect(challengeBody.keys.contains("key_id"))
        #expect(challengeBody["key_id"] is NSNull)
        #expect(assertionChallengeBody["purpose"] == "assertion")
        #expect(assertionChallengeBody["key_id"] == "key-1")
        #expect(assertionBody["challenge"] == challengeValue)
        #expect(assertionBody["challenge_id"] == "a80cfcac-4911-4e99-a1ea-228f3924f673")
        #expect(assertionBody["assertion_object"] == "+/8=")
        #expect(assertionBody["client_data"] == "Y2Fub25pY2Fs")
    }

    @Test func productionHTTPClientRequiresAndUsesDynamicAuthorizer() async throws {
        let request = makeDailyRequest()
        let missingAuthTransport = AuthRequestCapture()
        let configuration = try LoreBackendHTTPClientConfiguration(
            baseURL: URL(string: "https://lore.example/api")!
        )
        let clientWithoutAuth = LoreBackendHTTPClient(
            configuration: configuration,
            transport: LoreBackendHTTPTransport { value, _ in
                await missingAuthTransport.record(value)
                throw URLError(.badServerResponse)
            }
        )
        await #expect(throws: LoreBackendProcessingError.notConfigured) {
            _ = try await clientWithoutAuth.generateDailyEntry(request)
        }
        #expect(await missingAuthTransport.requests.isEmpty)

        let capture = AuthRequestCapture()
        let client = LoreBackendHTTPClient(
            configuration: configuration,
            transport: LoreBackendHTTPTransport { value, _ in
                await capture.record(value)
                throw URLError(.badServerResponse)
            },
            productionAuthorizer: StaticTestAuthorizer(value: "Bearer dynamic-session")
        )
        await #expect(throws: LoreBackendProcessingError.transportUnavailable) {
            _ = try await client.generateDailyEntry(request)
        }
        #expect(await capture.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer dynamic-session")
    }

    @Test func productionHTTPClientMapsAuthorizerPolicyWithoutSendingContent() async throws {
        let configuration = try LoreBackendHTTPClientConfiguration(
            baseURL: URL(string: "https://lore.example/api")!
        )
        let capture = AuthRequestCapture()
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            throw URLError(.badServerResponse)
        }
        let client = LoreBackendHTTPClient(
            configuration: configuration,
            transport: transport,
            productionAuthorizer: ThrowingTestAuthorizer(
                error: .rateLimited(retryAfterSeconds: 13)
            )
        )

        await #expect(throws: LoreBackendProcessingError.rateLimited(retryAfterSeconds: 13)) {
            _ = try await client.generateDailyEntry(makeDailyRequest())
        }
        #expect(await capture.requests.isEmpty)
    }

    @Test func productionHTTPClientRefreshesRejectedSessionExactlyOnce() async throws {
        let configuration = try LoreBackendHTTPClientConfiguration(
            baseURL: URL(string: "https://lore.example/api")!
        )
        let capture = AuthRequestCapture()
        let authorizer = RotatingTestAuthorizer()
        let errorBody = Data("""
        {"schema_version":"1.0","request_id":"req_auth","error":{"code":"unauthorized","message":"Unauthorized","retryable":false}}
        """.utf8)
        let client = LoreBackendHTTPClient(
            configuration: configuration,
            transport: LoreBackendHTTPTransport { request, _ in
                await capture.record(request)
                return (
                    errorBody,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            },
            productionAuthorizer: authorizer
        )

        await #expect(throws: LoreBackendProcessingError.rejected(
            code: "unauthorized",
            retryable: false,
            retryAfterSeconds: nil
        )) {
            _ = try await client.generateDailyEntry(makeDailyRequest())
        }
        let requests = await capture.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer session-1")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer session-2")
        #expect(await authorizer.invalidationCount == 1)
    }

    @MainActor @Test func debugRuntimeIsAlwaysLocalOnly() {
#if DEBUG
        let services = LoreRemoteServices.configuredForCurrentBuild(
            environment: [
                "LORE_BACKEND_BASE_URL": "https://should-not-be-used.example"
            ]
        )
        #expect(services.speechTranscriber is UnavailableRemoteSpeechTranscriber)
#endif
    }

    private func makeChallenge(
        id: String,
        bytes: Data,
        purpose: LoreAppAttestChallengePurpose,
        expiresAt: Date
    ) -> LoreAppAttestChallenge {
        LoreAppAttestChallenge(
            schemaVersion: "1.0",
            challengeId: id,
            challenge: LoreAppAttestHTTPAPIClient.base64URLEncode(bytes),
            purpose: purpose,
            expiresAt: expiresAt
        )
    }

    private func makeSession(token: String, expiresAt: Date) -> LoreAppAttestSession {
        LoreAppAttestSession(
            schemaVersion: "1.0",
            tokenType: "Bearer",
            sessionToken: token,
            expiresAt: expiresAt
        )
    }

    private func makeDailyRequest() -> DailyEntryGenerationRequest {
        DailyEntryGenerationRequest(
            jobId: UUID(),
            noteId: UUID(),
            transcriptArtifactId: UUID(),
            transcriptVersionId: UUID(),
            capturedLocalDate: "2026-08-03",
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: []),
            sourceSegments: [
                TranscriptSourceSegment(
                    id: "s1",
                    startMilliseconds: 0,
                    endMilliseconds: 100,
                    text: "A grounded note.",
                    confidence: nil,
                    speakerLabel: nil
                )
            ]
        )
    }
}

private actor FakeAppAttestService: LoreAppAttestServicing {
    let supported: Bool
    let generatedKeyId: String
    let assertionError: LoreAppAttestError?
    var attestationErrors: [LoreAppAttestError]
    private(set) var generatedKeyCount = 0
    private(set) var attestationHashes: [Data] = []
    private(set) var assertionHashes: [Data] = []

    init(
        generatedKeyId: String,
        isSupported: Bool = true,
        attestationErrors: [LoreAppAttestError] = [],
        assertionError: LoreAppAttestError? = nil
    ) {
        self.generatedKeyId = generatedKeyId
        supported = isSupported
        self.attestationErrors = attestationErrors
        self.assertionError = assertionError
    }

    func isSupported() -> Bool { supported }

    func generateKey() -> String {
        generatedKeyCount += 1
        return generatedKeyId
    }

    func attestKey(_ keyId: String, clientDataHash: Data) throws -> Data {
        attestationHashes.append(clientDataHash)
        if !attestationErrors.isEmpty {
            throw attestationErrors.removeFirst()
        }
        return Data("attestation".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) throws -> Data {
        assertionHashes.append(clientDataHash)
        if let assertionError { throw assertionError }
        return Data("assertion".utf8)
    }
}

private actor FakeAppAttestKeyStore: LoreAppAttestKeyStoring {
    private(set) var keyId: String?
    private(set) var pendingEnrollment: LoreAppAttestPendingEnrollment?
    private(set) var deleteCount = 0

    init(keyId: String? = nil) {
        self.keyId = keyId
    }

    func loadKeyId() -> String? { keyId }
    func saveKeyId(_ keyId: String) { self.keyId = keyId }
    func deleteKeyId() {
        keyId = nil
        deleteCount += 1
    }
    func loadPendingEnrollment() -> LoreAppAttestPendingEnrollment? { pendingEnrollment }
    func savePendingEnrollment(_ enrollment: LoreAppAttestPendingEnrollment) {
        pendingEnrollment = enrollment
    }
    func deletePendingEnrollment() { pendingEnrollment = nil }
}

private actor FakeAppAttestAPI: LoreAppAttestAPIClient {
    struct AssertionSubmission: Sendable {
        let challengeId: String
        let keyId: String
        let assertion: Data
        let clientData: Data
    }

    let attestationChallenge: LoreAppAttestChallenge
    let assertionChallenge: LoreAppAttestChallenge
    let attestationSession: LoreAppAttestSession
    let assertionSession: LoreAppAttestSession
    let assertionError: LoreAppAttestError?
    private(set) var challengeRequests: [(LoreAppAttestChallengePurpose, String?)] = []
    private(set) var attestationSubmissions: [(String, String, Data)] = []
    private(set) var assertionSubmissions: [AssertionSubmission] = []

    init(
        attestationChallenge: LoreAppAttestChallenge,
        assertionChallenge: LoreAppAttestChallenge,
        attestationSession: LoreAppAttestSession,
        assertionSession: LoreAppAttestSession,
        assertionError: LoreAppAttestError? = nil
    ) {
        self.attestationChallenge = attestationChallenge
        self.assertionChallenge = assertionChallenge
        self.attestationSession = attestationSession
        self.assertionSession = assertionSession
        self.assertionError = assertionError
    }

    func challenge(
        purpose: LoreAppAttestChallengePurpose,
        keyId: String?
    ) -> LoreAppAttestChallenge {
        challengeRequests.append((purpose, keyId))
        return purpose == .attestation ? attestationChallenge : assertionChallenge
    }

    func submitAttestation(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        attestationObject: Data
    ) -> LoreAppAttestSession {
        attestationSubmissions.append((challenge.challengeId, keyId, attestationObject))
        return attestationSession
    }

    func submitAssertion(
        challenge: LoreAppAttestChallenge,
        keyId: String,
        assertion: Data,
        clientData: Data
    ) throws -> LoreAppAttestSession {
        assertionSubmissions.append(AssertionSubmission(
            challengeId: challenge.challengeId,
            keyId: keyId,
            assertion: assertion,
            clientData: clientData
        ))
        if let assertionError { throw assertionError }
        return assertionSession
    }
}

private actor AuthRequestCapture {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct StaticTestAuthorizer: LoreBackendAuthorizing {
    let value: String
    func authorizationHeaderValue() -> String { value }
}

private struct ThrowingTestAuthorizer: LoreBackendAuthorizing {
    let error: LoreAppAttestError
    func authorizationHeaderValue() throws -> String { throw error }
}

private actor RotatingTestAuthorizer: LoreBackendAuthorizing {
    private(set) var invalidationCount = 0

    func authorizationHeaderValue() -> String {
        "Bearer session-\(invalidationCount + 1)"
    }

    func invalidateSession() {
        invalidationCount += 1
    }
}
