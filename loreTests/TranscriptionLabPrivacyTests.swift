#if DEBUG
import Foundation
import Testing
@testable import lore

/// Benchmark clips must stay on the phone until launch: nothing uploads by
/// default, and nothing is included in device backups.
struct TranscriptionLabPrivacyTests {
    @MainActor @Test func uploadingEnginesStartOffAndOnDeviceEnginesStartOn() {
        let lab = TranscriptionLabModel()
        let uploading = lab.engines.filter(\.uploadsAudio)

        #expect(uploading.map(\.id) == ["remote.groq-whisper"])
        #expect(uploading.allSatisfy { $0.displayName.contains("uploads this clip") })
        for engine in lab.engines {
            #expect(lab.enabledEngineIDs.contains(engine.id) == !engine.uploadsAudio)
        }
    }

    @MainActor @Test func eachLabSessionStartsWithGroqOffEvenIfEnabledBefore() {
        let first = TranscriptionLabModel()
        first.enabledEngineIDs.insert("remote.groq-whisper")

        let next = TranscriptionLabModel()
        #expect(!next.enabledEngineIDs.contains("remote.groq-whisper"))
    }

    @Test func ensureRootExcludesRootAndExistingClipsFromBackupWithoutTouchingThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-privacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("2026-11-01-existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let audio = existing.appendingPathComponent("audio.m4a")
        let payload = Data("not really audio".utf8)
        try payload.write(to: audio)
        let store = TranscriptionLabClipStore(rootURL: root)
        #expect(!store.isExcludedFromBackup(existing))

        try store.ensureRoot()

        #expect(store.isExcludedFromBackup(root))
        #expect(store.isExcludedFromBackup(existing))
        #expect(try Data(contentsOf: audio) == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["2026-11-01-existing"])
    }

    @Test func newClipFoldersAreExcludedFromBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-privacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptionLabClipStore(rootURL: root)

        try store.createClipFolder("2026-11-14-new")

        #expect(store.isExcludedFromBackup(root))
        #expect(store.isExcludedFromBackup(store.folderURL(for: "2026-11-14-new")))
    }
}
#endif
