import ImageIO
import SwiftData
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct LifeDialView: View {
    let birthYear: Int
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query private var photos: [DayPhoto]
    @Query private var illustrations: [DayIllustration]
    @State private var now = Date()
    @State private var destination: Destination?

    private enum Destination: Hashable {
        case day(String)
        case memories([UUID], selected: UUID)
    }

    var body: some View {
        let calendar = JournalCalendar()
        let notes = speechRecognizer.stories.compactMap { story in
            story.effectiveDayKey(recordedDayKey: speechRecognizer.storyDayKeys[story.id] ?? calendar.dayKey(for: story.date))
        }
        let entryKeys = speechRecognizer.dailyBiographyEntries.filter { $0.memoryStoryId == nil }.map(\.dayKey)
        let archive = LifeDialArchive(
            birthYear: birthYear,
            now: now,
            calendar: calendar,
            contentDays: Set(notes).union(entryKeys),
            stories: speechRecognizer.stories,
            photos: photos,
            illustrations: illustrations
        )

        NavigationStack {
            LifeDialScreen(
                archive: archive,
                speechRecognizer: speechRecognizer,
                close: { dismiss() },
                openDay: { destination = .day($0) },
                openMemories: { destination = .memories($0, selected: $1) }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .day(let key):
                    DayJournalView(dayKey: key, speechRecognizer: speechRecognizer)
                        .toolbar(.visible, for: .navigationBar)
                case .memories(let ids, let selected):
                    MemoryJournalView(storyIds: ids, selected: selected, speechRecognizer: speechRecognizer)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
        }
        .interactiveDismissDisabled(speechRecognizer.isRecording || speechRecognizer.isSecuringRecording)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            now = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = Date() }
        }
    }
}

/// The ruler and image picker share a pre-bucketed index. SwiftData image
/// attributes are read only for the picture that is about to be displayed.
private struct LifeDialArchive {
    let dial: LifeDial
    let content: Set<LifeDial.Selection>
    let pictures: [LifeDial.Selection: Picture]
    let memories: [LifeDial.Selection: [UUID]]

    struct Picture {
        let cover: DayCover
        let memoryStoryId: UUID?
    }

    init(
        birthYear: Int,
        now: Date,
        calendar: JournalCalendar,
        contentDays: Set<String>,
        stories: [Story],
        photos: [DayPhoto],
        illustrations: [DayIllustration]
    ) {
        let availablePhotos = photos.filter { $0.pixelWidth > 0 && $0.pixelHeight > 0 }
        let availableIllustrations = illustrations.filter { $0.pixelWidth > 0 && $0.pixelHeight > 0 }
        let allDays = contentDays.union(availablePhotos.map(\.dayKey))
            .union(availableIllustrations.filter { $0.memoryStoryId == nil }.map(\.dayKey))
        let coarseMemories = stories.reversed().compactMap { story -> (UUID, RememberedTime)? in
            guard let time = story.rememberedTime, time.isCoarse else { return nil }
            return (story.id, time)
        }
        let days = allDays.reduce(into: [String: Date]()) { result, key in
            if let date = calendar.date(forDayKey: key), date <= now { result[key] = date }
        }
        let memoryStarts = coarseMemories.compactMap { calendar.date(forDayKey: $0.1.startDate) }
        let earliestData = (Array(days.values) + memoryStarts).min()
        let dial = LifeDial(birthYear: birthYear, earliestData: earliestData, now: now, calendar: calendar.calendar)
        let levels = dial.levels
        var unitsByDay: [String: [LifeDial.Selection]] = [:]
        var occupied: Set<LifeDial.Selection> = []
        for (key, date) in days where date >= dial.start {
            let units = levels.map { LifeDial.Selection(level: $0, index: dial.index(of: date, at: $0)) }
            unitsByDay[key] = units
            occupied.formUnion(units)
        }

        var unitsByMemory: [UUID: [LifeDial.Selection]] = [:]
        var memoriesByUnit: [LifeDial.Selection: [UUID]] = [:]
        for (id, time) in coarseMemories where unitsByMemory[id] == nil {
            let units = dial.selections(for: time, calendar: calendar)
            unitsByMemory[id] = units
            occupied.formUnion(units)
            for unit in units { memoriesByUnit[unit, default: []].append(id) }
        }

        let covers = availablePhotos.coversByDay()
        var sources: [UUID: Picture] = [:]
        var candidates: [LifeDial.Selection: [LifeDial.PictureCandidate]] = [:]

        func add(_ cover: DayCover, dayKey: String, memoryStoryId: UUID? = nil, kind: LifeDial.PictureCandidate.Kind) {
            let units = memoryStoryId.map { unitsByMemory[$0, default: []] } ?? unitsByDay[dayKey, default: []]
            let candidate = LifeDial.PictureCandidate(id: cover.id, kind: kind)
            sources[cover.id] = Picture(cover: cover, memoryStoryId: memoryStoryId)
            for unit in units { candidates[unit, default: []].append(candidate) }
        }

        for photo in availablePhotos {
            add(.photo(photo), dayKey: photo.dayKey, kind: covers[photo.dayKey]?.id == photo.id ? .cover : .photo)
        }
        for illustration in availableIllustrations {
            add(.illustration(illustration), dayKey: illustration.dayKey, memoryStoryId: illustration.memoryStoryId, kind: .illustration)
        }

        self.dial = dial
        content = occupied
        memories = memoriesByUnit
        pictures = candidates.reduce(into: [:]) { result, bucket in
            if let id = LifeDial.pickPicture(from: bucket.value, for: bucket.key) { result[bucket.key] = sources[id] }
        }
    }
}

private struct LifeDialScreen: View {
    let archive: LifeDialArchive
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    let close: () -> Void
    let openDay: (String) -> Void
    let openMemories: ([UUID], UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44
    @State private var motion: LifeDialMotion

    init(
        archive: LifeDialArchive,
        speechRecognizer: SpeechRecognitionViewModel,
        close: @escaping () -> Void,
        openDay: @escaping (String) -> Void,
        openMemories: @escaping ([UUID], UUID) -> Void
    ) {
        self.archive = archive
        self.speechRecognizer = speechRecognizer
        self.close = close
        self.openDay = openDay
        self.openMemories = openMemories
        _motion = State(initialValue: LifeDialMotion(dial: archive.dial))
    }

    private var isCapturing: Bool {
        speechRecognizer.isRecording || speechRecognizer.isSecuringRecording
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                dialContent
                    .allowsHitTesting(!isCapturing)
                    .accessibilityHidden(isCapturing)
                    .padding(.bottom, 94)

                if isCapturing {
                    VoiceCaptureOverlay(speechRecognizer: speechRecognizer)
                        .transition(.opacity)
                }

                VStack(spacing: 8) {
                    VoiceCaptureFeedback(speechRecognizer: speechRecognizer, showsPermissionHint: false)
                    VoiceCaptureButton(
                        containerWidth: geometry.size.width,
                        isAvailable: speechRecognizer.isAuthorized,
                        isRecording: speechRecognizer.isRecording,
                        isProcessing: speechRecognizer.isAwaitingRemoteTranscription,
                        accessibilityID: "lifeDialRecordButton"
                    ) {
                        speechRecognizer.toggleRecording(
                            remembering: archive.dial.rememberedTime(for: motion.selection, at: Date())
                        )
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .loreCanvas()
        .animation(.easeInOut(duration: 0.3), value: isCapturing)
        .onAppear { motion.start(reduceMotion: reduceMotion) }
        .onDisappear { motion.stop() }
        .onChange(of: reduceMotion) { _, enabled in motion.setReduceMotion(enabled) }
        .onChange(of: archive.dial) { _, dial in motion.update(dial: dial) }
    }

    private var dialContent: some View {
        let selection = motion.selection
        let labels = archive.dial.labels(for: selection)
        return VStack(spacing: 0) {
            header(labels)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)

            GeometryReader { geometry in
                let width = max(0, min(geometry.size.width - 32, geometry.size.height * 0.8))
                let height = width * 1.25
                let picture = archive.pictures[selection]
                let aspect = picture?.cover.aspectRatio ?? 0.8
                let fillWidth = max(width, height * aspect)
                let pixelSize = Int(min(
                    DayPhotoEncoder.maximumPixelLength,
                    (max(fillWidth, fillWidth / aspect) * displayScale).rounded(.up)
                ))
                LifeDialPicture(
                    picture: picture,
                    pixelSize: pixelSize,
                    open: pictureAction(for: selection, picture: picture),
                    accessibilityLabel: selection.level == .day ? "Open day" : "Open memory",
                    showsMemoryPlaceholder: archive.memories[selection] != nil && picture == nil,
                    reduceMotion: reduceMotion
                )
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 7) {
                ForEach(archive.dial.levels, id: \.self) { level in
                    Circle()
                        .fill(level == selection.level ? LoreTheme.ink : LoreTheme.hairline)
                        .frame(width: 5, height: 5)
                }
            }
            .animation(.easeOut(duration: 0.2), value: selection.level)
            .accessibilityHidden(true)
            .padding(.top, 20)
            .padding(.bottom, 6)

            LifeDialRuler(motion: motion, content: archive.content, reduceMotion: reduceMotion)
                .frame(height: 78)
                .ignoresSafeArea(.container, edges: .horizontal)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time")
                .accessibilityValue(labels.accessibilityValue)
                .accessibilityIdentifier("lifeDialRuler")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: motion.step(by: 1)
                    case .decrement: motion.step(by: -1)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: "Zoom in") { motion.zoom(towardFiner: true) }
                .accessibilityAction(named: "Zoom out") { motion.zoom(towardFiner: false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(LifeDialScrubGesture(motion: motion))
        .gesture(LifeDialPinchGesture(motion: motion))
    }

    private func pictureAction(for selection: LifeDial.Selection, picture: LifeDialArchive.Picture?) -> (() -> Void)? {
        if selection.level == .day, archive.content.contains(selection),
           let date = archive.dial.range(of: selection)?.lowerBound {
            let key = JournalCalendar(calendar: archive.dial.calendar).dayKey(for: date)
            return { openDay(key) }
        }
        if let ids = archive.memories[selection], let picked = picture?.memoryStoryId ?? ids.first {
            return { openMemories(ids, picked) }
        }
        return nil
    }

    private func header(_ labels: LifeDial.Labels) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .center, spacing: 5) {
                Text(labels.title)
                    .font(LoreTheme.display(min(titleSize, 56)))
                    .foregroundStyle(LoreTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                Text(labels.subtitle.isEmpty ? " " : labels.subtitle)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.opacity)
                    .accessibilityHidden(labels.subtitle.isEmpty)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48) // keeps the centred title clear of the close button
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.18), value: labels)

            Button(action: close) {
                CircleIcon(systemImage: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("lifeDialClose")
        }
    }
}

private struct LifeDialPicture: View {
    let picture: LifeDialArchive.Picture?
    let pixelSize: Int
    let open: (() -> Void)?
    let accessibilityLabel: String
    let showsMemoryPlaceholder: Bool
    let reduceMotion: Bool

    @State private var presenter = LifeDialPicturePresenter()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
        let request = picture.flatMap { picture in
            pixelSize > 0 ? LifeDialPicturePresenter.Request(cover: picture.cover, pixelSize: pixelSize) : nil
        }
        ZStack {
            shape.strokeBorder(LoreTheme.hairline, lineWidth: 0.5)

            if showsMemoryPlaceholder {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(LoreTheme.tertiaryInk)
                    .accessibilityHidden(true)
            }

            if let frame = presenter.frame {
                Rectangle()
                    .fill(LoreTheme.surface)
                    .overlay {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(shape)
                    .transition(.opacity)
                    .id(frame.sequence)
                    .zIndex(Double(frame.sequence))
            }
        }
        .contentShape(shape)
        .overlay {
            if let open, presenter.frame == nil || presenter.frame?.key == request?.key {
                Button(action: open) {
                    shape.fill(.clear)
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("lifeDialPicture")
            }
        }
        .onChange(of: request?.key) { _, _ in
            presenter.schedule(request, reduceMotion: reduceMotion)
        }
        .onAppear { presenter.schedule(request, reduceMotion: reduceMotion) }
        .onDisappear { presenter.stop() }
    }
}

@MainActor @Observable
private final class LifeDialPicturePresenter {
    struct Key: Hashable, Sendable {
        let id: UUID
        let updatedAt: Date
        let pixelSize: Int
    }

    struct Request {
        let key: Key
        let cover: DayCover

        init(cover: DayCover, pixelSize: Int) {
            key = Key(id: cover.id, updatedAt: cover.updatedAt, pixelSize: pixelSize)
            self.cover = cover
        }
    }

    struct Frame {
        let key: Key
        let image: CGImage
        let sequence: Int
    }

    private(set) var frame: Frame?
    @ObservationIgnored private let cache = LifeDialThumbnailCache()
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var pending: (request: Request?, reduceMotion: Bool)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextSwap: ContinuousClock.Instant?
    @ObservationIgnored private var sequence = 0

    func schedule(_ request: Request?, reduceMotion: Bool) {
        pending = (request, reduceMotion)
        guard task == nil else { return }
        task = Task { await showPending() }
    }

    func stop() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func showPending() async {
        while pending != nil {
            // Keep the timer alive while new detents replace the pending
            // request. A fast flick can never enqueue a backlog of decodes.
            if let nextSwap { try? await clock.sleep(until: nextSwap) }
            guard !Task.isCancelled, let update = pending else { return }
            pending = nil
            if update.request?.key == frame?.key { continue }

            let newFrame: Frame?
            if let request = update.request, let image = await load(request) {
                sequence += 1
                newFrame = Frame(key: request.key, image: image, sequence: sequence)
            } else {
                newFrame = nil
            }
            guard !Task.isCancelled else { return }
            nextSwap = clock.now.advanced(by: .milliseconds(70))
            withAnimation(.easeInOut(duration: update.reduceMotion ? 0.18 : 0.3)) {
                frame = newFrame
            }
        }
        task = nil
    }

    private func load(_ request: Request) async -> CGImage? {
        if let cached = await cache.image(for: request.key) { return cached }
        guard !Task.isCancelled,
              let data = request.cover.data(for: .full) ?? request.cover.data(for: .thumbnail) else { return nil }
        return await cache.decode(data, for: request.key)
    }
}

private actor LifeDialThumbnailCache {
    private let capacity = 8
    private var images: [LifeDialPicturePresenter.Key: CGImage] = [:]
    private var recency: [LifeDialPicturePresenter.Key] = []

    func image(for key: LifeDialPicturePresenter.Key) -> CGImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    func decode(_ data: Data, for key: LifeDialPicturePresenter.Key) -> CGImage? {
        if let image = image(for: key) { return image }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: key.pixelSize
              ] as CFDictionary) else { return nil }
        images[key] = image
        touch(key)
        if recency.count > capacity { images.removeValue(forKey: recency.removeFirst()) }
        return image
    }

    private func touch(_ key: LifeDialPicturePresenter.Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

private struct LifeDialRuler: View {
    let motion: LifeDialMotion
    let content: Set<LifeDial.Selection>
    let reduceMotion: Bool

    var body: some View {
        let frame = motion.frame
        Canvas { context, size in
            if let previous = frame.previous {
                draw(previous, wake: frame.wake, context: context, width: size.width)
            }
            draw(frame.current, wake: frame.wake, context: context, width: size.width)

            let center = size.width / 2
            let top = 13 - 6 * frame.wake
            let dot = 2 + 0.8 * frame.wake
            if content.contains(motion.selection) {
                context.fill(Path(CGRect(x: center - 1, y: 46, width: 2, height: 6)), with: .color(LoreTheme.ink))
            }
            context.fill(Path(CGRect(x: center - 1, y: top, width: 2, height: 46 - top)), with: .color(LoreTheme.ink))
            context.fill(
                Path(ellipseIn: CGRect(x: center - dot, y: top - 4 - dot, width: 2 * dot, height: 2 * dot)),
                with: .color(LoreTheme.ink)
            )
        }
    }

    private func draw(_ layer: LifeDialMotion.Layer, wake: Double, context: GraphicsContext, width: Double) {
        let center = width / 2
        guard center > 0, layer.opacity > 0 else { return }
        let spacing = layer.level.spacing * layer.scale
        let half = center / spacing + 2
        let first = max(0, Int(floor(layer.position - half)))
        let last = min(motion.lastIndex(at: layer.level), Int(ceil(layer.position + half)))
        guard first <= last else { return }
        let baseline = 44.0

        for index in first...last {
            let dx = (Double(index) + 0.5 - layer.position) * spacing
            let edge = max(0, 1 - pow(abs(dx) / center, 2.2))
            guard edge > 0 else { continue }
            let unit = LifeDial.Selection(level: layer.level, index: index)
            let label = motion.tickLabel(for: unit)
            let occupied = content.contains(unit)
            let major = label != nil
            let distance = dx / 42
            let lens = reduceMotion ? 0 : exp(-distance * distance)
            let base = major ? 15.0 : occupied ? 10.0 : 6.0
            let height = base + lens * (4 + 14 * wake)
            let ink = occupied ? 0.9 : major ? 0.5 : 0.22
            let opacity = min(1, layer.opacity * edge * (ink + lens * 0.45 * wake))
            let lineWidth = 1.5 + lens * 0.6 * wake
            let x = center + dx
            let tick = CGRect(x: x - lineWidth / 2, y: baseline - height, width: lineWidth, height: height)
            context.fill(Path(tick), with: .color(LoreTheme.ink.opacity(opacity)))

            if let label {
                let text = Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LoreTheme.secondaryInk.opacity(layer.opacity * edge))
                context.draw(text, at: CGPoint(x: x, y: baseline + 13))
            }
        }
    }
}

@MainActor @Observable
private final class LifeDialMotion {
    struct Layer: Equatable {
        let level: LifeDial.Level
        let position: Double
        let scale: Double
        let opacity: Double
    }

    struct Frame: Equatable {
        let current: Layer
        let previous: Layer?
        let wake: Double
    }

    private struct Zoom {
        let previous: Layer
        let finer: Bool
        let startedAt: CFTimeInterval
    }

    private enum Movement {
        case coasting(velocity: Double)
        case snapping(target: Double, velocity: Double)
    }

    private(set) var selection: LifeDial.Selection
    private(set) var frame: Frame

    @ObservationIgnored private var dial: LifeDial
    @ObservationIgnored private var position: Double
    @ObservationIgnored private var dragOrigin: Double = 0
    @ObservationIgnored private var movement: Movement?
    @ObservationIgnored private var zoomTransition: Zoom?
    @ObservationIgnored private var pinchScale = 1.0
    @ObservationIgnored private var wake = 0.25
    @ObservationIgnored private var fingersDown = false
    @ObservationIgnored private var isPinching = false
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var edge: Double?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var tickLabels: [LifeDial.Selection: String] = [:]
    @ObservationIgnored private let haptics = LifeDialHaptics()

    init(dial: LifeDial) {
        self.dial = dial
        let initial = LifeDial.Selection(level: .month, index: dial.lastIndex(at: .month))
        selection = initial
        position = initial.center
        frame = Frame(current: Layer(level: .month, position: initial.center, scale: 1, opacity: 1), previous: nil, wake: 0.25)
    }

    func start(reduceMotion: Bool) {
        setReduceMotion(reduceMotion)
        guard displayLink == nil else { return }
        let target = LifeDialDisplayLinkTarget(motion: self)
        let link = CADisplayLink(target: target, selector: #selector(LifeDialDisplayLinkTarget.update(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        fingersDown = false
        isPinching = false
        movement = nil
        zoomTransition = nil
        pinchScale = 1
        wake = 0.25
        edge = nil
        position = selection.center
        publishFrame(at: CACurrentMediaTime())
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        guard enabled else { return }
        movement = nil
        zoomTransition = nil
        pinchScale = 1
        wake = 0.25
        if !fingersDown { position = selection.center }
        publishFrame(at: CACurrentMediaTime())
    }

    func update(dial: LifeDial) {
        let date = selection.index == self.dial.lastIndex(at: selection.level)
            ? dial.today : self.dial.centerTime(of: selection)
        self.dial = dial
        tickLabels.removeAll(keepingCapacity: true)
        let level = dial.levels.contains(selection.level) ? selection.level : .year
        selection = LifeDial.Selection(level: level, index: dial.index(of: date, at: level))
        stopAnimationAtSelection()
    }

    func lastIndex(at level: LifeDial.Level) -> Int { dial.lastIndex(at: level) }

    func tickLabel(for unit: LifeDial.Selection) -> String? {
        if let cached = tickLabels[unit] { return cached.isEmpty ? nil : cached }
        if tickLabels.count >= 512 { tickLabels.removeAll(keepingCapacity: true) }
        let label = dial.tickLabel(for: unit)
        tickLabels[unit] = label ?? ""
        return label
    }

    func touchDown() {
        haptics.prepare()
        fingersDown = true
        movement = nil
        beginDrag()
        publishFrame(at: CACurrentMediaTime())
    }

    func beginDrag() { dragOrigin = position }

    func drag(by translation: Double) {
        guard !isPinching else { return }
        let level = selection.level
        let raw = dragOrigin - translation / level.spacing
        let limit = dial.clamp(raw, at: level)
        let overshoot = raw - limit
        // Rubber band in screen points, regardless of the current detent size.
        let pull = abs(overshoot) * level.spacing
        let stretch = (26 * pull * 0.55) / (26 + pull * 0.55) / level.spacing
        position = limit + (overshoot < 0 ? -stretch : stretch)
        selectPosition(reportEdge: true)
        publishFrame(at: CACurrentMediaTime())
    }

    func touchUp(velocity: Double) {
        fingersDown = false
        edge = nil
        let velocity = -velocity / selection.level.spacing
        if reduceMotion {
            position = selection.center
        } else if !isPinching {
            if abs(velocity) > 2, position == dial.clamp(position, at: selection.level) {
                movement = .coasting(velocity: velocity)
            } else {
                beginSnap(velocity: 0)
            }
        }
        publishFrame(at: CACurrentMediaTime())
    }

    func beginPinch() {
        isPinching = true
        movement = nil
        pinchScale = 1
        publishFrame(at: CACurrentMediaTime())
    }

    /// Returns whether the native pinch should reset its baseline.
    func pinch(to ratio: Double) -> Bool {
        if !reduceMotion { pinchScale = min(1.3, max(0.77, ratio)) }
        if ratio > 1.3 || ratio < 0.77,
           zoom(towardFiner: ratio > 1.3) {
            return true
        }
        publishFrame(at: CACurrentMediaTime())
        return false
    }

    func endPinch() {
        isPinching = false
        beginDrag()
        if !fingersDown && !reduceMotion { beginSnap(velocity: 0) }
        publishFrame(at: CACurrentMediaTime())
    }

    @discardableResult
    func zoom(towardFiner: Bool) -> Bool {
        guard let next = dial.zoom(from: selection, towardFiner: towardFiner) else { return false }
        let now = CACurrentMediaTime()
        let old = Layer(level: selection.level, position: position, scale: pinchScale, opacity: 1)
        zoomTransition = Zoom(previous: old, finer: towardFiner, startedAt: now)
        pinchScale = 1
        movement = nil
        edge = nil
        position = next.center
        selection = next
        haptics.play(.level)
        publishFrame(at: now)
        return true
    }

    func step(by amount: Int) {
        let old = selection
        position = dial.clamp(old.center + Double(amount), at: old.level)
        selectPosition(reportEdge: true)
        stopAnimationAtSelection()
    }

    private func stopAnimationAtSelection() {
        movement = nil
        zoomTransition = nil
        pinchScale = 1
        edge = nil
        position = selection.center
        beginDrag()
        publishFrame(at: CACurrentMediaTime())
    }

    private func beginSnap(velocity: Double) {
        let target = selection.center
        if abs(position - target) < 0.003 {
            position = target
            movement = nil
        } else {
            movement = .snapping(target: target, velocity: velocity)
        }
    }

    private func selectPosition(reportEdge: Bool) {
        let level = selection.level
        let next = dial.selection(at: level, position: position)
        let limit = dial.clamp(position, at: level)
        let onEdge = position <= 0.5 || position >= Double(dial.lastIndex(at: level)) + 0.5
        let hitEdge = reportEdge && onEdge && edge != limit
        edge = onEdge ? limit : nil

        if next != selection {
            let old = selection
            selection = next
            if hitEdge {
                haptics.play(.edge)
            } else {
                // A flick can pass a major detent between two display frames.
                let step = next.index > old.index ? -1 : 1
                let crossedMajor = stride(from: next.index, to: old.index, by: step).contains { index in
                    tickLabel(for: LifeDial.Selection(level: level, index: index)) != nil
                }
                haptics.play(crossedMajor ? .major : .selection)
            }
        } else if hitEdge {
            haptics.play(.edge)
        }
    }

    func advance(_ link: CADisplayLink) {
        let dt = min(0.032, link.targetTimestamp - link.timestamp)
        switch movement {
        case .coasting(let velocity):
            // Integrate the prototype's 0.9955 decay per millisecond at any refresh rate.
            let decay = pow(0.9955, dt * 1_000)
            position += velocity * (1 - decay) / (-log(0.9955) * 1_000)
            selectPosition(reportEdge: true)
            let limit = dial.clamp(position, at: selection.level)
            let hitEnd = limit != position
            position = limit
            if hitEnd || abs(velocity * decay) < 1.5 {
                beginSnap(velocity: hitEnd ? 0 : velocity * decay)
            } else {
                movement = .coasting(velocity: velocity * decay)
            }

        case .snapping(let target, let velocity):
            // A critically damped spring returns the ruler without crossing
            // a neighboring detent on its way back from the rubber band.
            let stiffness = 34.0
            let distance = position - target
            let slope = velocity + stiffness * distance
            let decay = exp(-stiffness * dt)
            position = target + (distance + slope * dt) * decay
            beginSnap(velocity: (velocity - stiffness * slope * dt) * decay)

        case nil:
            break
        }

        let targetWake = !reduceMotion && (fingersDown || isPinching || movement != nil) ? 1.0 : 0.25
        wake = approach(wake, targetWake, rate: targetWake > wake ? 18 : 6, dt: dt)
        if !isPinching { pinchScale = approach(pinchScale, 1, rate: 20, dt: dt) }
        publishFrame(at: link.targetTimestamp)
    }

    private func approach(_ value: Double, _ target: Double, rate: Double, dt: Double) -> Double {
        abs(value - target) < 0.002 ? target : target + (value - target) * exp(-rate * dt)
    }

    private func publishFrame(at time: CFTimeInterval) {
        if let change = zoomTransition, time - change.startedAt >= (reduceMotion ? 0.18 : 0.32) {
            zoomTransition = nil
        }

        let nextFrame: Frame
        if let change = zoomTransition {
            let elapsed = max(0, time - change.startedAt)
            let progress = 1 - pow(1 - elapsed / (reduceMotion ? 0.18 : 0.32), 3)
            let outScale = reduceMotion ? 1 : (change.finer ? 2.2 : 0.45)
            let inScale = reduceMotion ? 1 : (change.finer ? 0.45 : 2.2)
            let previous = Layer(
                level: change.previous.level,
                position: change.previous.position,
                scale: change.previous.scale + (outScale - change.previous.scale) * progress,
                opacity: 1 - progress
            )
            let current = Layer(
                level: selection.level,
                position: position,
                scale: pinchScale * (inScale + (1 - inScale) * progress),
                opacity: progress
            )
            nextFrame = Frame(current: current, previous: previous, wake: wake)
        } else {
            nextFrame = Frame(
                current: Layer(level: selection.level, position: position, scale: pinchScale, opacity: 1),
                previous: nil,
                wake: wake
            )
        }
        if frame != nextFrame { frame = nextFrame }

        let targetWake = !reduceMotion && (fingersDown || isPinching || movement != nil) ? 1.0 : 0.25
        let atRest = movement == nil && wake == targetWake && (isPinching || pinchScale == 1) && zoomTransition == nil
        displayLink?.isPaused = atRest
    }
}

@MainActor
private final class LifeDialDisplayLinkTarget: NSObject {
    weak var motion: LifeDialMotion?

    init(motion: LifeDialMotion) { self.motion = motion }

    @objc func update(_ link: CADisplayLink) {
        if let motion { motion.advance(link) } else { link.invalidate() }
    }
}

@MainActor
private final class LifeDialHaptics {
    enum Pulse { case selection, major, level, edge }

    private let selection = UISelectionFeedbackGenerator()
    private let major = UIImpactFeedbackGenerator(style: .rigid)
    private let level = UIImpactFeedbackGenerator(style: .medium)
    private let edge = UIImpactFeedbackGenerator(style: .light)
    private var lastPulse = -Double.infinity

    func prepare() {
        selection.prepare()
        major.prepare()
        level.prepare()
        edge.prepare()
    }

    func play(_ pulse: Pulse) {
        let now = CACurrentMediaTime()
        guard now - lastPulse >= 0.035 else { return }
        lastPulse = now
        switch pulse {
        case .selection: selection.selectionChanged()
        case .major: major.impactOccurred(intensity: 0.7)
        case .level: level.impactOccurred()
        case .edge: edge.impactOccurred(intensity: 0.55)
        }
    }
}

private struct LifeDialScrubGesture: UIGestureRecognizerRepresentable {
    let motion: LifeDialMotion

    func makeUIGestureRecognizer(context: Context) -> LifeDialScrubRecognizer {
        let recognizer = LifeDialScrubRecognizer()
        recognizer.motion = motion
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> LifeDialGestureDelegate { LifeDialGestureDelegate() }
}

private struct LifeDialPinchGesture: UIGestureRecognizerRepresentable {
    let motion: LifeDialMotion

    func makeUIGestureRecognizer(context: Context) -> LifeDialPinchRecognizer {
        let recognizer = LifeDialPinchRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> LifeDialGestureDelegate { LifeDialGestureDelegate() }

    func handleUIGestureRecognizerAction(_ recognizer: LifeDialPinchRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            motion.beginPinch()
            if motion.pinch(to: recognizer.relativeScale) { recognizer.rebase() }
        case .changed:
            if motion.pinch(to: recognizer.relativeScale) { recognizer.rebase() }
        case .ended, .cancelled, .failed:
            motion.endPinch()
        default:
            break
        }
    }
}

/// Measures from the second finger's touchdown, before UIKit's recognition
/// threshold, so the level changes at the actual finger-spread ratio.
private final class LifeDialPinchRecognizer: UIPinchGestureRecognizer {
    private var fingers: Set<UITouch> = []
    private var initialDistance: CGFloat?

    var relativeScale: CGFloat {
        guard let initialDistance, let distance, initialDistance > 0 else { return scale }
        return distance / initialDistance
    }

    private var distance: CGFloat? {
        guard numberOfTouches == 2 else { return nil }
        let first = location(ofTouch: 0, in: nil)
        let second = location(ofTouch: 1, in: nil)
        return hypot(first.x - second.x, first.y - second.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.formUnion(touches)
        if fingers.count == 2, let first = fingers.first, let second = fingers.first(where: { $0 != first }) {
            let a = first.location(in: nil)
            let b = second.location(in: nil)
            initialDistance = hypot(a.x - b.x, a.y - b.y)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        fingers.subtract(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        fingers.subtract(touches)
    }

    override func reset() {
        super.reset()
        fingers.removeAll()
        initialDistance = nil
    }

    func rebase() {
        initialDistance = distance
        scale = 1
    }
}

private final class LifeDialGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is LifeDialScrubRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is LifeDialScrubRecognizer)
    }
}

/// Owns single-finger tracking so a pinch can hand back to the remaining
/// finger without jumping or carrying velocity from before the pinch.
private final class LifeDialScrubRecognizer: UIGestureRecognizer {
    weak var motion: LifeDialMotion?
    private var fingers: Set<UITouch> = []
    private var origin = CGPoint.zero
    private var samples: [(x: Double, time: TimeInterval)] = []
    private var dragging = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let firstTouch = fingers.isEmpty
        fingers.formUnion(touches)
        if firstTouch { motion?.touchDown() }
        if let touch = fingers.first, fingers.count == 1 { rebase(on: touch) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard fingers.count == 1, let touch = fingers.first, touches.contains(touch) else { return }
        move(touch)
    }

    private func move(_ touch: UITouch) {
        let point = touch.location(in: view)
        let dx = point.x - origin.x
        if !dragging {
            guard abs(dx) >= 3, abs(dx) >= abs(point.y - origin.y) else { return }
            dragging = true
        }
        state = state == .possible ? .began : .changed
        motion?.drag(by: dx)
        samples.append((point.x, touch.timestamp))
        while samples.count > 2, touch.timestamp - samples[0].time > 0.09 { samples.removeFirst() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    override func reset() {
        if !fingers.isEmpty { motion?.touchUp(velocity: 0) }
        fingers.removeAll()
        samples.removeAll(keepingCapacity: true)
        dragging = false
    }

    private func rebase(on touch: UITouch) {
        motion?.beginDrag()
        origin = touch.location(in: view)
        samples = [(origin.x, touch.timestamp)]
        dragging = false
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let wasSingle = fingers.count == 1
        if wasSingle, !cancelled, let touch = touches.first, touch.location(in: view).x != samples.last?.x {
            move(touch)
        }
        fingers.subtract(touches)
        if fingers.count == 1, let touch = fingers.first {
            rebase(on: touch)
        } else if fingers.isEmpty {
            var velocity = 0.0
            if wasSingle, dragging, !cancelled,
               let first = samples.first, let last = samples.last,
               let endedAt = touches.first?.timestamp,
               last.time > first.time, endedAt - last.time < 0.06 {
                velocity = (last.x - first.x) / (last.time - first.time)
            }
            motion?.touchUp(velocity: velocity)
            if state == .possible {
                state = .failed
            } else {
                state = cancelled ? .cancelled : .ended
            }
        }
    }
}
