// Adapted from VoiceGlowKit (https://github.com/Jakubantalik/Libraries.dev,
// MIT, © 2026 Jakub Antalik) at bad63221. Lore's change: the glow reads raw
// audio analysis from a closure (`audio:`) instead of owning a VoiceMeter, so
// it can share the recorder's single audio engine. See ThirdPartyNotices.txt.

import SwiftUI

/// One frame of raw microphone analysis: RMS of the latest window and the
/// three voice bands (lows, mids, highs), unshaped — the glow applies its
/// own gain, gate and attack/release.
struct VoiceGlowAudio: Sendable {
    var rms: Double
    var bands: SIMD3<Double>
}

/// Sound-reactive glow along the bottom edge of the wrapped view that rises
/// and blooms with a voice, its lobes moving independently with the low,
/// mid and high bands.
struct VoiceGlow<Content: View>: View {
    private let type: VoiceGlowType
    private let audio: (() -> VoiceGlowAudio?)?
    private let level: Double
    private let mood: VoiceMood?
    private let motion: (() -> VoiceGlowMotion)?
    private let active: Bool
    private let colorVariant: VoiceGlowColorVariant
    private let theme: VoiceGlowTheme
    private let cornerRadius: Double
    private let options: VoiceGlowOptions
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = VoiceGlowEngine()

    /// - Parameters:
    ///   - type: host preset — `.standard` (chat input), `.pill`, `.mobile`.
    ///   - audio: sampled every frame; return nil while there is no audio
    ///     and the glow falls back to `level`.
    ///   - level: 0–1 when nothing is being analysed.
    ///   - active: fades the glow in and out.
    ///   - cornerRadius: the wrapped view's corner radius.
    init(
        type: VoiceGlowType = .standard,
        audio: (() -> VoiceGlowAudio?)? = nil,
        level: Double = 0,
        mood: VoiceMood? = nil,
        motion: (() -> VoiceGlowMotion)? = nil,
        active: Bool = true,
        colorVariant: VoiceGlowColorVariant = .colorful,
        theme: VoiceGlowTheme = .auto,
        cornerRadius: Double = 16,
        options: VoiceGlowOptions = .init(),
        @ViewBuilder content: () -> Content
    ) {
        self.type = type
        self.audio = audio
        self.level = level
        self.mood = mood
        self.motion = motion
        self.active = active
        self.colorVariant = colorVariant
        self.theme = theme
        self.cornerRadius = cornerRadius
        self.options = options
        self.content = content()
    }

    var body: some View {
        content.overlay {
            GeometryReader { geo in
                TimelineView(.animation(paused: !active && !engine.isVisible)) { timeline in
                    let config = VoiceGlowConfig(
                        type: type, options: options, dark: isDark, colorVariant: colorVariant,
                        cornerRadius: cornerRadius, reducedMotion: reduceMotion
                    )
                    let frame = engine.step(
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        input: input,
                        config: config,
                        size: geo.size
                    )
                    if frame.presence > 0.002 {
                        VoiceGlowLayers(frame: frame, config: config, size: geo.size)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .auto: return colorScheme == .dark
        }
    }

    private var input: VoiceGlowInput {
        if let read = audio?() {
            return VoiceGlowInput(level: read.rms, bands: read.bands, motion: motion?() ?? .rest, active: active, mood: mood)
        }
        return VoiceGlowInput(level: level, bands: nil, motion: motion?() ?? .rest, active: active, mood: mood)
    }
}
