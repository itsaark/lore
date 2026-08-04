import SwiftUI

struct VoiceCaptureVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isAvailable: Bool
    let isRecording: Bool
    let isProcessing: Bool
    let audioLevel: Float
    let responseLevel: Float

    private var visualState: VoiceOrbState {
        if isProcessing { return .processing }
        return isRecording ? .listening : .idle
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion || !isAvailable
            )
        ) { context in
            let elapsed = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            captureSurface(elapsed: elapsed)
        }
        .frame(width: 304, height: 304)
        .accessibilityHidden(true)
    }

    private func captureSurface(elapsed: TimeInterval) -> some View {
        let normalizedLevel = CGFloat(min(max(responseLevel, 0), 1))
        let response = isRecording && !reduceMotion ? normalizedLevel : 0
        let restingSpeed = isRecording ? 1.15 : isProcessing ? 0.8 : 0.34
        let waveSpeed = restingSpeed + Double(response) * 1.9
        let restingBreath = reduceMotion ? 0 : sin(elapsed * restingSpeed) * (isRecording ? 0.004 : 0.002)

        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                let ring = CGFloat(index)
                CaptureWaveRing(
                    amplitude: (isRecording ? 4.5 : 2.2) + response * 13 + ring,
                    lobes: 6 + index * 2,
                    phase: elapsed * waveSpeed * (index.isMultiple(of: 2) ? 1 : -0.72)
                )
                .stroke(
                    ringColor(index: index),
                    style: StrokeStyle(
                        lineWidth: index == 0 ? 1.5 : 1,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(
                    width: 202 + ring * 34,
                    height: 202 + ring * 34
                )
                .scaleEffect(
                    x: 1 + restingBreath + response * (0.018 + ring * 0.004),
                    y: 1 + restingBreath + response * (0.052 + ring * 0.008)
                )
                .opacity(ringOpacity(index: index, elapsed: elapsed))
            }

            Circle()
                .fill(Color(.systemBackground).opacity(0.78))
                .frame(width: 184, height: 184)

            CloudWaveOrb(
                size: 176,
                state: visualState,
                audioLevel: isRecording ? audioLevel : 0
            )
            // Scale the completed orb as a single layer. Its internal Metal wave
            // animation remains exactly as authored in CloudWaveOrb.
            .scaleEffect(
                x: 1 + response * 0.018,
                y: 1 + response * 0.058
            )
        }
        .animation(.easeInOut(duration: 0.24), value: isRecording)
        .animation(.easeInOut(duration: 0.24), value: isProcessing)
    }

    private func ringColor(index: Int) -> Color {
        if !isAvailable {
            return Color.secondary.opacity(0.22)
        }

        if isRecording {
            return [
                Color(red: 0.31, green: 0.69, blue: 0.48),
                Color(red: 0.42, green: 0.62, blue: 0.50),
                Color(red: 0.56, green: 0.70, blue: 0.60)
            ][index]
        }

        return Color.primary.opacity(0.55 - Double(index) * 0.08)
    }

    private func ringOpacity(index: Int, elapsed: TimeInterval) -> Double {
        guard isAvailable else { return 0.45 }
        guard !reduceMotion else { return isRecording ? 0.66 - Double(index) * 0.12 : 0.34 }

        let offset = Double(index) * 1.4
        let wave = (sin(elapsed * (isRecording ? 1.75 : 0.42) - offset) + 1) / 2
        let base = isRecording ? 0.38 : 0.28
        return base + wave * (isRecording ? 0.35 : 0.18) - Double(index) * 0.035
    }
}

struct VoiceCaptureButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    BreathingOrb(size: 64, speed: 0.75)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                } else {
                    restingButton
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(VoiceCaptureButtonStyle())
        .disabled(!isAvailable || isProcessing)
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
            let distortion: CGFloat = 2.4

            ZStack {
                OrganicCaptureBlob(distortion: distortion + 1.4, phase: drift - 0.45)
                    .stroke(buttonTint.opacity(0.16), lineWidth: 1)
                    .frame(width: 62, height: 62)
                    .scaleEffect(1 + pulse * 0.035)
                    .opacity(reduceMotion ? 0.55 : 0.35 + Double(pulse) * 0.35)

                OrganicCaptureBlob(distortion: distortion, phase: drift)
                    .fill(buttonFill)
                    .overlay {
                        OrganicCaptureBlob(distortion: distortion, phase: drift)
                            .stroke(buttonTint.opacity(0.22), lineWidth: 1)
                    }
                    .frame(width: 50, height: 50)
                    .shadow(color: buttonTint.opacity(0.06), radius: 6, y: 2)
            }
        }
    }

    private var buttonTint: Color {
        guard isAvailable else { return .secondary }
        if isProcessing { return .secondary }
        return .primary
    }

    private var buttonFill: Color {
        guard isAvailable else { return Color(.tertiarySystemBackground) }
        if isProcessing { return Color(.tertiarySystemBackground) }
        return Color(.secondarySystemBackground)
    }
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

private struct CaptureWaveRing: Shape {
    let amplitude: CGFloat
    let lobes: Int
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - amplitude - 2
        let samples = 128
        var path = Path()

        for sample in 0...samples {
            let progress = Double(sample) / Double(samples)
            let angle = progress * .pi * 2
            let primaryWave = sin(angle * Double(lobes) + phase)
            let secondaryWave = sin(angle * Double(max(3, lobes - 3)) - phase * 0.63)
            let displacement = CGFloat(primaryWave * 0.68 + secondaryWave * 0.32) * amplitude
            let pointRadius = radius + displacement
            let cosine: Double = cos(angle)
            let sine: Double = sin(angle)
            let point = CGPoint(
                x: center.x + CGFloat(cosine) * pointRadius,
                y: center.y + CGFloat(sine) * pointRadius
            )

            if sample == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
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
    VStack {
        Color(.systemBackground).ignoresSafeArea()
        VoiceCaptureVisual(
            isAvailable: true,
            isRecording: false,
            isProcessing: false,
            audioLevel: 0,
            responseLevel: 0
        )
        VoiceCaptureButton(
            isAvailable: true,
            isRecording: false,
            isProcessing: false,
            action: {}
        )
    }
}

#Preview("Recording") {
    VStack {
        Color(.systemBackground).ignoresSafeArea()
        VoiceCaptureVisual(
            isAvailable: true,
            isRecording: true,
            isProcessing: false,
            audioLevel: 0.58,
            responseLevel: 0.58
        )
        VoiceCaptureButton(
            isAvailable: true,
            isRecording: true,
            isProcessing: false,
            action: {}
        )
    }
}
