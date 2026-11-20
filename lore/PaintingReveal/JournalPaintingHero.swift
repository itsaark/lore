import SwiftUI
import UIKit

struct JournalPaintingHero: View {
    let biographyKey: String
    let cover: DayCover?
    let isGenerating: Bool
    let session: PaintingRevealSession
    let accessibilityLabel: String
    let canRepaint: Bool
    let repaint: @MainActor () async -> Void

    @State private var painting: DecodedPainting?
    @State private var failedRevision: PaintingRevision?

    private struct DecodedPainting {
        let revision: PaintingRevision
        let image: UIImage
    }

    var body: some View {
        let image = painting.map { Image(uiImage: $0.image) }
        let ratio = min(max(cover?.aspectRatio ?? 0.75, 0.75), 4.0 / 3.0)
        let shape = RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)

        LoreTheme.raisedSurface
            .overlay {
                image?
                    .resizable()
                    .scaledToFill()
            }
            .overlay {
                PaintingReveal(
                    biographyKey: biographyKey,
                    expectedRevision: cover?.paintingRevision == failedRevision ? nil : cover?.paintingRevision,
                    revision: painting?.revision,
                    image: image,
                    isGenerating: isGenerating,
                    session: session,
                    tracksScrollVisibility: true,
                    keepsImageVisibleWhileLoading: true
                )
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(shape)
            .overlay { shape.strokeBorder(LoreTheme.hairline) }
            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isImage)
            .contextMenu {
                if canRepaint, !isGenerating {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await repaint() }
                    } label: {
                        Label("Repaint", systemImage: "paintbrush")
                    }
                }
            }
            .task(id: cover?.paintingRevision) { await load() }
    }

    private func load() async {
        guard let cover, let revision = cover.paintingRevision else { return }
        let cache = DayPhotoImageCache.shared
        if let image = cache.image(forKey: DayPhotoImageCache.key(for: cover, variant: .full)) {
            painting = DecodedPainting(revision: revision, image: image)
            return
        }

        // Keep the placeholder until the full image can drive the reveal.
        // An archived cover can show its thumbnail while it decodes.
        if session.pendingRevision(for: biographyKey) != revision, painting == nil,
           let thumbnail = await cache.load(cover, variant: .thumbnail), !Task.isCancelled {
            painting = DecodedPainting(revision: revision, image: thumbnail)
        }
        let full = await cache.load(cover, variant: .full)
        let image: UIImage?
        if let full {
            image = full
        } else {
            image = await cache.load(cover, variant: .thumbnail)
        }
        guard !Task.isCancelled else { return }
        if let image {
            painting = DecodedPainting(revision: revision, image: image)
        } else {
            failedRevision = revision
        }
    }
}
