import Foundation
import Testing
@testable import lore

@Suite(.serialized)
struct LoreBackendHTTPClientTests {
    @Test func configurationRequiresHTTPS() throws {
        #expect(throws: LoreBackendProcessingError.invalidConfiguration) {
            _ = try LoreBackendHTTPClientConfiguration(
                baseURL: try #require(URL(string: "http://lore.example"))
            )
        }
    }

    @Test func transcriptionUsesBoundedMultipartAndDecodesStrictResponse() async throws {
        let jobId = try #require(UUID(uuidString: "9f170d1f-8e71-4a12-a861-2ca5f9f52ed2"))
        let chunkId = "chunk-\(jobId.uuidString.lowercased())-0"
        let capture = LoreRequestCapture()
        let responseData = try transcriptionResponse(jobId: jobId, chunkId: chunkId)
        let transport = LoreBackendHTTPTransport { request, uploadFileURL in
            let body = try Data(contentsOf: try #require(uploadFileURL))
            await capture.record(request, body: body)
            return (
                responseData,
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json; charset=utf-8",
                        "X-Request-ID": "req_backend_audio"
                    ]
                ))
            )
        }
        let client = try makeClient(transport: transport)

        let response = try await client.transcribe(RemoteTranscriptionRequest(
            jobId: jobId,
            audio: RemoteAudioPayload(
                bytes: Data("synthetic-audio".utf8),
                mimeType: "audio/m4a",
                filenameExtension: "m4a",
                durationSeconds: 2.5
            ),
            languageCode: "en-US",
            vocabularyHints: ["Hyderabad"]
        ))

        let recorded = try #require(await capture.last)
        let bodyText = String(decoding: recorded.body, as: UTF8.self)
        #expect(recorded.request.url?.absoluteString == "https://lore.example/api/v1/transcriptions")
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer production-session")
        #expect(recorded.request.value(forHTTPHeaderField: "Idempotency-Key") == "transcription:\(jobId.uuidString.lowercased()):chunk-0")
        #expect(recorded.request.value(forHTTPHeaderField: "X-Request-ID")?.hasPrefix("ios_") == true)
        #expect(recorded.body.count <= LoreBackendHTTPClient.maximumMultipartBodyBytes)
        #expect(bodyText.contains("name=\"retention_policy\""))
        #expect(bodyText.contains("{\"maximum_retention_seconds\":0,\"mode\":\"request_ephemeral\"}"))
        #expect(bodyText.contains("name=\"vocabulary_hints\""))
        #expect(bodyText.contains("Hyderabad"))
        #expect(bodyText.contains("name=\"audio\"; filename=\"audio.m4a\""))
        #expect(recorded.request.allHTTPHeaderFields?.values.contains(where: { $0.contains("GROQ") }) == false)
        #expect(response.requestId == "req_backend_audio")
        #expect(response.provenance.providerId == "groq")
        #expect(response.provenance.retentionAttestation.maximumRetentionSeconds == 0)
    }

    @Test func transcriptionRejectsAudioOverChunkLimitBeforeTransport() async throws {
        let capture = LoreRequestCapture()
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request, body: Data())
            throw URLError(.badServerResponse)
        }
        let client = try makeClient(transport: transport)
        let request = RemoteTranscriptionRequest(
            jobId: UUID(),
            audio: RemoteAudioPayload(
                bytes: Data(count: LoreBackendHTTPClient.maximumAudioChunkBytes + 1),
                mimeType: "audio/m4a",
                filenameExtension: "m4a",
                durationSeconds: 1
            )
        )

        await #expect(throws: LoreBackendProcessingError.payloadTooLarge(
            maximumBytes: LoreBackendHTTPClient.maximumAudioChunkBytes
        )) {
            _ = try await client.transcribe(request)
        }
        #expect(await capture.last == nil)
    }

    @Test func dailyEntryUsesSnakeCaseJSONAndMapsRateLimitRetryAfter() async throws {
        let capture = LoreRequestCapture()
        let errorData = Data("""
        {
          "schema_version":"1.0",
          "request_id":"req_rate_limit",
          "error":{"code":"provider_rate_limited","message":"Busy","retryable":true},
          "retry_after_seconds":7
        }
        """.utf8)
        let transport = LoreBackendHTTPTransport { request, _ in
            await capture.record(request, body: request.httpBody ?? Data())
            return (
                errorData,
                try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "9"]
                ))
            )
        }
        let client = try makeClient(transport: transport)
        let request = makeDailyRequest()

        await #expect(throws: LoreBackendProcessingError.rateLimited(retryAfterSeconds: 7)) {
            _ = try await client.generateDailyEntry(request)
        }
        let recorded = try #require(await capture.last)
        let object = try #require(
            JSONSerialization.jsonObject(with: recorded.body) as? [String: Any]
        )
        let render = try #require(object["render_configuration"] as? [String: Any])
        let segments = try #require(object["source_segments"] as? [[String: Any]])
        let sourceSegment = try #require(segments.first)
        #expect(recorded.request.url?.absoluteString == "https://lore.example/api/v1/daily-entries")
        #expect(recorded.request.value(forHTTPHeaderField: "Idempotency-Key") == "daily-entry:\(request.jobId.uuidString.lowercased())")
        #expect(render["perspective"] as? String == "third_person")
        #expect(sourceSegment["chunk_id"] as? String == "source-0")
        #expect(sourceSegment.keys.contains("confidence"))
        #expect(sourceSegment["confidence"] is NSNull)
        #expect(sourceSegment.keys.contains("speaker_label"))
        #expect(sourceSegment["speaker_label"] is NSNull)
        #expect((object["retention_policy"] as? [String: Any])?["mode"] as? String == "request_ephemeral")
    }

    @Test func dailyEntryDecodesGroundedResponseAndRejectsWrongJob() async throws {
        let request = makeDailyRequest()
        let transport = LoreBackendHTTPTransport { urlRequest, _ in
            (
                try dailyEntryResponse(jobId: request.jobId),
                try #require(HTTPURLResponse(
                    url: urlRequest.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Request-ID": "req_backend_daily"
                    ]
                ))
            )
        }
        let client = try makeClient(transport: transport)

        let response = try await client.generateDailyEntry(request)

        #expect(response.entry.prose == "Maya recorded a synthetic note.")
        #expect(response.requestId == "req_backend_daily")
        #expect(response.provenance.providerId == "fireworks")
    }

    @Test func cancelledTransportProducesProviderNeutralCancellation() async throws {
        let transport = LoreBackendHTTPTransport { _, _ in
            throw URLError(.cancelled)
        }
        let client = try makeClient(transport: transport)

        await #expect(throws: LoreBackendProcessingError.cancelled) {
            _ = try await client.generateDailyEntry(makeDailyRequest())
        }
    }

    @Test func remoteSpeechAdapterUsesStableFileJobAndNormalizedProvenance() async throws {
        let storyId = try #require(UUID(uuidString: "f8a383e5-8830-41e4-a92f-257fa295d41b"))
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(storyId.uuidString)
            .appendingPathExtension("caf")
        let capture = LoreTranscriptionRequestCapture()
        let backend = ClosureLoreBackendClient(
            transcribe: { request in
                await capture.record(request)
                return try decodedTranscriptionResponse(
                    jobId: request.jobId,
                    chunkId: "adapter-chunk"
                )
            },
            generate: { _ in throw LoreBackendProcessingError.notConfigured }
        )
        let adapter = LoreBackendRemoteSpeechTranscriber(
            backend: backend,
            audioFileLoader: LoreRemoteAudioFileLoader { requestedURL in
                #expect(requestedURL == sourceURL)
                return RemoteAudioPayload(
                    bytes: Data("audio".utf8),
                    mimeType: "audio/m4a",
                    filenameExtension: "m4a",
                    durationSeconds: 2
                )
            }
        )

        let result = try await adapter.transcribe(
            audioFileURL: sourceURL,
            localeIdentifier: "en_US"
        )

        let request = try #require(await capture.last)
        #expect(request.jobId == storyId)
        #expect(request.languageCode == "en")
        #expect(result.transcript == "Synthetic transcript.")
        #expect(result.provider == "groq")
        #expect(result.model == "whisper-large-v3-turbo")
        #expect(result.requestID == "req_backend_audio")
    }

    @Test func remoteSpeechAdapterUploadsAndAssemblesBoundedChunksInOrder() async throws {
        let storyId = try #require(UUID(uuidString: "c76f329c-775f-4a59-a352-e650cc73ea8c"))
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(storyId.uuidString)
            .appendingPathExtension("caf")
        let capture = LoreTranscriptionRequestCapture()
        let backend = ClosureLoreBackendClient(
            transcribe: { request in
                await capture.record(request)
                var response = try decodedTranscriptionResponse(
                    jobId: request.jobId,
                    chunkId: "chunk-\(request.chunkIndex)"
                )
                response.chunk = RemoteTranscriptionChunk(
                    id: "chunk-\(request.chunkIndex)",
                    index: request.chunkIndex,
                    count: request.chunkCount,
                    startMilliseconds: request.startMilliseconds,
                    durationMilliseconds: Int(request.audio.durationSeconds * 1_000)
                )
                response.transcript = request.chunkIndex == 0 ? "First memory." : "Second memory."
                return response
            },
            generate: { _ in throw LoreBackendProcessingError.notConfigured }
        )
        let adapter = LoreBackendRemoteSpeechTranscriber(
            backend: backend,
            audioFileLoader: LoreRemoteAudioFileLoader(loadChunks: { _ in
                [
                    LoadedRemoteAudioChunk(
                        audio: RemoteAudioPayload(
                            bytes: Data("first".utf8),
                            mimeType: "audio/m4a",
                            filenameExtension: "m4a",
                            durationSeconds: 90
                        ),
                        startMilliseconds: 0
                    ),
                    LoadedRemoteAudioChunk(
                        audio: RemoteAudioPayload(
                            bytes: Data("second".utf8),
                            mimeType: "audio/m4a",
                            filenameExtension: "m4a",
                            durationSeconds: 45
                        ),
                        startMilliseconds: 90_000
                    )
                ]
            })
        )

        let result = try await adapter.transcribe(
            audioFileURL: sourceURL,
            localeIdentifier: "en-US"
        )
        let requests = await capture.all

        #expect(requests.count == 2)
        #expect(requests.map(\.jobId) == [storyId, storyId])
        #expect(requests.map(\.chunkIndex) == [0, 1])
        #expect(requests.map(\.chunkCount) == [2, 2])
        #expect(requests.map(\.startMilliseconds) == [0, 90_000])
        #expect(result.transcript == "First memory. Second memory.")
    }

    private func makeClient(
        transport: LoreBackendHTTPTransport
    ) throws -> LoreBackendHTTPClient {
        let configuration = try LoreBackendHTTPClientConfiguration(
            baseURL: try #require(URL(string: "https://lore.example/api"))
        )
        return LoreBackendHTTPClient(
            configuration: configuration,
            transport: transport,
            productionAuthorizer: LoreStaticTestAuthorizer(value: "Bearer production-session")
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
            subject: JournalSubject(displayName: "Maya", pronouns: ["she", "her"]),
            sourceSegments: [
                TranscriptSourceSegment(
                    id: "s1",
                    startMilliseconds: 0,
                    endMilliseconds: 2_500,
                    text: "Synthetic transcript.",
                    confidence: nil,
                    speakerLabel: nil
                )
            ]
        )
    }

    private func transcriptionResponse(jobId: UUID, chunkId: String) throws -> Data {
        Data("""
        {
          "schema_version":"1.0",
          "job_id":"\(jobId.uuidString.lowercased())",
          "request_id":"req_backend_audio",
          "chunk":{"id":"\(chunkId)","index":0,"count":1,"start_milliseconds":0,"duration_milliseconds":2500},
          "transcript":"Synthetic transcript.",
          "language_code":"en",
          "segments":[{"id":"segment-0","chunk_id":"\(chunkId)","start_milliseconds":0,"end_milliseconds":2500,"text":"Synthetic transcript.","confidence":null,"speaker_label":null}],
          "provenance":\(provenance(provider: "groq", modelAlias: "transcription-fallback-v1", modelId: "whisper-large-v3-turbo"))
        }
        """.utf8)
    }

    private func decodedTranscriptionResponse(
        jobId: UUID,
        chunkId: String
    ) throws -> RemoteTranscriptionResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            RemoteTranscriptionResponse.self,
            from: transcriptionResponse(jobId: jobId, chunkId: chunkId)
        )
    }

    private func dailyEntryResponse(jobId: UUID) throws -> Data {
        Data("""
        {
          "schema_version":"1.0",
          "prompt_version":"grounded-journal-v1",
          "job_id":"\(jobId.uuidString.lowercased())",
          "request_id":"req_backend_daily",
          "entry":{"title":"Synthetic day","title_source_references":["s1"],"perspective":"third_person","sentences":[{"text":"Maya recorded a synthetic note.","source_references":["s1"],"fact_references":[],"preserves_uncertainty":false}]},
          "memory_candidates":[],
          "uncertainties":[],
          "sensitive_omissions":[],
          "quality_flags":[],
          "follow_up_questions":[],
          "provenance":\(provenance(provider: "fireworks", modelAlias: "daily-entry-v1", modelId: "accounts/fireworks/models/deepseek-v4-flash"))
        }
        """.utf8)
    }

    private func provenance(provider: String, modelAlias: String, modelId: String) -> String {
        """
        {"provider_id":"\(provider)","model_alias":"\(modelAlias)","model_id":"\(modelId)","model_policy_version":"test-policy-v1","provider_request_id":"provider-request","processed_at":"2026-08-03T12:00:00Z","processing_duration_milliseconds":125,"retention_attestation":{"mode":"request_ephemeral","maximum_retention_seconds":0,"policy_version":"request-ephemeral-v1","attested_at":"2026-08-03T12:00:00Z"}}
        """
    }
}

private struct LoreStaticTestAuthorizer: LoreBackendAuthorizing {
    let value: String
    func authorizationHeaderValue() -> String { value }
}

private actor LoreRequestCapture {
    struct Value: @unchecked Sendable {
        let request: URLRequest
        let body: Data
    }

    private(set) var last: Value?

    func record(_ request: URLRequest, body: Data) {
        last = Value(request: request, body: body)
    }
}

private actor LoreTranscriptionRequestCapture {
    private(set) var last: RemoteTranscriptionRequest?
    private(set) var all: [RemoteTranscriptionRequest] = []

    func record(_ request: RemoteTranscriptionRequest) {
        last = request
        all.append(request)
    }
}

private struct ClosureLoreBackendClient: LoreBackendProcessingClient {
    let transcribeImplementation: @Sendable (RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse
    let generateImplementation: @Sendable (DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse

    init(
        transcribe: @escaping @Sendable (RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse,
        generate: @escaping @Sendable (DailyEntryGenerationRequest) async throws -> DailyEntryGenerationResponse
    ) {
        transcribeImplementation = transcribe
        generateImplementation = generate
    }

    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse {
        try await transcribeImplementation(request)
    }

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        try await generateImplementation(request)
    }
}
