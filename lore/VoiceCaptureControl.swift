import SwiftUI

struct VoiceCaptureButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let containerWidth: CGFloat
    let isAvailable: Bool
    let isRecording: Bool
    let isProcessing: Bool
    let action: () -> Void

    private var accessibilityTitle: String {
        if isProcessing { return "Finishing recording" }
        return isRecording ? "Stop recording" : "Start recording"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    BreathingOrb(
                        size: controlDiameter * Self.activeOrbDiameterRatio,
                        speed: 0.75,
                        tint: LoreTheme.ink
                    )
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                } else {
                    restingButton
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
            .frame(width: controlDiameter, height: controlDiameter)
        }
        .buttonStyle(VoiceCaptureButtonStyle())
        // Keep the control tappable while prior processing finishes so the
        // action can explain why capture is temporarily unavailable instead
        // of appearing completely inert.
        .disabled(!isAvailable)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(isRecording ? "Ends and saves this voice note" : "Begins a new voice note")
        .accessibilityValue(isRecording ? "Recording" : isProcessing ? "Processing" : "Not recording")
        .accessibilityIdentifier("recordVoiceNoteButton")
        .sensoryFeedback(.impact(weight: .light), trigger: isRecording)
        .animation(.easeInOut(duration: 0.24), value: isRecording)
        .animation(.easeInOut(duration: 0.24), value: isProcessing)
    }

    private var restingButton: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 24.0,
                paused: reduceMotion || !isAvailable
            )
        ) { context in
            let elapsed = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let pulse = CGFloat((sin(elapsed * 0.7) + 1) / 2)
            let drift = elapsed * 0.22
            let distortion = 2.4 * controlScale

            ZStack {
                OrganicCaptureBlob(
                    distortion: distortion + 1.4 * controlScale,
                    phase: drift - 0.45
                )
                    .stroke(buttonTint.opacity(0.16), lineWidth: controlStrokeWidth)
                    .frame(
                        width: controlDiameter * Self.outlineDiameterRatio,
                        height: controlDiameter * Self.outlineDiameterRatio
                    )
                    .scaleEffect(1 + pulse * 0.035)
                    .opacity(reduceMotion ? 0.55 : 0.35 + Double(pulse) * 0.35)

                OrganicCaptureBlob(distortion: distortion, phase: drift)
                    .fill(buttonFill)
                    .overlay {
                        OrganicCaptureBlob(distortion: distortion, phase: drift)
                            .stroke(buttonTint.opacity(0.22), lineWidth: controlStrokeWidth)
                    }
                    .frame(
                        width: controlDiameter * Self.blobDiameterRatio,
                        height: controlDiameter * Self.blobDiameterRatio
                    )
                    .shadow(
                        color: buttonTint.opacity(0.06),
                        radius: 6 * controlScale,
                        y: 2 * controlScale
                    )
            }
        }
    }

    private var controlDiameter: CGFloat {
        min(max(containerWidth * 0.183, 60), 80)
    }

    private var controlScale: CGFloat {
        controlDiameter / 72
    }

    private var controlStrokeWidth: CGFloat {
        max(0.85, controlScale)
    }

    private var buttonTint: Color {
        guard isAvailable else { return LoreTheme.tertiaryInk }
        if isProcessing { return LoreTheme.secondaryInk }
        return LoreTheme.ink
    }

    // At rest the capture blob is the screen's one solid white mark; it dims
    // to grey surfaces while processing or unavailable.
    private var buttonFill: Color {
        guard isAvailable else { return LoreTheme.surface }
        if isProcessing { return LoreTheme.raisedSurface }
        return LoreTheme.ink.opacity(0.94)
    }

    private static let activeOrbDiameterRatio: CGFloat = 64.0 / 72.0
    private static let outlineDiameterRatio: CGFloat = 62.0 / 72.0
    private static let blobDiameterRatio: CGFloat = 50.0 / 72.0
}

private struct OrganicCaptureBlob: Shape {
    let distortion: CGFloat
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - distortion - 1
        let samples = 24
        let points = (0..<samples).map { sample in
            let angle = Double(sample) / Double(samples) * .pi * 2
            let firstWave = sin(angle * 3 + phase)
            let secondWave = sin(angle * 5 - phase * 0.74)
            let thirdWave = cos(angle * 2 + phase * 0.38)
            let displacement = CGFloat(firstWave * 0.48 + secondWave * 0.30 + thirdWave * 0.22) * distortion
            let pointRadius = radius + displacement

            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * pointRadius,
                y: center.y + CGFloat(sin(angle)) * pointRadius
            )
        }

        guard let first = points.first, let last = points.last else { return Path() }

        var path = Path()
        path.move(to: midpoint(last, first))

        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(point, next), control: point)
        }

        path.closeSubpath()
        return path
    }

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

private struct VoiceCaptureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Idle capture") {
    ZStack {
        LoreTheme.canvas.ignoresSafeArea()
        VoiceCaptureButton(
            containerWidth: 320,
            isAvailable: true,
            isRecording: false,
            isProcessing: false,
            action: {}
        )
    }
}

#Preview("Recording") {
    ZStack {
        LoreTheme.canvas.ignoresSafeArea()
        VoiceCaptureButton(
            containerWidth: 430,
            isAvailable: true,
            isRecording: true,
            isProcessing: false,
            action: {}
        )
    }
}
