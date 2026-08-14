import SwiftUI

enum ReflectionSessionPhase: String, CaseIterable, Hashable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case review
    case completed
    case error

    var accessibilityValue: String {
        switch self {
        case .idle:
            "Ready"
        case .connecting:
            "Connecting"
        case .listening:
            "Listening"
        case .thinking:
            "Lore is preparing a response"
        case .speaking:
            "Lore is speaking"
        case .review:
            "Reviewing the reflection"
        case .completed:
            "Reflection saved"
        case .error:
            "The reflection needs attention"
        }
    }

    fileprivate var orbState: VoiceOrbState {
        switch self {
        case .listening:
            .listening
        case .connecting, .thinking:
            .processing
        case .speaking:
            .speaking
        case .idle, .review, .completed, .error:
            .idle
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
        viewBiography: {}
    )
}

struct ReflectHomeView<SessionContent: View>: View {
    private let sessionContent: () -> SessionContent

    init(@ViewBuilder sessionContent: @escaping () -> SessionContent) {
        self.sessionContent = sessionContent
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 28)

                        ReflectionOrb(phase: .idle, audioLevel: 0, size: heroSize(in: geometry.size))
                            .padding(.bottom, 28)

                        VStack(spacing: 12) {
                            Text("Take a moment")
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)

                            Text("Talk through your day. Lore will ask a few questions and save only what you tell it.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }

                        Spacer(minLength: 32)

                        NavigationLink {
                            sessionContent()
                        } label: {
                            Label("Start reflection", systemImage: "waveform.and.mic")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("reflectStartButton")

                        Label(
                            "Only your words can become biography evidence.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .accessibilityIdentifier("reflectPrivacySummary")

                        Text("Soniox transcribes your live voice and speaks Lore’s questions. Finalized text is sent to Lore’s secure processing service to guide the conversation and write the biography entry.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 430)
                            .padding(.top, 10)
                            .accessibilityIdentifier("reflectProviderDisclosure")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Reflect")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func heroSize(in availableSize: CGSize) -> CGFloat {
        min(max(availableSize.width * 0.50, 150), 220)
    }
}

struct ReflectionSessionView: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: ReflectionSessionPresentation
    let actions: ReflectionSessionActions

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader

                    if presentation.phase == .review {
                        reviewExplanation
                    }

                    conversation

                    if let provisionalTranscript = presentation.provisionalTranscript,
                       !provisionalTranscript.isEmpty,
                       presentation.phase == .listening {
                        provisionalCaption(provisionalTranscript)
                    }

                    controls
                        .padding(.top, 4)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .onChange(of: presentation.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Reflection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation.phase.showsEndButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("End", action: actions.requestEnd)
                        .accessibilityIdentifier("reflectionEndButton")
                }
            }
        }
        .accessibilityIdentifier("reflectionSessionScreen")
    }

    private var statusHeader: some View {
        VStack(spacing: 14) {
            ReflectionOrb(
                phase: presentation.phase,
                audioLevel: presentation.audioLevel,
                size: 150
            )

            VStack(spacing: 5) {
                Text(statusTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            if presentation.phase.isTimedSessionState {
                Text(presentation.elapsedTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reflection duration")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reflection status")
        .accessibilityValue(presentation.phase.accessibilityValue)
        .accessibilityIdentifier("reflectionStatus")
    }

    @ViewBuilder
    private var conversation: some View {
        if presentation.turns.isEmpty {
            if presentation.phase == .idle {
                Text("When you’re ready, Lore will begin with one simple question.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.vertical, 8)
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(presentation.turns) { turn in
                    ReflectionTurnBubble(turn: turn)
                }
            }
            .accessibilityIdentifier("reflectionTranscript")
        }
    }

    private var reviewExplanation: some View {
        Label {
            Text("Lore’s questions add context, but only your finalized replies are used as evidence for the biography entry.")
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("reflectionReviewExplanation")
    }

    private func provisionalCaption(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Listening", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcript")
        .accessibilityIdentifier("reflectionProvisionalTranscript")
    }

    @ViewBuilder
    private var controls: some View {
        switch presentation.phase {
        case .idle:
            primaryButton("Begin", systemImage: "sparkles", action: actions.begin)

        case .connecting:
            progressControl("Connecting securely…")

        case .speaking:
            primaryButton("Answer now", systemImage: "mic.fill", action: actions.interruptLore)

        case .listening:
            primaryButton("Done answering", systemImage: "checkmark", action: actions.finishAnswer)

        case .thinking:
            progressControl("Understanding…")

        case .review:
            VStack(spacing: 12) {
                primaryButton("Save reflection", systemImage: "checkmark.circle", action: actions.saveReflection)

                Button("Keep talking", action: actions.continueReflection)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("reflectionContinueButton")

                Button("Discard reflection", role: .destructive, action: actions.discardReflection)
                    .font(.footnote)
                    .accessibilityIdentifier("reflectionDiscardButton")
            }

        case .completed:
            VStack(spacing: 12) {
                primaryButton("View in Biography", systemImage: "book.closed", action: actions.viewBiography)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("reflectionDoneButton")
            }

        case .error:
            VStack(spacing: 12) {
                primaryButton("Try again", systemImage: "arrow.clockwise", action: actions.retry)

                if presentation.canSavePartialReflection {
                    Button("Save what we have", action: actions.savePartialReflection)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("reflectionSavePartialButton")
                }

                Button("Discard reflection", role: .destructive, action: actions.discardReflection)
                    .font(.footnote)
                    .accessibilityIdentifier("reflectionDiscardButton")
            }
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

    private func progressControl(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reflectionProgress")
    }

    private var statusTitle: String {
        switch presentation.phase {
        case .idle:
            "Ready when you are"
        case .connecting:
            "Getting things ready"
        case .listening:
            "I’m listening"
        case .thinking:
            "One moment"
        case .speaking:
            "Lore is speaking"
        case .review:
            "Review your reflection"
        case .completed:
            "Reflection saved"
        case .error:
            "We lost the thread"
        }
    }

    private var statusDetail: String {
        switch presentation.phase {
        case .idle:
            "You can end at any time."
        case .connecting:
            "This should only take a moment."
        case .listening:
            "Take your time. Tap Done answering when you’ve finished."
        case .thinking:
            "Lore is choosing one short follow-up."
        case .speaking:
            "Tap Answer now if you’re ready to respond."
        case .review:
            "Check the conversation before it becomes a biography entry."
        case .completed:
            "Lore is preparing a faithful third-person entry from your words."
        case .error:
            presentation.errorMessage ?? "Your completed answers are still safe on this iPhone."
        }
    }

    private static let bottomAnchor = "reflectionBottom"
}

private struct ReflectionOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let phase: ReflectionSessionPhase
    let audioLevel: Float
    let size: CGFloat

    var body: some View {
        ZStack {
            BreathingOrb(
                size: size,
                speed: breathingSpeed,
                tint: phase == .error ? .secondary : nil
            )
            .opacity(phase == .error ? 0.22 : 0.42)

            Circle()
                .fill(Color(.systemBackground).opacity(0.82))
                .frame(width: size * 0.62, height: size * 0.62)

            CloudWaveOrb(
                size: size * 0.58,
                state: phase.orbState,
                audioLevel: reduceMotion ? 0 : audioLevel
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var breathingSpeed: Double {
        switch phase {
        case .listening: 0.34
        case .speaking: 0.26
        case .connecting, .thinking: 0.14
        case .idle, .review, .completed, .error: 0.07
        }
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
        case .lore:
            Color(.secondarySystemBackground)
        case .user:
            Color.accentColor.opacity(0.13)
        }
    }
}

private extension ReflectionSessionPhase {
    var showsEndButton: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking:
            true
        case .idle, .review, .completed, .error:
            false
        }
    }

    var isTimedSessionState: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking, .review:
            true
        case .idle, .completed, .error:
            false
        }
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
    ReflectHomeView {
        ReflectionSessionView(
            presentation: ReflectionSessionPresentation(phase: .idle),
            actions: .disabled
        )
    }
}

#Preview("Listening") {
    NavigationStack {
        ReflectionSessionView(
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
}

#Preview("Review") {
    NavigationStack {
        ReflectionSessionView(
            presentation: ReflectionSessionPresentation(
                phase: .review,
                turns: reflectionPreviewTurns,
                elapsedTime: "5:42"
            ),
            actions: .disabled
        )
    }
}

#Preview("Recoverable error") {
    NavigationStack {
        ReflectionSessionView(
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
}
