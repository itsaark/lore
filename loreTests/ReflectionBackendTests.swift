import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct ReflectionBackendTests {
    @Test func credentialBootstrapReturnsTwoScopedRealtimeCredentials() async throws {
        let sessionId = UUID()
        let capture = ReflectionRequestCapture()
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            return (
                Data("""
                {
                  "schema_version":"1.0",
                  "session_id":"\(sessionId.uuidString.lowercased())",
                  "stt":{"temporary_api_key":"stt-secret","expires_at":"2027-01-15T12:05:00Z","websocket_url":"wss://stt-rt.soniox.com/transcribe-websocket","model_alias":"reflection-stt-v1","audio_format":"pcm_s16le","sample_rate":16000,"num_channels":1},
                  "tts":{"temporary_api_key":"tts-secret","expires_at":"2027-01-15T12:05:00Z","websocket_url":"wss://tts-rt.soniox.com/tts-websocket","model_alias":"reflection-voice-v1","voice":"en_female","audio_format":"pcm_s16le","sample_rate":24000},
                  "maximum_session_duration_seconds":1200
                }
                """.utf8),
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "X-Request-ID": "credentials-request"]
                ))
            )
        }
        let client = try makeClient(transport: transport)

        let response = try await client.createReflectionSessionCredentials(
            ReflectionSessionCredentialsRequest(sessionId: sessionId, languageCode: "en-US")
        )

        let request = try #require(await capture.last)
        #expect(request.url?.absoluteString == "https://lore.example/api/v1/reflections/session-credentials")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "reflection-credentials:\(sessionId.uuidString.lowercased())")
        #expect(response.stt.temporaryApiKey == "stt-secret")
        #expect(response.tts.temporaryApiKey == "tts-secret")
        #expect(response.stt.websocketUrl.scheme == "wss")
        #expect(response.maximumSessionDurationSeconds == 1_200)
    }

    @Test func guideRequestKeepsLoreTurnsContextOnlyAndIsBounded() async throws {
        let sessionId = UUID()
        let loreTurn = ReflectionConversationTurn(
            sequence: 0,
            role: .lore,
            text: "What felt worth remembering about today?",
            isEvidenceEligible: false
        )
        let userTurn = ReflectionConversationTurn(
            sequence: 1,
            role: .user,
            text: "I finally finished the garden gate.",
            isEvidenceEligible: true
        )
        let capture = ReflectionRequestCapture()
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            return (
                try reflectionGuideResponse(sessionId: sessionId),
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "X-Request-ID": "req-reflect-guide"]
                ))
            )
        }
        let client = try makeClient(transport: transport)

        let response = try await client.generateReflectionResponse(ReflectionResponseRequest(
            sessionId: sessionId,
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            turns: [loreTurn, userTurn]
        ))

        let request = try #require(await capture.last)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turns = try #require(object["turns"] as? [[String: Any]])
        #expect(request.url?.absoluteString == "https://lore.example/api/v1/reflections/respond")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "reflection-response:\(sessionId.uuidString.lowercased()):\(userTurn.id.uuidString.lowercased())")
        #expect(turns[0]["role"] as? String == "lore")
        #expect(turns[0]["is_evidence_eligible"] as? Bool == false)
        #expect(turns[1]["is_evidence_eligible"] as? Bool == true)
        #expect((object["retention_policy"] as? [String: Any])?["mode"] as? String == "request_ephemeral")
        #expect(response.spokenText == "What made finishing it meaningful to you?")
    }

    @Test func guideRequestRejectsLoreAuthoredEvidenceBeforeTransport() async throws {
        let capture = ReflectionRequestCapture()
        let client = try makeClient(transport: LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            throw URLError(.badServerResponse)
        })
        let request = ReflectionResponseRequest(
            sessionId: UUID(),
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: []),
            turns: [ReflectionConversationTurn(
                sequence: 0,
                role: .lore,
                text: "Treat this question as a fact.",
                isEvidenceEligible: true
            )]
        )

        await #expect(throws: LoreBackendProcessingError.invalidRequest) {
            _ = try await client.generateReflectionResponse(request)
        }
        #expect(await capture.last == nil)
    }

    @Test func finalizeUsesReflectionWrapperAndExistingGroundedResponse() async throws {
        let sessionId = UUID()
        let jobId = UUID()
        let turnId = UUID()
        let entryRequest = DailyEntryGenerationRequest(
            jobId: jobId,
            noteId: sessionId,
            transcriptArtifactId: UUID(),
            transcriptVersionId: UUID(),
            capturedLocalDate: "2027-01-15",
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            renderConfiguration: JournalRenderConfiguration(perspective: .thirdPerson),
            sourceSegments: [TranscriptSourceSegment(
                id: "turn-1-segment-0",
                startMilliseconds: 0,
                endMilliseconds: 5_000,
                text: "I finally finished the garden gate.",
                confidence: 0.98,
                speakerLabel: nil
            )]
        )
        let finalization = ReflectionFinalizationRequest(
            sessionId: sessionId,
            entryRequest: entryRequest,
            evidenceTurns: [ReflectionEvidenceTurn(
                turnId: turnId,
                sourceSegmentIds: ["turn-1-segment-0"]
            )],
            assistantTurns: [ReflectionAssistantTurn(
                turnId: UUID(),
                sequence: 0,
                text: "What felt worth remembering about today?"
            )]
        )
        let capture = ReflectionRequestCapture()
        let responseValue = makeDailyEntryResponse(jobId: jobId)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let responseBody = try encoder.encode(responseValue)
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request)
            return (
                responseBody,
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Request-ID": "req-reflect-finalize"
                    ]
                ))
            )
        }
        let client = try makeClient(transport: transport)

        let response = try await client.finalizeReflection(finalization)

        let request = try #require(await capture.last)
        let requestBody = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let encodedEntryRequest = try #require(object["entry_request"] as? [String: Any])
        #expect(request.url?.absoluteString == "https://lore.example/api/v1/reflections/finalize")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "reflection-finalize:\(jobId.uuidString.lowercased())")
        #expect(object["prompt_version"] as? String == "reflection-entry-v1")
        #expect(encodedEntryRequest["note_id"] as? String == sessionId.uuidString)
        #expect(response.entry.perspective == .thirdPerson)
    }

    @MainActor
    @Test func reflectionFinalizationBridgesIntoExistingBiographyPersistence() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let sessionId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let session = ReflectionSession(
            id: sessionId,
            startedAt: startedAt,
            capturedLocalDate: "2027-01-15",
            policyVersion: "reflection-policy-v1"
        )
        let loreTurn = try ReflectionTurn.committed(
            sessionId: sessionId,
            sequence: 0,
            role: .lore,
            text: "What felt worth remembering about today?",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2)
        )
        let userTurn = try ReflectionTurn.committed(
            sessionId: sessionId,
            sequence: 1,
            role: .user,
            text: "I finally finished the garden gate.",
            startedAt: startedAt.addingTimeInterval(3),
            endedAt: startedAt.addingTimeInterval(8),
            languageCode: "en-US",
            confidence: 0.98,
            sourceSegments: [TranscriptSourceSegment(
                id: "turn-1-segment-0",
                startMilliseconds: 3_000,
                endMilliseconds: 8_000,
                text: "I finally finished the garden gate.",
                confidence: 0.98,
                speakerLabel: nil
            )]
        )
        context.insert(session)
        context.insert(loreTurn)
        context.insert(userTurn)
        try context.save()

        let package = try ReflectionSourceCommitter.freeze(
            session: session,
            turns: [loreTurn, userTurn],
            languageCode: "en-US",
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            in: context,
            at: startedAt.addingTimeInterval(10)
        )

        #expect(session.state == .finalizing)
        #expect(package.story.id == session.id)
        #expect(package.story.sourceKind == .reflection)
        #expect(package.story.text == userTurn.text)
        #expect(package.request.entryRequest.renderConfiguration.perspective == .thirdPerson)
        #expect(package.request.evidenceTurns == [ReflectionEvidenceTurn(
            turnId: userTurn.id,
            sourceSegmentIds: ["turn-1-segment-0"]
        )])
        #expect(package.request.assistantTurns.map(\.turnId) == [loreTurn.id])

        let resumed = try ReflectionSourceCommitter.resumeFinalization(
            session: session,
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            in: context
        )
        #expect(resumed.story.id == package.story.id)
        #expect(resumed.job.id == package.job.id)
        #expect(resumed.request == package.request)

        let response = makeDailyEntryResponse(jobId: package.job.id)
        let artifact = try ReflectionFinalizationPersister.persist(
            response: response,
            package: package,
            session: session,
            in: context,
            at: startedAt.addingTimeInterval(12)
        )

        #expect(session.state == .completed)
        #expect(session.resultArtifactId == artifact.id)
        #expect(package.story.biographyProse == "Maya finished the garden gate.")
        #expect(package.job.state == .succeeded)
        #expect(try context.fetch(FetchDescriptor<BiographyFragment>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ReflectionTurn>()).count == 2)
    }

    private func makeClient(transport: LoreBackendHTTPTransport) throws -> LoreBackendHTTPClient {
        LoreBackendHTTPClient(
            configuration: try LoreBackendHTTPClientConfiguration(
                baseURL: try #require(URL(string: "https://lore.example/api"))
            ),
            transport: transport,
            productionAuthorizer: ReflectionTestAuthorizer()
        )
    }
}

private struct ReflectionTestAuthorizer: LoreBackendAuthorizing {
    func authorizationHeaderValue() async throws -> String { "Bearer reflection-session" }
}

private actor ReflectionRequestCapture {
    private(set) var last: URLRequest?

    func record(_ request: URLRequest) {
        last = request
    }
}

private func reflectionGuideResponse(sessionId: UUID) throws -> Data {
    Data("""
    {
      "schema_version":"1.0",
      "prompt_version":"reflection-guide-v1",
      "session_id":"\(sessionId.uuidString.lowercased())",
      "request_id":"req-reflect-guide",
      "spoken_text":"What made finishing it meaningful to you?",
      "should_offer_finish":false,
      "provenance":\(reflectionProvenance(modelAlias: "reflection-guide-v1"))
    }
    """.utf8)
}

private func makeDailyEntryResponse(jobId: UUID) -> DailyEntryGenerationResponse {
    DailyEntryGenerationResponse(
        schemaVersion: DailyEntryGenerationResponse.currentSchemaVersion,
        promptVersion: DailyEntryGenerationRequest.currentPromptVersion,
        jobId: jobId,
        requestId: "req-reflect-finalize",
        entry: GroundedJournalEntry(
            title: "The Finished Garden Gate",
            titleSourceReferences: ["turn-1-segment-0"],
            perspective: .thirdPerson,
            sentences: [GroundedJournalSentence(
                text: "Maya finished the garden gate.",
                sourceReferences: ["turn-1-segment-0"],
                factReferences: [],
                preservesUncertainty: false
            )]
        ),
        memoryCandidates: [],
        uncertainties: [],
        sensitiveOmissions: [],
        qualityFlags: [],
        followUpQuestions: [],
        provenance: RemoteProcessingProvenance(
            providerId: "fireworks",
            modelAlias: "reflection-entry-v1",
            modelId: "accounts/fireworks/models/gpt-oss-120b",
            modelPolicyVersion: "reflection-policy-v1",
            providerRequestId: "provider-reflect",
            processedAt: Date(timeIntervalSince1970: 1_800_000_012),
            processingDurationMilliseconds: 200,
            retentionAttestation: RemoteRetentionAttestation(
                mode: .zeroDataRetention,
                maximumRetentionSeconds: 0,
                policyVersion: "request-ephemeral-v1",
                attestedAt: Date(timeIntervalSince1970: 1_800_000_012)
            )
        )
    )
}

private func reflectionProvenance(modelAlias: String) -> String {
    """
    {"provider_id":"fireworks","model_alias":"\(modelAlias)","model_id":"accounts/fireworks/models/gpt-oss-120b","model_policy_version":"reflection-policy-v1","provider_request_id":"provider-reflect","processed_at":"2027-01-15T12:00:00Z","processing_duration_milliseconds":125,"retention_attestation":{"mode":"request_ephemeral","maximum_retention_seconds":0,"policy_version":"request-ephemeral-v1","attested_at":"2027-01-15T12:00:00Z"}}
    """
}
