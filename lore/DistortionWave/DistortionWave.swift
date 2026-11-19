// Adapted from DistortionWavesKit (https://github.com/Jakubantalik/Libraries.dev,
// MIT, © 2026 Jakub Antalik) at 14ae9d2. See ThirdPartyNotices.txt.

import SwiftUI
import UIKit

/// The outgoing, opaque SwiftUI surface opens onto a live destination below.
/// Only the outgoing surface is sampled, so platform views on the destination
/// stay in their normal hierarchy throughout the transition.
struct DistortionWave<Content: View>: View {
    let isRevealing: Bool
    let source: CGRect
    let cornerRadius: Double
    let onFinish: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    @State private var heldSource = CGRect.zero
    @State private var run = 0

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            WaveStage(
                progress: progress,
                source: heldSource.offsetBy(dx: -frame.minX, dy: -frame.minY),
                size: geometry.size,
                style: style,
                plain: reduceMotion || heldSource.isEmpty,
                content: content()
            )
        }
        .onChange(of: isRevealing, initial: true) { _, revealing in
            run += 1
            let thisRun = run
            guard revealing else {
                progress = 0
                return
            }
            heldSource = source
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(.linear(duration: reduceMotion || source.isEmpty ? 0.25 : style.duration)) {
                progress = 1
            } completion: {
                if run == thisRun { onFinish() }
            }
        }
    }

    private var style: DistortionWaveStyle {
        var style = DistortionWaveStyle.vertical
        style.cornerRadius = cornerRadius
        style.palette = .colorful
        style.anticipation = 0.14
        style.travel = 1.25
        style.linger = -0.12
        style.rimFade = 0.85
        style.hairlineLinger = 0.08
        style.hairlineFade = 0.9
        style.particleLife = 0.78
        return style
    }
}

private struct WaveStage<Content: View>: View, Animatable {
    nonisolated var progress: Double
    let source: CGRect
    let size: CGSize
    let style: DistortionWaveStyle
    let plain: Bool
    let content: Content

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let front = waveFront
        let field = front?.packed ?? []
        let lensIsActive = front.map { !$0.hasCleared } ?? false
        let visible = progress < 1 && front?.hasCleared != true
        // The lens can sample both a swell and a pull, plus their fringes.
        let offset = (style.amplitude + style.pull) * (1 + style.aberration)

        ZStack {
            content
                .compositingGroup()
                .layerEffect(
                    ShaderLibrary.default.waveLens(
                        .floatArray(field),
                        .float(style.amplitude),
                        .float(style.lensWidth),
                        .float(style.aberration)
                    ),
                    maxSampleOffset: CGSize(width: offset, height: offset),
                    isEnabled: lensIsActive
                )
                .opacity(plain ? 1 - progress : visible ? 1 : 0)
            if let front {
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.default.waveBand(
                        .floatArray(field),
                        .floatArray(style.bandPalette),
                        .float(style.lead),
                        .float(style.tail),
                        .float(style.strength),
                        .float(style.rimWidth),
                        .float(style.rimSoftness),
                        .float(style.cornerRadius),
                        .float(style.rimUnevenness),
                        .float(style.rimPulse),
                        .float(style.hairlineWidth),
                        .float(style.hairlineOpacity),
                        .float(style.hairlineWhite),
                        .floatArray(WaveRim.lumps(
                            time: front.time, size: size, cornerRadius: style.cornerRadius, pulse: style.rimPulse
                        ))
                    ))
                WaveParticles(front: front, source: source, style: style, on: true)
            }
        }
    }

    private var waveFront: WaveFront? {
        guard !plain, progress > 0, progress < 1, size.width > 1, size.height > 1 else { return nil }
        let focus = CGPoint(x: source.midX, y: source.midY)
        return WaveFront(progress: progress, source: source, size: size, style: style, focus: focus)
    }
}
