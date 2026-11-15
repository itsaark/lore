#if DEBUG
import Foundation
import Testing
@testable import lore

struct ModelLabJournalTests {
    @Test func splitsTranscriptIntoCitableSentences() {
        let segments = LabJournalSegmenter.segments(for: "We drove to Astoria. Dad bought chowder! It rained the whole way?")
        #expect(segments.map(\.id) == ["s1", "s2", "s3"])
        #expect(segments.first?.text == "We drove to Astoria.")
    }

    @Test func labRequestEncodesAsOneFlatObjectWithTheChosenWriter() throws {
        let request = LabDailyEntryRequest(
            base: DailyEntryGenerationRequest(
                promptVersion: "grounded-journal-v2",
                jobId: UUID(),
                noteId: UUID(),
                transcriptArtifactId: UUID(),
                transcriptVersionId: UUID(),
                capturedLocalDate: "2026-11-14",
                languageCode: "en-US",
                subject: JournalSubject(displayName: "Maya", pronouns: []),
                sourceSegments: [
                    TranscriptSourceSegment(id: "s1", startMilliseconds: 0, endMilliseconds: 10, text: "Hi.", confidence: nil, speakerLabel: nil)
                ]
            ),
            labModel: "glm-5p3"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        #expect(object["lab_model"] as? String == "glm-5p3")
        #expect(object["prompt_version"] as? String == "grounded-journal-v2")
        #expect(object["base"] == nil)
        #expect((object["source_segments"] as? [Any])?.count == 1)
    }

    @Test func flagsNamesThatNeverAppearInTheSource() {
        var output = LabJournalOutput(id: UUID(), candidateID: "glm-5p3|grounded-journal-v2", blindLabel: "A", status: .succeeded)
        output.sentences = [LabJournalSentence(text: "Maya walked with Priya through Portland.", sourceReferences: ["s1"])]
        let names = output.unsupportedNames(source: "I walked with Priya after work.", subject: "Maya")
        #expect(names.contains("Priya") == false)
        #expect(names.contains("Maya") == false)
        #expect(names.contains("Portland"))
    }

    @Test func everyCandidateUsesAnAllowlistedBackendAlias() {
        let backendAliases: Set<String> = [
            "gpt-oss-120b", "deepseek-v4-flash", "deepseek-v4p1-flash", "glm-5p3", "glm-5p3-flash", "minimax-m3"
        ]
        #expect(LabJournalCandidate.all.allSatisfy { backendAliases.contains($0.modelAlias) })
        #expect(LabJournalCandidate.defaultSelection.allSatisfy { LabJournalCandidate.find($0) != nil })
    }
}
#endif
