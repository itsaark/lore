import SwiftUI

/// A full-width, voice-reactive field inspired by the calm layered motion of
/// live conversation interfaces. The drawing is native SwiftUI so it stays
/// lightweight, adapts to every device size, and can freeze for Reduce Motion.
struct ReflectionWaveField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let phase: ReflectionSessionPhase
    let audioLevel: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0.75 : timeline.date.timeIntervalSinceReferenceDate

            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                drawWaves(in: &context, size: size, time: time)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func drawWaves(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let energy = max(Double(audioLevel), phase.baselineWaveEnergy)
        let speed = phase.waveSpeed
        let palette = colorScheme == .dark ? Self.darkPalette : Self.lightPalette

        for layer in palette.indices {
            let progress = Double(layer) / Double(max(palette.count - 1, 1))
            let baseY = size.height * CGFloat(0.24 + progress * 0.18)
            let amplitude = size.height * CGFloat(0.035 + progress * 0.018 + energy * 0.025)
            let secondaryAmplitude = amplitude * 0.45
            let phaseOffset = Double(layer) * 1.37
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: baseY))

            let samples = max(32, Int(size.width / 8))
            for sample in 0...samples {
                let normalizedX = Double(sample) / Double(samples)
                let x = size.width * CGFloat(normalizedX)
                let primary = sin(
                    normalizedX * Double.pi * (1.35 + progress * 0.42)
                        + time * speed
                        + phaseOffset
                )
                let secondary = sin(
                    normalizedX * Double.pi * (3.2 - progress * 0.55)
                        - time * speed * 0.46
                        + phaseOffset * 0.7
                )
                let y = baseY
                    + amplitude * CGFloat(primary)
                    + secondaryAmplitude * CGFloat(secondary)
                path.addLine(to: CGPoint(x: x, y: y))
            }

            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(palette[layer]))
        }
    }

    private static let lightPalette: [Color] = [
        Color(red: 0.84, green: 0.91, blue: 0.77),
        Color(red: 0.58, green: 0.78, blue: 0.55),
        Color(red: 0.27, green: 0.61, blue: 0.40),
        Color(red: 0.11, green: 0.39, blue: 0.25)
    ]

    private static let darkPalette: [Color] = [
        Color(red: 0.17, green: 0.30, blue: 0.22),
        Color(red: 0.12, green: 0.39, blue: 0.26),
        Color(red: 0.08, green: 0.50, blue: 0.30),
        Color(red: 0.04, green: 0.27, blue: 0.16)
    ]
}

extension ReflectionSessionPhase {
    fileprivate var baselineWaveEnergy: Double {
        switch self {
        case .idle, .review, .completed:
            0.10
        case .connecting, .thinking, .ending:
            0.18
        case .listening:
            0.34
        case .speaking:
            0.58
        case .error:
            0.04
        }
    }

    fileprivate var waveSpeed: Double {
        switch self {
        case .idle, .review, .completed, .error:
            0.16
        case .connecting, .thinking, .ending:
            0.24
        case .listening:
            0.42
        case .speaking:
            0.58
        }
    }
}

#Preview("Reflection waves") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ReflectionWaveField(phase: .listening, audioLevel: 0.35)
            .frame(height: 420)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
    }
}
