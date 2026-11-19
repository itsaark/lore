import Foundation
import Testing
@testable import lore

struct MotionStateTests {
    @Test func captureOnlyRevealsAfterItsOwnSuccessfulSave() {
        var phase = CaptureSaveWavePhase.hidden
        phase.update(isCapturing: false, didSave: true, isOnScreen: true)
        #expect(phase == .hidden)

        phase.update(isCapturing: true, didSave: false, isOnScreen: true)
        #expect(phase == .capturing)
        phase.update(isCapturing: false, didSave: false, isOnScreen: true)
        #expect(phase == .hidden)

        phase.update(isCapturing: true, didSave: false, isOnScreen: true)
        phase.update(isCapturing: false, didSave: true, isOnScreen: true)
        #expect(phase == .revealing)
        phase.update(isCapturing: false, didSave: false, isOnScreen: false)
        #expect(phase == .hidden)
    }

    @Test @MainActor func onlyLocallyGeneratedRevisionsCanRevealAndOnlyOnce() {
        let session = PaintingRevealSession()
        let id = UUID()
        let date = Date()
        let first = PaintingRevision(id: id, updatedAt: date, fingerprint: "initial")
        let second = PaintingRevision(id: id, updatedAt: date, fingerprint: "rewritten")
        let day = "2026-11-18"

        #expect(!session.claim(first, for: day))
        session.register(first, for: day)
        #expect(session.pendingRevision(for: day) == first)
        #expect(!session.claim(first, for: "2026-11-17"))
        #expect(session.claim(first, for: day))
        session.register(first, for: day)
        #expect(!session.claim(first, for: day))

        session.register(second, for: day)
        #expect(!session.claim(first, for: day))
        #expect(session.claim(second, for: day))
        #expect(session.pendingRevision(for: day) == nil)
    }

    @Test @MainActor func aNewerPaintingReplacesAnUnseenRevision() {
        let session = PaintingRevealSession()
        let id = UUID()
        let date = Date()
        let old = PaintingRevision(id: id, updatedAt: date, fingerprint: "old")
        let new = PaintingRevision(id: id, updatedAt: date, fingerprint: "new")
        let key = "memory:test"

        session.register(old, for: key)
        session.register(new, for: key)
        #expect(!session.claim(old, for: key))
        #expect(session.claim(new, for: key))
    }

    @Test func recordOrbFollowsTranscriptionAndTodaysWriting() {
        let today = "2026-11-19"
        #expect(WritingOrbVisibility.onRecordButton(
            isRecording: false, isTranscribing: true, todayKey: today, writingKey: nil
        ))
        #expect(WritingOrbVisibility.onRecordButton(
            isRecording: false, isTranscribing: false, todayKey: today, writingKey: today
        ))
        #expect(!WritingOrbVisibility.onRecordButton(
            isRecording: false, isTranscribing: false, todayKey: today, writingKey: "2026-11-18"
        ))
        #expect(!WritingOrbVisibility.onRecordButton(
            isRecording: true, isTranscribing: false, todayKey: today, writingKey: today
        ))
    }

    @Test func dialOrbOnlyFillsAnEmptyPictureForTheSelectedStory() {
        #expect(WritingOrbVisibility.inDialPicture(hasPicture: false, selectionContainsWritingStory: true))
        #expect(!WritingOrbVisibility.inDialPicture(hasPicture: true, selectionContainsWritingStory: true))
        #expect(!WritingOrbVisibility.inDialPicture(hasPicture: false, selectionContainsWritingStory: false))
    }
}
