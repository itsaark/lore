import SwiftUI

/// Draws only over the picture area. The parent remains responsible for its
/// image, layout and gestures.
struct PaintingReveal: View {
    let biographyKey: String?
    let expectedRevision: PaintingRevision?
    let revision: PaintingRevision?
    let image: Image?
    let isGenerating: Bool
    let session: PaintingRevealSession
    var isPresented = true
    var tracksScrollVisibility = false
    var keepsImageVisibleWhileLoading = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var intersectsViewport = false
    @State private var epoch = Date()
    @State private var activeReveal: ActiveReveal?

    private static let duration = 1.2

    private struct ActiveReveal: Equatable {
        let revision: PaintingRevision
        let start: Date
    }

    private struct Input: Equatable {
        let key: String?
        let revision: PaintingRevision?
        let pending: PaintingRevision?
        let generating: Bool
        let visible: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        let pending = biographyKey.flatMap { session.pendingRevision(for: $0) }
        let visible = isOnScreen && isPresented && scenePhase == .active && (!tracksScrollVisibility || intersectsViewport)
        let input = Input(
            key: biographyKey, revision: revision, pending: pending, generating: isGenerating,
            visible: visible, reduceMotion: reduceMotion
        )
        let waiting = isGenerating || (pending != nil && pending == expectedRevision)
        let reveal = activeReveal.flatMap { $0.revision == revision ? $0 : nil }
        let loadingOpacity = keepsImageVisibleWhileLoading && image != nil ? 0.35 : 1.0

        Color.clear
            .overlay {
                if visible && (waiting || reveal != nil) {
                    if reduceMotion {
                        if waiting {
                            LoreTheme.surface.opacity(loadingOpacity).transition(.opacity)
                        }
                    } else {
                        TimelineView(.animation) { timeline in
                            let progress = reveal.map {
                                min(1, max(0, timeline.date.timeIntervalSince($0.start) / Self.duration))
                            } ?? 0
                            mosaic(time: timeline.date.timeIntervalSince(epoch), progress: progress, showingImage: reveal != nil)
                                .opacity(reveal == nil ? loadingOpacity : 1)
                        }
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : nil, value: waiting)
            .onGeometryChange(for: Bool.self) { proxy in
                guard tracksScrollVisibility,
                      let bounds = proxy.bounds(of: .scrollView) else { return true }
                let viewport = CGRect(origin: .zero, size: bounds.size)
                return proxy.frame(in: .scrollView).intersects(viewport)
            } action: {
                intersectsViewport = $0
            }
            .onChange(of: input, initial: true) { _, current in
                if !current.visible || current.reduceMotion || current.generating || activeReveal?.revision != current.revision {
                    activeReveal = nil
                }
                guard current.visible, !current.generating,
                      let key = current.key, let revision = current.revision,
                      session.claim(revision, for: key) else { return }
                if !current.reduceMotion {
                    activeReveal = ActiveReveal(revision: revision, start: Date())
                }
            }
            .task(id: activeReveal) {
                guard activeReveal != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(Self.duration))
                    activeReveal = nil
                } catch {
                    // A newer selection or a hidden surface cancels the old reveal.
                }
            }
            .onAppear { isOnScreen = true }
            .onDisappear {
                isOnScreen = false
                activeReveal = nil
            }
    }

    @ViewBuilder
    private func mosaic(time: Double, progress: Double, showingImage: Bool) -> some View {
        if showingImage, let image {
            LoreTheme.raisedSurface
                .overlay { image.resizable().scaledToFill() }
                .clipped()
                .drawingGroup(opaque: true)
                .layerEffect(
                    ShaderLibrary.default.lorePixelsOrganicReveal(
                        .boundingRect, .float(time), .float(progress),
                        .color(LoreTheme.canvas), .color(LoreTheme.raisedSurface), .color(LoreTheme.ink)
                    ),
                    maxSampleOffset: CGSize(width: 8, height: 8)
                )
        } else {
            Rectangle()
                .fill(LoreTheme.raisedSurface)
                .colorEffect(ShaderLibrary.default.lorePixelsOrganicLoading(
                    .boundingRect, .float(time),
                    .color(LoreTheme.canvas), .color(LoreTheme.raisedSurface), .color(LoreTheme.ink)
                ))
        }
    }
}
