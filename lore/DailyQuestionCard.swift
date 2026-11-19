import SwiftUI

struct DailyQuestionCard: View {
    let question: DailyQuestion
    let isRecordAvailable: Bool
    let record: () -> Void
    let dismiss: () -> Void
    let finishDismissal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState(for: .voiceOver) private var isFocused: Bool
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.38, bounce: 0.16)))
    private var drag: CGSize = .zero
    @State private var exitOffset = CGSize.zero
    @State private var isLeaving = false

    private var offset: CGSize { isLeaving ? exitOffset : drag }
    private var rotation: Double { min(max(Double(offset.width) * 0.045, -14), 14) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(isLeaving ? 0 : 0.64)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)

                card(in: geometry.size)
                    .rotationEffect(.degrees(reduceMotion ? 0 : rotation))
                    .offset(reduceMotion ? .zero : offset)
                    .opacity(isLeaving ? 0 : 1)
                    .allowsHitTesting(!isLeaving)
                    .simultaneousGesture(swipe(in: geometry.size))
                    // UI automation can address the physical button. VoiceOver
                    // gets the question and its two actions on a single stop.
                    .accessibilityElement(children: voiceOverEnabled ? .ignore : .contain)
                    .accessibilityLabel(question.text)
                    .accessibilityIdentifier("dailyQuestionCard")
                    .accessibilityAction(named: Text("Record answer"), attemptRecord)
                    .accessibilityAction(named: Text("Dismiss")) {
                        flyOut(direction: .zero, in: geometry.size)
                    }
                    .accessibilityFocused($isFocused)
            }
            .onAppear { isFocused = voiceOverEnabled }
        }
    }

    private func card(in size: CGSize) -> some View {
        let compact = size.height < 320
        let shape = RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius)
        return VStack(spacing: compact ? 12 : 28) {
            Text(question.text)
                .font(LoreTheme.title(.largeTitle))
                .foregroundStyle(LoreTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(7)
                .minimumScaleFactor(0.45)

            VoiceCaptureButton(
                containerWidth: size.width,
                isAvailable: isRecordAvailable,
                isRecording: false,
                isProcessing: false,
                accessibilityID: "dailyQuestionRecordButton",
                action: attemptRecord
            )
        }
        .padding(.horizontal, 26)
        .padding(.vertical, compact ? 14 : 30)
        .frame(maxWidth: 380, minHeight: compact ? 0 : 224)
        .background(LoreTheme.surface, in: shape)
        .overlay(shape.strokeBorder(LoreTheme.hairline))
        .contentShape(shape)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func attemptRecord() {
        guard !isLeaving, isRecordAvailable else { return }
        record()
    }

    private func swipe(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($drag) { value, offset, _ in
                if !reduceMotion && !isLeaving {
                    offset = value.translation
                }
            }
            .onEnded { value in
                let translation = value.translation
                let velocity = value.velocity
                if hypot(translation.width, translation.height) >= 90 {
                    flyOut(direction: translation, in: size)
                } else if hypot(velocity.width, velocity.height) >= 650 {
                    flyOut(direction: velocity, in: size)
                }
            }
    }

    private func flyOut(direction: CGSize, in size: CGSize) {
        guard !isLeaving else { return }

        let length = hypot(direction.width, direction.height)
        let distance = hypot(size.width, size.height) * 1.5
        let target = length == 0 ? .zero : CGSize(
            width: direction.width / length * distance,
            height: direction.height / length * distance
        )
        dismiss()
        withAnimation(.easeOut(duration: reduceMotion || length == 0 ? 0.18 : 0.26)) {
            isLeaving = true
            exitOffset = target
        } completion: {
            finishDismissal()
        }
    }
}
