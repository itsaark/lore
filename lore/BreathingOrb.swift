import SwiftUI

/// A native SwiftUI port of thinking-orbs' 64-point breathing preset.
/// Source: https://github.com/Jakubantalik/thinking-orbs (MIT licensed).
struct BreathingOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var phaseClock = BreathingOrbPhaseClock()

    let size: CGFloat
    let speed: Double
    let tint: Color?

    init(size: CGFloat = 64, speed: Double = 1, tint: Color? = nil) {
        self.size = size
        self.speed = speed
        self.tint = tint
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion
            )
        ) { context in
            let time = reduceMotion
                ? 0.6
                : phaseClock.time(
                    at: context.date.timeIntervalSinceReferenceDate,
                    targetSpeed: speed,
                    baseSpeed: Self.presetSpeed
                )

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
        let segmentCount = max(
            Self.baseSegmentCount,
            Int((Double(Self.baseSegmentCount) * pow(renderSize / 64, 0.6)).rounded())
        )
        let dots = BreathingOrbGeometry.dots(
            renderSize: renderSize, time: time, lanes: Self.laneCount,
            segmentCount: segmentCount, radiusMultiplier: 0.956, staggersAngles: renderSize > 64
        )

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
                with: .color((tint ?? Color(white: grayscale)).opacity(dot.opacity))
            )
        }
    }

    // The tuned 64px breathing preset from thinking-orbs resolves to eleven
    // lanes and forty-four dots per lane after applying its count multipliers.
    private static let laneCount = 11
    private static let baseSegmentCount = 44
    private static let presetSpeed = 3.24
}

final class BreathingOrbPhaseClock {
    private var lastTimestamp: TimeInterval?
    private var smoothedSpeed: Double?
    private var phase = 0.6

    func time(
        at timestamp: TimeInterval,
        targetSpeed: Double,
        baseSpeed: Double
    ) -> Double {
        let targetSpeed = max(0, targetSpeed)

        guard let lastTimestamp else {
            self.lastTimestamp = timestamp
            smoothedSpeed = targetSpeed
            return phase
        }

        let frameDuration = min(max(timestamp - lastTimestamp, 0), 0.1)
        self.lastTimestamp = timestamp

        let currentSpeed = smoothedSpeed ?? targetSpeed
        let smoothing = 1 - exp(-frameDuration * 4)
        let nextSpeed = currentSpeed + (targetSpeed - currentSpeed) * smoothing
        smoothedSpeed = nextSpeed
        phase += frameDuration * baseSpeed * nextSpeed

        return phase
    }
}

#Preview("Breathing orb") {
    VStack(spacing: 28) {
        BreathingOrb(size: 64, speed: 0.75)
            .padding(20)
            .background(LoreTheme.canvas)

        BreathingOrb(size: 64, speed: 0.75)
            .padding(20)
            .background(LoreTheme.canvas)
            .preferredColorScheme(.dark)
    }
}
