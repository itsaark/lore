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

    @Test func invalidInputDuringAttestationEnrollsOneReplacementKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "fresh-key-recovery-challenge",
            bytes: Data(repeating: 0x4E, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let session = makeSession(
            token: "fresh-key-recovery-session-token-with-at-least-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(
            generatedKeyId: "replacement-generated-key",
            attestationErrors: [.invalidInput]
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

        let header = try await authorizer.authorizationHeaderValue()

        #expect(header == "Bearer fresh-key-recovery-session-token-with-at-least-forty-characters")
        #expect(await service.generatedKeyCount == 2)
        #expect(await service.attestationHashes.count == 2)
        #expect(await api.challengeRequests.count == 2)
        #expect(await api.attestationSubmissions.count == 1)
        #expect(await keyStore.keyId == "replacement-generated-key")
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

    @Test func invalidInputFromPersistedAssertionDeletesKeyAndReattestsOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let challenge = makeChallenge(
            id: "invalid-input-replacement-challenge",
            bytes: Data(repeating: 0x12, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let session = makeSession(
            token: "invalid-input-replacement-session-token-with-forty-characters",
            expiresAt: now.addingTimeInterval(600)
        )
        let service = FakeAppAttestService(
            generatedKeyId: "invalid-input-replacement-key",
            assertionError: .invalidInput
        )
        let keyStore = FakeAppAttestKeyStore(keyId: "stale-keychain-key")
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

        #expect(header == "Bearer invalid-input-replacement-session-token-with-forty-characters")
        #expect(await keyStore.deleteCount == 1)
        #expect(await keyStore.keyId == "invalid-input-replacement-key")
        #expect(await service.assertionHashes.count == 1)
        #expect(await service.generatedKeyCount == 1)
        #expect(await api.attestationSubmissions.count == 1)
    }

    @Test func genericAssertionRejectionFailsClosedWithoutRotatingKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = assertionHarness(now: now, assertionErrors: [
            .rejected(code: "unauthorized", retryable: false, retryAfterSeconds: nil)
        ])

        await #expect(throws: LoreAppAttestError.rejected(
            code: "unauthorized",
            retryable: false,
            retryAfterSeconds: nil
        )) {
            _ = try await harness.authorizer.authorizationHeaderValue()
        }
        #expect(await harness.keyStore.keyId == "diagnostic-key")
        #expect(await harness.keyStore.deleteCount == 0)
        #expect(await harness.service.generatedKeyCount == 0)
        #expect(await harness.api.assertionSubmissions.count == 1)
    }

    @Test func repeatedAssertionInvalidRotatesPersistedKeyOnce() async throws {
        // A key the server permanently refuses (for example an enrollment
        // whose stored iOS 27 extension state no longer matches) must not
        // lock the installation out of remote processing.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = assertionHarness(now: now, assertionErrors: [
            .rejected(code: "assertion_invalid", retryable: false, retryAfterSeconds: nil)
        ])

        let header = try await harness.authorizer.authorizationHeaderValue()

        #expect(header == "Bearer attested-session-token-with-at-least-forty-characters")
        #expect(await harness.api.assertionSubmissions.count == 2)
        #expect(await harness.service.generatedKeyCount == 1)
        #expect(await harness.api.attestationSubmissions.count == 1)
        #expect(await harness.keyStore.keyId == "rotated-key")
        #expect(await harness.keyStore.deleteCount == 1)
        #expect(await harness.keyStore.lastServerRejectionRotation == now)
    }

    @Test func serverRejectionRotationHappensAtMostOncePerLaunch() async throws {
        // Two authorizers share one launch budget, as ContentView's and the
        // Transcription Lab's do; a persistently refused replacement must not
        // start a second attestation in the same launch.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let budget = LoreAppAttestRotationBudget()
        let rejection = LoreAppAttestError.rejected(
            code: "assertion_invalid",
            retryable: false,
            retryAfterSeconds: nil
        )
        let first = assertionHarness(now: now, assertionErrors: [rejection], budget: budget)
        _ = try await first.authorizer.authorizationHeaderValue()

        // Same launch, a later day (so only the launch budget can stop it).
        let later = now.addingTimeInterval(3 * LoreAppAttestSessionAuthorizer.serverRejectionRotationBackoff)
        let second = assertionHarness(now: later, assertionErrors: [rejection], budget: budget)
        await #expect(throws: rejection) {
            _ = try await second.authorizer.authorizationHeaderValue()
        }
        #expect(await second.service.generatedKeyCount == 0)
        #expect(await second.keyStore.deleteCount == 0)
        #expect(await second.keyStore.keyId == "diagnostic-key")
    }

    @Test func refusedReplacementKeyBacksOffForADayAcrossLaunches() async throws {
        let rotatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rejection = LoreAppAttestError.rejected(
            code: "assertion_invalid",
            retryable: false,
            retryAfterSeconds: nil
        )
        let backoff = LoreAppAttestSessionAuthorizer.serverRejectionRotationBackoff

        // New launch (fresh budget) inside the window: fail closed, keep key.
        let inside = assertionHarness(
            now: rotatedAt.addingTimeInterval(backoff - 60),
            assertionErrors: [rejection],
            lastRotation: rotatedAt
        )
        await #expect(throws: rejection) {
            _ = try await inside.authorizer.authorizationHeaderValue()
        }
        #expect(await inside.service.generatedKeyCount == 0)
        #expect(await inside.keyStore.deleteCount == 0)
        #expect(await inside.keyStore.lastServerRejectionRotation == rotatedAt)

        // After the window a new launch may try one more replacement.
        let afterNow = rotatedAt.addingTimeInterval(backoff + 60)
        let after = assertionHarness(now: afterNow, assertionErrors: [rejection], lastRotation: rotatedAt)
        _ = try await after.authorizer.authorizationHeaderValue()
        #expect(await after.service.generatedKeyCount == 1)
        #expect(await after.keyStore.lastServerRejectionRotation == afterNow)
    }

    @Test func refusedReplacementAttestationStartsBackoffInsteadOfAKeyLoop() async throws {
        // If the server also refuses the replacement's attestation (a policy
        // bug such as an unaccepted launch category), later requests and
        // launches must not keep generating and attesting new keys.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refusal = LoreAppAttestError.rejected(
            code: "attestation_invalid",
            retryable: false,
            retryAfterSeconds: nil
        )
        let first = assertionHarness(now: now, assertionErrors: [
            .rejected(code: "assertion_invalid", retryable: false, retryAfterSeconds: nil)
        ])
        await first.api.setAttestationError(refusal)
        await #expect(throws: refusal) {
            _ = try await first.authorizer.authorizationHeaderValue()
        }
        #expect(await first.service.generatedKeyCount == 1)
        #expect(await first.keyStore.lastServerRejectionRotation == now)

        // Next launch, an hour later, with no persisted key left.
        let backoff = LoreAppAttestError.rejected(
            code: "app_attest_backoff",
            retryable: true,
            retryAfterSeconds: nil
        )
        let next = assertionHarness(
            now: now.addingTimeInterval(3_600),
            assertionErrors: [],
            lastRotation: now,
            persistedKeyId: nil
        )
        await #expect(throws: backoff) {
            _ = try await next.authorizer.authorizationHeaderValue()
        }
        #expect(await next.service.generatedKeyCount == 0)
        #expect(await next.api.challengeRequests.isEmpty)

        // After the window, enrollment is attempted again.
        let recovered = assertionHarness(
            now: now.addingTimeInterval(LoreAppAttestSessionAuthorizer.serverRejectionRotationBackoff + 1),
            assertionErrors: [],
            lastRotation: now,
            persistedKeyId: nil
        )
        _ = try await recovered.authorizer.authorizationHeaderValue()
        #expect(await recovered.service.generatedKeyCount == 1)
    }

    @Test func transportServerAndNonExplicitFailuresNeverRotateTheKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failures: [LoreAppAttestError] = [
            .unavailable,
            .rateLimited(retryAfterSeconds: 30),
            .rejected(code: "assertion_invalid", retryable: true, retryAfterSeconds: nil),
            .rejected(code: "auth_rejected", retryable: false, retryAfterSeconds: nil),
            .rejected(code: "challenge_expired", retryable: false, retryAfterSeconds: nil)
        ]
        for failure in failures {
            let harness = assertionHarness(now: now, assertionErrors: [failure])
            await #expect(throws: failure) {
                _ = try await harness.authorizer.authorizationHeaderValue()
            }
            #expect(await harness.service.generatedKeyCount == 0)
            #expect(await harness.keyStore.deleteCount == 0)
            #expect(await harness.keyStore.keyId == "diagnostic-key")
            #expect(await harness.keyStore.lastServerRejectionRotation == nil)
        }
    }

    @Test func authHTTPAPIMapsServerErrorsAndNon401AssertionVerdictsAwayFromRotation() async throws {
        let future = "2099-08-03T12:00:00Z"
        let challengeValue = LoreAppAttestHTTPAPIClient.base64URLEncode(Data(repeating: 4, count: 32))
        let challenge = LoreAppAttestChallenge(
            schemaVersion: "1.0",
            challengeId: "a80cfcac-4911-4e99-a1ea-228f3924f673",
            challenge: challengeValue,
            purpose: .assertion,
            expiresAt: ISO8601DateFormatter().date(from: future)!
        )
        let cases: [(Int, LoreAppAttestError)] = [
            (401, .rejected(code: "assertion_invalid", retryable: false, retryAfterSeconds: nil)),
            (500, .unavailable),
            (503, .unavailable),
            (403, .rejected(code: "auth_rejected", retryable: false, retryAfterSeconds: nil))
        ]
        for (status, expected) in cases {
            let transport = LoreBackendHTTPTransport { request, _ in
                (
                    Data("""
                    {"schema_version":"1.0","error":{"code":"assertion_invalid","message":"x","retryable":false}}
                    """.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
            let api = try LoreAppAttestHTTPAPIClient(
                baseURL: URL(string: "https://lore.example/")!,
                transport: transport
            )
            await #expect(throws: expected) {
                _ = try await api.submitAssertion(
                    challenge: challenge,
                    keyId: "key-1",
                    assertion: Data("assertion".utf8),
                    clientData: Data("client".utf8)
                )
            }
        }
    }

    @Test func counterRaceRetriesAssertionWithoutRotatingKey() async throws {
        for raceCode in ["counter_replayed", "assertion_invalid"] {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let harness = assertionHarness(now: now, assertionErrors: [
                .rejected(code: raceCode, retryable: false, retryAfterSeconds: nil)
            ], thenSucceed: true)

            let header = try await harness.authorizer.authorizationHeaderValue()

            #expect(header == "Bearer asserted-session-token-with-at-least-forty-characters")
            #expect(await harness.api.assertionSubmissions.count == 2)
            #expect(await harness.service.assertionHashes.count == 2)
            #expect(await harness.service.generatedKeyCount == 0)
            #expect(await harness.keyStore.keyId == "diagnostic-key")
        }
    }

    private func assertionHarness(
        now: Date,
        assertionErrors: [LoreAppAttestError],
        thenSucceed: Bool = false,
        lastRotation: Date? = nil,
        budget: LoreAppAttestRotationBudget = LoreAppAttestRotationBudget(),
        persistedKeyId: String? = "diagnostic-key"
    ) -> (
        authorizer: LoreAppAttestSessionAuthorizer,
        service: FakeAppAttestService,
        keyStore: FakeAppAttestKeyStore,
        api: FakeAppAttestAPI
    ) {
        let attestation = makeChallenge(
            id: "rotation-attestation",
            bytes: Data(repeating: 0x32, count: 32),
            purpose: .attestation,
            expiresAt: now.addingTimeInterval(300)
        )
        let assertion = makeChallenge(
            id: "rejected-assertion",
            bytes: Data(repeating: 0x31, count: 32),
            purpose: .assertion,
            expiresAt: now.addingTimeInterval(300)
        )
        let service = FakeAppAttestService(generatedKeyId: "rotated-key")
        let keyStore = FakeAppAttestKeyStore(
            keyId: persistedKeyId,
            lastServerRejectionRotation: lastRotation
        )
        let api = FakeAppAttestAPI(
            attestationChallenge: attestation,
            assertionChallenge: assertion,
            attestationSession: makeSession(
                token: "attested-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            ),
            assertionSession: makeSession(
                token: "asserted-session-token-with-at-least-forty-characters",
                expiresAt: now.addingTimeInterval(600)
            ),
            assertionErrors: assertionErrors,
            succeedAfterErrors: thenSucceed
        )
        let authorizer = LoreAppAttestSessionAuthorizer(
            service: service,
            keyStore: keyStore,
            api: api,
            now: { now },
            rotationBudget: budget
        )
        return (authorizer, service, keyStore, api)
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
    private(set) var lastServerRejectionRotation: Date?

    init(keyId: String? = nil, lastServerRejectionRotation: Date? = nil) {
        self.keyId = keyId
        self.lastServerRejectionRotation = lastServerRejectionRotation
    }

    func loadLastServerRejectionRotation() -> Date? { lastServerRejectionRotation }
    func saveLastServerRejectionRotation(_ date: Date) { lastServerRejectionRotation = date }

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
    /// Thrown in order, one per assertion submission; the last one repeats.
    private var assertionErrors: [LoreAppAttestError]
    private let succeedAfterErrors: Bool
    private var attestationError: LoreAppAttestError?
    private(set) var challengeRequests: [(LoreAppAttestChallengePurpose, String?)] = []
    private(set) var attestationSubmissions: [(String, String, Data)] = []
    private(set) var assertionSubmissions: [AssertionSubmission] = []

    init(
        attestationChallenge: LoreAppAttestChallenge,
        assertionChallenge: LoreAppAttestChallenge,
        attestationSession: LoreAppAttestSession,
        assertionSession: LoreAppAttestSession,
        assertionError: LoreAppAttestError? = nil,
        assertionErrors: [LoreAppAttestError]? = nil,
        succeedAfterErrors: Bool = false
    ) {
        self.succeedAfterErrors = succeedAfterErrors
        self.attestationChallenge = attestationChallenge
        self.assertionChallenge = assertionChallenge
        self.attestationSession = attestationSession
        self.assertionSession = assertionSession
        self.assertionErrors = assertionErrors ?? assertionError.map { [$0] } ?? []
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
    ) throws -> LoreAppAttestSession {
        attestationSubmissions.append((challenge.challengeId, keyId, attestationObject))
        if let attestationError { throw attestationError }
        return attestationSession
    }

    func setAttestationError(_ error: LoreAppAttestError?) { attestationError = error }

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
        if let next = assertionErrors.first {
            if assertionErrors.count > 1 || succeedAfterErrors { assertionErrors.removeFirst() }
            throw next
        }
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

#if !targetEnvironment(simulator)
import DeviceCheck

/// Opt-in on-device probe: `TEST_RUNNER_LORE_APP_ATTEST_PROBE=1 xcodebuild test ...`.
/// It uses a throwaway App Attest key, random client-data hashes, and never
/// contacts Lore's backend or touches the installation's persisted key. The
/// printed objects carry no user content and the key is never registered, so
/// they are safe fixtures for checking the backend parser against real iOS bytes.
@Suite struct LoreAppAttestDeviceProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LORE_APP_ATTEST_PROBE"] == "1"))
    func dumpRealAttestationAndAssertionShapes() async throws {
        let service = DCAppAttestService.shared
        try #require(service.isSupported)
        let keyId = try await service.generateKey()
        let attestationHash = Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        let attestation = try await service.attestKey(keyId, clientDataHash: attestationHash)
        print("LORE_PROBE os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("LORE_PROBE keyId=\(keyId)")
        print("LORE_PROBE attestationHash=\(attestationHash.base64EncodedString())")
        print("LORE_PROBE attestation=\(attestation.base64EncodedString())")
        for index in 1...2 {
            let clientData = Data("probe-\(index)-\(UUID().uuidString)".utf8)
            let assertion = try await service.generateAssertion(
                keyId,
                clientDataHash: Data(SHA256.hash(data: clientData))
            )
            print("LORE_PROBE clientData\(index)=\(clientData.base64EncodedString())")
            print("LORE_PROBE assertion\(index)=\(assertion.base64EncodedString())")
        }
    }
}
#endif
