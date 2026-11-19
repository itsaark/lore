import SwiftUI

/// Keeps the capture surface mounted until its successful save wave finishes.
struct CaptureSaveWave: View {
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    let source: CGRect
    var isOnCaptureScreen = true

    @State private var phase = CaptureSaveWavePhase.hidden

    private struct Capture: Equatable {
        let active: Bool
        let saveID: UUID?
        let onScreen: Bool
    }

    var body: some View {
        let capture = Capture(
            active: isOnCaptureScreen && (speechRecognizer.isRecording || speechRecognizer.isSecuringRecording),
            saveID: speechRecognizer.securedRecordingID,
            onScreen: isOnCaptureScreen
        )

        ZStack {
            if capture.active || phase != .hidden {
                DistortionWave(
                    isRevealing: phase == .revealing,
                    source: source,
                    cornerRadius: VoiceCaptureOverlay.displayCornerRadius,
                    onFinish: {
                        if phase == .revealing { phase = .hidden }
                    }
                ) {
                    VoiceCaptureOverlay(speechRecognizer: speechRecognizer)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .allowsHitTesting(capture.active)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.25), value: capture.active)
        .onChange(of: capture, initial: true) { previous, current in
            withAnimation(.easeInOut(duration: 0.25)) {
                phase.update(
                    isCapturing: current.active, didSave: previous.saveID != current.saveID,
                    isOnScreen: current.onScreen
                )
            }
        }
    }
}

enum CaptureSaveWavePhase {
    case hidden, capturing, revealing

    mutating func update(isCapturing: Bool, didSave: Bool, isOnScreen: Bool) {
        if !isOnScreen {
            self = .hidden
        } else if isCapturing {
            self = .capturing
        } else if self == .capturing {
            self = didSave ? .revealing : .hidden
        }
    }
}
