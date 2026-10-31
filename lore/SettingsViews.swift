import AVFAudio
import CoreLocation
import SwiftData
import SwiftUI
import UIKit

struct SettingsHomeView: View {
    let userProfile: UserProfile
    @EnvironmentObject private var cloudArchiveStatus: CloudArchiveStatusMonitor
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Query private var vocabularyEntries: [VocabularyEntry]
    @State private var locationPermission: SettingsPermissionState = .notRequested
    @State private var microphonePermission: SettingsPermissionState = .notRequested

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Settings")
                            .font(LoreTheme.display(40))
                            .foregroundStyle(LoreTheme.ink)
                            .accessibilityAddTraits(.isHeader)

                        Spacer()

                        Button("Done") { dismiss() }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LoreTheme.ink)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("settingsDoneButton")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 16))
                }

                Section {
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
                    .loreListRow()
                } header: {
                    LoreSectionHeader("Transcription")
                }

                Section {
                    NavigationLink {
                        JournalStyleSettingsView(userProfile: userProfile)
                    } label: {
                        SettingsNavigationLabel(
                            title: "Journal Style",
                            systemImage: "book.pages"
                        )
                    }
                    .accessibilityIdentifier("journalStyleSettingsLink")
                    .loreListRow()
                } header: {
                    LoreSectionHeader("Preferences")
                }

                Section {
                    LabeledContent {
                        Text(cloudArchiveStatus.status.settingsTitle)
                            .foregroundStyle(cloudArchiveStatus.status.settingsColor)
                    } label: {
                        SettingsRowLabel(title: "Journal & Transcripts", systemImage: "icloud")
                    }
                    .accessibilityIdentifier("iCloudArchiveStatus")
                    .loreListRow()
                } header: {
                    LoreSectionHeader("Private iCloud Archive")
                } footer: {
                    SettingsFooter(cloudArchiveStatus.status.settingsDetail)
                }

                Section {
                    SettingsPermissionRow(
                        title: "Location",
                        systemImage: "location",
                        permission: locationPermission
                    )
                    .accessibilityIdentifier("locationPermissionStatus")
                    .loreListRow()

                    SettingsPermissionRow(
                        title: "Microphone",
                        systemImage: "mic",
                        permission: microphonePermission
                    )
                    .accessibilityIdentifier("microphonePermissionStatus")
                    .loreListRow()

                    Button {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(settingsURL)
                    } label: {
                        HStack {
                            SettingsRowLabel(title: "Open iPhone Settings", systemImage: "gearshape")
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LoreTheme.tertiaryInk)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(LoreTheme.ink)
                    .accessibilityIdentifier("openIPhoneSettingsButton")
                    .loreListRow()
                } header: {
                    LoreSectionHeader("Permissions")
                } footer: {
                    SettingsFooter("Allow Location to add local context and Microphone to record voice notes. Permissions are requested when first used and can be changed in iPhone Settings.")
                }

                Section {
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
                    .loreListRow()
                } header: {
                    LoreSectionHeader("About")
                }
            }
            .listStyle(.insetGrouped)
            .loreGroupedList()
            .navigationTitle("Settings")
            .toolbar(.hidden, for: .navigationBar)
            .task {
                refreshPermissionStates()
                await cloudArchiveStatus.refreshAccountStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshPermissionStates()
                    Task {
                        await cloudArchiveStatus.refreshAccountStatus()
                    }
                }
            }
        }
    }

    private func refreshPermissionStates() {
        locationPermission = SettingsPermissionState(
            locationAuthorizationStatus: CLLocationManager().authorizationStatus
        )
        microphonePermission = SettingsPermissionState(
            recordPermission: AVAudioApplication.shared.recordPermission
        )
    }
}

private enum SettingsPermissionState {
    case allowed
    case denied
    case notRequested
    case restricted

    init(locationAuthorizationStatus: CLAuthorizationStatus) {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            self = .allowed
        case .denied:
            self = .denied
        case .notDetermined:
            self = .notRequested
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }

    init(recordPermission: AVAudioApplication.recordPermission) {
        switch recordPermission {
        case .granted:
            self = .allowed
        case .denied:
            self = .denied
        case .undetermined:
            self = .notRequested
        @unknown default:
            self = .restricted
        }
    }

    var title: String {
        switch self {
        case .allowed:
            "Allowed"
        case .denied:
            "Off"
        case .notRequested:
            "Not Asked"
        case .restricted:
            "Restricted"
        }
    }

    var color: Color {
        switch self {
        case .allowed:
            LoreTheme.ink
        case .denied:
            LoreTheme.attention
        case .notRequested, .restricted:
            LoreTheme.secondaryInk
        }
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let systemImage: String
    let permission: SettingsPermissionState

    var body: some View {
        LabeledContent {
            Text(permission.title)
                .foregroundStyle(permission.color)
        } label: {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
    }
}

private extension CloudArchiveStatusSnapshot {
    var settingsTitle: String {
        switch displayState {
        case .checkingAccount:
            "Checking…"
        case .accountUnavailable(let accountState, _):
            switch accountState {
            case .noAccount:
                "Not Signed In"
            case .restricted:
                "Restricted"
            case .temporarilyUnavailable, .couldNotDetermine, .checking, .available:
                "Unavailable"
            }
        case .preparing:
            "Preparing…"
        case .restoring:
            "Restoring…"
        case .syncing:
            "Syncing…"
        case .paused:
            "Waiting to Sync"
        case .readyToSync:
            "Ready to Sync"
        case .synced(let date):
            "Synced \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    var settingsColor: Color {
        switch displayState {
        case .synced:
            LoreTheme.ink
        case .accountUnavailable, .paused:
            LoreTheme.attention
        default:
            LoreTheme.secondaryInk
        }
    }

    var settingsDetail: String {
        switch displayState {
        case .accountUnavailable(.noAccount, _):
            "Sign in to iCloud to protect and restore your journal. Existing entries remain saved on this iPhone."
        case .accountUnavailable:
            "iCloud is currently unavailable. Lore keeps saving locally and will retry when iCloud is available."
        case .paused(let issue, _):
            switch issue {
            case .operationFailed(_, .quotaExceeded):
                "Your iCloud storage is full. Lore keeps saving locally, but new changes cannot sync until space is available."
            case .operationFailed(_, .notAuthenticated):
                "Sign in to iCloud to resume syncing. Existing entries remain saved on this iPhone."
            default:
                "Lore keeps saving locally and will retry automatically."
            }
        default:
            "Journal entries, transcripts, profile, and vocabulary sync through your private iCloud database. Recordings and pending processing stay on this iPhone."
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
        .loreCanvas()
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .loreInlineTitle("Vocabulary")
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
                .foregroundStyle(LoreTheme.ink)
                .loreField(minHeight: 58)
                .accessibilityIdentifier("vocabularyPhraseField")

            if isReplacementMode {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LoreTheme.secondaryInk)

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
                .foregroundStyle(LoreTheme.ink)
                .loreField(minHeight: 58)
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
                .buttonStyle(.lorePillSecondary)
                .accessibilityIdentifier("replacementModeButton")

                Button(action: saveEntry) {
                    Text(isReplacementMode ? "Save replacement" : "Add to vocabulary")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.lorePillAdaptive)
                .disabled(!canSave)
                .accessibilityIdentifier("saveVocabularyButton")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Text("No vocabulary")
                .font(LoreTheme.title())
                .foregroundStyle(LoreTheme.ink)

            Text("Add names, phrases, or a replacement to improve future transcripts.")
                .font(LoreTheme.caption(.body))
                .foregroundStyle(LoreTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 116)
        .accessibilityIdentifier("emptyVocabularyState")
    }

    private var vocabularyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoreSectionHeader("Your vocabulary")
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VocabularyEntryRow(entry: entry) {
                        delete(entry)
                    }

                    if index < entries.count - 1 {
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
                            .foregroundStyle(LoreTheme.secondaryInk)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LoreTheme.tertiaryInk)
                        Text(replacement)
                            .fontWeight(.semibold)
                            .foregroundStyle(LoreTheme.ink)
                    }
                    .font(LoreTheme.body)

                    Text("Replacement")
                        .font(LoreTheme.caption(.caption))
                        .foregroundStyle(LoreTheme.secondaryInk)
                } else {
                    Text(entry.phrase)
                        .font(LoreTheme.body)
                        .foregroundStyle(LoreTheme.ink)

                    Text("Preferred spelling")
                        .font(LoreTheme.caption(.caption))
                        .foregroundStyle(LoreTheme.secondaryInk)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
            SettingsRowLabel(title: title, systemImage: systemImage)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay {
                        Capsule().strokeBorder(LoreTheme.hairline)
                    }
            }

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .lineLimit(1)
            }
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.regular))
                .foregroundStyle(LoreTheme.secondaryInk)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(LoreTheme.ink)
        }
    }
}

private struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(LoreTheme.caption(.footnote))
            .foregroundStyle(LoreTheme.secondaryInk)
    }
}

private extension View {
    /// Serif inline title for pushed settings screens.
    func loreInlineTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(LoreTheme.title(.headline))
                    .foregroundStyle(LoreTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .loreNavigationBar()
    }
}

private struct JournalStyleSettingsView: View {
    @Bindable var userProfile: UserProfile
    @AppStorage("LoreJournalPerspective") private var journalPerspective = "thirdPerson"

    var body: some View {
        Form {
            Section {
                Picker("Perspective", selection: $journalPerspective) {
                    Text("Third person").tag("thirdPerson")
                    Text("First person").tag("firstPerson")
                }
                .accessibilityIdentifier("journalPerspectivePicker")
                .loreListRow()
            } header: {
                LoreSectionHeader("Daily entries")
            }

            Section {
                LabeledContent("Name", value: userProfile.name)
                    .loreListRow()
                TextField("Hometown", text: $userProfile.hometown)
                    .textContentType(.addressCity)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("journalHometownField")
                    .loreListRow()
            } header: {
                LoreSectionHeader("Subject")
            }
        }
        .loreGroupedList()
        .navigationTitle("Journal Style")
        .navigationBarTitleDisplayMode(.inline)
        .loreInlineTitle("Journal Style")
        .onChange(of: userProfile.hometown) { _, _ in
            userProfile.updatedAt = Date()
        }
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
                    .loreListRow()
                LabeledContent("Archive", value: "Private iCloud")
                    .loreListRow()
            } footer: {
                SettingsFooter("Lore is a private, voice-first journal that turns faithful transcripts into an evolving life story.")
            }

            Section {
                Text("Lore sends recordings to Groq for transcription and transcript text to Fireworks AI for journal writing. Lore does not keep this content in its server database; finished transcripts and stories sync through your private iCloud database.")
                    .font(LoreTheme.body)
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .lineSpacing(3)
                    .loreListRow()
            } header: {
                LoreSectionHeader("How processing works")
            }
        }
        .loreGroupedList()
        .navigationTitle("About Lore")
        .navigationBarTitleDisplayMode(.inline)
        .loreInlineTitle("About Lore")
    }
}

#Preview("Settings") {
    SettingsHomeView(userProfile: UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994))
    .modelContainer(LoreModelContainer.preview)
    .environmentObject(CloudArchiveStatusMonitor(startsImmediately: false))
}

#Preview("Vocabulary") {
    NavigationStack {
        VocabularyView()
    }
    .modelContainer(LoreModelContainer.preview)
}
