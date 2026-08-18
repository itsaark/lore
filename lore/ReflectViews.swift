import SwiftUI

enum ReflectionSessionPhase: String, CaseIterable, Hashable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case ending
    case review
    case completed
    case error

    var accessibilityValue: String {
        switch self {
        case .idle: "Ready"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .thinking: "Lore is preparing a response"
        case .speaking: "Lore is speaking"
        case .ending: "Finishing the reflection"
        case .review: "Reviewing the reflection"
        case .completed: "Reflection saved"
        case .error: "The reflection needs attention"
        }
    }
}

struct ReflectionTurnPresentation: Identifiable, Hashable {
    enum Speaker: Hashable {
        case lore
        case user

        var name: String {
            switch self {
            case .lore: "Lore"
            case .user: "You"
            }
        }
    }

    let id: UUID
    let speaker: Speaker
    let text: String

    init(id: UUID = UUID(), speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

struct ReflectionSessionPresentation: Equatable {
    var phase: ReflectionSessionPhase
    var turns: [ReflectionTurnPresentation]
    var provisionalTranscript: String?
    var elapsedTime: String
    var audioLevel: Float
    var errorMessage: String?
    var canSavePartialReflection: Bool

    init(
        phase: ReflectionSessionPhase,
        turns: [ReflectionTurnPresentation] = [],
        provisionalTranscript: String? = nil,
        elapsedTime: String = "0:00",
        audioLevel: Float = 0,
        errorMessage: String? = nil,
        canSavePartialReflection: Bool = false
    ) {
        self.phase = phase
        self.turns = turns
        self.provisionalTranscript = provisionalTranscript
        self.elapsedTime = elapsedTime
        self.audioLevel = audioLevel
        self.errorMessage = errorMessage
        self.canSavePartialReflection = canSavePartialReflection
    }
}

struct ReflectionSessionActions {
    var begin: () -> Void
    var interruptLore: () -> Void
    var finishAnswer: () -> Void
    var requestEnd: () -> Void
    var continueReflection: () -> Void
    var saveReflection: () -> Void
    var retry: () -> Void
    var savePartialReflection: () -> Void
    var discardReflection: () -> Void
    var close: () -> Void
    var viewBiography: () -> Void

    static let disabled = Self(
        begin: {},
        interruptLore: {},
        finishAnswer: {},
        requestEnd: {},
        continueReflection: {},
        saveReflection: {},
        retry: {},
        savePartialReflection: {},
        discardReflection: {},
        close: {},
        viewBiography: {}
    )
}

/// The entire Reflect tab has one state owner and one navigation surface. The
/// first tap starts the session; there is intentionally no pushed "ready" page.
struct ReflectRootView: View {
    let presentation: ReflectionSessionPresentation
    let actions: ReflectionSessionActions

    var body: some View {
        NavigationStack {
            Group {
                if presentation.phase == .idle {
                    ReflectHomeView(start: actions.begin)
                        .transition(.opacity)
                } else {
                    ReflectionSessionView(
                        presentation: presentation,
                        actions: actions
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.24), value: presentation.phase == .idle)
        }
        .toolbar(presentation.phase == .idle ? .visible : .hidden, for: .tabBar)
    }
}

struct ReflectHomeView: View {
    let start: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                reflectionCanvasBackground
                    .ignoresSafeArea()

                ReflectionWaveField(phase: .idle, audioLevel: 0)
                    .frame(height: geometry.size.height * 0.54)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 0) {
                    Spacer(minLength: 36)

                    VStack(spacing: 12) {
                        Text("Take a moment")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)

                        Text("Talk through your day with Lore.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    VStack(spacing: 14) {
                        Button(action: start) {
                            Label("Start reflection", systemImage: "waveform.and.mic")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .accessibilityHint("Starts the conversation immediately")
                        .accessibilityIdentifier("reflectStartButton")

                        Label(
                            "Only your finalized words become biography evidence.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("reflectPrivacySummary")

                        Text("Live speech is processed by Soniox.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                            .accessibilityIdentifier("reflectProviderDisclosure")
                    }
                    .padding(.bottom, max(22, geometry.safeAreaInsets.bottom + 12))
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Reflect")
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(reflectionCanvasBackground)
    }
}

struct ReflectionSessionView: View {
    let presentation: ReflectionSessionPresentation
    let actions: ReflectionSessionActions

    @State private var showsCaptions = true

    var body: some View {
        Group {
            switch presentation.phase {
            case .review:
                reviewScreen
            case .completed:
                completionScreen
            case .idle:
                EmptyView()
            case .connecting, .listening, .thinking, .speaking, .ending, .error:
                liveCallScreen
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var liveCallScreen: some View {
        GeometryReader { geometry in
            ZStack {
                reflectionCanvasBackground
                    .ignoresSafeArea()

                ReflectionWaveField(
                    phase: presentation.phase,
                    audioLevel: presentation.audioLevel
                )
                .frame(height: geometry.size.height * 0.60)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 0) {
                    callHeader

                    Spacer(minLength: 28)

                    VStack(spacing: 16) {
                        Text(statusTitle)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .contentTransition(.numericText())

                        if presentation.phase == .error {
                            VStack(spacing: 14) {
                                Text(presentation.errorMessage ?? "Your completed answers are still safe on this iPhone.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 340)

                                if presentation.canSavePartialReflection {
                                    Button("Save completed answers", action: actions.savePartialReflection)
                                        .font(.subheadline.weight(.semibold))
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                        .accessibilityIdentifier("reflectionSavePartialButton")
                                }
                            }
                        } else if showsCaptions, let captionText {
                            Text(captionText)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: 340, minHeight: 66, alignment: .top)
                                .transition(.opacity)
                                .accessibilityIdentifier("reflectionLiveCaption")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Reflection status")
                    .accessibilityValue(presentation.phase.accessibilityValue)
                    .accessibilityIdentifier("reflectionStatus")

                    Spacer()

                    liveControls
                        .padding(.bottom, max(24, geometry.safeAreaInsets.bottom + 12))
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
            }
        }
    }

    private var callHeader: some View {
        HStack {
            Text("Reflection")
                .font(.headline)

            Spacer()

            Text(presentation.elapsedTime)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Reflection duration")
        }
    }

    private var liveControls: some View {
        HStack(alignment: .top, spacing: 24) {
            CallControlButton(
                title: "Captions",
                systemImage: showsCaptions ? "captions.bubble.fill" : "captions.bubble",
                tint: .primary,
                background: Color(.systemBackground).opacity(0.88),
                action: { showsCaptions.toggle() }
            )
            .accessibilityValue(showsCaptions ? "On" : "Off")
            .accessibilityIdentifier("reflectionCaptionsButton")

            contextualCallControl

            if presentation.phase == .error {
                CallControlButton(
                    title: "Close",
                    systemImage: "xmark",
                    tint: .white,
                    background: .red,
                    action: actions.discardReflection
                )
                .accessibilityIdentifier("reflectionDiscardButton")
            } else {
                CallControlButton(
                    title: "End",
                    systemImage: "phone.down.fill",
                    tint: .white,
                    background: .red,
                    action: actions.requestEnd
                )
                .accessibilityIdentifier("reflectionEndButton")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var contextualCallControl: some View {
        switch presentation.phase {
        case .speaking:
            CallControlButton(
                title: "Answer",
                systemImage: "mic.fill",
                tint: .primary,
                background: Color(.systemBackground).opacity(0.88),
                action: actions.interruptLore
            )
            .accessibilityIdentifier("reflectionAnswerButton")

        case .listening:
            CallControlButton(
                title: "Done",
                systemImage: "checkmark",
                tint: .primary,
                background: Color(.systemBackground).opacity(0.88),
                action: actions.finishAnswer
            )
            .accessibilityIdentifier("reflectionFinishAnswerButton")

        case .error:
            CallControlButton(
                title: "Retry",
                systemImage: "arrow.clockwise",
                tint: .primary,
                background: Color(.systemBackground).opacity(0.88),
                action: actions.retry
            )
            .accessibilityIdentifier("reflectionRetryButton")

        case .connecting, .thinking, .ending:
            CallProgressControl(title: progressTitle)

        case .idle, .review, .completed:
            EmptyView()
        }
    }

    private var reviewScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.green)

                    Text("Review your reflection")
                        .font(.title2.bold())

                    Text("Only your replies are used to write the biography entry.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                LazyVStack(spacing: 12) {
                    ForEach(presentation.turns) { turn in
                        ReflectionTurnBubble(turn: turn)
                    }
                }
                .accessibilityIdentifier("reflectionTranscript")

                VStack(spacing: 12) {
                    primaryButton(
                        "Save to Biography",
                        systemImage: "checkmark.circle",
                        action: actions.saveReflection
                    )

                    Button("Keep talking", action: actions.continueReflection)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("reflectionContinueButton")

                    Button("Discard reflection", role: .destructive, action: actions.discardReflection)
                        .font(.footnote)
                        .accessibilityIdentifier("reflectionDiscardButton")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Reflection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("reflectionReviewScreen")
    }

    private var completionScreen: some View {
        GeometryReader { geometry in
            ZStack {
                reflectionCanvasBackground.ignoresSafeArea()

                ReflectionWaveField(phase: .completed, audioLevel: 0)
                    .frame(height: geometry.size.height * 0.52)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 18) {
                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.green)

                    Text("Added to Biography")
                        .font(.title.bold())

                    Text("Lore created a faithful third-person entry from your words.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)

                    Spacer()

                    VStack(spacing: 12) {
                        primaryButton(
                            "View in Biography",
                            systemImage: "book.closed",
                            action: actions.viewBiography
                        )

                        Button("Done", action: actions.close)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("reflectionDoneButton")
                    }
                    .padding(.bottom, max(24, geometry.safeAreaInsets.bottom + 12))
                }
                .padding(.horizontal, 24)
            }
        }
        .accessibilityIdentifier("reflectionCompletedScreen")
    }

    private var captionText: String? {
        if let provisional = presentation.provisionalTranscript,
           !provisional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return provisional
        }
        return presentation.turns.last?.text
    }

    private var statusTitle: String {
        switch presentation.phase {
        case .idle: ""
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Lore is speaking…"
        case .ending: "Finishing…"
        case .review: "Review your reflection"
        case .completed: "Added to Biography"
        case .error: "We lost the thread"
        }
    }

    private var progressTitle: String {
        switch presentation.phase {
        case .connecting: "Connecting"
        case .thinking: "Thinking"
        case .ending: "Finishing"
        default: "Working"
        }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("reflectionPrimaryButton")
    }
}

private struct CallControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .foregroundStyle(tint)
                    .background(background, in: Circle())

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct CallProgressControl: View {
    let title: String

    var body: some View {
        VStack(spacing: 7) {
            ProgressView()
                .tint(.primary)
                .frame(width: 58, height: 58)
                .background(Color(.systemBackground).opacity(0.88), in: Circle())

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .frame(width: 76)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reflectionProgress")
    }
}

private struct ReflectionTurnBubble: View {
    let turn: ReflectionTurnPresentation

    var body: some View {
        HStack {
            if turn.speaker == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(turn.speaker.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))

            if turn.speaker == .lore {
                Spacer(minLength: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.speaker.name) said: \(turn.text)")
        .accessibilityIdentifier("reflectionTurn_\(turn.id.uuidString)")
    }

    private var bubbleColor: Color {
        switch turn.speaker {
        case .lore: Color(.secondarySystemBackground)
        case .user: Color.accentColor.opacity(0.13)
        }
    }
}

private var reflectionCanvasBackground: Color {
    Color(light: Color(red: 0.97, green: 0.95, blue: 0.91), dark: .black)
}

private extension Color {
    init(light: Color, dark: Color) {
#if canImport(UIKit)
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
#else
        self = light
#endif
    }
}

private let reflectionPreviewTurns = [
    ReflectionTurnPresentation(
        speaker: .lore,
        text: "What felt worth remembering about today?"
    ),
    ReflectionTurnPresentation(
        speaker: .user,
        text: "I finally took the long walk by the river with Maya, and we talked about moving closer to family."
    ),
    ReflectionTurnPresentation(
        speaker: .lore,
        text: "What about that conversation stayed with you?"
    )
]

#Preview("Reflect home") {
    ReflectRootView(
        presentation: ReflectionSessionPresentation(phase: .idle),
        actions: .disabled
    )
}

#Preview("Listening") {
    ReflectRootView(
        presentation: ReflectionSessionPresentation(
            phase: .listening,
            turns: reflectionPreviewTurns,
            provisionalTranscript: "It made the idea feel possible…",
            elapsedTime: "3:18",
            audioLevel: 0.28
        ),
        actions: .disabled
    )
}

#Preview("Review") {
    ReflectRootView(
        presentation: ReflectionSessionPresentation(
            phase: .review,
            turns: reflectionPreviewTurns,
            elapsedTime: "5:42"
        ),
        actions: .disabled
    )
}

#Preview("Recoverable error") {
    ReflectRootView(
        presentation: ReflectionSessionPresentation(
            phase: .error,
            turns: reflectionPreviewTurns,
            elapsedTime: "4:03",
            errorMessage: "The connection paused before your last answer finished.",
            canSavePartialReflection: true
        ),
        actions: .disabled
    )
}
