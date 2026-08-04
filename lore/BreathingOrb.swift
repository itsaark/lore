import SwiftUI

/// A native SwiftUI port of thinking-orbs' 64-point breathing preset.
/// Source: https://github.com/Jakubantalik/thinking-orbs (MIT licensed).
struct BreathingOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let size: CGFloat
    let speed: Double

    init(size: CGFloat = 64, speed: Double = 1) {
        self.size = size
        self.speed = speed
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion
            )
        ) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let time = reduceMotion ? 0.6 : elapsed * Self.presetSpeed * speed

            Canvas(opaque: false, rendersAsynchronously: true) { context, canvasSize in
                draw(in: &context, canvasSize: canvasSize, time: time)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(
        in context: inout GraphicsContext,
        canvasSize: CGSize,
        time: Double
    ) {
        let renderSize = Double(min(canvasSize.width, canvasSize.height))
        let center = (
            x: Double(canvasSize.width / 2),
            y: Double(canvasSize.height / 2)
        )
        let sphereRadius = renderSize * 0.39
        let wobbleAmplitude = 0.23 * Self.wobbleMultiplier
        let baseRadius = sphereRadius / (1 + 0.85 * wobbleAmplitude)
        let dotScale = pow(renderSize / 300, 0.6)

        let dots = (0..<Self.laneCount).flatMap { lane -> [BreathingDot] in
            let lanePosition = Double(lane) - Double(Self.laneCount - 1) / 2
            let laneOffset = lanePosition * 0.075
            let edge = abs(lanePosition) / max(1, Double(Self.laneCount - 1) / 2)
            let normalization = sqrt(1 + laneOffset * laneOffset)

            return (0..<Self.segmentCount).map { segment in
                let angle = Double(segment) / Double(Self.segmentCount) * 2 * Double.pi
                let wobble = (
                    0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                        + 0.07 * sin(angle * 5 + time * 1.1)
                ) * Self.wobbleMultiplier
                let radius = baseRadius * (1 + wobble)
                let depthValue = laneOffset / normalization * radius
                let depth = (depthValue / sphereRadius + 1) / 2
                let dotRadius = max(
                    0.3,
                    (Self.dotRadiusBase + Self.dotRadiusDepth * depth)
                        * (1 - 0.25 * edge)
                        * dotScale
                )

                return BreathingDot(
                    center: CGPoint(
                        x: CGFloat(center.x + cos(angle) / normalization * radius),
                        y: CGFloat(center.y - sin(angle) / normalization * radius)
                    ),
                    depth: depthValue,
                    radius: dotRadius,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    opacity: 0.4 + 0.6 * depth
                )
            }
        }
        .sorted { $0.depth < $1.depth }

        for dot in dots {
            let white = min(max(dot.white, 0), 1)
            let grayscale = colorScheme == .dark ? 1 - white : white
            let dotRadius = CGFloat(dot.radius)
            let rect = CGRect(
                x: dot.center.x - dotRadius,
                y: dot.center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color(white: grayscale).opacity(dot.opacity))
            )
        }
    }

    // The tuned 64px breathing preset from thinking-orbs resolves to eleven
    // lanes and forty-four dots per lane after applying its count multipliers.
    private static let laneCount = 11
    private static let segmentCount = 44
    private static let presetSpeed = 3.24
    private static let wobbleMultiplier = 0.368
    private static let dotRadiusBase = 1.1 * 0.956
    private static let dotRadiusDepth = 1.7 * 0.956
}

private struct BreathingDot {
    let center: CGPoint
    let depth: Double
    let radius: Double
    let white: Double
    let opacity: Double
}

#Preview("Breathing orb") {
    VStack(spacing: 28) {
        BreathingOrb(size: 64, speed: 0.75)
            .padding(20)
            .background(Color(.systemBackground))

        BreathingOrb(size: 64, speed: 0.75)
            .padding(20)
            .background(Color(.systemBackground))
            .preferredColorScheme(.dark)
    }
}
