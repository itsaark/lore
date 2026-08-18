import Combine
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ReflectionSessionModel: ObservableObject {
    @Published private(set) var presentation = ReflectionSessionPresentation(phase: .idle)

    private let backend: any LoreReflectionBackendClient
    private let transport: SonioxRealtimeSessionTransport
    private let audio: any ReflectionAudioControlling
    private let modelContext: ModelContext
    private let userProfile: UserProfile
    private let languageCode: String

    private var session: ReflectionSession?
    private var turns: [ReflectionTurn] = []
    private var finalizationPackage: ReflectionFinalizationPackage?
    private var credentials: ReflectionSessionCredentialsResponse?
    private var ttsConfiguration = SonioxTTSConfiguration()
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var currentFlowTask: Task<Void, Never>?
    private var currentTTSStreamID: String?
    private var currentUserTurnID: UUID?
    private var currentUserTurnStartedAt: Date?
    private var currentAudioURL: URL?
    private var finalTokens: [SonioxTranscriptToken] = []
    private var isCompletingUserTurn = false
    private var endAfterCurrentTurn = false
    private var hasStarted = false

    init(
        backend: any LoreReflectionBackendClient,
        modelContext: ModelContext,
        userProfile: UserProfile,
        languageCode: String = Locale.current.language.languageCode?.identifier ?? "en",
        transport: SonioxRealtimeSessionTransport = SonioxRealtimeSessionTransport(),
        audio: (any ReflectionAudioControlling)? = nil
    ) {
        self.backend = backend
        self.modelContext = modelContext
        self.userProfile = userProfile
        self.languageCode = languageCode
        self.transport = transport
        self.audio = audio ?? ReflectionAudioController()
    }

    deinit {
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        timerTask?.cancel()
        currentFlowTask?.cancel()
    }

    var actions: ReflectionSessionActions {
        ReflectionSessionActions(
            begin: { [weak self] in self?.begin() },
            interruptLore: { [weak self] in self?.interruptLore() },
            finishAnswer: { [weak self] in self?.finishAnswer() },
            requestEnd: { [weak self] in self?.requestEnd() },
            continueReflection: { [weak self] in self?.continueReflection() },
            saveReflection: { [weak self] in self?.saveReflection() },
            retry: { [weak self] in self?.retry() },
            savePartialReflection: { [weak self] in self?.savePartialReflection() },
            discardReflection: { [weak self] in self?.discardReflection() },
            close: { [weak self] in self?.closeCompletedReflection() },
            viewBiography: {}
        )
    }

    func begin() {
        guard !hasStarted, presentation.phase == .idle else { return }
        hasStarted = true
        presentation = ReflectionSessionPresentation(phase: .connecting)
        currentFlowTask = Task { [weak self] in
            await self?.beginFlow()
        }
    }

    func resumePendingFinalizationIfNeeded() {
        guard !hasStarted, session == nil else { return }
        do {
            guard let pending = try modelContext.fetch(FetchDescriptor<ReflectionSession>())
                .filter({ $0.state == .finalizing })
                .max(by: { $0.updatedAt < $1.updatedAt })
            else { return }
            let storedTurns = try modelContext.fetch(FetchDescriptor<ReflectionTurn>())
                .filter { $0.sessionId == pending.id }
                .sorted { $0.sequence < $1.sequence }
            let package = try ReflectionSourceCommitter.resumeFinalization(
                session: pending,
                subject: subject,
                in: modelContext
            )
            session = pending
            turns = storedTurns
            finalizationPackage = package
            hasStarted = true
            refreshPresentationTurns()
            currentFlowTask = Task { [weak self] in await self?.finalizeFlow() }
        } catch {
            fail("Lore found an unfinished biography entry but could not resume it safely.", canSavePartial: true)
        }
    }

    func interruptLore() {
        guard presentation.phase == .speaking, let streamID = currentTTSStreamID else { return }
        audio.stopPlayback()
        Task { [weak self] in
            guard let self else { return }
            try? await transport.textToSpeech.cancel(streamID: streamID)
        }
    }

    func finishAnswer() {
        guard presentation.phase == .listening, !isCompletingUserTurn else { return }
        isCompletingUserTurn = true
        presentation.phase = .thinking
        do {
            try audio.stopCapture()
        } catch {
            fail("Lore could not finish recording this answer.", canSavePartial: !turns.isEmpty)
            return
        }
        Task { [weak self] in
            do {
                guard let self else { return }
                try await transport.speechToText.finalizeTurn()
            } catch is CancellationError {
                return
            } catch {
                await self?.handleTransportFailure()
            }
        }
    }

    func requestEnd() {
        switch presentation.phase {
        case .listening:
            endAfterCurrentTurn = true
            finishAnswer()
            presentation.phase = .ending
        case .speaking:
            guard hasFinalizedUserTurn else {
                discardReflection()
                return
            }
            endAfterCurrentTurn = true
            interruptLore()
            presentation.phase = .ending
        case .connecting:
            discardReflection()
        case .thinking:
            endAfterCurrentTurn = true
            presentation.phase = .ending
        case .ending:
            break
        case .idle, .review, .completed, .error:
            presentation.phase = turns.contains(where: { $0.role == .user }) ? .review : .idle
        }
    }

    func continueReflection() {
        guard presentation.phase == .review else { return }
        endAfterCurrentTurn = false
        presentation.phase = .connecting
        currentFlowTask = Task { [weak self] in await self?.startListening() }
    }

    func saveReflection() {
        guard presentation.phase == .review || presentation.phase == .error else { return }
        currentFlowTask = Task { [weak self] in await self?.finalizeFlow() }
    }

    func retry() {
        if finalizationPackage != nil {
            currentFlowTask = Task { [weak self] in await self?.finalizeFlow() }
        } else if session?.state == .active, hasFinalizedUserTurn {
            currentFlowTask = Task { [weak self] in await self?.reconnectFlow() }
        } else {
            currentFlowTask = Task { [weak self] in await self?.restartFlow() }
        }
    }

    func savePartialReflection() {
        guard turns.contains(where: { $0.role == .user }) else { return }
        presentation.phase = .review
        saveReflection()
    }

    func discardReflection() {
        cancelRuntimeWork()
        let storedTurns = turns
        turns.removeAll()
        storedTurns.forEach(modelContext.delete)
        session?.discard()
        try? modelContext.save()
        Task { [transport] in await transport.disconnect() }
        resetInMemoryState()
    }

    func closeCompletedReflection() {
        guard presentation.phase == .completed else { return }
        cancelRuntimeWork()
        Task { [transport] in await transport.disconnect() }
        resetInMemoryState()
    }

    func pauseForInterruption() {
        guard presentation.phase != .idle, presentation.phase != .completed else { return }
        currentFlowTask?.cancel()
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        timerTask?.cancel()
        audio.tearDown()
        Task { [transport] in await transport.disconnect() }
        credentials = nil
        fail(
            "The reflection paused while Lore was in the background. Your finalized answers are still safe.",
            canSavePartial: hasFinalizedUserTurn
        )
    }

    private func beginFlow() async {
        guard await audio.requestMicrophonePermission() else {
            fail("Microphone access is required to start a reflection.", canSavePartial: false)
            return
        }

        let startedAt = Date()
        let activeSession = ReflectionSession(
            startedAt: startedAt,
            capturedLocalDate: Self.localDate(startedAt),
            policyVersion: ReflectionResponseRequest.currentPromptVersion
        )
        modelContext.insert(activeSession)
        do {
            try modelContext.save()
            session = activeSession
            try await connect(session: activeSession)
            startTimer(at: startedAt)
            startSTTReceiveLoop()

            let opening = "What felt worth remembering about today?"
            try persistLoreTurn(opening)
            try await speak(opening)
            if endAfterCurrentTurn {
                presentation.phase = .review
            } else {
                await startListening()
            }
        } catch is CancellationError {
            return
        } catch {
            activeSession.markFailed()
            try? modelContext.save()
            fail(message(for: error), canSavePartial: hasFinalizedUserTurn)
        }
    }

    private func restartFlow() async {
        cancelRuntimeWork(cancelCurrentFlow: false)
        await transport.disconnect()

        let storedTurns = turns
        turns.removeAll()
        storedTurns.forEach(modelContext.delete)
        if let session, session.state != .completed, session.state != .finalizing {
            session.discard()
        }
        try? modelContext.save()

        resetInMemoryState()
        hasStarted = true
        presentation = ReflectionSessionPresentation(phase: .connecting)
        await beginFlow()
    }

    private func reconnectFlow() async {
        guard let session, session.state == .active else {
            fail("This reflection cannot be resumed, but finalized answers can still be saved.", canSavePartial: !turns.isEmpty)
            return
        }
        presentation.phase = .connecting
        audio.tearDown()
        await transport.disconnect()
        credentials = nil
        do {
            try await connect(session: session)
            startSTTReceiveLoop()
            let isRecoveringAnswer = currentAudioURL != nil && currentUserTurnID != nil
            let resumePrompt = isRecoveringAnswer
                ? "The connection returned. I'm safely recovering your last answer."
                : "We can continue whenever you're ready. What else feels worth remembering?"
            try persistLoreTurn(resumePrompt)
            try await speak(resumePrompt)
            if isRecoveringAnswer, let currentAudioURL {
                presentation.phase = .thinking
                isCompletingUserTurn = true
                try await audio.replayProtectedCapture(at: currentAudioURL) { [transport] pcm in
                    try await transport.speechToText.sendAudio(pcm)
                }
                try await transport.speechToText.finalizeTurn()
            } else {
                await startListening()
            }
        } catch is CancellationError {
            return
        } catch {
            fail(message(for: error), canSavePartial: hasFinalizedUserTurn)
        }
    }

    private func connect(session: ReflectionSession) async throws {
        let response = try await backend.createReflectionSessionCredentials(
            ReflectionSessionCredentialsRequest(sessionId: session.id, languageCode: languageCode)
        )
        credentials = response
        let sttCredential = try SonioxTemporaryCredential(
            endpoint: response.stt.websocketUrl,
            apiKey: response.stt.temporaryApiKey,
            expiresAt: response.stt.expiresAt,
            maximumSessionDurationSeconds: response.maximumSessionDurationSeconds
        )
        let ttsCredential = try SonioxTemporaryCredential(
            endpoint: response.tts.websocketUrl,
            apiKey: response.tts.temporaryApiKey,
            expiresAt: response.tts.expiresAt,
            maximumSessionDurationSeconds: response.maximumSessionDurationSeconds
        )
        var sttConfiguration = SonioxSTTConfiguration()
        sttConfiguration.languageHints = [Self.baseLanguage(languageCode)]
        try await transport.connect(
            credentials: SonioxRealtimeSessionCredentials(
                speechToText: sttCredential,
                textToSpeech: ttsCredential
            ),
            speechToTextConfiguration: sttConfiguration
        )
        ttsConfiguration.language = Self.baseLanguage(languageCode)
        ttsConfiguration.voice = response.tts.voice
    }

    private func startSTTReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let update = try await transport.speechToText.receive()
                    await handleTranscriptUpdate(update)
                    if update.isSessionFinished { return }
                }
            } catch is CancellationError {
                return
            } catch {
                await handleTransportFailure()
            }
        }
    }

    private func handleTranscriptUpdate(_ update: SonioxTranscriptUpdate) async {
        guard presentation.phase == .listening
            || presentation.phase == .thinking
            || presentation.phase == .ending
        else { return }
        finalTokens.append(contentsOf: update.tokens.filter(\.isFinal))
        let provisionalTokens = update.tokens.filter { !$0.isFinal }
        let caption = (finalTokens + provisionalTokens).map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        presentation.provisionalTranscript = caption.isEmpty ? nil : caption

        guard update.boundary != nil,
              !isCompletingUserTurn || presentation.phase == .thinking || presentation.phase == .ending
        else { return }
        if presentation.phase == .listening {
            isCompletingUserTurn = true
            presentation.phase = .thinking
            try? audio.stopCapture()
        }
        await completeUserTurn()
    }

    private func completeUserTurn() async {
        guard
            isCompletingUserTurn,
            let session,
            let turnID = currentUserTurnID,
            let startedAt = currentUserTurnStartedAt
        else { return }
        defer { isCompletingUserTurn = false }

        let text = finalTokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail(
                "Lore did not catch enough speech to save that answer. Please try again.",
                canSavePartial: hasFinalizedUserTurn
            )
            return
        }
        let evidenceTokens = finalTokens.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let segments = evidenceTokens.enumerated().map { index, token in
            TranscriptSourceSegment(
                id: "\(turnID.uuidString.lowercased())-\(index)",
                chunkId: "turn-\(turnID.uuidString.lowercased())",
                startMilliseconds: max(0, token.startMilliseconds ?? 0),
                endMilliseconds: max(token.startMilliseconds ?? 0, token.endMilliseconds ?? token.startMilliseconds ?? 0),
                text: token.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: token.confidence,
                speakerLabel: nil
            )
        }

        do {
            let turn = try ReflectionTurn.committed(
                id: turnID,
                sessionId: session.id,
                sequence: turns.count,
                role: .user,
                text: text,
                startedAt: startedAt,
                endedAt: Date(),
                languageCode: languageCode,
                confidence: Self.averageConfidence(evidenceTokens),
                sourceSegments: segments
            )
            modelContext.insert(turn)
            try modelContext.save()
            turns.append(turn)
            refreshPresentationTurns()
            if let currentAudioURL { try? FileManager.default.removeItem(at: currentAudioURL) }
            resetCurrentUserTurn()

            if endAfterCurrentTurn {
                presentation.phase = .review
                return
            }
            let response = try await backend.generateReflectionResponse(
                ReflectionResponseRequest(
                    sessionId: session.id,
                    languageCode: languageCode,
                    subject: subject,
                    turns: turns.map(\.conversationTurn)
                )
            )
            if endAfterCurrentTurn {
                presentation.phase = .review
                return
            }
            try persistLoreTurn(response.spokenText)
            try await speak(response.spokenText)
            if endAfterCurrentTurn {
                presentation.phase = .review
            } else {
                await startListening()
            }
        } catch is CancellationError {
            return
        } catch {
            fail(message(for: error), canSavePartial: turns.contains(where: { $0.role == .user }))
        }
    }

    private func startListening() async {
        guard let session, session.state == .active else { return }
        resetCurrentUserTurn()
        let turnID = UUID()
        let fileURL = ReflectionAudioController.makeProtectedTurnAudioURL(
            sessionID: session.id,
            turnID: turnID
        )
        currentUserTurnID = turnID
        currentUserTurnStartedAt = Date()
        currentAudioURL = fileURL
        presentation.provisionalTranscript = nil
        presentation.phase = .listening
        do {
            try audio.startCapture(recordingTo: fileURL) { [weak self] pcm in
                Task {
                    guard let self else { return }
                    do {
                        try await self.transport.speechToText.sendAudio(pcm)
                    } catch {
                        await self.handleTransportFailure()
                    }
                }
            }
        } catch {
            fail(message(for: error), canSavePartial: turns.contains(where: { $0.role == .user }))
        }
    }

    private func speak(_ text: String) async throws {
        presentation.phase = .speaking
        presentation.provisionalTranscript = nil
        let streamID = "turn-\(UUID().uuidString.lowercased())"
        currentTTSStreamID = streamID
        defer { currentTTSStreamID = nil }
        try await transport.textToSpeech.synthesize(
            text: text,
            streamID: streamID,
            configuration: ttsConfiguration
        )
        startKeepAliveLoopIfNeeded()
        while !Task.isCancelled {
            switch try await transport.textToSpeech.receive() {
            case let .audio(eventStreamID, bytes, _, _) where eventStreamID == streamID:
                try audio.enqueuePlaybackPCM(bytes)
            case let .terminated(eventStreamID) where eventStreamID == streamID:
                await audio.waitForPlaybackToFinish()
                return
            default:
                continue
            }
        }
        throw CancellationError()
    }

    private func persistLoreTurn(_ text: String) throws {
        guard let session else { throw ReflectionPersistenceError.missingSession }
        let now = Date()
        let turn = try ReflectionTurn.committed(
            sessionId: session.id,
            sequence: turns.count,
            role: .lore,
            text: text,
            startedAt: now,
            endedAt: now
        )
        modelContext.insert(turn)
        try modelContext.save()
        turns.append(turn)
        refreshPresentationTurns()
    }

    private func finalizeFlow() async {
        guard let session else { return }
        presentation.phase = .thinking
        audio.tearDown()
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await transport.disconnect()
        credentials = nil
        do {
            let package: ReflectionFinalizationPackage
            if let finalizationPackage {
                package = finalizationPackage
            } else {
                package = try ReflectionSourceCommitter.freeze(
                    session: session,
                    turns: turns,
                    languageCode: languageCode,
                    subject: subject,
                    in: modelContext
                )
                finalizationPackage = package
            }
            let response = try await backend.finalizeReflection(package.request)
            _ = try ReflectionFinalizationPersister.persist(
                response: response,
                package: package,
                session: session,
                in: modelContext
            )
            timerTask?.cancel()
            presentation.phase = .completed
            presentation.provisionalTranscript = nil
        } catch is CancellationError {
            return
        } catch {
            fail("Lore saved the source conversation but could not finish the biography entry yet. Try again.", canSavePartial: true)
        }
    }

    private func handleTransportFailure() async {
        guard presentation.phase != .error, presentation.phase != .completed else { return }
        try? audio.stopCapture()
        audio.stopPlayback()
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await transport.disconnect()
        credentials = nil
        fail(
            "The live speech connection was interrupted. Your finalized answers are still safe.",
            canSavePartial: hasFinalizedUserTurn
        )
    }

    private var hasFinalizedUserTurn: Bool {
        turns.contains(where: { $0.role == .user })
    }

    private func cancelRuntimeWork(cancelCurrentFlow: Bool = true) {
        if cancelCurrentFlow {
            currentFlowTask?.cancel()
        }
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        timerTask?.cancel()
        audio.tearDown()
    }

    private func resetInMemoryState() {
        session = nil
        finalizationPackage = nil
        credentials = nil
        currentTTSStreamID = nil
        endAfterCurrentTurn = false
        isCompletingUserTurn = false
        resetCurrentUserTurn()
        presentation = ReflectionSessionPresentation(phase: .idle)
        hasStarted = false
    }

    private func refreshPresentationTurns() {
        presentation.turns = turns.map { turn in
            ReflectionTurnPresentation(
                id: turn.id,
                speaker: turn.role == .user ? .user : .lore,
                text: turn.text
            )
        }
    }

    private func resetCurrentUserTurn() {
        finalTokens.removeAll()
        currentUserTurnID = nil
        currentUserTurnStartedAt = nil
        currentAudioURL = nil
        presentation.provisionalTranscript = nil
    }

    private func startTimer(at startedAt: Date) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                presentation.elapsedTime = String(format: "%d:%02d", seconds / 60, seconds % 60)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startKeepAliveLoopIfNeeded() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await transport.speechToText.keepAlive()
                    try await transport.textToSpeech.keepAlive()
                } catch {
                    await handleTransportFailure()
                    return
                }
            }
        }
    }

    private var subject: JournalSubject {
        JournalSubject(displayName: userProfile.name, pronouns: [])
    }

    private func fail(_ message: String, canSavePartial: Bool) {
        presentation.phase = .error
        presentation.errorMessage = message
        presentation.canSavePartialReflection = canSavePartial
    }

    private func message(for error: Error) -> String {
        switch error {
        case LoreBackendProcessingError.notConfigured:
            "Reflect requires a physical iPhone with Lore's secure processing service configured."
        case ReflectionAudioError.microphonePermissionDenied:
            "Microphone access is required to start a reflection."
        case is SonioxRealtimeError:
            "Lore could not connect to the live speech service. Please try again."
        default:
            "Lore could not continue the reflection. Your finalized answers are still safe."
        }
    }

    private static func localDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func baseLanguage(_ languageCode: String) -> String {
        String(languageCode.split(separator: "-").first ?? "en")
    }

    private static func averageConfidence(_ tokens: [SonioxTranscriptToken]) -> Double? {
        let values = tokens.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct ReflectionLiveSessionView: View {
    @Environment(\.modelContext) private var modelContext

    let userProfile: UserProfile
    let backend: any LoreReflectionBackendClient
    let onViewBiography: () -> Void

    var body: some View {
        ReflectionLiveSessionBoundView(
            userProfile: userProfile,
            backend: backend,
            modelContext: modelContext,
            onViewBiography: onViewBiography
        )
    }
}

private struct ReflectionLiveSessionBoundView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: ReflectionSessionModel
    let onViewBiography: () -> Void

    init(
        userProfile: UserProfile,
        backend: any LoreReflectionBackendClient,
        modelContext: ModelContext,
        onViewBiography: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: ReflectionSessionModel(
            backend: backend,
            modelContext: modelContext,
            userProfile: userProfile
        ))
        self.onViewBiography = onViewBiography
    }

    var body: some View {
        ReflectRootView(
            presentation: model.presentation,
            actions: wiredActions
        )
        .task {
            model.resumePendingFinalizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { model.pauseForInterruption() }
        }
    }

    private var wiredActions: ReflectionSessionActions {
        var actions = model.actions
        actions.discardReflection = {
            model.discardReflection()
        }
        actions.viewBiography = {
            model.closeCompletedReflection()
            onViewBiography()
        }
        return actions
    }
}
