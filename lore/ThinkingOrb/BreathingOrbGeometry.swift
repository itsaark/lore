// Adapted from ThinkingOrbsKit (https://github.com/Jakubantalik/Libraries.dev,
// MIT, © 2026 Jakub Antalik) at 14ae9d2. Lore keeps the face-on breathing
// geometry and shares it with the capture orb. See ThirdPartyNotices.txt.

import CoreGraphics
import Foundation

enum BreathingOrbGeometry {
    struct Dot {
        let center: CGPoint
        let depth: Double
        let radius: Double
        let white: Double
        let opacity: Double
    }

    static func dots(
        renderSize: Double,
        time: Double,
        lanes: Int,
        segmentCount: Int,
        radiusMultiplier: Double,
        staggersAngles: Bool = false
    ) -> [Dot] {
        let wobbleMultiplier = 0.368
        let center = renderSize / 2
        let sphereRadius = renderSize * 0.39
        let wobbleAmplitude = 0.23 * wobbleMultiplier
        let baseRadius = sphereRadius / (1 + 0.85 * wobbleAmplitude)
        let dotScale = pow(renderSize / 300, 0.6)
        return (0..<lanes).flatMap { lane -> [Dot] in
            let lanePosition = Double(lane) - Double(lanes - 1) / 2
            let laneOffset = lanePosition * 0.075
            let edge = abs(lanePosition) / max(1, Double(lanes - 1) / 2)
            let normalization = sqrt(1 + laneOffset * laneOffset)
            let angularStagger = staggersAngles
                ? (Double(lane) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
                : 0

            return (0..<segmentCount).map { segment in
                let angle = (Double(segment) + angularStagger)
                    / Double(segmentCount)
                    * 2
                    * Double.pi
                let wobble = (
                    0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                        + 0.07 * sin(angle * 5 + time * 1.1)
                ) * wobbleMultiplier
                let radius = baseRadius * (1 + wobble)
                let depthValue = laneOffset / normalization * radius
                let depth = (depthValue / sphereRadius + 1) / 2
                let dotRadius = max(
                    0.3,
                    ((1.1 + 1.7 * depth) * radiusMultiplier)
                        * (1 - 0.25 * edge)
                        * dotScale
                )

                return Dot(
                    center: CGPoint(
                        x: center + cos(angle) / normalization * radius,
                        y: center - sin(angle) / normalization * radius
                    ),
                    depth: depthValue,
                    radius: dotRadius,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    opacity: 0.4 + 0.6 * depth
                )
            }
        }
        .sorted { $0.depth < $1.depth }
    }
}
