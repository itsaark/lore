import Foundation
import Testing
@testable import lore

struct SonioxRealtimeTransportTests {
    @Test func credentialsOnlyAllowSecureSonioxEndpoints() throws {
        let valid = try makeCredential(endpoint: SonioxRealtimeEndpoint.speechToText)
        #expect(valid.endpoint == SonioxRealtimeEndpoint.speechToText)

        #expect(throws: SonioxRealtimeError.invalidConfiguration) {
            try makeCredential(endpoint: URL(string: "wss://soniox.com.attacker.example/socket")!)
        }
        #expect(throws: SonioxRealtimeError.invalidConfiguration) {
            try makeCredential(endpoint: URL(string: "https://stt-rt.soniox.com/socket")!)
        }
    }

    @Test func sttConfigurationMatchesRealtimePCMContract() throws {
        let message = try SonioxRealtimeSTTClient.configurationMessage(
            credential: makeCredential(endpoint: SonioxRealtimeEndpoint.speechToText),
            configuration: SonioxSTTConfiguration(languageHints: ["en", "te"])
        )
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(message.utf8)
        ) as? [String: Any])

        #expect(object["model"] as? String == "stt-rt-v5")
        #expect(object["audio_format"] as? String == "pcm_s16le")
        #expect(object["sample_rate"] as? Int == 16_000)
        #expect(object["num_channels"] as? Int == 1)
        #expect(object["enable_endpoint_detection"] as? Bool == true)
        #expect(object["language_hints"] as? [String] == ["en", "te"])
    }

    @Test func sttParserSeparatesEvidenceTokensFromEndpointMarker() throws {
        let update = try SonioxRealtimeSTTClient.parseResponse(Data("""
        {
          "tokens": [
            {"text":"Today ","start_ms":0,"end_ms":300,"confidence":0.98,"is_final":true,"language":"en"},
            {"text":"was quiet.","start_ms":300,"end_ms":800,"confidence":0.96,"is_final":true,"language":"en"},
            {"text":"<end>","is_final":true}
          ],
          "final_audio_proc_ms":800,
          "total_audio_proc_ms":900
        }
        """.utf8))

        #expect(update.tokens.map(\.text) == ["Today ", "was quiet."])
        #expect(update.tokens.allSatisfy { $0.isFinal })
        #expect(update.boundary == .endpoint)
        #expect(update.finalAudioProcessedMilliseconds == 800)
        #expect(!update.isSessionFinished)
    }

    @Test func sttParserRecognizesManualFinalizationAndFinishedSession() throws {
        let update = try SonioxRealtimeSTTClient.parseResponse(Data("""
        {"tokens":[{"text":"<fin>","is_final":true}],"finished":true}
        """.utf8))

        #expect(update.tokens.isEmpty)
        #expect(update.boundary == .manualFinalization)
        #expect(update.isSessionFinished)
    }

    @Test func providerErrorsExposeCredentialAndBackoffBoundaries() {
        let expired = SonioxRealtimeError.provider(SonioxProviderError(
            statusCode: 403,
            type: "temp_api_key_session_expired",
            message: "expired",
            requestID: nil
        ))
        let unavailable = SonioxRealtimeError.provider(SonioxProviderError(
            statusCode: 503,
            type: "service_unavailable",
            message: "retry",
            requestID: "request-1"
        ))

        #expect(expired.recoveryAction == .refreshCredentials)
        #expect(unavailable.recoveryAction == .reconnectWithBackoff)
        #expect(SonioxRealtimeError.transport.recoveryAction == .reconnect)
    }

    @Test func ttsParserDecodesPCMAndCharacterTimings() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let event = try SonioxRealtimeTTSClient.parseResponse(Data("""
        {
          "stream_id":"turn-1",
          "audio":"\(pcm.base64EncodedString())",
          "audio_end":true,
          "timestamps":{
            "characters":["H","i"],
            "character_start_times_seconds":[0.0,0.1],
            "character_end_times_seconds":[0.1,0.2]
          }
        }
        """.utf8))

        guard case .audio(let streamID, let bytes, let isFinal, let timings) = event else {
            Issue.record("Expected an audio event")
            return
        }
        #expect(streamID == "turn-1")
        #expect(bytes == pcm)
        #expect(isFinal)
        #expect(timings.map(\.character) == ["H", "i"])
    }

    @Test func ttsParserRejectsMismatchedTimestampArrays() {
        #expect(throws: SonioxRealtimeError.invalidMessage) {
            try SonioxRealtimeTTSClient.parseResponse(Data("""
            {
              "stream_id":"turn-1",
              "audio":"AQI=",
              "timestamps":{
                "characters":["H","i"],
                "character_start_times_seconds":[0.0],
                "character_end_times_seconds":[0.1,0.2]
              }
            }
            """.utf8))
        }
    }

    @MainActor
    @Test func turnAudioURLUsesAnUnambiguousLocalCAFContainer() {
        let sessionID = UUID()
        let turnID = UUID()
        let url = ReflectionAudioController.makeProtectedTurnAudioURL(
            sessionID: sessionID,
            turnID: turnID
        )

        #expect(url.pathExtension == "caf")
        #expect(url.lastPathComponent.contains(turnID.uuidString.lowercased()))
        #expect(url.deletingLastPathComponent().lastPathComponent.contains(
            sessionID.uuidString.lowercased()
        ))
    }

    @Test func sttClientUsesOnePersistentSocketForAudioAndTurnControls() async throws {
        let recorder = FakeSonioxSocket()
        let client = SonioxRealtimeSTTClient(connector: recorder.connector)
        try await client.connect(
            credential: makeCredential(endpoint: SonioxRealtimeEndpoint.speechToText),
            configuration: .init()
        )
        try await client.sendAudio(Data([1, 2, 3, 4]))
        try await client.finalizeTurn()
        try await client.keepAlive()
        try await client.finishSession()
        await client.disconnect()

        let messages = await recorder.sentMessages
        #expect(messages.count == 5)
        #expect(messages[1] == .data(Data([1, 2, 3, 4])))
        #expect(messages[2] == .text("{\"type\":\"finalize\"}"))
        #expect(messages[3] == .text("{\"type\":\"keepalive\"}"))
        #expect(messages[4] == .data(Data()))
        #expect(await recorder.wasClosed)
    }

    @Test func ttsClientWaitsForTerminatedBeforeReusingStreamID() async throws {
        let recorder = FakeSonioxSocket(receiveMessages: [
            .text("{\"stream_id\":\"turn-1\",\"audio\":\"AQI=\",\"audio_end\":true}"),
            .text("{\"stream_id\":\"turn-1\",\"terminated\":true}")
        ])
        let client = SonioxRealtimeTTSClient(connector: recorder.connector)
        try await client.connect(
            credential: makeCredential(endpoint: SonioxRealtimeEndpoint.textToSpeech)
        )
        try await client.synthesize(text: "Hello", streamID: "turn-1", configuration: .init())
        await #expect(throws: SonioxRealtimeError.streamAlreadyActive) {
            try await client.synthesize(text: "Again", streamID: "turn-1", configuration: .init())
        }

        _ = try await client.receive()
        let terminal = try await client.receive()
        #expect(terminal == .terminated(streamID: "turn-1"))

        try await client.synthesize(text: "Again", streamID: "turn-1", configuration: .init())
        #expect(await recorder.sentMessages.count == 4)
        await client.disconnect()
    }

    private func makeCredential(endpoint: URL) throws -> SonioxTemporaryCredential {
        try SonioxTemporaryCredential(
            endpoint: endpoint,
            apiKey: "temporary-test-key",
            expiresAt: Date().addingTimeInterval(300),
            maximumSessionDurationSeconds: 1_200
        )
    }
}

private actor FakeSonioxSocket {
    private(set) var sentMessages: [SonioxWebSocketMessage] = []
    private(set) var wasClosed = false
    private var receiveMessages: [SonioxWebSocketMessage]

    init(receiveMessages: [SonioxWebSocketMessage] = []) {
        self.receiveMessages = receiveMessages
    }

    nonisolated var connector: SonioxWebSocketConnector {
        SonioxWebSocketConnector { _ in
            SonioxWebSocketConnection(
                send: { message in await self.record(message) },
                receive: { try await self.nextMessage() },
                close: { await self.recordClose() }
            )
        }
    }

    private func record(_ message: SonioxWebSocketMessage) {
        sentMessages.append(message)
    }

    private func nextMessage() throws -> SonioxWebSocketMessage {
        guard !receiveMessages.isEmpty else { throw SonioxRealtimeError.transport }
        return receiveMessages.removeFirst()
    }

    private func recordClose() {
        wasClosed = true
    }
}
