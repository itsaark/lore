import Foundation

struct LoreBackendHTTPClientConfiguration: Equatable, Sendable {
    enum Deployment: Sendable {
        case preview
        case test
        case production
    }

    let baseURL: URL
    let deployment: Deployment
    let previewBearerToken: String?
    let requestTimeout: TimeInterval

    init(
        baseURL: URL,
        deployment: Deployment,
        previewBearerToken: String? = nil,
        requestTimeout: TimeInterval = 60
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
            throw LoreBackendProcessingError.invalidConfiguration
        }

        let normalizedToken = previewBearerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if deployment == .production, normalizedToken?.isEmpty == false {
            throw LoreBackendProcessingError.invalidConfiguration
        }
        if let normalizedToken,
           normalizedToken.isEmpty || normalizedToken.contains("\n") || normalizedToken.contains("\r") {
            throw LoreBackendProcessingError.invalidConfiguration
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let normalizedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = normalizedPath.isEmpty ? "/" : "/\(normalizedPath)/"
        guard let normalizedBaseURL = components?.url else {
            throw LoreBackendProcessingError.invalidConfiguration
        }

        self.baseURL = normalizedBaseURL
        self.deployment = deployment
        self.previewBearerToken = normalizedToken
        self.requestTimeout = requestTimeout
    }
}

/// A small transport seam keeps provider and authorization details out of the
/// app-facing client and lets tests inspect requests without logging content.
struct LoreBackendHTTPTransport: Sendable {
    typealias Send = @Sendable (URLRequest, URL?) async throws -> (Data, URLResponse)

    private let sendImplementation: Send

    init(send: @escaping Send) {
        sendImplementation = send
    }

    func send(_ request: URLRequest, uploadFileURL: URL? = nil) async throws -> (Data, URLResponse) {
        try await sendImplementation(request, uploadFileURL)
    }

    static func urlSession(_ session: URLSession) -> Self {
        Self { request, uploadFileURL in
            if let uploadFileURL {
                // File-backed uploads are compatible with a caller-supplied
                // background URLSession. Lore still owns retry/recovery state.
                return try await session.upload(for: request, fromFile: uploadFileURL)
            }
            return try await session.data(for: request)
        }
    }

    static func ephemeral() -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        return .urlSession(URLSession(configuration: configuration))
    }
}

struct LoreBackendHTTPClient: LoreBackendProcessingClient, Sendable {
    static let maximumAudioChunkBytes = 3_250_000
    static let maximumMultipartBodyBytes = 3_500_000
    static let maximumDailyEntryBodyBytes = 1_000_000

    private let configuration: LoreBackendHTTPClientConfiguration
    private let transport: LoreBackendHTTPTransport
    private let temporaryDirectory: URL

    init(
        configuration: LoreBackendHTTPClientConfiguration,
        transport: LoreBackendHTTPTransport = .ephemeral(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.configuration = configuration
        self.transport = transport
        self.temporaryDirectory = temporaryDirectory
    }

    func transcribe(_ request: RemoteTranscriptionRequest) async throws -> RemoteTranscriptionResponse {
        try Task.checkCancellation()
        try validate(request)

        let requestId = Self.makeRequestId()
        let idempotencyKey = "transcription:\(request.jobId.uuidString.lowercased()):chunk-\(request.chunkIndex)"
        let chunkId = "chunk-\(request.jobId.uuidString.lowercased())-\(request.chunkIndex)"
        let boundary = "LoreBoundary-\(requestId)"
        let body = try makeTranscriptionBody(
            request,
            idempotencyKey: idempotencyKey,
            chunkId: chunkId,
            boundary: boundary
        )
        guard body.count <= Self.maximumMultipartBodyBytes else {
            throw LoreBackendProcessingError.payloadTooLarge(maximumBytes: Self.maximumAudioChunkBytes)
        }

        let bodyURL = temporaryDirectory
            .appendingPathComponent("lore-upload-\(requestId)")
            .appendingPathExtension("multipart")
        do {
            try body.write(to: bodyURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw LoreBackendProcessingError.transportUnavailable
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var urlRequest = try makeRequest(
            path: "v1/transcriptions",
            requestId: requestId,
            idempotencyKey: idempotencyKey
        )
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await perform(urlRequest, uploadFileURL: bodyURL)
        let result: RemoteTranscriptionResponse = try decodeSuccess(data, response: response)
        try validate(result, for: request, expectedChunkId: chunkId)
        return result
    }

    func generateDailyEntry(
        _ request: DailyEntryGenerationRequest
    ) async throws -> DailyEntryGenerationResponse {
        try Task.checkCancellation()
        try validate(request)

        let requestId = Self.makeRequestId()
        let idempotencyKey = "daily-entry:\(request.jobId.uuidString.lowercased())"
        var wireRequest = request
        wireRequest.sourceSegments = request.sourceSegments.enumerated().map { index, segment in
            var value = segment
            if value.chunkId?.isEmpty != false {
                value.chunkId = "source-\(index)"
            }
            return value
        }

        let body: Data
        do {
            body = try Self.jsonEncoder.encode(wireRequest)
        } catch {
            throw LoreBackendProcessingError.invalidRequest
        }
        guard body.count <= Self.maximumDailyEntryBodyBytes else {
            throw LoreBackendProcessingError.payloadTooLarge(maximumBytes: Self.maximumDailyEntryBodyBytes)
        }

        var urlRequest = try makeRequest(
            path: "v1/daily-entries",
            requestId: requestId,
            idempotencyKey: idempotencyKey
        )
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, response) = try await perform(urlRequest)
        let result: DailyEntryGenerationResponse = try decodeSuccess(data, response: response)
        try validate(result, for: wireRequest)
        return result
    }

    private func makeRequest(
        path: String,
        requestId: String,
        idempotencyKey: String
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https" else {
            throw LoreBackendProcessingError.invalidConfiguration
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        if configuration.deployment != .production,
           let token = configuration.previewBearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        uploadFileURL: URL? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.send(request, uploadFileURL: uploadFileURL)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LoreBackendProcessingError.invalidResponse(requestId: nil)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw decodeError(data, response: httpResponse)
            }
            guard httpResponse.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().contains("application/json") == true else {
                throw LoreBackendProcessingError.invalidResponse(
                    requestId: httpResponse.value(forHTTPHeaderField: "X-Request-ID")
                )
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw LoreBackendProcessingError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LoreBackendProcessingError.cancelled
        } catch let error as LoreBackendProcessingError {
            throw error
        } catch {
            throw LoreBackendProcessingError.transportUnavailable
        }
    }

    private func decodeSuccess<Response: Decodable>(
        _ data: Data,
        response: HTTPURLResponse
    ) throws -> Response {
        do {
            let decoded = try Self.jsonDecoder.decode(Response.self, from: data)
            if let headerRequestId = response.value(forHTTPHeaderField: "X-Request-ID"),
               let bodyRequestId = (decoded as? any LoreRequestIdentifiedResponse)?.requestId,
               headerRequestId != bodyRequestId {
                throw LoreBackendProcessingError.invalidResponse(requestId: headerRequestId)
            }
            return decoded
        } catch let error as LoreBackendProcessingError {
            throw error
        } catch {
            throw LoreBackendProcessingError.invalidResponse(
                requestId: response.value(forHTTPHeaderField: "X-Request-ID")
            )
        }
    }

    private func decodeError(_ data: Data, response: HTTPURLResponse) -> LoreBackendProcessingError {
        let envelope = try? Self.jsonDecoder.decode(LoreBackendErrorEnvelope.self, from: data)
        let retryAfter = envelope?.retryAfterSeconds
            ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        if response.statusCode == 429 || envelope?.error.code == "provider_rate_limited" {
            return .rateLimited(retryAfterSeconds: retryAfter)
        }
        guard let envelope, envelope.schemaVersion == RemoteTranscriptionResponse.currentSchemaVersion else {
            return .invalidResponse(requestId: response.value(forHTTPHeaderField: "X-Request-ID"))
        }
        if envelope.error.code == "request_cancelled" {
            return .cancelled
        }
        return .rejected(
            code: envelope.error.code,
            retryable: envelope.error.retryable,
            retryAfterSeconds: retryAfter
        )
    }

    private func validate(_ request: RemoteTranscriptionRequest) throws {
        guard
            request.schemaVersion == RemoteTranscriptionRequest.currentSchemaVersion,
            request.audio.bytes.isEmpty == false,
            request.audio.bytes.count <= Self.maximumAudioChunkBytes,
            request.audio.durationSeconds > 0,
            request.audio.durationSeconds <= 3_600,
            Self.supportedAudioMIMETypes.contains(request.audio.mimeType.lowercased()),
            request.vocabularyHints.count <= 100,
            request.vocabularyHints.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
            request.chunkCount > 0,
            request.chunkCount <= 10_000,
            request.chunkIndex >= 0,
            request.chunkIndex < request.chunkCount,
            request.startMilliseconds >= 0,
            request.retentionPolicy.mode == .zeroDataRetention,
            request.retentionPolicy.maximumRetentionSeconds == 0
        else {
            if request.audio.bytes.count > Self.maximumAudioChunkBytes {
                throw LoreBackendProcessingError.payloadTooLarge(maximumBytes: Self.maximumAudioChunkBytes)
            }
            throw LoreBackendProcessingError.invalidRequest
        }
    }

    private func validate(_ request: DailyEntryGenerationRequest) throws {
        guard
            request.schemaVersion == DailyEntryGenerationRequest.currentSchemaVersion,
            request.promptVersion == DailyEntryGenerationRequest.currentPromptVersion,
            request.sourceSegments.isEmpty == false,
            request.retentionPolicy.mode == .zeroDataRetention,
            request.retentionPolicy.maximumRetentionSeconds == 0
        else {
            throw LoreBackendProcessingError.invalidRequest
        }
    }

    private func validate(
        _ response: RemoteTranscriptionResponse,
        for request: RemoteTranscriptionRequest,
        expectedChunkId: String
    ) throws {
        guard
            response.schemaVersion == RemoteTranscriptionResponse.currentSchemaVersion,
            response.jobId == request.jobId,
            response.requestId.isEmpty == false,
            response.chunk.id == expectedChunkId,
            response.chunk.index == request.chunkIndex,
            response.chunk.count == request.chunkCount,
            response.chunk.startMilliseconds == request.startMilliseconds,
            response.chunk.durationMilliseconds > 0,
            response.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            response.segments.allSatisfy({
                $0.chunkId == expectedChunkId
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.startMilliseconds >= 0
                    && $0.endMilliseconds >= $0.startMilliseconds
            }),
            isValid(response.provenance)
        else {
            throw LoreBackendProcessingError.invalidResponse(requestId: response.requestId)
        }
    }

    private func validate(
        _ response: DailyEntryGenerationResponse,
        for request: DailyEntryGenerationRequest
    ) throws {
        let sourceIds = Set(request.sourceSegments.map(\.id))
        let factIds = Set(request.acceptedPriorFacts.map(\.id))
        let sentenceReferencesAreGrounded = response.entry.sentences.allSatisfy { sentence in
            !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !sentence.sourceReferences.isEmpty
                && Set(sentence.sourceReferences).isSubset(of: sourceIds)
                && Set(sentence.factReferences).isSubset(of: factIds)
        }
        guard
            response.schemaVersion == DailyEntryGenerationResponse.currentSchemaVersion,
            response.promptVersion == DailyEntryGenerationRequest.currentPromptVersion,
            response.jobId == request.jobId,
            response.requestId.isEmpty == false,
            response.entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            !response.entry.titleSourceReferences.isEmpty,
            Set(response.entry.titleSourceReferences).isSubset(of: sourceIds),
            !response.entry.sentences.isEmpty,
            sentenceReferencesAreGrounded,
            isValid(response.provenance)
        else {
            throw LoreBackendProcessingError.invalidResponse(requestId: response.requestId)
        }
    }

    private func isValid(_ provenance: RemoteProcessingProvenance) -> Bool {
        !provenance.providerId.isEmpty
            && !provenance.modelAlias.isEmpty
            && !provenance.modelId.isEmpty
            && !provenance.modelPolicyVersion.isEmpty
            && provenance.processingDurationMilliseconds >= 0
            && provenance.retentionAttestation.mode == .zeroDataRetention
            && provenance.retentionAttestation.maximumRetentionSeconds == 0
            && !provenance.retentionAttestation.policyVersion.isEmpty
    }

    private func makeTranscriptionBody(
        _ request: RemoteTranscriptionRequest,
        idempotencyKey: String,
        chunkId: String,
        boundary: String
    ) throws -> Data {
        let retentionData: Data
        let vocabularyData: Data
        do {
            retentionData = try Self.jsonEncoder.encode(request.retentionPolicy)
            vocabularyData = try Self.jsonEncoder.encode(request.vocabularyHints)
        } catch {
            throw LoreBackendProcessingError.invalidRequest
        }
        guard
            let retention = String(data: retentionData, encoding: .utf8),
            let vocabulary = String(data: vocabularyData, encoding: .utf8)
        else {
            throw LoreBackendProcessingError.invalidRequest
        }

        let durationMilliseconds = max(1, Int((request.audio.durationSeconds * 1_000).rounded()))
        let fields: [(String, String)] = [
            ("schema_version", request.schemaVersion),
            ("job_id", request.jobId.uuidString.lowercased()),
            ("idempotency_key", idempotencyKey),
            ("chunk_id", chunkId),
            ("chunk_index", String(request.chunkIndex)),
            ("chunk_count", String(request.chunkCount)),
            ("start_milliseconds", String(request.startMilliseconds)),
            ("duration_milliseconds", String(durationMilliseconds)),
            ("language_code", request.languageCode ?? ""),
            ("vocabulary_hints", vocabulary),
            ("retention_policy", retention)
        ]

        var body = Data()
        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }

        let fileExtension = Self.safeFileExtension(request.audio.filenameExtension)
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.\(fileExtension)\"\r\n")
        body.appendUTF8("Content-Type: \(request.audio.mimeType.lowercased())\r\n\r\n")
        body.append(request.audio.bytes)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func safeFileExtension(_ value: String) -> String {
        let filtered = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return String(filtered.prefix(10)).isEmpty ? "m4a" : String(filtered.prefix(10))
    }

    private static func makeRequestId() -> String {
        "ios_\(UUID().uuidString.lowercased())"
    }

    private static let supportedAudioMIMETypes: Set<String> = [
        "audio/flac", "audio/m4a", "audio/mp4", "audio/mpeg", "audio/ogg",
        "audio/wav", "audio/webm", "video/mp4"
    ]

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractionalISO8601.date(from: value) ?? standardISO8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp."
            )
        }
        return decoder
    }()

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardISO8601 = ISO8601DateFormatter()
}

private protocol LoreRequestIdentifiedResponse {
    var requestId: String { get }
}

extension RemoteTranscriptionResponse: LoreRequestIdentifiedResponse {}
extension DailyEntryGenerationResponse: LoreRequestIdentifiedResponse {}

private struct LoreBackendErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
        let retryable: Bool
    }

    let schemaVersion: String
    let requestId: String
    let error: Detail
    let retryAfterSeconds: Int?
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
