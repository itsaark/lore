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
        Color(white: 0.90),
        Color(white: 0.80),
        Color(white: 0.66),
        Color(white: 0.50)
    ]

    // Silver layers that recede from a pale back ridge into the near-black
    // canvas, so the field glows without introducing color.
    private static let darkPalette: [Color] = [
        Color(red: 0.25, green: 0.255, blue: 0.27),
        Color(red: 0.17, green: 0.175, blue: 0.185),
        Color(red: 0.11, green: 0.113, blue: 0.12),
        Color(red: 0.065, green: 0.066, blue: 0.07)
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
        LoreTheme.canvas.ignoresSafeArea()
        ReflectionWaveField(phase: .listening, audioLevel: 0.35)
            .frame(height: 420)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
    }
}
