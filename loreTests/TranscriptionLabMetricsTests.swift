#if DEBUG
import Foundation
import Testing
@testable import lore

struct TranscriptionLabMetricsTests {
    @Test func normalizationIgnoresCasePunctuationAndApostrophes() {
        #expect(
            TranscriptionLabMetrics.normalizedWords("Don’t stop, Mrs. O'Brien — well-known!")
                == ["dont", "stop", "mrs", "obrien", "well", "known"]
        )
    }

    @Test func identicalTextHasZeroWordErrorRate() throws {
        let wer = try #require(
            TranscriptionLabMetrics.wordErrorRate(reference: "Met Priya at the café.", hypothesis: "met priya at the café")
        )
        #expect(wer.errors == 0)
        #expect(wer.rate == 0)
    }

    @Test func countsSubstitutionsAndDeletions() throws {
        // cat→bat is a substitution and the second "the" is dropped.
        let wer = try #require(
            TranscriptionLabMetrics.wordErrorRate(
                reference: "The cat sat on the mat",
                hypothesis: "the bat sat on mat"
            )
        )
        #expect(wer.substitutions == 1)
        #expect(wer.deletions == 1)
        #expect(wer.insertions == 0)
        #expect(wer.referenceWordCount == 6)
        #expect(abs(wer.rate - 2.0 / 6.0) < 1e-9)
    }

    @Test func countsInsertions() throws {
        let wer = try #require(
            TranscriptionLabMetrics.wordErrorRate(reference: "hello world", hypothesis: "hello big world")
        )
        #expect(wer.insertions == 1)
        #expect(wer.errors == 1)
        #expect(wer.rate == 0.5)
    }

    @Test func emptyHypothesisDeletesEveryReferenceWord() throws {
        let wer = try #require(TranscriptionLabMetrics.wordErrorRate(reference: "one two three", hypothesis: ""))
        #expect(wer.deletions == 3)
        #expect(wer.rate == 1)
    }

    @Test func emptyReferenceIsNotScored() {
        #expect(TranscriptionLabMetrics.wordErrorRate(reference: " ... ", hypothesis: "anything") == nil)
    }

    @Test func nameRecallMatchesWholeWordsCaseInsensitively() throws {
        let recall = try #require(
            TranscriptionLabMetrics.nameRecall(
                names: ["Anne", "Siobhan", "Mary Jane", "Priya"],
                hypothesis: "Annex said siobhan and mary jane met PRIYA."
            )
        )
        #expect(recall.found == ["Siobhan", "Mary Jane", "Priya"])
        #expect(recall.missed == ["Anne"])
        #expect(abs(recall.rate - 0.75) < 1e-9)
    }

    @Test func noNamesMeansNoRecall() {
        #expect(TranscriptionLabMetrics.nameRecall(names: [" ", ""], hypothesis: "hello") == nil)
    }

    @Test func parsesCommaSeparatedNamesWithoutDuplicates() {
        #expect(TranscriptionLabMetrics.parseNames(" Anne, Priya ,, anne, Mary Jane ") == ["Anne", "Priya", "Mary Jane"])
    }
}
#endif
