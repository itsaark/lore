import SwiftUI

/// One language the person can tell Lore they speak.
struct SpokenLanguageOption: Identifiable, Equatable, Sendable {
    /// Normalized language code ("en", "es", "zh").
    let code: String
    /// The language's name in itself ("Español", "中文").
    let endonym: String
    /// The language's name in the interface language ("Spanish"), or nil when
    /// it would just repeat the endonym.
    let localizedName: String?

    var id: String { code }

    init(code: String, displayLocale: Locale = .current) {
        let code = SpokenLanguageSupport.normalizedCode(code)
        self.code = code

        let nativeLocale = Locale(identifier: code)
        let endonym = nativeLocale.localizedString(forLanguageCode: code)?
            .capitalized(with: nativeLocale) ?? code
        let localized = displayLocale.localizedString(forLanguageCode: code)?
            .capitalized(with: displayLocale)

        self.endonym = endonym
        self.localizedName = localized.flatMap { name in
            name.compare(endonym, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                ? nil
                : name
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return endonym.range(of: query, options: options) != nil
            || (localizedName?.range(of: query, options: options) != nil)
            || code.range(of: query, options: options) != nil
    }
}

/// The languages offered in onboarding and Settings, and the copy that
/// explains where each choice is transcribed.
enum SpokenLanguageCatalog {
    /// Common languages, after the device's own. Ordered roughly by how many
    /// people speak them, with the Indian languages grouped together.
    static let curatedCodes: [String] = [
        "en", "es", "fr", "de", "pt", "it", "nl",
        "hi", "te", "ta", "bn", "mr", "gu", "kn", "ml", "pa", "ur",
        "zh", "ja", "ko", "ar", "ru", "tr", "pl", "uk",
        "vi", "th", "id", "ms", "fil", "sv", "el", "he", "fa", "sw",
    ]

    /// Device languages first, then the curated list, without repeats.
    static func options(
        preferredLanguages: [String] = Locale.preferredLanguages,
        displayLocale: Locale = .current
    ) -> [SpokenLanguageOption] {
        orderedCodes(preferredLanguages: preferredLanguages)
            .map { SpokenLanguageOption(code: $0, displayLocale: displayLocale) }
    }

    static func orderedCodes(preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        var seen = Set<String>()
        return (preferredLanguages + curatedCodes)
            .map(SpokenLanguageSupport.normalizedCode)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The device's preferred languages, pre-selected on first ask.
    static func defaultSelection(preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        let codes = SpokenLanguageSupport.effectiveLanguageCodes(
            profileCodes: [],
            preferredLanguages: preferredLanguages
        )
        return codes.isEmpty ? ["en"] : codes
    }

    /// A short summary for a Settings row: "English", "English, Español",
    /// or "4 languages".
    static func summary(for codes: [String], displayLocale: Locale = .current) -> String {
        let names = codes.map { SpokenLanguageOption(code: $0, displayLocale: displayLocale).endonym }
        switch names.count {
        case 0: return "None"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names.count) languages"
        }
    }

    /// The quiet line under the language choice. Kept to what Lore actually
    /// does, so it never promises more privacy than it gives.
    static func routingNote(for codes: [String]) -> String {
        if codes.isEmpty {
            return "Choose at least one language."
        }
        if SpokenLanguageSupport.allowsOnDeviceTranscription(for: codes) {
            return englishOnDeviceNote
        }
        return "Notes in these languages are transcribed by Lore’s server and deleted right after."
    }

    static let englishOnDeviceNote = "English notes are transcribed on your iPhone once its speech model downloads."
}

/// Searchable multi-select list of languages. At least one stays selected:
/// the last selected row can't be turned off.
struct SpokenLanguagePicker: View {
    @Binding var selection: [String]
    var options: [SpokenLanguageOption] = SpokenLanguageCatalog.options()

    @State private var query = ""

    private var visibleOptions: [SpokenLanguageOption] {
        options.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 16) {
            searchField

            if visibleOptions.isEmpty {
                Text("No languages match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(LoreTheme.caption(.footnote))
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleOptions.enumerated()), id: \.element.id) { index, option in
                        SpokenLanguageRow(
                            option: option,
                            isSelected: selection.contains(option.code)
                        ) {
                            toggle(option.code)
                        }

                        if index < visibleOptions.count - 1 {
                            LoreHairline()
                                .padding(.leading, 18)
                        }
                    }
                }
                .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                        .strokeBorder(LoreTheme.hairline, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(LoreTheme.tertiaryInk)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $query,
                prompt: Text("Search languages").foregroundStyle(LoreTheme.tertiaryInk)
            )
            .foregroundStyle(LoreTheme.ink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityIdentifier("languageSearchField")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LoreTheme.tertiaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .loreField(minHeight: 48)
    }

    private func toggle(_ code: String) {
        if let index = selection.firstIndex(of: code) {
            guard selection.count > 1 else { return }
            selection.remove(at: index)
        } else {
            // Keep the selection in list order so summaries read naturally.
            let order = options.map(\.code)
            selection.append(code)
            selection.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        }
    }
}

private struct SpokenLanguageRow: View {
    let option: SpokenLanguageOption
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.endonym)
                        .font(LoreTheme.body)
                        .foregroundStyle(LoreTheme.ink)

                    if let localizedName = option.localizedName {
                        Text(localizedName)
                            .font(LoreTheme.caption(.caption))
                            .foregroundStyle(LoreTheme.secondaryInk)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.light))
                    .foregroundStyle(isSelected ? LoreTheme.ink : LoreTheme.tertiaryInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("language-\(option.code)")
    }
}

/// The live line explaining where the chosen languages are transcribed.
struct SpokenLanguageRoutingNote: View {
    let codes: [String]

    var body: some View {
        Text(SpokenLanguageCatalog.routingNote(for: codes))
            .font(LoreTheme.caption(.footnote))
            .foregroundStyle(LoreTheme.secondaryInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.25), value: codes)
            .accessibilityIdentifier("languageRoutingNote")
    }
}
