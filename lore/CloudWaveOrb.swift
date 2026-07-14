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
                        .float3(0.58, 0.82, 0.68),
                        .float3(0.09, 0.50, 0.32),
                        .float3(0.24, 0.68, 0.46),
                        .float3(0.88, 0.96, 0.91)
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
        Color.black.ignoresSafeArea()
        CloudWaveOrb(state: .listening, audioLevel: 0.35)
    }
}
