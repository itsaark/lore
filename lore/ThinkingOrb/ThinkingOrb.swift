// Adapted from ThinkingOrbsKit (https://github.com/Jakubantalik/Libraries.dev,
// MIT, © 2026 Jakub Antalik) at 14ae9d2. Lore keeps the face-on breathing
// preset and uses its dot depth and ink values as tint opacity. See ThirdPartyNotices.txt.

import SwiftUI

struct ThinkingOrb: View {
    enum OrbState {
        case breathing
    }

    enum OrbSize: Double {
        case px20 = 20
        case px64 = 64

        // ThinkingOrbsKit's ring presets, with its density and radius scaling applied.
        fileprivate var lanes: Int { self == .px20 ? 10 : 11 }
        fileprivate var segments: Int { self == .px20 ? 15 : 44 }
        fileprivate var radiusScale: Double { self == .px20 ? 1.622 : 0.956 }
        fileprivate var speed: Double { self == .px20 ? 3.78 : 3.24 }
    }

    let state: OrbState
    let size: OrbSize
    var tint = LoreTheme.ink

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active {
                canvas(time: 0.6 * size.speed)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    canvas(time: timeline.date.timeIntervalSinceReferenceDate * size.speed)
                }
            }
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .allowsHitTesting(false)
    }

    private func canvas(time: Double) -> some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            switch state {
            case .breathing:
                let dots = BreathingOrbGeometry.dots(
                    renderSize: size.rawValue, time: time, lanes: size.lanes,
                    segmentCount: size.segments, radiusMultiplier: size.radiusScale
                )
                for dot in dots {
                    let radius = dot.radius
                    let rect = CGRect(
                        x: dot.center.x - radius, y: dot.center.y - radius,
                        width: 2 * radius, height: 2 * radius
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity((1 - dot.white) * dot.opacity)))
                }
            }
        }
    }
}
