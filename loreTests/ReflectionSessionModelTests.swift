import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct ReflectionSessionModelTests {
    @MainActor
    @Test func controlledTurnCommitsOnlyFinalUserSpeechBeforeRequestingGuide() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(name: "Maya", hometown: "Portland", birthYear: 1990)
        context.insert(profile)
        try context.save()

        let stt = ReflectionFakeSTT()
        let tts = ReflectionFakeTTS()
        let audio = ReflectionFakeAudio()
        let backend = ReflectionFakeBackend()
        let model = ReflectionSessionModel(
            backend: backend,
            modelContext: context,
            userProfile: profile,
            languageCode: "en-US",
            transport: SonioxRealtimeSessionTransport(
                speechToText: stt,
                textToSpeech: tts
            ),
            audio: audio
        )

        model.begin()
        try await waitUntil { model.presentation.phase == .listening }
        #expect(model.presentation.turns.map(\.speaker) == [.lore])

        model.finishAnswer()
        await stt.yield(SonioxTranscriptUpdate(
            tokens: [SonioxTranscriptToken(
                text: "I finished the garden gate.",
                startMilliseconds: 0,
                endMilliseconds: 1_800,
                confidence: 0.98,
                isFinal: true,
                language: "en"
            )],
            boundary: .manualFinalization,
            finalAudioProcessedMilliseconds: 1_800,
            totalAudioProcessedMilliseconds: 1_800,
            isSessionFinished: false
        ))

        try await waitUntil {
            model.presentation.phase == .listening && model.presentation.turns.count == 3
        }
        #expect(model.presentation.turns.map(\.speaker) == [.lore, .user, .lore])
        #expect(model.presentation.turns[1].text == "I finished the garden gate.")
        #expect(await backend.lastGuideRequest?.turns.last?.role == .user)
        #expect(await backend.lastGuideRequest?.turns.last?.isEvidenceEligible == true)

        let persistedTurns = try context.fetch(FetchDescriptor<ReflectionTurn>())
        let userTurn = try #require(persistedTurns.first(where: { $0.role == .user }))
        #expect(userTurn.isEvidenceEligible)
        #expect(try userTurn.decodedSourceSegments().map(\.text) == ["I finished the garden gate."])
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for reflection state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ReflectionFakeBackend: LoreReflectionBackendClient {
    private(set) var lastGuideRequest: ReflectionResponseRequest?

    func createReflectionSessionCredentials(
        _ request: ReflectionSessionCredentialsRequest
    ) async throws -> ReflectionSessionCredentialsResponse {
        ReflectionSessionCredentialsResponse(
            schemaVersion: "1.0",
            sessionId: request.sessionId,
            stt: ReflectionSTTCredential(
                temporaryApiKey: "temp-stt",
                expiresAt: Date().addingTimeInterval(300),
                websocketUrl: SonioxRealtimeEndpoint.speechToText,
                modelAlias: "reflection-stt-v1",
                audioFormat: "pcm_s16le",
                sampleRate: 16_000,
                numChannels: 1
            ),
            tts: ReflectionTTSCredential(
                temporaryApiKey: "temp-tts",
                expiresAt: Date().addingTimeInterval(300),
                websocketUrl: SonioxRealtimeEndpoint.textToSpeech,
                modelAlias: "reflection-voice-v1",
                voice: "Adrian",
                audioFormat: "pcm_s16le",
                sampleRate: 24_000
            ),
            maximumSessionDurationSeconds: 1_200
        )
    }

    func generateReflectionResponse(
        _ request: ReflectionResponseRequest
    ) async throws -> ReflectionResponse {
        lastGuideRequest = request
        return ReflectionResponse(
            schemaVersion: "1.0",
            promptVersion: "reflection-guide-v1",
            sessionId: request.sessionId,
            requestId: "guide-request",
            spokenText: "What made finishing it memorable?",
            shouldOfferFinish: false,
            provenance: reflectionTestProvenance(modelAlias: "reflection-guide-v1")
        )
    }

    func finalizeReflection(
        _ request: ReflectionFinalizationRequest
    ) async throws -> DailyEntryGenerationResponse {
        throw LoreBackendProcessingError.notConfigured
    }
}

private actor ReflectionFakeSTT: SonioxRealtimeTranscribing {
    private var queued: [SonioxTranscriptUpdate] = []
    private var waiter: CheckedContinuation<SonioxTranscriptUpdate, Error>?

    func connect(credential: SonioxTemporaryCredential, configuration: SonioxSTTConfiguration) async throws {}
    func sendAudio(_ pcmS16LE: Data) async throws {}
    func finalizeTurn() async throws {}
    func keepAlive() async throws {}
    func finishSession() async throws {}
    func disconnect() async {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func receive() async throws -> SonioxTranscriptUpdate {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func yield(_ update: SonioxTranscriptUpdate) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: update)
        } else {
            queued.append(update)
        }
    }
}

private actor ReflectionFakeTTS: SonioxRealtimeSynthesizing {
    private var events: [SonioxTTSEvent] = []

    func connect(credential: SonioxTemporaryCredential) async throws {}

    func synthesize(text: String, streamID: String, configuration: SonioxTTSConfiguration) async throws {
        events.append(.terminated(streamID: streamID))
    }

    func cancel(streamID: String) async throws {
        events.append(.terminated(streamID: streamID))
    }

    func keepAlive() async throws {}

    func receive() async throws -> SonioxTTSEvent {
        guard !events.isEmpty else { throw SonioxRealtimeError.transport }
        return events.removeFirst()
    }

    func disconnect() async { events.removeAll() }
}

@MainActor
private final class ReflectionFakeAudio: ReflectionAudioControlling {
    private(set) var isCapturing = false
    private(set) var isPlaying = false

    func requestMicrophonePermission() async -> Bool { true }

    func startCapture(
        recordingTo fileURL: URL,
        onPCMChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        isCapturing = true
        onPCMChunk(Data([0, 0]))
    }

    func stopCapture() throws { isCapturing = false }
    func replayProtectedCapture(
        at fileURL: URL,
        sendPCMChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await sendPCMChunk(Data([0, 0]))
    }
    func enqueuePlaybackPCM(_ pcmS16LE: Data) throws { isPlaying = true }
    func waitForPlaybackToFinish() async { isPlaying = false }
    func stopPlayback() { isPlaying = false }
    func tearDown() { isCapturing = false; isPlaying = false }
}

private func reflectionTestProvenance(modelAlias: String) -> RemoteProcessingProvenance {
    RemoteProcessingProvenance(
        providerId: "fireworks",
        modelAlias: modelAlias,
        modelId: "test-model",
        modelPolicyVersion: "test-policy",
        providerRequestId: "provider-request",
        processedAt: Date(),
        processingDurationMilliseconds: 1,
        retentionAttestation: RemoteRetentionAttestation(
            mode: .zeroDataRetention,
            maximumRetentionSeconds: 0,
            policyVersion: "test-retention",
            attestedAt: Date()
        )
    )
}
