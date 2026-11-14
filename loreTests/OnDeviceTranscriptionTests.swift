import Foundation
import SwiftData
import Testing
@testable import lore

@Suite(.serialized)
struct OnDeviceTranscriptionTests {

    // MARK: - Routing

    @Test func routingMatrixPrefersOnDeviceOnlyForSupportedLanguagesWithAReadyModel() {
        let policy = SpeechTranscriptionPolicy.production
        let languageSets: [[String]] = [["en"], ["en", "es"], ["es"], []]
        let networks: [SpeechNetworkConnection] = [.wifi, .cellular, .unavailable, .unknown]

        for languages in languageSets {
            for modelReady in [true, false] {
                for network in networks {
                    for consent in [true, false] {
                        let route = policy.route(for: .init(
                            preferences: RemoteProcessingPreferences(hasConsent: consent),
                            networkConnection: network,
                            spokenLanguageCodes: languages,
                            isOnDeviceModelReady: modelReady
                        ))

                        let expected: SpeechTranscriptionRoute
                        if modelReady, languages == ["en"] {
                            expected = .onDevice
                        } else if !consent {
                            expected = .deferred(reason: .remoteProcessingConsentRequired)
                        } else {
                            switch network {
                            case .wifi, .cellular: expected = .remote
                            case .unavailable: expected = .deferred(reason: .networkUnavailable)
                            case .unknown: expected = .deferred(reason: .networkUnknown)
                            }
                        }
                        #expect(
                            route == expected,
                            "languages=\(languages) ready=\(modelReady) network=\(network) consent=\(consent)"
                        )
                    }
                }
            }
        }
    }

    @Test func onDeviceRouteRemovesTheOfflineAndConsentWait() {
        let route = SpeechTranscriptionPolicy.production.route(for: .init(
            preferences: RemoteProcessingPreferences(hasConsent: false),
            networkConnection: .unavailable,
            spokenLanguageCodes: ["en"],
            isOnDeviceModelReady: true
        ))
        #expect(route == .onDevice)
        #expect(route.allowsCapture)
        #expect(!route.usesRemoteService)
        #expect(!SpeechTranscriptionRoute.deferred(reason: .networkUnavailable).allowsCapture)
    }

    // MARK: - Languages

    @Test func languageCodesNormalizeToLowercaseLanguageSubtags() {
        #expect(SpokenLanguageSupport.normalizedCode("en-US") == "en")
        #expect(SpokenLanguageSupport.normalizedCode("en_GB") == "en")
        #expect(SpokenLanguageSupport.normalizedCode("EN") == "en")
        #expect(SpokenLanguageSupport.normalizedCode(" es-419 ") == "es")
        #expect(SpokenLanguageSupport.normalizedCode("zh-Hant-TW") == "zh")
        #expect(SpokenLanguageSupport.normalizedCode("") == "")
        #expect(SpokenLanguageSupport.normalizedCode("   ") == "")
    }

    @Test func effectiveLanguagesPreferTheProfileAndDeduplicate() {
        #expect(SpokenLanguageSupport.effectiveLanguageCodes(
            profileCodes: [],
            preferredLanguages: ["en-US", "en-GB", "fr-FR"]
        ) == ["en", "fr"])
        #expect(SpokenLanguageSupport.effectiveLanguageCodes(
            profileCodes: ["EN"],
            preferredLanguages: ["fr-FR"]
        ) == ["en"])
        #expect(SpokenLanguageSupport.allowsOnDeviceTranscription(for: ["en"]))
        #expect(!SpokenLanguageSupport.allowsOnDeviceTranscription(for: ["en", "fr"]))
        #expect(!SpokenLanguageSupport.allowsOnDeviceTranscription(for: []))
    }

    @Test func profileStoresNormalizedSpokenLanguages() {
        let profile = UserProfile(name: "A", hometown: "B", birthYear: 1990)
        profile.setSpokenLanguages(["en-US", "en_GB", "es"])
        #expect(profile.spokenLanguageCodes == ["en", "es"])
    }

    // MARK: - Transcription job

    @MainActor
    @Test func onDeviceTranscriptCommitsWithProvenanceAndNeverCallsRemote() async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        var remoteCalled = false
        let remote = FakeRemoteTranscriber { _, _ in
            remoteCalled = true
            return RemoteSpeechTranscription(transcript: "unused", provider: "groq", model: "whisper")
        }
        let local = FakeLocalTranscriber { url in
            #expect(url == fixture.audioURL)
            return LocalSpeechTranscription(
                transcript: "I grew up near the river.",
                segments: [TranscriptSourceSegment(
                    id: "local-0", startMilliseconds: 0, endMilliseconds: 2_000,
                    text: "I grew up near the river.", confidence: nil, speakerLabel: nil
                )],
                audioDurationSeconds: 5
            )
        }

        let story = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: fixture.job.id,
            remoteTranscriber: remote,
            localTranscriber: local,
            remoteFallbackPermitted: { false },
            localeIdentifier: "en-US",
            modelContext: fixture.context
        )

        let artifact = try #require(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).first)
        #expect(!remoteCalled)
        #expect(story.text == "I grew up near the river.")
        #expect(artifact.source == .onDevice)
        #expect(artifact.sourceValue == "onDevice")
        #expect(artifact.providerId == "fluidaudio")
        #expect(artifact.providerModelId == "FluidVoice-Labs/fluid-speech-mini-coreml@d81c3160dfe5a5e1f8f7267164a07d30617a3a1a")
        #expect(artifact.languageCode == "en")
        #expect(artifact.providerRequestId == nil)
        #expect(artifact.sourceSegmentsJSON?.contains("local-0") == true)
        #expect(fixture.job.state == .succeeded)
        #expect(fixture.job.providerId == "fluidaudio")
        #expect(fixture.job.transcriptArtifactId == artifact.id)
        #expect(try fixture.context.fetch(FetchDescriptor<AudioAsset>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @MainActor
    @Test func failingLocalTranscriberFallsBackToRemoteBeforeAnyCommitOrDeletion() async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        var localSawRunningJob = false
        var remoteSawDurableState = false
        let local = FakeLocalTranscriber { _ in
            localSawRunningJob = fixture.job.state == .running
            throw TestLocalFailure.modelLoadFailed
        }
        let remote = FakeRemoteTranscriber { url, locale in
            let artifacts = try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>())
            let assets = try fixture.context.fetch(FetchDescriptor<AudioAsset>())
            remoteSawDurableState = artifacts.isEmpty
                && assets.contains { !$0.isDeleted }
                && FileManager.default.fileExists(atPath: url.path)
                && fixture.job.state == .running
                && (fixture.job.leaseExpiresAt ?? .distantPast) > Date()
            #expect(locale == "en-US")
            return RemoteSpeechTranscription(
                transcript: "The backup heard me.",
                provider: "groq",
                model: "whisper-large-v3-turbo",
                requestID: "req-1"
            )
        }

        let story = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: fixture.job.id,
            remoteTranscriber: remote,
            localTranscriber: local,
            remoteFallbackPermitted: { true },
            localeIdentifier: "en-US",
            modelContext: fixture.context
        )

        let artifacts = try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>())
        #expect(localSawRunningJob)
        #expect(remoteSawDurableState)
        #expect(story.text == "The backup heard me.")
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.source == .remoteProvider)
        #expect(artifacts.first?.providerId == "groq")
        #expect(fixture.job.state == .succeeded)
        #expect(fixture.job.attemptCount == 1)
        #expect(fixture.job.providerId == "groq")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptVersion>()).count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))

        // A replay after success neither re-transcribes nor duplicates rows.
        _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: fixture.job.id,
            remoteTranscriber: FakeRemoteTranscriber { _, _ in
                Issue.record("A succeeded job transcribed again")
                throw TestLocalFailure.modelLoadFailed
            },
            localTranscriber: FakeLocalTranscriber { _ in
                Issue.record("A succeeded job transcribed again")
                throw TestLocalFailure.modelLoadFailed
            },
            localeIdentifier: "en-US",
            modelContext: fixture.context
        )
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptVersion>()).count == 1)
    }

    @MainActor
    @Test(arguments: ["", "   ", "... ?", "the the the the the the the the the the the the the the the the the the the the the"])
    func unusableLocalOutputFallsBackToRemote(localText: String) async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        let local = FakeLocalTranscriber { _ in
            LocalSpeechTranscription(transcript: localText, audioDurationSeconds: 10)
        }
        let remote = FakeRemoteTranscriber { _, _ in
            RemoteSpeechTranscription(transcript: "Real words.", provider: "groq", model: "whisper")
        }

        let story = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: fixture.job.id,
            remoteTranscriber: remote,
            localTranscriber: local,
            localeIdentifier: "en-US",
            modelContext: fixture.context
        )
        #expect(story.text == "Real words.")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).first?.source == .remoteProvider)
    }

    @MainActor
    @Test func localFailureWithoutRemoteFallbackIsRetryableAndKeepsAudio() async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        let remote = FakeRemoteTranscriber { _, _ in
            Issue.record("Remote must not run when the fallback is not permitted")
            return RemoteSpeechTranscription(transcript: "unused", provider: "groq", model: "whisper")
        }
        let local = FakeLocalTranscriber { _ in throw TestLocalFailure.modelLoadFailed }

        await #expect(throws: OnDeviceTranscriptionFailure.self) {
            _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
                jobID: fixture.job.id,
                remoteTranscriber: remote,
                localTranscriber: local,
                remoteFallbackPermitted: { false },
                localeIdentifier: "en-US",
                modelContext: fixture.context
            )
        }

        #expect(fixture.job.state == .queued)
        #expect(fixture.job.nextAttemptAt != nil)
        #expect(fixture.job.lastErrorCode == "on_device_transcription_failed")
        #expect(fixture.story.processingStatus == "transcriptionPending")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<AudioAsset>()).count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @MainActor
    @Test func unusableLocalOutputWithoutFallbackRecordsItsOwnErrorCode() async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        let local = FakeLocalTranscriber { _ in
            LocalSpeechTranscription(transcript: "", audioDurationSeconds: 8)
        }

        do {
            _ = try await SpeechRecognitionViewModel.runTranscriptionJob(
                jobID: fixture.job.id,
                remoteTranscriber: UnavailableRemoteSpeechTranscriber(),
                localTranscriber: local,
                remoteFallbackPermitted: { false },
                localeIdentifier: "en-US",
                modelContext: fixture.context
            )
            Issue.record("Unusable local output committed")
        } catch {}

        #expect(fixture.job.lastErrorCode == "on_device_transcript_unusable")
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    // MARK: - Vocabulary

    @MainActor
    @Test func vocabularyReplacementsLayerAnAutomaticCorrectionOverTheRawSource() async throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        fixture.context.insert(VocabularyEntry(phrase: "Marisa", replacement: "Marissa"))
        fixture.context.insert(VocabularyEntry(phrase: "Hyderabad"))
        try fixture.context.save()
        let local = FakeLocalTranscriber { _ in
            LocalSpeechTranscription(transcript: "marisa visited Hyderabad.", audioDurationSeconds: 4)
        }

        let story = try await SpeechRecognitionViewModel.runTranscriptionJob(
            jobID: fixture.job.id,
            remoteTranscriber: UnavailableRemoteSpeechTranscriber(),
            localTranscriber: local,
            localeIdentifier: "en-US",
            modelContext: fixture.context
        )

        let artifact = try #require(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).first)
        let versions = try fixture.context.fetch(FetchDescriptor<TranscriptVersion>())
            .sorted { $0.revision < $1.revision }
        #expect(artifact.rawText == "marisa visited Hyderabad.")
        #expect(versions.count == 2)
        #expect(versions[0].kind == .sourceSnapshot)
        #expect(versions[0].text == "marisa visited Hyderabad.")
        #expect(versions[1].kind == .automaticCorrection)
        #expect(versions[1].author == .system)
        #expect(versions[1].supersedesVersionId == versions[0].id)
        #expect(versions[1].text == "Marissa visited Hyderabad.")
        #expect(story.text == "Marissa visited Hyderabad.")

        // Downstream generation reads the corrected revision.
        let profile = UserProfile(name: "A", hometown: "B", birthYear: 1990)
        let request = try RemoteGenerationRequestFactory.makeRequest(
            for: story, userProfile: profile, in: fixture.context
        )
        #expect(request.transcriptVersionId == versions[1].id)
        #expect(request.sourceSegments.first?.text == "Marissa visited Hyderabad.")
    }

    @MainActor
    @Test func remoteTranscriptsAlsoReceiveVocabularyReplacements() throws {
        let fixture = try makeJobFixture()
        defer { fixture.cleanUp() }
        fixture.context.insert(VocabularyEntry(phrase: "Mike", replacement: "Myke"))
        fixture.job.beginAttempt()
        try fixture.context.save()
        let audioAsset = try #require(try fixture.context.fetch(FetchDescriptor<AudioAsset>()).first)
        let response = RemoteSpeechTranscription(transcript: "Mike said hi.", provider: "groq", model: "whisper")

        for _ in 0..<2 {
            _ = try SpeechRecognitionViewModel.commitRemoteTranscription(
                response, for: fixture.story, audioAsset: audioAsset, job: fixture.job,
                localeIdentifier: "en-US", modelContext: fixture.context
            )
        }

        #expect(fixture.story.text == "Myke said hi.")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptArtifact>()).first?.rawText == "Mike said hi.")
        #expect(try fixture.context.fetch(FetchDescriptor<TranscriptVersion>()).count == 2)
    }

    @Test func vocabularyReplacementEdgeCases() {
        let corrector = TranscriptVocabularyCorrector(replacements: [
            .init(phrase: "Marisa", replacement: "Marissa"),
            .init(phrase: "new york", replacement: "New York"),
            .init(phrase: "new york city", replacement: "NYC"),
            .init(phrase: "A", replacement: "B"),
            .init(phrase: "B", replacement: "C"),
            .init(phrase: "c++", replacement: "C plus plus"),
            .init(phrase: "  ", replacement: "ignored"),
            .init(phrase: "Zoë", replacement: "Zoey"),
        ])

        // Case-insensitive, whole word, punctuation preserved.
        #expect(corrector.apply(to: "MARISA, marisa! (Marisa)") == "Marissa, Marissa! (Marissa)")
        #expect(corrector.apply(to: "Marisa's dog") == "Marissa's dog")
        // Never inside a longer word.
        #expect(corrector.apply(to: "Marisabel and Marisas") == "Marisabel and Marisas")
        // Longest phrase wins; whitespace inside a phrase is flexible.
        #expect(corrector.apply(to: "I moved to New  York City.") == "I moved to NYC.")
        #expect(corrector.apply(to: "New York state") == "New York state")
        // One pass: a replacement is never replaced again.
        #expect(corrector.apply(to: "A then B") == "B then C")
        // Regex metacharacters in a phrase are literal.
        #expect(corrector.apply(to: "I wrote c++ code") == "I wrote C plus plus code")
        #expect(corrector.apply(to: "I wrote cxx code") == "I wrote cxx code")
        // Non-ASCII letters count as word characters.
        #expect(corrector.apply(to: "Zoë came; Zoëy didn't") == "Zoey came; Zoëy didn't")
        // Empty input and empty vocabularies are no-ops.
        #expect(corrector.apply(to: "") == "")
        #expect(TranscriptVocabularyCorrector(replacements: []).apply(to: "Marisa") == "Marisa")
    }

    @Test func vocabularyCollisionsPreferTheMostRecentlyEditedEntry() {
        let older = VocabularyEntry(phrase: "Jon", replacement: "John", updatedAt: Date(timeIntervalSince1970: 1))
        let newer = VocabularyEntry(phrase: "jon", replacement: "Jonne", updatedAt: Date(timeIntervalSince1970: 2))
        let preferredOnly = VocabularyEntry(phrase: "Jon")
        let corrector = TranscriptVocabularyCorrector(entries: [older, preferredOnly, newer])
        #expect(corrector.apply(to: "Jon left.") == "Jonne left.")
        #expect(corrector.replacements.count == 1)
    }

    // MARK: - Provenance storage

    @Test func transcriptSourceRawValuesAreStable() {
        #expect(TranscriptSource(rawValue: "appleSpeech") == .appleSpeech)
        #expect(TranscriptSource(rawValue: "remoteProvider") == .remoteProvider)
        #expect(TranscriptSource(rawValue: "imported") == .imported)
        #expect(TranscriptSource(rawValue: "legacyStory") == .legacyStory)
        #expect(TranscriptSource.onDevice.rawValue == "onDevice")
    }

    // MARK: - Model store

    @MainActor
    @Test func modelStoreDetectsACompleteInstallWithoutNetwork() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = OnDeviceSpeechModelStore.installedModelDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(OnDeviceSpeechModelManifest.revision.utf8)
            .write(to: directory.appendingPathComponent(".lore-model-complete"))

        let store = OnDeviceSpeechModelStore(rootDirectory: root, monitorsNetwork: false)
        #expect(store.state == .ready)
        #expect(store.installedModelDirectory == directory)

        store.deleteModel()
        #expect(store.state == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    @Test func modelStoreNeverTrustsAnInstallWithoutAMatchingMarker() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = OnDeviceSpeechModelStore.installedModelDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("an-older-revision".utf8).write(to: directory.appendingPathComponent(".lore-model-complete"))

        let store = OnDeviceSpeechModelStore(rootDirectory: root, monitorsNetwork: false)
        #expect(store.state == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    @Test func modelStoreWaitsForWiFiWhenNoNetworkIsKnown() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnDeviceSpeechModelStore(rootDirectory: root, monitorsNetwork: false)
        store.startDownloadIfNeeded()
        #expect(store.state == .waitingForWiFi)
    }

    @Test func modelFileVerificationChecksSizeAndHash() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let contents = Data("hello\n".utf8)
        try contents.write(to: url)

        // `git hash-object` of "hello\n" and `shasum -a 256` of the same bytes.
        let blob = OnDeviceSpeechModelFile(path: "config.json", size: 6, gitBlobSHA1: "ce013625030ba8dba906f756967f9e9ca394464a")
        let lfs = OnDeviceSpeechModelFile(path: "config.json", size: 6, sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        #expect(try OnDeviceSpeechModelStore.verify(url, against: blob))
        #expect(try OnDeviceSpeechModelStore.verify(url, against: lfs))
        #expect(try !OnDeviceSpeechModelStore.verify(url, against: .init(path: "config.json", size: 7, sha256: lfs.sha256!)))
        #expect(try !OnDeviceSpeechModelStore.verify(url, against: .init(path: "config.json", size: 6, sha256: String(repeating: "0", count: 64))))
    }

    @Test func manifestMatchesThePinnedRevisionsSize() {
        #expect(OnDeviceSpeechModelManifest.totalBytes == 252_730_493)
        #expect(OnDeviceSpeechModelManifest.files.allSatisfy { ($0.sha256 == nil) != ($0.gitBlobSHA1 == nil) })
        #expect(OnDeviceSpeechModelManifest.files.contains { $0.path == "JointDecision.mlmodelc/weights/weight.bin" })
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-ondevice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeJobFixture() throws -> JobFixture {
        let container = try LoreModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-ondevice-\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: audioURL)
        let (story, job) = try SpeechRecognitionViewModel.persistRemoteCaptureForTranscription(
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            endTime: Date(timeIntervalSince1970: 1_800_000_010),
            audioFileURL: audioURL,
            modelContext: context
        )
        return JobFixture(container: container, context: context, story: story, job: job, audioURL: audioURL)
    }
}

private struct JobFixture {
    let container: ModelContainer
    let context: ModelContext
    let story: Story
    let job: ProcessingJob
    let audioURL: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: audioURL)
    }
}

private enum TestLocalFailure: Error {
    case modelLoadFailed
}

private final class FakeLocalTranscriber: LocalSpeechTranscribing, @unchecked Sendable {
    typealias Handler = @MainActor (URL) throws -> LocalSpeechTranscription
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func prepare() async {}

    func transcribe(audioFileURL: URL) async throws -> LocalSpeechTranscription {
        try await handler(audioFileURL)
    }

    func unload() async {}
}

private final class FakeRemoteTranscriber: RemoteSpeechTranscribing, @unchecked Sendable {
    typealias Handler = @MainActor (URL, String) throws -> RemoteSpeechTranscription
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func transcribe(audioFileURL: URL, localeIdentifier: String) async throws -> RemoteSpeechTranscription {
        try await handler(audioFileURL, localeIdentifier)
    }
}
