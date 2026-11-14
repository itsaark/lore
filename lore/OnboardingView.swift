import SwiftUI

struct OnboardingView: View {
    let onComplete: (UserProfile) -> Void

    private enum Step: Int, CaseIterable {
        case welcome
        case name
        case hometown
        case birthYear
        case languages
    }

    @State private var name = ""
    @State private var hometown = ""
    @State private var birthYear = ""
    @State private var spokenLanguageCodes = SpokenLanguageCatalog.defaultSelection()
    @State private var isShowingProcessingPermission = false
    @State private var step: Step = .welcome
    @FocusState private var isFieldFocused: Bool

    init(onComplete: @escaping (UserProfile) -> Void) {
        self.onComplete = onComplete
    }

#if DEBUG
    /// Opens on the language question, for previews and screenshots.
    init(previewingLanguagesWith codes: [String]? = nil, onComplete: @escaping (UserProfile) -> Void = { _ in }) {
        self.onComplete = onComplete
        _name = State(initialValue: "Aark")
        _hometown = State(initialValue: "Hyderabad")
        _birthYear = State(initialValue: "1994")
        _step = State(initialValue: .languages)
        if let codes {
            _spokenLanguageCodes = State(initialValue: codes)
        }
    }
#endif

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                ScrollView {
                    stepContent
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .padding(.horizontal, 28)
                        .padding(.top, step == .languages ? 28 : 72)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)

                VStack(spacing: 22) {
                    if step == .languages {
                        SpokenLanguageRoutingNote(codes: spokenLanguageCodes)
                            .frame(maxWidth: 340)
                            .transition(.opacity)
                    }

                    OnboardingPageDots(count: Step.allCases.count, current: step.rawValue)

                    primaryButton
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .loreCanvas()
            .animation(.smooth(duration: 0.32), value: step)
            .navigationBarHidden(true)
        }
    }

    private var topBar: some View {
        HStack {
            if step != .welcome {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LoreTheme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .transition(.opacity)
            }

            Spacer()
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            OnboardingHeadline(
                title: "Begin your\nlife story",
                detail: "Speak about your days. Lore keeps them, faithfully, in a private journal that grows with you."
            )

        case .name:
            VStack(spacing: 40) {
                OnboardingHeadline(
                    title: "What should\nLore call you?",
                    detail: "Your stories will be written about you."
                )

                ProfileField(
                    title: "Name",
                    placeholder: "Aark",
                    text: $name,
                    keyboardType: .default,
                    textContentType: .name,
                    isFocused: $isFieldFocused,
                    onSubmit: advanceIfPossible
                )
            }

        case .hometown:
            VStack(spacing: 40) {
                OnboardingHeadline(
                    title: "Where are\nyou from?",
                    detail: "Lore uses this to place your stories in context."
                )

                ProfileField(
                    title: "Hometown",
                    placeholder: "Hyderabad",
                    text: $hometown,
                    keyboardType: .default,
                    textContentType: .addressCity,
                    isFocused: $isFieldFocused,
                    onSubmit: advanceIfPossible
                )
            }

        case .birthYear:
            VStack(spacing: 40) {
                OnboardingHeadline(
                    title: "When did your\nstory begin?",
                    detail: "Your birth year helps Lore understand the chapters of your life."
                )

                VStack(spacing: 14) {
                    ProfileField(
                        title: "Birth year",
                        placeholder: "1994",
                        text: $birthYear,
                        keyboardType: .numberPad,
                        textContentType: nil,
                        isFocused: $isFieldFocused,
                        onSubmit: advanceIfPossible
                    )

                    if let validationMessage {
                        Text(validationMessage)
                            .font(LoreTheme.caption(.footnote))
                            .foregroundStyle(LoreTheme.attention)
                            .multilineTextAlignment(.center)
                    }
                }
            }

        case .languages:
            VStack(spacing: 32) {
                OnboardingHeadline(
                    title: "Which languages\nwill you speak?",
                    detail: "Choose every language you’ll use with Lore. You can change this later in Settings."
                )

                SpokenLanguagePicker(selection: $spokenLanguageCodes)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if step == .languages {
            Button {
                isFieldFocused = false
                isShowingProcessingPermission = true
            } label: {
                OnboardingButtonLabel(title: "Continue")
            }
            .disabled(!canComplete)
            .buttonStyle(.lorePillAdaptive)
            .accessibilityHint("Reviews processing permission and completes setup")
            .alert("Allow AI processing?", isPresented: $isShowingProcessingPermission) {
                Button("Not Now", role: .cancel) {}
                Button("Allow and Continue", action: completeOnboarding)
            } message: {
                Text(RemoteProcessingPermissionView.processingSummary)
            }
        } else {
            Button(action: advanceIfPossible) {
                OnboardingButtonLabel(title: step == .welcome ? "Begin" : "Next")
            }
            .disabled(!canAdvance)
            .buttonStyle(.lorePillAdaptive)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome: true
        case .name: !trimmedName.isEmpty
        case .hometown: !trimmedHometown.isEmpty
        case .birthYear: isBirthYearValid
        case .languages: canComplete
        }
    }

    private func advanceIfPossible() {
        guard canAdvance else { return }

        if let next = Step(rawValue: step.rawValue + 1) {
            if next == .languages {
                isFieldFocused = false
            }
            step = next
        } else {
            isFieldFocused = false
            isShowingProcessingPermission = true
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
        if previous == .welcome {
            isFieldFocused = false
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHometown: String {
        hometown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedBirthYear: Int? {
        Int(birthYear.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var isBirthYearValid: Bool {
        guard let parsedBirthYear else {
            return false
        }

        return (1900...currentYear).contains(parsedBirthYear)
    }

    private var canComplete: Bool {
        !trimmedName.isEmpty
            && !trimmedHometown.isEmpty
            && isBirthYearValid
            && !spokenLanguageCodes.isEmpty
    }

    private var validationMessage: String? {
        guard !birthYear.isEmpty, !isBirthYearValid else {
            return nil
        }

        return "Enter a birth year between 1900 and \(currentYear)."
    }

    private func completeOnboarding() {
        guard canComplete, let parsedBirthYear else {
            return
        }

        let profile = UserProfile(
            name: trimmedName,
            hometown: trimmedHometown,
            birthYear: parsedBirthYear,
            remoteProcessingConsentedAt: Date()
        )
        profile.setSpokenLanguages(spokenLanguageCodes)
        onComplete(profile)
    }

}

struct RemoteProcessingPermissionView: View {
    let onAllow: () -> Void

    /// What leaves the iPhone, said plainly. Shared with the onboarding alert
    /// so the two never drift apart.
    static let processingSummary = "English notes are transcribed on your iPhone once its speech model has downloaded. Other languages, any English note the iPhone can’t transcribe, and the transcripts Lore writes your journal from are processed by Lore’s server and deleted right after. Reflect conversations stream live to Soniox for speech. Your journal syncs through your private iCloud."

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Image(systemName: "lock")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .accessibilityHidden(true)

                OnboardingHeadline(
                    title: "Turn voice\ninto story",
                    detail: Self.processingSummary
                )
            }

            Spacer()

            Button(action: onAllow) {
                OnboardingButtonLabel(title: "Continue and allow processing")
            }
            .buttonStyle(.lorePill)
            .accessibilityIdentifier("allowRemoteProcessingButton")
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loreCanvas()
    }
}

private struct OnboardingHeadline: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(LoreTheme.display(38))
                .foregroundStyle(LoreTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(detail)
                .font(LoreTheme.caption(.body))
                .foregroundStyle(LoreTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
    }
}

private struct OnboardingPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? LoreTheme.ink : LoreTheme.tertiaryInk)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct ProfileField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(LoreTheme.tertiaryInk)
            )
            .font(LoreTheme.title(.title))
            .foregroundStyle(LoreTheme.ink)
            .multilineTextAlignment(.center)
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .textInputAutocapitalization(.words)
            .disableAutocorrection(true)
            .submitLabel(.next)
            .focused(isFocused)
            .onSubmit(onSubmit)
            .task {
                // Focus once the step has finished inserting so the keyboard
                // follows the field rather than racing the transition.
                isFocused.wrappedValue = true
            }
            .padding(.vertical, 10)
            .accessibilityLabel(title)

            LoreHairline()
        }
    }
}

#Preview {
    OnboardingView { _ in }
}

#Preview("Languages") {
    OnboardingView(previewingLanguagesWith: ["en", "hi"])
}
