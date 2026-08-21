import Foundation

enum SonioxRealtimeEndpoint {
    static let speechToText = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let textToSpeech = URL(string: "wss://tts-rt.soniox.com/tts-websocket")!
}

struct SonioxTemporaryCredential: Sendable {
    let endpoint: URL
    let apiKey: String
    let expiresAt: Date
    let maximumSessionDurationSeconds: Int

    init(
        endpoint: URL,
        apiKey: String,
        expiresAt: Date,
        maximumSessionDurationSeconds: Int
    ) throws {
        guard
            endpoint.scheme?.lowercased() == "wss",
            let host = endpoint.host?.lowercased(),
            host == "soniox.com" || host.hasSuffix(".soniox.com"),
            endpoint.user == nil,
            endpoint.password == nil,
            !apiKey.isEmpty,
            !apiKey.contains("\n"),
            !apiKey.contains("\r"),
            expiresAt > Date(),
            maximumSessionDurationSeconds > 0
        else {
            throw SonioxRealtimeError.invalidConfiguration
        }

        self.endpoint = endpoint
        self.apiKey = apiKey
        self.expiresAt = expiresAt
        self.maximumSessionDurationSeconds = maximumSessionDurationSeconds
    }
}

struct SonioxRealtimeSessionCredentials: Sendable {
    let speechToText: SonioxTemporaryCredential
    let textToSpeech: SonioxTemporaryCredential
}

enum SonioxRealtimeSessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

enum SonioxRecoveryAction: Equatable, Sendable {
    case none
    case reconnect
    case reconnectWithBackoff
    case refreshCredentials
}

struct SonioxProviderError: Error, Equatable, Sendable {
    let statusCode: Int
    let type: String
    let message: String
    let requestID: String?

    var recoveryAction: SonioxRecoveryAction {
        switch statusCode {
        case 401, 403:
            return .refreshCredentials
        case 408, 429, 500, 503:
            return .reconnectWithBackoff
        default:
            return .none
        }
    }
}

enum SonioxRealtimeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case notConnected
    case alreadyConnected
    case invalidMessage
    case invalidAudioPayload
    case streamAlreadyActive
    case provider(SonioxProviderError)
    case transport

    var recoveryAction: SonioxRecoveryAction {
        switch self {
        case .provider(let error): error.recoveryAction
        case .transport: .reconnect
        default: .none
        }
    }
}

enum SonioxWebSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// A narrow WebSocket seam. Tests can inject deterministic messages without
/// exposing Soniox credentials to fixtures, logs, or global configuration.
struct SonioxWebSocketConnection: Sendable {
    typealias Send = @Sendable (SonioxWebSocketMessage) async throws -> Void
    typealias Receive = @Sendable () async throws -> SonioxWebSocketMessage
    typealias Close = @Sendable () async -> Void

    private let sendImplementation: Send
    private let receiveImplementation: Receive
    private let closeImplementation: Close

    init(
        send: @escaping Send,
        receive: @escaping Receive,
        close: @escaping Close
    ) {
        sendImplementation = send
        receiveImplementation = receive
        closeImplementation = close
    }

    func send(_ message: SonioxWebSocketMessage) async throws {
        try await sendImplementation(message)
    }

    func receive() async throws -> SonioxWebSocketMessage {
        try await receiveImplementation()
    }

    func close() async {
        await closeImplementation()
    }
}

struct SonioxWebSocketConnector: Sendable {
    typealias Connect = @Sendable (URL) async throws -> SonioxWebSocketConnection

    private let connectImplementation: Connect

    init(connect: @escaping Connect) {
        connectImplementation = connect
    }

    func connect(to url: URL) async throws -> SonioxWebSocketConnection {
        try await connectImplementation(url)
    }

    static func urlSession(
        configuration: URLSessionConfiguration = .ephemeral,
        diagnosticChannel: String = "unknown"
    ) -> Self {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true

        return Self { url in
            let box = URLSessionSonioxWebSocketBox(
                url: url,
                configuration: configuration,
                diagnosticChannel: diagnosticChannel
            )
            try await box.connect()
            return SonioxWebSocketConnection(
                send: { message in try await box.send(message) },
                receive: { try await box.receive() },
                close: { await box.close() }
            )
        }
    }
}

private final class URLSessionSonioxWebSocketBox: @unchecked Sendable {
    private let delegate: URLSessionSonioxWebSocketDelegate
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let diagnosticChannel: String

    init(
        url: URL,
        configuration: URLSessionConfiguration,
        diagnosticChannel: String
    ) {
        let delegate = URLSessionSonioxWebSocketDelegate()
        self.delegate = delegate
        self.diagnosticChannel = diagnosticChannel
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        task = session.webSocketTask(with: url)
    }

    func connect() async throws {
        do {
            try await delegate.waitForOpen(task: task)
        } catch is CancellationError {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw CancellationError()
        } catch {
            reportTransportFailure(error, operation: "connect")
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw SonioxRealtimeError.transport
        }
    }

    func send(_ message: SonioxWebSocketMessage) async throws {
        do {
            switch message {
            case .text(let value):
                try await task.send(.string(value))
            case .data(let value):
                try await task.send(.data(value))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            reportTransportFailure(error, operation: "send")
            throw SonioxRealtimeError.transport
        }
    }

    func receive() async throws -> SonioxWebSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let value): return .text(value)
            case .data(let value): return .data(value)
            @unknown default: throw SonioxRealtimeError.invalidMessage
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SonioxRealtimeError {
            throw error
        } catch {
            reportTransportFailure(error, operation: "receive")
            throw SonioxRealtimeError.transport
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func reportTransportFailure(_ error: Error, operation: String) {
        let value = error as NSError
        // Domain/code/close code are content-free connection diagnostics. Do
        // not log localized descriptions, URLs, credentials, or frame bodies.
        print(
            "Soniox WebSocket \(operation) failure: "
                + "channel=\(diagnosticChannel) "
                + "domain=\(value.domain) "
                + "code=\(value.code) "
                + "close_code=\(task.closeCode.rawValue)"
        )
    }
}

private final class URLSessionSonioxWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var terminalError: Error?

    func waitForOpen(task: URLSessionWebSocketTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if let terminalError {
                    lock.unlock()
                    continuation.resume(throwing: terminalError)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        let failure = error ?? URLError(.cannotConnectToHost)
        terminalError = failure
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: failure)
    }
}

struct SonioxSTTConfiguration: Equatable, Sendable {
    var model = "stt-rt-v5"
    var audioFormat = "pcm_s16le"
    var sampleRate = 16_000
    var channelCount = 1
    var languageHints: [String] = []
    var endpointDetectionEnabled = true
    var maximumEndpointDelayMilliseconds = 1_500
    var endpointSensitivity = 0.3
    var endpointLatencyAdjustmentLevel = 2
}

struct SonioxTranscriptToken: Equatable, Sendable {
    let text: String
    let startMilliseconds: Int?
    let endMilliseconds: Int?
    let confidence: Double?
    let isFinal: Bool
    let language: String?
}

enum SonioxTranscriptBoundary: Equatable, Sendable {
    case endpoint
    case manualFinalization
}

struct SonioxTranscriptUpdate: Equatable, Sendable {
    let tokens: [SonioxTranscriptToken]
    let boundary: SonioxTranscriptBoundary?
    let finalAudioProcessedMilliseconds: Int?
    let totalAudioProcessedMilliseconds: Int?
    let isSessionFinished: Bool
}

protocol SonioxRealtimeTranscribing: Sendable {
    func connect(credential: SonioxTemporaryCredential, configuration: SonioxSTTConfiguration) async throws
    func sendAudio(_ pcmS16LE: Data) async throws
    func finalizeTurn() async throws
    func keepAlive() async throws
    func finishSession() async throws
    func receive() async throws -> SonioxTranscriptUpdate
    func disconnect() async
}

actor SonioxRealtimeSTTClient: SonioxRealtimeTranscribing {
    private let connector: SonioxWebSocketConnector
    private var connection: SonioxWebSocketConnection?

    init(connector: SonioxWebSocketConnector = .urlSession(diagnosticChannel: "stt")) {
        self.connector = connector
    }

    func connect(
        credential: SonioxTemporaryCredential,
        configuration: SonioxSTTConfiguration = .init()
    ) async throws {
        guard connection == nil else { throw SonioxRealtimeError.alreadyConnected }
        guard credential.expiresAt > Date() else { throw SonioxRealtimeError.invalidConfiguration }
        let opened = try await connector.connect(to: credential.endpoint)
        do {
            try await opened.send(.text(try Self.configurationMessage(
                credential: credential,
                configuration: configuration
            )))
            connection = opened
        } catch {
            await opened.close()
            throw error
        }
    }

    func sendAudio(_ pcmS16LE: Data) async throws {
        guard !pcmS16LE.isEmpty else { return }
        try await requireConnection().send(.data(pcmS16LE))
    }

    func finalizeTurn() async throws {
        try await requireConnection().send(.text("{\"type\":\"finalize\"}"))
    }

    func keepAlive() async throws {
        try await requireConnection().send(.text("{\"type\":\"keepalive\"}"))
    }

    func finishSession() async throws {
        try await requireConnection().send(.data(Data()))
    }

    func receive() async throws -> SonioxTranscriptUpdate {
        let message = try await requireConnection().receive()
        guard case .text(let text) = message, let data = text.data(using: .utf8) else {
            throw SonioxRealtimeError.invalidMessage
        }
        return try Self.parseResponse(data)
    }

    func disconnect() async {
        let current = connection
        connection = nil
        await current?.close()
    }

    private func requireConnection() throws -> SonioxWebSocketConnection {
        guard let connection else { throw SonioxRealtimeError.notConnected }
        return connection
    }

    static func configurationMessage(
        credential: SonioxTemporaryCredential,
        configuration: SonioxSTTConfiguration
    ) throws -> String {
        var value: [String: Any] = [
            "api_key": credential.apiKey,
            "model": configuration.model,
            "audio_format": configuration.audioFormat,
            "sample_rate": configuration.sampleRate,
            "num_channels": configuration.channelCount,
            "enable_endpoint_detection": configuration.endpointDetectionEnabled,
            "max_endpoint_delay_ms": configuration.maximumEndpointDelayMilliseconds,
            "endpoint_sensitivity": configuration.endpointSensitivity,
            "endpoint_latency_adjustment_level": configuration.endpointLatencyAdjustmentLevel
        ]
        if !configuration.languageHints.isEmpty {
            value["language_hints"] = configuration.languageHints
        }
        return try encodeJSONObject(value)
    }

    static func parseResponse(_ data: Data) throws -> SonioxTranscriptUpdate {
        let response: STTResponse
        do {
            response = try JSONDecoder().decode(STTResponse.self, from: data)
        } catch {
            throw SonioxRealtimeError.invalidMessage
        }
        if let providerError = response.providerError {
            throw SonioxRealtimeError.provider(providerError)
        }

        var boundary: SonioxTranscriptBoundary?
        let tokens = (response.tokens ?? []).compactMap { token -> SonioxTranscriptToken? in
            if token.text == "<end>" {
                boundary = .endpoint
                return nil
            }
            if token.text == "<fin>" {
                boundary = .manualFinalization
                return nil
            }
            return SonioxTranscriptToken(
                text: token.text,
                startMilliseconds: token.startMilliseconds,
                endMilliseconds: token.endMilliseconds,
                confidence: token.confidence,
                isFinal: token.isFinal,
                language: token.language
            )
        }
        return SonioxTranscriptUpdate(
            tokens: tokens,
            boundary: boundary,
            finalAudioProcessedMilliseconds: response.finalAudioProcessedMilliseconds,
            totalAudioProcessedMilliseconds: response.totalAudioProcessedMilliseconds,
            isSessionFinished: response.finished ?? false
        )
    }
}

struct SonioxTTSConfiguration: Equatable, Sendable {
    var model = "tts-rt-v2"
    var language = "en"
    var voice = "Adrian"
    var audioFormat = "pcm_s16le"
    var sampleRate = 24_000
    var speed = 1.0
    var reducesSilence: Bool?
    var returnsTimestamps = true
}

struct SonioxCharacterTiming: Equatable, Sendable {
    let character: String
    let startSeconds: Double
    let endSeconds: Double
}

enum SonioxTTSEvent: Equatable, Sendable {
    case audio(streamID: String, bytes: Data, isFinalChunk: Bool, timings: [SonioxCharacterTiming])
    case terminated(streamID: String)
}

protocol SonioxRealtimeSynthesizing: Sendable {
    func connect(credential: SonioxTemporaryCredential) async throws
    func synthesize(text: String, streamID: String, configuration: SonioxTTSConfiguration) async throws
    func cancel(streamID: String) async throws
    func keepAlive() async throws
    func receive() async throws -> SonioxTTSEvent
    func disconnect() async
}

actor SonioxRealtimeTTSClient: SonioxRealtimeSynthesizing {
    private let connector: SonioxWebSocketConnector
    private var connection: SonioxWebSocketConnection?
    private var credential: SonioxTemporaryCredential?
    private var activeStreamIDs = Set<String>()

    init(connector: SonioxWebSocketConnector = .urlSession(diagnosticChannel: "tts")) {
        self.connector = connector
    }

    func connect(credential: SonioxTemporaryCredential) async throws {
        guard connection == nil else { throw SonioxRealtimeError.alreadyConnected }
        guard credential.expiresAt > Date() else { throw SonioxRealtimeError.invalidConfiguration }
        connection = try await connector.connect(to: credential.endpoint)
        self.credential = credential
    }

    func synthesize(
        text: String,
        streamID: String,
        configuration: SonioxTTSConfiguration = .init()
    ) async throws {
        guard let credential else { throw SonioxRealtimeError.notConnected }
        guard !text.isEmpty, text.count <= 5_000, !streamID.isEmpty, streamID.count <= 256 else {
            throw SonioxRealtimeError.invalidConfiguration
        }
        guard activeStreamIDs.insert(streamID).inserted else {
            throw SonioxRealtimeError.streamAlreadyActive
        }

        do {
            try await requireConnection().send(.text(try Self.configurationMessage(
                credential: credential,
                streamID: streamID,
                configuration: configuration
            )))
            try await requireConnection().send(.text(try encodeJSONObject([
                "stream_id": streamID,
                "text": text,
                "text_end": true
            ])))
        } catch {
            activeStreamIDs.remove(streamID)
            throw error
        }
    }

    func cancel(streamID: String) async throws {
        guard activeStreamIDs.contains(streamID) else { return }
        try await requireConnection().send(.text(try encodeJSONObject([
            "stream_id": streamID,
            "cancel": true
        ])))
    }

    func keepAlive() async throws {
        try await requireConnection().send(.text("{\"keep_alive\":true}"))
    }

    func receive() async throws -> SonioxTTSEvent {
        let message = try await requireConnection().receive()
        guard case .text(let text) = message, let data = text.data(using: .utf8) else {
            throw SonioxRealtimeError.invalidMessage
        }
        let event = try Self.parseResponse(data)
        if case .terminated(let streamID) = event {
            activeStreamIDs.remove(streamID)
        }
        return event
    }

    func disconnect() async {
        let current = connection
        connection = nil
        credential = nil
        activeStreamIDs.removeAll()
        await current?.close()
    }

    private func requireConnection() throws -> SonioxWebSocketConnection {
        guard let connection else { throw SonioxRealtimeError.notConnected }
        return connection
    }

    static func configurationMessage(
        credential: SonioxTemporaryCredential,
        streamID: String,
        configuration: SonioxTTSConfiguration
    ) throws -> String {
        var value: [String: Any] = [
            "api_key": credential.apiKey,
            "model": configuration.model,
            "language": configuration.language,
            "voice": configuration.voice,
            "audio_format": configuration.audioFormat,
            "sample_rate": configuration.sampleRate,
            "stream_id": streamID,
            "return_timestamps": configuration.returnsTimestamps,
            "speed": configuration.speed
        ]
        // Silence reduction is capability-gated by Soniox. Keep the default
        // payload minimal and send it only when a caller deliberately opts in.
        if let reducesSilence = configuration.reducesSilence {
            value["reduce_silence"] = reducesSilence
        }
        return try encodeJSONObject(value)
    }

    static func parseResponse(_ data: Data) throws -> SonioxTTSEvent {
        let response: TTSResponse
        do {
            response = try JSONDecoder().decode(TTSResponse.self, from: data)
        } catch {
            throw SonioxRealtimeError.invalidMessage
        }
        if let providerError = response.providerError {
            throw SonioxRealtimeError.provider(providerError)
        }
        guard let streamID = response.streamID, !streamID.isEmpty else {
            throw SonioxRealtimeError.invalidMessage
        }
        if response.terminated == true {
            return .terminated(streamID: streamID)
        }
        guard let encodedAudio = response.audio, let audio = Data(base64Encoded: encodedAudio) else {
            throw SonioxRealtimeError.invalidAudioPayload
        }
        let timings: [SonioxCharacterTiming]
        if let timestamps = response.timestamps {
            guard
                timestamps.characters.count == timestamps.starts.count,
                timestamps.characters.count == timestamps.ends.count
            else {
                throw SonioxRealtimeError.invalidMessage
            }
            timings = timestamps.timings
        } else {
            timings = []
        }
        return .audio(
            streamID: streamID,
            bytes: audio,
            isFinalChunk: response.audioEnd ?? false,
            timings: timings
        )
    }
}

/// Connects and tears down the two provider channels as one app-level session.
/// Reconnect remains an explicit caller decision because STT must replay the
/// protected turn audio while TTS may safely resend text on a fresh stream.
actor SonioxRealtimeSessionTransport {
    nonisolated let speechToText: any SonioxRealtimeTranscribing
    nonisolated let textToSpeech: any SonioxRealtimeSynthesizing
    private(set) var state: SonioxRealtimeSessionState = .disconnected
    private var isSpeechToTextConnected = false
    private var isTextToSpeechConnected = false

    init(
        speechToText: any SonioxRealtimeTranscribing = SonioxRealtimeSTTClient(),
        textToSpeech: any SonioxRealtimeSynthesizing = SonioxRealtimeTTSClient()
    ) {
        self.speechToText = speechToText
        self.textToSpeech = textToSpeech
    }

    func connect(
        credentials: SonioxRealtimeSessionCredentials,
        speechToTextConfiguration: SonioxSTTConfiguration = .init()
    ) async throws {
        guard state == .disconnected else { throw SonioxRealtimeError.alreadyConnected }
        do {
            // TTS is intentionally opened first. Reflection prompts can play
            // before microphone capture begins, while Soniox STT expects audio
            // promptly after its authenticated configuration frame.
            try await connectTextToSpeech(credential: credentials.textToSpeech)
            try await connectSpeechToText(
                credential: credentials.speechToText,
                configuration: speechToTextConfiguration
            )
        } catch {
            await disconnect()
            throw error
        }
    }

    func connectTextToSpeech(credential: SonioxTemporaryCredential) async throws {
        guard !isTextToSpeechConnected else { return }
        state = .connecting
        try Task.checkCancellation()
        do {
            try await textToSpeech.connect(credential: credential)
            isTextToSpeechConnected = true
            updateState()
        } catch {
            updateState()
            throw error
        }
    }

    func connectSpeechToText(
        credential: SonioxTemporaryCredential,
        configuration: SonioxSTTConfiguration = .init()
    ) async throws {
        guard !isSpeechToTextConnected else { return }
        state = .connecting
        try Task.checkCancellation()
        do {
            try await speechToText.connect(
                credential: credential,
                configuration: configuration
            )
            isSpeechToTextConnected = true
            updateState()
        } catch {
            updateState()
            throw error
        }
    }

    func disconnect() async {
        await speechToText.disconnect()
        await textToSpeech.disconnect()
        isSpeechToTextConnected = false
        isTextToSpeechConnected = false
        state = .disconnected
    }

    private func updateState() {
        if isSpeechToTextConnected && isTextToSpeechConnected {
            state = .connected
        } else if isSpeechToTextConnected || isTextToSpeechConnected {
            state = .connecting
        } else {
            state = .disconnected
        }
    }
}

private struct STTResponse: Decodable {
    struct Token: Decodable {
        let text: String
        let startMilliseconds: Int?
        let endMilliseconds: Int?
        let confidence: Double?
        let isFinal: Bool
        let language: String?

        enum CodingKeys: String, CodingKey {
            case text, confidence, language
            case startMilliseconds = "start_ms"
            case endMilliseconds = "end_ms"
            case isFinal = "is_final"
        }
    }

    let tokens: [Token]?
    let finalAudioProcessedMilliseconds: Int?
    let totalAudioProcessedMilliseconds: Int?
    let finished: Bool?
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case finalAudioProcessedMilliseconds = "final_audio_proc_ms"
        case totalAudioProcessedMilliseconds = "total_audio_proc_ms"
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }

    var providerError: SonioxProviderError? {
        guard let errorCode, let errorType, let errorMessage else { return nil }
        return SonioxProviderError(
            statusCode: errorCode,
            type: errorType,
            message: errorMessage,
            requestID: requestID
        )
    }
}

private struct TTSResponse: Decodable {
    struct Timestamps: Decodable {
        let characters: [String]
        let starts: [Double]
        let ends: [Double]

        enum CodingKeys: String, CodingKey {
            case characters
            case starts = "character_start_times_seconds"
            case ends = "character_end_times_seconds"
        }

        var timings: [SonioxCharacterTiming] {
            zip(characters, zip(starts, ends)).map { character, times in
                SonioxCharacterTiming(character: character, startSeconds: times.0, endSeconds: times.1)
            }
        }
    }

    let streamID: String?
    let audio: String?
    let audioEnd: Bool?
    let terminated: Bool?
    let timestamps: Timestamps?
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case audio, terminated, timestamps
        case streamID = "stream_id"
        case audioEnd = "audio_end"
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }

    var providerError: SonioxProviderError? {
        guard let errorCode, let errorType, let errorMessage else { return nil }
        return SonioxProviderError(
            statusCode: errorCode,
            type: errorType,
            message: errorMessage,
            requestID: requestID
        )
    }
}

private func encodeJSONObject(_ value: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw SonioxRealtimeError.invalidConfiguration
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw SonioxRealtimeError.invalidConfiguration
    }
    return text
}
