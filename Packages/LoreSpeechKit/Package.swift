// swift-tools-version: 6.2
import PackageDescription

// Wraps FluidAudio so Lore can turn off its default traits, which Xcode
// project package references cannot do. With `traits: []` the TTS backends
// and their LuxTTS G2P bundle (an eSpeak NG-derived lexicon, GPL-3.0-or-later)
// drop out of the build, along with diarization and the prebuilt NeMo
// text-processing engine. Lore needs only ASR, plus CTC vocabulary boosting
// in the DEBUG Transcription Lab, and neither is trait-gated.
let package = Package(
    name: "LoreSpeechKit",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "LoreSpeechKit", targets: ["LoreSpeechKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.0", traits: []),
    ],
    targets: [
        .target(
            name: "LoreSpeechKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
