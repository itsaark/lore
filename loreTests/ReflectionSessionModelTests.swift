import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct ReflectionSessionModelTests {
    @MainActor
    @Test func firstStartTapBeginsImmediatelyAndOnlyOnce() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(name: "Maya", hometown: "Portland", birthYear: 1990)
        context.insert(profile)
        try context.save()

        let audio = ReflectionFakeAudio()
        let backend = ReflectionFakeBackend()
        let model = ReflectionSessionModel(
            backend: backend,
            modelContext: context,
            userProfile: profile,
            transport: SonioxRealtimeSessionTransport(
                speechToText: ReflectionFakeSTT(),
                textToSpeech: ReflectionFakeTTS()
            ),
            audio: audio
        )

        model.begin()
        #expect(model.presentation.phase == .connecting)
        model.begin()

        try await waitUntil { model.presentation.phase == .listening }
        #expect(audio.permissionRequestCount == 1)
        #expect(await backend.credentialRequestCount == 1)
        #expect(model.presentation.turns.count == 1)
    }

    @MainActor
    @Test func permissionDeniedRetryStartsFreshAfterPermissionIsGranted() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(name: "Maya", hometown: "Portland", birthYear: 1990)
        context.insert(profile)
        try context.save()

        let audio = ReflectionFakeAudio(permissionResponses: [false, true])
        let backend = ReflectionFakeBackend()
        let model = ReflectionSessionModel(
            backend: backend,
            modelContext: context,
            userProfile: profile,
            transport: SonioxRealtimeSessionTransport(
                speechToText: ReflectionFakeSTT(),
                textToSpeech: ReflectionFakeTTS()
            ),
            audio: audio
        )

        model.begin()
        try await waitUntil { model.presentation.phase == .error }
        #expect(model.presentation.canSavePartialReflection == false)
        #expect(try context.fetch(FetchDescriptor<ReflectionSession>()).isEmpty)

        model.retry()
        try await waitUntil { model.presentation.phase == .listening }
        #expect(audio.permissionRequestCount == 2)
        #expect(await backend.credentialRequestCount == 1)
        #expect(try context.fetch(FetchDescriptor<ReflectionSession>()).count == 1)
    }

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
    @Test func openingPromptFinishesBeforeSpeechToTextConnects() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(name: "Maya", hometown: "Portland", birthYear: 1990)
        context.insert(profile)
        try context.save()

        let probe = ReflectionLifecycleProbe()
        let model = ReflectionSessionModel(
            backend: ReflectionFakeBackend(),
            modelContext: context,
            userProfile: profile,
            transport: SonioxRealtimeSessionTransport(
                speechToText: ReflectionFakeSTT(probe: probe),
                textToSpeech: ReflectionFakeTTS(probe: probe)
            ),
            audio: ReflectionFakeAudio()
        )

        model.begin()
        try await waitUntil { model.presentation.phase == .listening }

        #expect(await probe.events == ["tts-connect", "tts-synthesize", "stt-connect"])
    }

    @MainActor
    @Test func finishAnswerDrainsAudioInOrderBeforeFinalize() async throws {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let profile = UserProfile(name: "Maya", hometown: "Portland", birthYear: 1990)
        context.insert(profile)
        try context.save()

        let chunks = [Data([1, 0]), Data([2, 0]), Data([3, 0])]
        let stt = ReflectionFakeSTT(audioSendDelay: .milliseconds(20))
        let model = ReflectionSessionModel(
            backend: ReflectionFakeBackend(),
            modelContext: context,
            userProfile: profile,
            transport: SonioxRealtimeSessionTransport(
                speechToText: stt,
                textToSpeech: ReflectionFakeTTS()
            ),
            audio: ReflectionFakeAudio(captureChunks: chunks)
        )

        model.begin()
        try await waitUntil { model.presentation.phase == .listening }
        model.finishAnswer()
        try await waitUntilAsync { await stt.didFinalize }

        #expect(await stt.sentAudio == chunks)
        #expect(await stt.actions == ["audio", "audio", "audio", "finalize"])
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

    @MainActor
    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for asynchronous reflection state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ReflectionFakeBackend: LoreReflectionBackendClient {
    private(set) var lastGuideRequest: ReflectionResponseRequest?
    private(set) var credentialRequestCount = 0

    func createReflectionSessionCredentials(
        _ request: ReflectionSessionCredentialsRequest
    ) async throws -> ReflectionSessionCredentialsResponse {
        credentialRequestCount += 1
        return ReflectionSessionCredentialsResponse(
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

private actor ReflectionLifecycleProbe {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor ReflectionFakeSTT: SonioxRealtimeTranscribing {
    private var queued: [SonioxTranscriptUpdate] = []
    private var waiter: CheckedContinuation<SonioxTranscriptUpdate, Error>?
    private let probe: ReflectionLifecycleProbe?
    private let audioSendDelay: Duration?
    private(set) var sentAudio: [Data] = []
    private(set) var actions: [String] = []
    private(set) var didFinalize = false

    init(
        probe: ReflectionLifecycleProbe? = nil,
        audioSendDelay: Duration? = nil
    ) {
        self.probe = probe
        self.audioSendDelay = audioSendDelay
    }

    func connect(credential: SonioxTemporaryCredential, configuration: SonioxSTTConfiguration) async throws {
        await probe?.record("stt-connect")
    }
    func sendAudio(_ pcmS16LE: Data) async throws {
        if let audioSendDelay { try await Task.sleep(for: audioSendDelay) }
        sentAudio.append(pcmS16LE)
        actions.append("audio")
    }
    func finalizeTurn() async throws {
        actions.append("finalize")
        didFinalize = true
    }
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
    private let probe: ReflectionLifecycleProbe?

    init(probe: ReflectionLifecycleProbe? = nil) {
        self.probe = probe
    }

    func connect(credential: SonioxTemporaryCredential) async throws {
        await probe?.record("tts-connect")
    }

    func synthesize(text: String, streamID: String, configuration: SonioxTTSConfiguration) async throws {
        await probe?.record("tts-synthesize")
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
    private(set) var permissionRequestCount = 0
    private var permissionResponses: [Bool]
    private let captureChunks: [Data]

    init(
        permissionResponses: [Bool] = [true],
        captureChunks: [Data] = [Data([0, 0])]
    ) {
        self.permissionResponses = permissionResponses
        self.captureChunks = captureChunks
    }

    func requestMicrophonePermission() async -> Bool {
        permissionRequestCount += 1
        guard !permissionResponses.isEmpty else { return true }
        return permissionResponses.removeFirst()
    }

    func startCapture(
        recordingTo fileURL: URL,
        onPCMChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        isCapturing = true
        captureChunks.forEach(onPCMChunk)
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
