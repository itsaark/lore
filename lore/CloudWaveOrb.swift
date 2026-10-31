import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum VoiceOrbState: Float {
    case idle = 0
    case listening = 1
    case processing = 2
    case speaking = 3
}

struct CloudWaveOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let size: CGFloat
    let state: VoiceOrbState
    let audioLevel: Float

    @State private var startDate = Date()
    @State private var patternSeed = Float.random(in: 0..<2048)

    init(
        size: CGFloat = 320,
        state: VoiceOrbState = .idle,
        audioLevel: Float = 0
    ) {
        self.size = size
        self.state = state
        self.audioLevel = audioLevel
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? 1.0 : max(0, context.date.timeIntervalSince(startDate))
            noiseImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .layerEffect(
                    ShaderLibrary.cloudWaveOrb(
                        .float2(Float(size), Float(size)),
                        .float(Float(elapsed * 0.95)),
                        .float(Float(elapsed)),
                        .float(min(max(audioLevel, 0), 1)),
                        .float(state.rawValue),
                        .float(patternSeed),
                        // Silver palette: main, low, mid, high. Low stays
                        // above the linear-burn floor so troughs read as
                        // graphite instead of vanishing into the canvas.
                        .float3(0.80, 0.81, 0.83),
                        .float3(0.44, 0.45, 0.48),
                        .float3(0.62, 0.63, 0.66),
                        .float3(0.97, 0.97, 0.98)
                    ),
                    maxSampleOffset: .zero
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var noiseImage: Image {
#if canImport(UIKit)
        Image(uiImage: Self.watercolorNoiseImage)
#else
        Image(systemName: "circle.fill")
#endif
    }

#if canImport(UIKit)
    private static let watercolorNoiseImage: UIImage = {
        guard let encodedData = NSDataAsset(name: "NoiseWatercolor")?.data,
              let encoded = String(data: encodedData, encoding: .utf8),
              let imageData = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let image = UIImage(data: imageData) else {
            assertionFailure("The Cloud Wave Orb noise texture is missing or invalid.")
            return UIImage()
        }
        return image
    }()
#endif
}

#Preview {
    ZStack {
        LoreTheme.canvas.ignoresSafeArea()
        CloudWaveOrb(state: .listening, audioLevel: 0.35)
    }
}
