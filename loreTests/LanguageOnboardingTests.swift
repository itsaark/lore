import Foundation
import Testing
@testable import lore

struct LanguageOnboardingTests {
    private let english = Locale(identifier: "en_US")

    @Test func deviceLanguagesComeFirstWithoutRepeats() {
        let codes = SpokenLanguageCatalog.orderedCodes(preferredLanguages: ["te-IN", "en-GB", "en-US"])

        #expect(Array(codes.prefix(2)) == ["te", "en"])
        #expect(codes.filter { $0 == "en" }.count == 1)
        #expect(codes.filter { $0 == "te" }.count == 1)
        #expect(codes.count == SpokenLanguageCatalog.curatedCodes.count)
    }

    @Test func uncuratedDeviceLanguageIsStillOffered() {
        let codes = SpokenLanguageCatalog.orderedCodes(preferredLanguages: ["is-IS"])

        #expect(codes.first == "is")
        #expect(codes.count == SpokenLanguageCatalog.curatedCodes.count + 1)
    }

    @Test func defaultSelectionIsTheDeviceLanguages() {
        #expect(SpokenLanguageCatalog.defaultSelection(preferredLanguages: ["es-MX", "en-US", "es-ES"]) == ["es", "en"])
        #expect(SpokenLanguageCatalog.defaultSelection(preferredLanguages: []) == ["en"])
    }

    @Test func optionsShowEndonymAndLocalizedName() {
        let spanish = SpokenLanguageOption(code: "es", displayLocale: english)
        #expect(spanish.endonym == "Español")
        #expect(spanish.localizedName == "Spanish")

        let englishOption = SpokenLanguageOption(code: "en-GB", displayLocale: english)
        #expect(englishOption.code == "en")
        #expect(englishOption.localizedName == nil)
    }

    @Test func searchMatchesEitherNameIgnoringAccents() {
        let spanish = SpokenLanguageOption(code: "es", displayLocale: english)
        #expect(spanish.matches("espanol"))
        #expect(spanish.matches("span"))
        #expect(!spanish.matches("french"))
        #expect(spanish.matches("  "))
    }

    @Test func routingNoteIsOnDeviceOnlyForEnglishAlone() {
        #expect(SpokenLanguageCatalog.routingNote(for: ["en"]) == "English notes are transcribed on your iPhone once its speech model downloads.")
        #expect(SpokenLanguageCatalog.routingNote(for: ["en", "hi"]) == "Notes in these languages are transcribed by Lore’s server and deleted right after.")
        #expect(SpokenLanguageCatalog.routingNote(for: ["fr"]) == "Notes in these languages are transcribed by Lore’s server and deleted right after.")
        #expect(SpokenLanguageCatalog.routingNote(for: []) == "Choose at least one language.")
    }

    @Test func settingsSummaryNamesUpToTwoLanguages() {
        #expect(SpokenLanguageCatalog.summary(for: ["en"], displayLocale: english) == "English")
        #expect(SpokenLanguageCatalog.summary(for: ["en", "es"], displayLocale: english) == "English, Español")
        #expect(SpokenLanguageCatalog.summary(for: ["en", "es", "hi"], displayLocale: english) == "3 languages")
    }

    @Test func onDeviceStatusCopy() {
        #expect(OnDeviceTranscriptionCopy.statusTitle(for: .ready) == "Ready · on this iPhone")
        #expect(OnDeviceTranscriptionCopy.statusTitle(for: .downloading(progress: 0.423)) == "Downloading · 42%")
        #expect(OnDeviceTranscriptionCopy.footer(languageCodes: ["en", "es"], modelName: "Fluid Speech Mini")
            == "On-device transcription is available for English. Your other languages use Lore’s server.")
    }
}
