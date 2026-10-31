import SwiftData
import SwiftUI
import UIKit

/// Decoded day photos keyed by day and revision, so calendar tiles never turn
/// `Data` into a `UIImage` during a body pass. `NSCache` is thread-safe.
final class DayPhotoImageCache: @unchecked Sendable {
    static let shared = DayPhotoImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key as NSString, cost: pixels * 4)
    }

    static func key(for photo: DayPhoto, variant: DayPhotoImage.Variant) -> String {
        "\(photo.dayKey)|\(photo.updatedAt.timeIntervalSinceReferenceDate)|\(variant.rawValue)"
    }

    static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
    }
}

/// A day photo filling its frame. Decodes off the main thread and shows the
/// cached thumbnail while a full-size image loads.
struct DayPhotoImage: View {
    enum Variant: String {
        case thumbnail
        case full
    }

    let photo: DayPhoto
    var variant: Variant = .thumbnail
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    init(photo: DayPhoto, variant: Variant = .thumbnail, contentMode: ContentMode = .fill) {
        self.photo = photo
        self.variant = variant
        self.contentMode = contentMode
        let cache = DayPhotoImageCache.shared
        _image = State(initialValue: cache.image(forKey: DayPhotoImageCache.key(for: photo, variant: variant))
            ?? cache.image(forKey: DayPhotoImageCache.key(for: photo, variant: .thumbnail)))
    }

    private var cacheKey: String {
        DayPhotoImageCache.key(for: photo, variant: variant)
    }

    var body: some View {
        Rectangle()
            .fill(contentMode == .fill ? LoreTheme.raisedSurface : Color.clear)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: image)
            .task(id: cacheKey) { await load() }
    }

    private func load() async {
        let cache = DayPhotoImageCache.shared
        if let cached = cache.image(forKey: cacheKey) {
            image = cached
            return
        }
        if variant == .full, image == nil, let thumbnail = await decoded(.thumbnail) {
            image = thumbnail
        }
        if let decoded = await decoded(variant) {
            image = decoded
        }
    }

    private func decoded(_ variant: Variant) async -> UIImage? {
        let key = DayPhotoImageCache.key(for: photo, variant: variant)
        if let cached = DayPhotoImageCache.shared.image(forKey: key) { return cached }
        guard let data = variant == .full ? photo.imageData : photo.thumbnailData,
              let decoded = await DayPhotoImageCache.decode(data) else { return nil }
        DayPhotoImageCache.shared.insert(decoded, forKey: key)
        return decoded
    }
}

/// A fanned pile of slightly rotated photo cards that springs open on appear.
/// The newest card sits on top; tapping a card opens its day.
struct FannedPhotoStack: View {
    struct Card: Identifiable {
        let day: JournalDay
        let photo: DayPhoto
        let caption: String

        var id: String { day.dayKey }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Oldest first, so the newest is drawn last and lands on top.
    let cards: [Card]
    @State private var isFanned = false

    private static let angles: [Double] = [-8, 6, -4, 9, -6]
    private let cardSize = CGSize(width: 172, height: 228)

    var body: some View {
        ZStack {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                NavigationLink(value: JournalRoute.day(card.day.dayKey)) {
                    PhotoCard(card: card, size: cardSize)
                }
                .buttonStyle(PhotoCardButtonStyle())
                .rotationEffect(.degrees(isFanned ? angle(at: index) : 0))
                .offset(x: isFanned ? horizontalOffset(at: index) : 0, y: isFanned ? verticalOffset(at: index) : 24)
                .scaleEffect(isFanned ? 1 : 0.9)
                .opacity(isFanned ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.62, dampingFraction: 0.7).delay(Double(index) * 0.06),
                    value: isFanned
                )
                .accessibilityLabel("\(card.caption), photo")
                .accessibilityIdentifier("weekPhotoCard_\(card.day.dayKey)")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardSize.height + 48)
        .onAppear { isFanned = true }
        .onDisappear { isFanned = false }
    }

    private func angle(at index: Int) -> Double {
        // The top card rests nearly straight so its caption stays readable.
        if index == cards.count - 1 { return cards.count == 1 ? -3 : 2 }
        return Self.angles[index % Self.angles.count]
    }

    private func horizontalOffset(at index: Int) -> CGFloat {
        guard cards.count > 1 else { return 0 }
        let spread: CGFloat = min(44, 150 / CGFloat(cards.count - 1))
        return (CGFloat(index) - CGFloat(cards.count - 1) / 2) * spread
    }

    private func verticalOffset(at index: Int) -> CGFloat {
        index == cards.count - 1 ? 0 : CGFloat((index % 2) * 10 - 4)
    }
}

private struct PhotoCard: View {
    let card: FannedPhotoStack.Card
    let size: CGSize

    var body: some View {
        DayPhotoImage(photo: card.photo)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                Text(card.caption)
                    .font(LoreTheme.caption(.callout))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14))
            }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
    }
}

private struct PhotoCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Full-screen black photo viewer with pinch-to-zoom and swipe-down dismissal.
struct DayPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: DayPhoto

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var dragOffset: CGSize = .zero

    private var dismissProgress: CGFloat {
        min(abs(dragOffset.height) / 300, 1)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissProgress * 0.6)
                .ignoresSafeArea()

            DayPhotoImage(photo: photo, variant: .full, contentMode: .fit)
                .scaleEffect(zoom * (1 - dismissProgress * 0.15))
                .offset(dragOffset)
                .ignoresSafeArea()
                .gesture(magnification)
                .simultaneousGesture(dismissDrag)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoom = zoom > 1 ? 1 : 2.2
                        committedZoom = zoom
                    }
                }
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isImage)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .padding(.trailing, 18)
            .padding(.top, 8)
            .opacity(1 - dismissProgress)
            .accessibilityLabel("Close photo")
            .accessibilityIdentifier("closePhotoViewerButton")
        }
        .statusBarHidden()
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value.magnification, 1), 4)
            }
            .onEnded { _ in
                committedZoom = zoom
            }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard zoom <= 1 else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard zoom <= 1 else { return }
                if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 320 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                }
            }
    }
}

extension DayPhotoStore {
    /// Encodes picked photo data off the main thread, then stores it. Returns
    /// nil when the data is not an image.
    @discardableResult
    static func setPhoto(
        decodingInBackground data: Data,
        for dayKey: String,
        in context: ModelContext
    ) async throws -> DayPhoto? {
        guard let encoded = await Task.detached(priority: .userInitiated, operation: {
            DayPhotoEncoder.encode(data)
        }).value else { return nil }
        // Hand the already-downscaled JPEG to the store so its own encode pass
        // on the main actor stays cheap.
        return try setPhoto(encoded.imageData, for: dayKey, in: context)
    }
}
