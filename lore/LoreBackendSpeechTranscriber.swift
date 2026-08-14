import AVFoundation
import Foundation

struct LoadedRemoteAudioChunk: Sendable {
    let audio: RemoteAudioPayload
    let startMilliseconds: Int
}

struct LoreRemoteAudioFileLoader: Sendable {
    typealias Load = @Sendable (URL) async throws -> RemoteAudioPayload
    typealias LoadChunks = @Sendable (URL) async throws -> [LoadedRemoteAudioChunk]

    private let loadChunksImplementation: LoadChunks

    init(load: @escaping Load) {
        loadChunksImplementation = { url in
            [LoadedRemoteAudioChunk(audio: try await load(url), startMilliseconds: 0)]
        }
    }

    init(loadChunks: @escaping LoadChunks) {
        loadChunksImplementation = loadChunks
    }

    func loadChunks(_ fileURL: URL) async throws -> [LoadedRemoteAudioChunk] {
        try await loadChunksImplementation(fileURL)
    }

    static let live = Self(loadChunks: { sourceURL in
        guard
            sourceURL.isFileURL,
            FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            throw RemoteSpeechTranscriptionError.audioFileMissing
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0 else {
            throw RemoteSpeechTranscriptionError.audioFileUnreadable
        }
        let asset = AVURLAsset(url: sourceURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw RemoteSpeechTranscriptionError.audioFileUnreadable
        }
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw RemoteSpeechTranscriptionError.audioFileUnreadable
        }
        print(
            "Transcription audio inspected: \(sourceURL.pathExtension.lowercased()), "
                + "\(byteCount.intValue) bytes, \(durationSeconds) seconds"
        )

        if Self.supportedExtension(sourceURL.pathExtension),
           byteCount.intValue <= LoreBackendHTTPClient.maximumAudioChunkBytes {
            let bytes: Data
            do {
                bytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            } catch {
                throw RemoteSpeechTranscriptionError.audioFileUnreadable
            }
            return [
                LoadedRemoteAudioChunk(
                    audio: RemoteAudioPayload(
                        bytes: bytes,
                        mimeType: Self.mimeType(for: sourceURL.pathExtension),
                        filenameExtension: sourceURL.pathExtension,
                        durationSeconds: durationSeconds
                    ),
                    startMilliseconds: 0
                )
            ]
        }

        var chunks: [LoadedRemoteAudioChunk] = []
        var startSeconds: TimeInterval = 0
        var targetChunkSeconds: TimeInterval = min(120, durationSeconds)
        while startSeconds < durationSeconds {
            try Task.checkCancellation()
            let remaining = durationSeconds - startSeconds
            let chunkDuration = min(targetChunkSeconds, remaining)
            let outputURL = try await exportM4AChunk(
                asset: asset,
                startSeconds: startSeconds,
                durationSeconds: chunkDuration
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let outputByteCount = (outputAttributes[.size] as? NSNumber)?.intValue ?? 0
            if outputByteCount > LoreBackendHTTPClient.maximumAudioChunkBytes {
                guard targetChunkSeconds > 10 else {
                    throw LoreBackendProcessingError.payloadTooLarge(
                        maximumBytes: LoreBackendHTTPClient.maximumAudioChunkBytes
                    )
                }
                targetChunkSeconds = max(10, targetChunkSeconds / 2)
                continue
            }

            chunks.append(
                LoadedRemoteAudioChunk(
                    audio: RemoteAudioPayload(
                        bytes: try Data(contentsOf: outputURL, options: [.mappedIfSafe]),
                        mimeType: "audio/m4a",
                        filenameExtension: "m4a",
                        durationSeconds: chunkDuration
                    ),
                    startMilliseconds: Int((startSeconds * 1_000).rounded())
                )
            )
            startSeconds += chunkDuration
        }
        return chunks
    })

    private static func supportedExtension(_ value: String) -> Bool {
        ["flac", "m4a", "mp3", "mp4", "mpeg", "ogg", "wav", "webm"]
            .contains(value.lowercased())
    }

    private static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "flac": "audio/flac"
        case "m4a": "audio/m4a"
        case "mp3", "mpeg": "audio/mpeg"
        case "mp4": "audio/mp4"
        case "ogg": "audio/ogg"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        default: "audio/m4a"
        }
    }

    private static func exportM4AChunk(
        asset: AVURLAsset,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-transcode-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RemoteSpeechTranscriptionError.audioTranscodeFailed
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
        do {
            try await exporter.export(to: outputURL, as: .m4a)
            return outputURL
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            let value = error as NSError
            print("Audio conversion failed: \(value.domain) \(value.code)")
            throw RemoteSpeechTranscriptionError.audioTranscodeFailed
        }
    }
}

/// Bridges the durable local audio file owned by the transcription job runner
/// to Lore's provider-neutral backend request. The adapter never receives a
/// Groq key and exposes only normalized provider provenance to persistence.
struct LoreBackendRemoteSpeechTranscriber: RemoteSpeechTranscribing, Sendable {
    let backend: any LoreBackendProcessingClient
    private let audioFileLoader: LoreRemoteAudioFileLoader

    init(
        backend: any LoreBackendProcessingClient,
        audioFileLoader: LoreRemoteAudioFileLoader = .live
    ) {
        self.backend = backend
        self.audioFileLoader = audioFileLoader
    }

    func transcribe(
        audioFileURL: URL,
        localeIdentifier: String
    ) async throws -> RemoteSpeechTranscription {
        try Task.checkCancellation()
        let chunks = try await audioFileLoader.loadChunks(audioFileURL)
        guard !chunks.isEmpty else {
            throw RemoteSpeechTranscriptionError.audioFileMissing
        }
        let stableJobId = UUID(
            uuidString: audioFileURL.deletingPathExtension().lastPathComponent
        ) ?? UUID()

        do {
            var responses: [RemoteTranscriptionResponse] = []
            responses.reserveCapacity(chunks.count)
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let request = RemoteTranscriptionRequest(
                    jobId: stableJobId,
                    audio: chunk.audio,
                    chunkIndex: index,
                    chunkCount: chunks.count,
                    startMilliseconds: chunk.startMilliseconds,
                    languageCode: Self.normalizedLanguageCode(localeIdentifier)
                )
                responses.append(try await backend.transcribe(request))
            }

            let transcript = responses
                .map(\.transcript)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !transcript.isEmpty else {
                throw RemoteSpeechTranscriptionError.emptyTranscript
            }
            guard let first = responses.first,
                  responses.allSatisfy({
                      $0.provenance.providerId == first.provenance.providerId
                          && $0.provenance.modelId == first.provenance.modelId
                  }) else {
                throw LoreBackendProcessingError.invalidResponse(requestId: responses.first?.requestId)
            }
            return RemoteSpeechTranscription(
                transcript: transcript,
                provider: first.provenance.providerId,
                model: first.provenance.modelId,
                requestID: first.requestId,
                segments: responses.flatMap(\.segments),
                provenance: responses.map(\.provenance)
            )
        } catch LoreBackendProcessingError.cancelled {
            throw CancellationError()
        }
    }

    private static func normalizedLanguageCode(_ localeIdentifier: String) -> String? {
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let language = normalized.split(separator: "-").first.map(String.init)?.lowercased()
        guard let language, (2...3).contains(language.count) else { return nil }
        return language
    }
}
