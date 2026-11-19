import SwiftData
import SwiftUI
import UIKit

enum DayCover {
    case photo(DayPhoto)
    case illustration(DayIllustration)

    var id: UUID {
        switch self {
        case .photo(let photo): photo.id
        case .illustration(let illustration): illustration.id
        }
    }

    var updatedAt: Date {
        switch self {
        case .photo(let photo): photo.updatedAt
        case .illustration(let illustration): illustration.updatedAt
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .photo(let photo): photo.aspectRatio
        case .illustration(let illustration): illustration.aspectRatio
        }
    }

    var isIllustration: Bool {
        if case .illustration = self { return true }
        return false
    }

    var paintingRevision: PaintingRevision? {
        if case .illustration(let illustration) = self { return illustration.paintingRevision }
        return nil
    }

    var paintingKey: String? {
        if case .illustration(let illustration) = self { return illustration.biographyKey }
        return nil
    }

    func data(for variant: DayPhotoImage.Variant) -> Data? {
        switch self {
        case .photo(let photo): variant == .full ? photo.imageData : photo.thumbnailData
        case .illustration(let illustration): variant == .full ? illustration.imageData : illustration.thumbnailData
        }
    }
}

/// Decoded day covers keyed by image and revision, so calendar tiles never turn
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

    static func key(for cover: DayCover, variant: DayPhotoImage.Variant) -> String {
        "\(cover.id.uuidString)|\(cover.updatedAt.timeIntervalSinceReferenceDate)|\(cover.paintingRevision?.fingerprint ?? "")|\(variant.rawValue)"
    }

    static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
    }

    @MainActor
    func load(_ cover: DayCover, variant: DayPhotoImage.Variant) async -> UIImage? {
        let key = Self.key(for: cover, variant: variant)
        if let cached = image(forKey: key) { return cached }
        guard let data = cover.data(for: variant), let decoded = await Self.decode(data) else { return nil }
        insert(decoded, forKey: key)
        return decoded
    }
}

/// A day cover filling its frame. Decodes off the main thread and shows the
/// cached thumbnail while a full-size image loads.
struct DayPhotoImage: View {
    enum Variant: String {
        case thumbnail
        case full
    }

    let cover: DayCover
    var variant: Variant = .thumbnail
    var contentMode: ContentMode = .fill

    @State private var loadedImage: (coverID: UUID, image: UIImage)?

    init(photo: DayPhoto, variant: Variant = .thumbnail, contentMode: ContentMode = .fill) {
        self.init(cover: .photo(photo), variant: variant, contentMode: contentMode)
    }

    init(cover: DayCover, variant: Variant = .thumbnail, contentMode: ContentMode = .fill) {
        self.cover = cover
        self.variant = variant
        self.contentMode = contentMode
        let cache = DayPhotoImageCache.shared
        let image = cache.image(forKey: DayPhotoImageCache.key(for: cover, variant: variant))
            ?? cache.image(forKey: DayPhotoImageCache.key(for: cover, variant: .thumbnail))
        _loadedImage = State(initialValue: image.map { (cover.id, $0) })
    }

    private var image: UIImage? {
        loadedImage?.coverID == cover.id ? loadedImage?.image : nil
    }

    private var cacheKey: String {
        DayPhotoImageCache.key(for: cover, variant: variant)
    }

    var body: some View {
        Rectangle()
            .fill(contentMode == .fill ? LoreTheme.raisedSurface : Color.clear)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .id(cover.isIllustration ? ObjectIdentifier(image) : nil)
                        .transition(.opacity)
                }
            }
            .clipped()
            // `clipped()` hides the overflow of a `.fill` image but leaves it
            // hit-testable; without this, a tall photo in the Day hero card
            // swallows taps on the Month/Week/Day picker above it.
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.2), value: image)
            .task(id: cacheKey) { await load() }
    }

    private func load() async {
        let cache = DayPhotoImageCache.shared
        if let cached = cache.image(forKey: cacheKey) {
            loadedImage = (cover.id, cached)
            return
        }
        if variant == .full, image == nil, let thumbnail = await decoded(.thumbnail), !Task.isCancelled {
            loadedImage = (cover.id, thumbnail)
        }
        if let decoded = await decoded(variant), !Task.isCancelled {
            loadedImage = (cover.id, decoded)
        }
    }

    private func decoded(_ variant: Variant) async -> UIImage? {
        await DayPhotoImageCache.shared.load(cover, variant: variant)
    }
}

/// A fanned pile of slightly rotated photo cards that springs open on appear.
/// The newest card sits on top; tapping a card opens its day.
struct FannedPhotoStack: View {
    struct Card: Identifiable {
        let day: JournalDay
        let cover: DayCover
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
                .accessibilityLabel(card.cover.isIllustration ? "\(card.caption), painting" : "\(card.caption), photo")
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
        DayPhotoImage(cover: card.cover)
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

/// Full-screen black viewer for a day's photos: swipe sideways between them,
/// pinch or double-tap to zoom, swipe down to dismiss.
struct DayPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [DayPhoto]

    @State private var selection: UUID
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var dragOffset: CGFloat = 0

    init(photos: [DayPhoto], startingAt photoID: UUID? = nil) {
        self.photos = photos
        _selection = State(initialValue: photoID ?? photos.first?.id ?? UUID())
    }

    private var index: Int {
        photos.firstIndex(where: { $0.id == selection }) ?? 0
    }

    private var dismissProgress: CGFloat {
        min(abs(dragOffset) / 300, 1)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissProgress * 0.6)
                .ignoresSafeArea()

            // Gestures live on the pager rather than inside its pages, where a
            // drag recognizer would swallow the sideways swipe.
            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    let isCurrent = photo.id == selection
                    DayPhotoImage(photo: photo, variant: .full, contentMode: .fit)
                        .scaleEffect(isCurrent ? zoom * (1 - dismissProgress * 0.15) : 1)
                        .offset(y: isCurrent ? dragOffset : 0)
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                zoom = zoom > 1 ? 1 : 2.2
                                committedZoom = zoom
                            }
                        }
                        .accessibilityLabel("Photo")
                        .accessibilityAddTraits(.isImage)
                        .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoom > 1)
            .simultaneousGesture(magnification)
            .simultaneousGesture(dismissDrag)
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            HStack {
                if photos.count > 1 {
                    Text("\(index + 1) of \(photos.count)")
                        .font(LoreTheme.label)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: index)
                        .accessibilityIdentifier("photoViewerCounter")
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .accessibilityLabel("Close photo")
                .accessibilityIdentifier("closePhotoViewerButton")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .opacity(1 - dismissProgress)
        }
        .onChange(of: selection) { _, _ in
            zoom = 1
            committedZoom = 1
            dragOffset = 0
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

    /// Only mostly-vertical drags dismiss, so sideways swipes page instead.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard zoom <= 1,
                      dragOffset != 0 || abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard zoom <= 1, dragOffset != 0 else { return }
                if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 320 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

extension DayPhotoStore {
    /// Downscales picked photo data off the main thread. Returns nil when the
    /// data is not an image.
    static func encodeInBackground(_ data: Data) async -> DayPhotoEncoder.Output? {
        await Task.detached(priority: .userInitiated) {
            DayPhotoEncoder.encode(data)
        }.value
    }
}
