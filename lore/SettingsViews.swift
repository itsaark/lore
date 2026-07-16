import SwiftData
import SwiftUI

struct SettingsHomeView: View {
    let userProfile: UserProfile
    @ObservedObject var modelManager: ModelManager
    var showsLocalModels = true
    @Query private var vocabularyEntries: [VocabularyEntry]

    var body: some View {
        NavigationStack {
            List {
                Section("Transcription") {
                    NavigationLink {
                        VocabularyView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Vocabulary",
                            systemImage: "text.quote",
                            detail: vocabularyEntries.isEmpty ? nil : "\(vocabularyEntries.count)"
                        )
                    }
                    .accessibilityIdentifier("vocabularySettingsLink")

                    NavigationLink {
                        TranscriptionModeSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Modes",
                            systemImage: "arrow.triangle.branch",
                            detail: "Automatic"
                        )
                    }
                    .accessibilityIdentifier("transcriptionModesSettingsLink")

                    if showsLocalModels {
                        NavigationLink {
                            LocalAISetupView(modelManager: modelManager)
                        } label: {
                            SettingsNavigationLabel(
                                title: "Models",
                                systemImage: "cpu",
                                detail: modelManager.status.statusText
                            )
                        }
                        .accessibilityIdentifier("modelsSettingsLink")
                    }
                }

                Section("Preferences") {
                    NavigationLink {
                        PrivacyDataSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Privacy & Data",
                            systemImage: "hand.raised"
                        )
                    }
                    .accessibilityIdentifier("privacyDataSettingsLink")

                    NavigationLink {
                        JournalStyleSettingsView(userProfile: userProfile)
                    } label: {
                        SettingsNavigationLabel(
                            title: "Journal Style",
                            systemImage: "book.pages"
                        )
                    }
                    .accessibilityIdentifier("journalStyleSettingsLink")

                    NavigationLink {
                        ShortcutsSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Shortcuts",
                            systemImage: "wand.and.stars",
                            badge: "NEW"
                        )
                    }
                    .accessibilityIdentifier("shortcutsSettingsLink")
                }

                Section("About") {
                    NavigationLink {
                        AboutLoreView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "About Lore",
                            systemImage: "info.circle",
                            badge: "PRIVATE"
                        )
                    }
                    .accessibilityIdentifier("aboutLoreSettingsLink")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
}

struct VocabularyView: View {
    private enum FocusField: Hashable {
        case phrase
        case replacement
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyEntry.createdAt, order: .reverse) private var entries: [VocabularyEntry]
    @State private var phrase = ""
    @State private var replacement = ""
    @State private var isReplacementMode = false
    @State private var saveError: String?
    @FocusState private var focusedField: FocusField?

    private var cleanedPhrase: String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !cleanedPhrase.isEmpty && (!isReplacementMode || !cleanedReplacement.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                composer

                if entries.isEmpty {
                    emptyState
                } else {
                    vocabularyList
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .alert(
            "Couldn’t update vocabulary",
            isPresented: Binding(
                get: { saveError != nil },
                set: { isPresented in
                    if !isPresented { saveError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Please try again.")
        }
    }

    private var composer: some View {
        VStack(spacing: 14) {
            TextField("New word or phrase", text: $phrase)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(isReplacementMode ? .next : .done)
                .focused($focusedField, equals: .phrase)
                .onSubmit {
                    if isReplacementMode {
                        focusedField = .replacement
                    } else if canSave {
                        saveEntry()
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 58)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 17))
                .accessibilityIdentifier("vocabularyPhraseField")

            if isReplacementMode {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Replace with", text: $replacement)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .replacement)
                        .onSubmit {
                            if canSave { saveEntry() }
                        }
                        .accessibilityIdentifier("vocabularyReplacementField")
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 58)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 17))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        isReplacementMode.toggle()
                        if !isReplacementMode { replacement = "" }
                    }
                    focusedField = isReplacementMode && !cleanedPhrase.isEmpty ? .replacement : .phrase
                } label: {
                    Text(isReplacementMode ? "Cancel replacement" : "Add replacement")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VocabularySecondaryButtonStyle(isActive: isReplacementMode))
                .accessibilityIdentifier("replacementModeButton")

                Button(action: saveEntry) {
                    Text(isReplacementMode ? "Save replacement" : "Add to vocabulary")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VocabularyPrimaryButtonStyle())
                .disabled(!canSave)
                .accessibilityIdentifier("saveVocabularyButton")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Text("No vocabulary")
                .font(.title2.weight(.semibold))

            Text("Add names, phrases, or a replacement to improve future transcripts.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 116)
        .accessibilityIdentifier("emptyVocabularyState")
    }

    private var vocabularyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your vocabulary")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VocabularyEntryRow(entry: entry) {
                        delete(entry)
                    }

                    if index < entries.count - 1 {
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func saveEntry() {
        guard canSave else { return }

        let key = VocabularyEntry.normalizedKey(for: cleanedPhrase)
        let replacementValue = isReplacementMode ? cleanedReplacement : nil
        let now = Date()

        if let existing = entries.first(where: { $0.normalizedPhrase == key }) {
            existing.phrase = cleanedPhrase
            existing.normalizedPhrase = key
            existing.replacement = replacementValue
            existing.updatedAt = now
        } else {
            modelContext.insert(
                VocabularyEntry(
                    phrase: cleanedPhrase,
                    replacement: replacementValue,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        do {
            try modelContext.save()
            phrase = ""
            replacement = ""
            isReplacementMode = false
            focusedField = .phrase
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete(_ entry: VocabularyEntry) {
        modelContext.delete(entry)
        do {
            try modelContext.save()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct VocabularyEntryRow: View {
    let entry: VocabularyEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if let replacement = entry.replacement, !replacement.isEmpty {
                    HStack(spacing: 8) {
                        Text(entry.phrase)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(replacement)
                            .fontWeight(.semibold)
                    }

                    Text("Replacement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.phrase)
                        .fontWeight(.medium)

                    Text("Preferred spelling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(entry.phrase)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

private struct SettingsNavigationLabel: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct VocabularyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? Color(.systemBackground) : .secondary)
            .padding(.vertical, 15)
            .background(
                isEnabled ? Color.primary : Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct VocabularySecondaryButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.vertical, 15)
            .background(
                isActive ? Color(.systemGray4) : Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct TranscriptionModeSettingsView: View {
    @AppStorage("LoreAllowsCellularProcessing") private var allowsCellularProcessing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Mode", value: "Automatic")

                Toggle("Use mobile data", isOn: $allowsCellularProcessing)
                    .accessibilityIdentifier("cellularProcessingToggle")
            } header: {
                Text("Automatic routing")
            } footer: {
                Text("Lore automatically chooses on-device or private cloud transcription for your iPhone.")
            }
        }
        .navigationTitle("Modes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyDataSettingsView: View {
    var body: some View {
        Form {
            Section {
                Label("Transcripts stay on this iPhone", systemImage: "iphone.gen3")
                Label("Audio is deleted after transcription", systemImage: "trash")
            } header: {
                Text("Local archive")
            } footer: {
                Text("If transcription fails, encrypted audio may be kept briefly so you can retry without losing the note.")
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct JournalStyleSettingsView: View {
    let userProfile: UserProfile
    @AppStorage("LoreJournalPerspective") private var journalPerspective = "thirdPerson"

    var body: some View {
        Form {
            Section("Daily entries") {
                Picker("Perspective", selection: $journalPerspective) {
                    Text("Third person").tag("thirdPerson")
                    Text("First person").tag("firstPerson")
                }
                .accessibilityIdentifier("journalPerspectivePicker")
            }

            Section("Subject") {
                LabeledContent("Name", value: userProfile.name)
                LabeledContent("Hometown", value: userProfile.hometown)
            }
        }
        .navigationTitle("Journal Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShortcutsSettingsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Shortcuts are coming", systemImage: "wand.and.stars")
        } description: {
            Text("A future shortcut will let you begin a voice note without opening Lore first.")
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutLoreView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Archive", value: "On-device")
            } footer: {
                Text("Lore is a private, voice-first journal that turns faithful transcripts into an evolving life story.")
            }
        }
        .navigationTitle("About Lore")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Settings") {
    SettingsHomeView(
        userProfile: UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994),
        modelManager: ModelManager()
    )
    .modelContainer(LoreModelContainer.preview)
}

#Preview("Vocabulary") {
    NavigationStack {
        VocabularyView()
    }
    .modelContainer(LoreModelContainer.preview)
}
