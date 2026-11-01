import SwiftData
import SwiftUI
import VoiceGlowKit

enum JournalRoute: Hashable {
    case day(String)
    case transcripts
}

/// The calendar-first home: this week's photos and days, earlier weeks or
/// months below, and voice capture floating at the bottom.
struct JournalHomeView: View {
    let userProfile: UserProfile
    @ObservedObject var speechRecognizer: SpeechRecognitionViewModel
    let reflectionBackend: any LoreReflectionBackendClient

    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showsSettings: Bool
    @State private var showsReflection = false
    @State private var today = Date()

    init(
        userProfile: UserProfile,
        speechRecognizer: SpeechRecognitionViewModel,
        reflectionBackend: any LoreReflectionBackendClient,
        opensSettings: Bool = false
    ) {
        self.userProfile = userProfile
        self.speechRecognizer = speechRecognizer
        self.reflectionBackend = reflectionBackend
        _showsSettings = State(initialValue: opensSettings)
    }

    private var showsSupportMessage: Bool {
        speechRecognizer.captureFeedbackMessage != nil || !speechRecognizer.isAuthorized
    }

    private var isCapturing: Bool {
        speechRecognizer.isRecording || speechRecognizer.isAwaitingRemoteTranscription
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ZStack {
                    JournalCalendarContent(
                        stories: speechRecognizer.stories,
                        dailyEntries: speechRecognizer.dailyBiographyEntries,
                        storyDayKeys: speechRecognizer.storyDayKeys,
                        today: today,
                        hasTranscripts: !speechRecognizer.stories.isEmpty,
                        openSettings: { showsSettings = true }
                    )
                    .equatable()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: showsSupportMessage ? 168 : 112)
                    }

                    if isCapturing {
                        captureOverlay
                            .transition(.opacity)
                    } else {
                        captureBarScrim
                    }

                    VStack(spacing: 8) {
                        Spacer()
                        captureFeedback
                        captureBar(width: geometry.size.width)
                    }
                    // Keeps side-button captions clear of the home indicator.
                    .padding(.bottom, 14)
                }
            }
            .loreCanvas()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: JournalRoute.self) { route in
                switch route {
                case let .day(dayKey):
                    DayJournalView(dayKey: dayKey, speechRecognizer: speechRecognizer)
                case .transcripts:
                    TranscriptArchiveView(speechRecognizer: speechRecognizer)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isCapturing)
            .animation(.easeInOut(duration: 0.22), value: speechRecognizer.isAuthorized)
            .animation(.easeInOut(duration: 0.22), value: speechRecognizer.captureFeedbackMessage)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsHomeView(userProfile: userProfile)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showsReflection) {
            ReflectionLiveSessionView(
                userProfile: userProfile,
                backend: reflectionBackend,
                onViewBiography: { showsReflection = false }
            )
            .environment(\.reflectionDismiss) { showsReflection = false }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            today = Date()
        }
    }

    private var captureOverlay: some View {
        // The glow rises from the bottom edge of the screen with your voice
        // and settles back when you pause. It samples the level every frame,
        // so speech doesn't re-render this view.
        VoiceGlow(
            type: .mobile,
            levelProvider: { [speechRecognizer] in
                speechRecognizer.isRecording ? speechRecognizer.voiceGlowLevel : 0
            },
            active: speechRecognizer.isAuthorized,
            colorVariant: .mono,
            cornerRadius: Self.displayCornerRadius,
            options: Self.voiceGlowOptions
        ) {
            LoreTheme.canvas
                .opacity(0.96)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("voiceCaptureOverlay")
    }

    /// Close to the corner radius of current iPhone displays, so the glow
    /// follows the screen's own curve into the corners.
    private static let displayCornerRadius: Double = 55

    private static let voiceGlowOptions: VoiceGlowOptions = {
        var options = VoiceGlowOptions()
        // Our level is already gated against room noise, so rise quickly
        // with the first syllable and ease down over a natural pause.
        options.attack = 0.16
        options.release = 0.75
        options.threshold = 0.01
        // A faint breath while silent, so the screen still reads as listening.
        options.idle = 0.14
        return options
    }()

    @ViewBuilder
    private var captureFeedback: some View {
        if let message = speechRecognizer.captureFeedbackMessage {
            supportMessage(message, color: LoreTheme.attention)
        } else if !speechRecognizer.isAuthorized {
            supportMessage("Microphone access is needed to record.", color: LoreTheme.secondaryInk)
        }
    }

    private func supportMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(LoreTheme.raisedSurface))
            .overlay(Capsule().strokeBorder(LoreTheme.hairline))
            .padding(.horizontal, 28)
            .transition(.opacity)
            .accessibilityIdentifier("recordingSupportMessage")
    }

    /// Camera-style capture row: the record button is the one large control,
    /// centered, with two equal secondary buttons mirrored on either side.
    private func captureBar(width: CGFloat) -> some View {
        let todayKey = JournalCalendar().dayKey(for: today)
        return HStack(alignment: .center, spacing: 0) {
            TodayCaptureButton(dayKey: todayKey) {
                path.append(JournalRoute.day(todayKey))
            }
            .frame(maxWidth: .infinity)

            VoiceCaptureButton(
                containerWidth: width,
                isAvailable: speechRecognizer.isAuthorized,
                isRecording: speechRecognizer.isRecording,
                isProcessing: speechRecognizer.isAwaitingRemoteTranscription,
                action: speechRecognizer.toggleRecording
            )

            CaptureSideButton(title: "Talk") {
                showsReflection = true
            } icon: {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LoreTheme.ink)
            }
            .accessibilityLabel("Talk with Lore")
            .accessibilityHint("Starts a spoken reflection")
            .accessibilityIdentifier("reflectButton")
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        // Side controls step aside while recording so only the record button
        // remains, matching the full-screen capture overlay.
        .modifier(CaptureSideVisibility(isCapturing: isCapturing))
    }

    /// Fades the calendar out beneath the floating capture bar.
    private var captureBarScrim: some View {
        // Fully opaque from just above the support message down, so the
        // banner and controls never sit on top of tiles or text.
        LinearGradient(
            stops: [
                .init(color: LoreTheme.canvas.opacity(0), location: 0),
                .init(color: LoreTheme.canvas, location: showsSupportMessage ? 0.3 : 0.5),
                .init(color: LoreTheme.canvas, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: showsSupportMessage ? 250 : 160)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The scrolling calendar. Kept separate from `JournalHomeView` and compared by
/// value so high-frequency audio level updates don't rebuild hundreds of tiles.
private struct JournalCalendarContent: View, Equatable {
    let stories: [Story]
    let dailyEntries: [DailyBiographyEntry]
    let storyDayKeys: [UUID: String]
    let today: Date
    let hasTranscripts: Bool
    let openSettings: () -> Void

    @Query private var photos: [DayPhoto]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stories == rhs.stories
            && lhs.dailyEntries == rhs.dailyEntries
            && lhs.storyDayKeys == rhs.storyDayKeys
            && lhs.today == rhs.today
            && lhs.hasTranscripts == rhs.hasTranscripts
    }

    private let journalCalendar = JournalCalendar()

    var body: some View {
        let content = JournalDayContent.index(
            stories: stories,
            dailyEntries: dailyEntries,
            storyDayKeys: storyDayKeys,
            calendar: journalCalendar
        )
        let photosByDay = Dictionary(photos.map { ($0.dayKey, $0) }, uniquingKeysWith: { newest, older in
            newest.updatedAt >= older.updatedAt ? newest : older
        })
        ZoomableJournal(
            model: JournalCalendarModel(
                calendar: journalCalendar,
                today: today,
                content: content,
                photos: photosByDay
            ),
            hasTranscripts: hasTranscripts,
            openSettings: openSettings
        )
    }
}

/// Owns the continuous pinch zoom. Lives below `JournalCalendarContent` so a
/// pinch re-renders only the visible rows, not the day index.
private struct ZoomableJournal: View {
    let model: JournalCalendarModel
    let hasTranscripts: Bool
    let openSettings: () -> Void

    static let densityKey = "journalDensity"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(densityKey) private var storedDensity = JournalDensity.week.rawValue
    @State private var zoom: Double
    @State private var layout: JournalLayout
    @State private var pinchBase: JournalDensity?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var anchorDayKey: String?
    @State private var heroDayKey: String?

    init(model: JournalCalendarModel, hasTranscripts: Bool, openSettings: @escaping () -> Void) {
        self.model = model
        self.hasTranscripts = hasTranscripts
        self.openSettings = openSettings
        let stored = UserDefaults.standard.object(forKey: Self.densityKey) as? Int
        let density = stored.flatMap(JournalDensity.init(rawValue:)) ?? .week
        _zoom = State(initialValue: density.zoom)
        _layout = State(initialValue: density.layout)
    }

    private var density: JournalDensity { JournalZoom.nearestLevel(zoom) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                JournalHeader(model: model, layout: layout, hasTranscripts: hasTranscripts, openSettings: openSettings)
                    .padding(.top, 8)
                    .id(JournalScrollID.top)

                JournalDensityPicker(layout: layout, density: density, select: settle(on:))
                    .padding(.top, 18)
                    .padding(.bottom, 26)

                switch layout {
                case .month:
                    monthContent
                case .week:
                    weekContent
                case .days:
                    dayContent
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visibleIDs in
            // Freeze the anchor while pinching so the gesture's own scrolling
            // can't move it.
            guard pinchBase == nil else { return }
            anchorDayKey = JournalScrollID.anchorDayKey(
                visibleIDs: visibleIDs,
                previous: anchorDayKey,
                calendar: model.calendar
            )
        }
        .simultaneousGesture(pinch)
        .sensoryFeedback(.selection, trigger: density)
    }

    // MARK: Pinch

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                let base = pinchBase ?? density
                if pinchBase == nil { pinchBase = base }
                let newZoom = JournalZoom.zoom(base: base.zoom, magnification: value.magnification)
                let newLayout = JournalZoom.layout(at: newZoom)
                zoom = newZoom
                if newLayout != layout {
                    withAnimation(layoutAnimation) {
                        layout = newLayout
                        keepAnchorInView(in: newLayout)
                    }
                } else if newLayout == .days {
                    keepAnchorInView(in: .days)
                }
            }
            .onEnded { _ in
                let target = JournalZoom.snapTarget(base: pinchBase ?? density, zoom: zoom)
                pinchBase = nil
                settle(on: target)
            }
    }

    private var layoutAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private func settle(on target: JournalDensity) {
        storedDensity = target.rawValue
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.84)) {
            zoom = target.zoom
            layout = target.layout
            keepAnchorInView(in: target.layout)
        }
    }

    /// Pins the day being read to the top while rows above it change height
    /// or the layout changes. Does nothing while the header is on screen.
    private func keepAnchorInView(in layout: JournalLayout) {
        guard let anchorDayKey else { return }
        scrollPosition.scrollTo(
            id: JournalScrollID.target(
                for: anchorDayKey,
                in: layout,
                dayRowKeys: model.dayRowKeys,
                calendar: model.calendar
            ),
            anchor: .top
        )
    }

    /// A small breathing scale on grid rows while a pinch is in progress, so
    /// month and week respond before the layout switches.
    private var liveScale: CGFloat {
        guard pinchBase != nil, !reduceMotion, layout != .days else { return 1 }
        let center = layout == .month ? JournalDensity.month.zoom : JournalDensity.week.zoom
        return 1 + CGFloat(min(max(zoom - center, -0.5), 0.5)) * 0.08
    }

    private var layoutTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    // MARK: Week

    @ViewBuilder
    private var weekContent: some View {
        let currentWeek = model.calendar.week(containing: model.today)

        Group {
            if model.isEmpty {
                JournalEmptyState()
            } else {
                let cards = model.photoCards(for: currentWeek)
                if cards.isEmpty {
                    Text("No photos this week yet. Open a day to give it one.")
                        .font(LoreTheme.caption(.body))
                        .foregroundStyle(LoreTheme.tertiaryInk)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                } else {
                    FannedPhotoStack(cards: cards)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.bottom, 18)
        .id(JournalScrollID.hero)
        .transition(layoutTransition)

        WeekStrip(week: currentWeek, model: model, rowIndex: 0)
            .scaleEffect(liveScale)
            .padding(.bottom, 34)
            .id(JournalScrollID.week(currentWeek))
            .transition(layoutTransition)

        ForEach(model.pastWeekItems) { item in
            Group {
                switch item {
                case let .monthHeader(title, _):
                    Text(title)
                        .font(LoreTheme.title(.title2))
                        .foregroundStyle(LoreTheme.ink)
                        .padding(.bottom, 16)
                        .accessibilityAddTraits(.isHeader)
                case let .week(week, offset, _):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Week \(week.weekNumber)")
                                .font(LoreTheme.label)
                                .foregroundStyle(LoreTheme.ink)
                            Text(model.calendar.rangeLabel(for: week))
                                .font(LoreTheme.label.weight(.regular))
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        }
                        .accessibilityElement(children: .combine)
                        WeekStrip(week: week, model: model, rowIndex: offset + 1)
                            .scaleEffect(liveScale)
                    }
                    .padding(.bottom, item.isLastInSection ? 30 : 16)
                }
            }
            .transition(layoutTransition)
        }
    }

    // MARK: Month

    @ViewBuilder
    private var monthContent: some View {
        ForEach(model.monthItems) { item in
            MonthGrid(month: item.month, model: model, rowIndex: item.index)
                .scaleEffect(liveScale)
                .padding(.bottom, 34)
                .transition(layoutTransition)
        }
    }

    // MARK: Days

    @ViewBuilder
    private var dayContent: some View {
        let heroKey = heroDayKey ?? model.dayRowKeys.first ?? model.todayKey

        DayHeroCard(model: model, dayKey: heroKey) { heroDayKey = $0 }
            .padding(.bottom, 20)
            .id(JournalScrollID.hero)
            .transition(layoutTransition)

        if model.dayRowKeys.isEmpty {
            Text("Days you record will gather here. Pinch out to read more of each one.")
                .font(LoreTheme.caption(.body))
                .foregroundStyle(LoreTheme.tertiaryInk)
                .padding(.vertical, 24)
                .transition(layoutTransition)
        }

        ForEach(model.dayRows) { row in
            DayListRow(
                day: row.day,
                content: model.content[row.day.dayKey],
                photo: model.photos[row.day.dayKey],
                zoom: zoom
            )
            .transition(layoutTransition)
        }
    }
}

private struct JournalEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your story starts today.")
                .font(LoreTheme.display(34))
                .foregroundStyle(LoreTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap the button below and tell Lore about your day. It becomes a page of your life.")
                .font(LoreTheme.caption(.body))
                .foregroundStyle(LoreTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 24)
        .accessibilityIdentifier("journalEmptyState")
    }
}

/// Precomputed lookups for the calendar, built once per data change so a
/// pinch never recomputes them.
private struct JournalCalendarModel {
    let calendar: JournalCalendar
    let today: Date
    let todayKey: String
    let content: [String: JournalDayContent]
    let photos: [String: DayPhoto]
    /// Days with notes, an entry, or a photo, newest first, up to today.
    let dayRowKeys: [String]
    let dayRows: [DayRowItem]
    let pastWeekItems: [WeekListItem]
    let monthItems: [MonthItem]

    init(calendar: JournalCalendar, today: Date, content: [String: JournalDayContent], photos: [String: DayPhoto]) {
        self.calendar = calendar
        self.today = today
        self.content = content
        self.photos = photos
        let todayKey = calendar.dayKey(for: today)
        self.todayKey = todayKey

        let keys = Set(content.keys).union(photos.keys)
        let earliest = keys.compactMap(calendar.date(forDayKey:)).min() ?? today

        dayRowKeys = keys.filter { $0 <= todayKey }.sorted(by: >)
        dayRows = dayRowKeys.compactMap { key in
            calendar.date(forDayKey: key).map { DayRowItem(day: JournalDay(dayKey: key, date: $0)) }
        }

        var items: [WeekListItem] = []
        var currentTitle: String?
        let weeks = calendar.weeks(from: earliest, through: today).dropFirst()
        for (offset, week) in weeks.enumerated() {
            // A week belongs to the month holding most of its days.
            let title = calendar.monthTitle(for: week.days[min(3, week.days.count - 1)].date)
            if title != currentTitle {
                if case let .week(previous, previousOffset, _)? = items.last {
                    items[items.count - 1] = .week(previous, previousOffset, isLastInSection: true)
                }
                items.append(.monthHeader(title, firstWeekID: week.id))
                currentTitle = title
            }
            items.append(.week(week, offset, isLastInSection: false))
        }
        if case let .week(last, lastOffset, _)? = items.last {
            items[items.count - 1] = .week(last, lastOffset, isLastInSection: true)
        }
        pastWeekItems = items

        monthItems = calendar.months(from: earliest, through: today).enumerated().map {
            MonthItem(month: $0.element, index: $0.offset)
        }
    }

    var isEmpty: Bool { content.isEmpty && photos.isEmpty }

    func photoCards(for week: JournalWeek) -> [FannedPhotoStack.Card] {
        week.days.compactMap { day in
            guard let photo = photos[day.dayKey] else { return nil }
            let caption = content[day.dayKey]?.title
                ?? day.date.formatted(.dateTime.weekday(.wide))
            return FannedPhotoStack.Card(day: day, photo: photo, caption: caption)
        }
        .suffix(5)
    }

    func state(for day: JournalDay) -> DayTileState {
        let dayContent = content[day.dayKey]
        return DayTileState(
            day: day,
            photo: photos[day.dayKey],
            hasEntry: dayContent?.hasEntry ?? false,
            hasNotes: dayContent?.hasNotes ?? false,
            isToday: day.dayKey == todayKey,
            isFuture: day.dayKey > todayKey
        )
    }
}

/// Rows of the week list. Ids double as scroll targets.
private enum WeekListItem: Identifiable {
    case monthHeader(String, firstWeekID: String)
    case week(JournalWeek, Int, isLastInSection: Bool)

    var id: String {
        switch self {
        case let .monthHeader(_, firstWeekID): "weekSection-\(firstWeekID)"
        case let .week(week, _, _): JournalScrollID.week(week)
        }
    }

    var isLastInSection: Bool {
        if case let .week(_, _, isLast) = self { return isLast }
        return false
    }
}

private struct MonthItem: Identifiable {
    let month: JournalMonth
    let index: Int

    var id: String { JournalScrollID.month(month) }
}

private struct DayRowItem: Identifiable {
    let day: JournalDay

    var id: String { JournalScrollID.day(day.dayKey) }
}

private struct DayTileState {
    let day: JournalDay
    let photo: DayPhoto?
    let hasEntry: Bool
    let hasNotes: Bool
    let isToday: Bool
    let isFuture: Bool

    var hasContent: Bool { hasEntry || hasNotes }

    var accessibilityLabel: String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        if isToday { parts.append("today") }
        if hasEntry {
            parts.append("has entry")
        } else if hasNotes {
            parts.append("has voice notes")
        }
        if photo != nil { parts.append("has photo") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Header

private struct JournalHeader: View {
    let model: JournalCalendarModel
    let layout: JournalLayout
    let hasTranscripts: Bool
    let openSettings: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    private var title: String {
        switch layout {
        case .week:
            "Week \(model.calendar.weekNumber(for: model.today))"
        case .month:
            model.today.formatted(.dateTime.month(.wide))
        case .days:
            "Days"
        }
    }

    private var subtitle: String {
        switch layout {
        case .week:
            model.calendar.rangeLabel(for: model.calendar.week(containing: model.today))
        case .month:
            model.today.formatted(.dateTime.year())
        case .days:
            model.dayRowKeys.count == 1 ? "1 day kept" : "\(model.dayRowKeys.count) days kept"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LoreTheme.display(min(titleSize, 64)))
                    .foregroundStyle(LoreTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("journalHeaderTitle")
                Text(subtitle)
                    .font(LoreTheme.caption(.subheadline))
                    .foregroundStyle(LoreTheme.secondaryInk)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if hasTranscripts {
                    NavigationLink(value: JournalRoute.transcripts) {
                        CircleIcon(systemImage: "quote.bubble")
                    }
                    .accessibilityLabel("Source transcripts")
                    .accessibilityIdentifier("sourceTranscriptsButton")
                }

                Button(action: openSettings) {
                    CircleIcon(systemImage: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }
            .padding(.top, 8)
        }
    }
}

private struct CircleIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LoreTheme.ink)
            .frame(width: 40, height: 40)
            .background(Circle().fill(LoreTheme.surface))
            .overlay(Circle().strokeBorder(LoreTheme.hairline))
            .contentShape(Circle())
    }
}

/// Monochrome capsule control that mirrors the pinch level live, and the
/// non-gesture way to change it: tap a segment, or swipe up/down in
/// VoiceOver to step through every density.
private struct JournalDensityPicker: View {
    let layout: JournalLayout
    let density: JournalDensity
    let select: (JournalDensity) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(JournalLayout.allCases, id: \.self) { option in
                let isSelected = option == layout
                Button {
                    guard !isSelected else { return }
                    select(option.defaultDensity)
                } label: {
                    Text(option.title)
                        .font(LoreTheme.label)
                        .foregroundStyle(isSelected ? Color.black : LoreTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(LoreTheme.ink)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(LoreTheme.surface))
        .overlay(Capsule().strokeBorder(LoreTheme.hairline))
        .frame(maxWidth: 270)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Detail")
        .accessibilityValue(density.accessibilityName)
        .accessibilityHint("Pinch the calendar, or swipe up or down, to show more or less of each day.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if let next = JournalDensity(rawValue: density.rawValue + 1) { select(next) }
            case .decrement:
                if let previous = JournalDensity(rawValue: density.rawValue - 1) { select(previous) }
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("calendarModePicker")
    }
}

// MARK: - Week

private struct WeekStrip: View {
    let week: JournalWeek
    let model: JournalCalendarModel
    let rowIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
                DayTileLink(state: model.state(for: day)) {
                    WeekDayTile(state: model.state(for: day))
                }
                .staggeredAppearance(index: min(rowIndex, 4) * 3 + index)
            }
        }
    }
}

/// Wraps a tile in navigation when its day can be opened.
private struct DayTileLink<Label: View>: View {
    let state: DayTileState
    @ViewBuilder let label: () -> Label

    var body: some View {
        Group {
            if state.isFuture {
                label()
            } else {
                NavigationLink(value: JournalRoute.day(state.day.dayKey)) {
                    label()
                }
                .buttonStyle(DayTileButtonStyle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(state.isFuture ? [] : .isButton)
        .accessibilityIdentifier("dayTile_\(state.day.dayKey)")
    }
}

private struct DayTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

private struct WeekDayTile: View {
    let state: DayTileState

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
    }

    var body: some View {
        Color.clear
            .aspectRatio(64.0 / 88.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let photo = state.photo {
                    DayPhotoImage(photo: photo)
                        .overlay(alignment: .bottom) {
                            Text(state.day.date.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.bottom, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                )
                        }
                } else {
                    emptyFace
                }
            }
            .clipShape(shape)
            .overlay {
                if state.isToday {
                    shape.strokeBorder(LoreTheme.ink, lineWidth: 1.5)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var emptyFace: some View {
        let inkOpacity: Double = state.isFuture ? 0.28 : state.hasContent ? 1 : 0.55
        return ZStack {
            shape.fill(state.hasContent ? LoreTheme.raisedSurface : LoreTheme.surface)

            VStack(spacing: 1) {
                Text(state.day.date.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LoreTheme.secondaryInk)
                Text(state.day.date.formatted(.dateTime.day()))
                    .font(LoreTheme.display(22))
                    .foregroundStyle(LoreTheme.ink)
                    .minimumScaleFactor(0.7)
                Text(state.day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LoreTheme.secondaryInk)
                Circle()
                    .fill(LoreTheme.ink)
                    .frame(width: 4, height: 4)
                    .padding(.top, 3)
                    .opacity(state.hasContent ? 1 : 0)
            }
            .lineLimit(1)
            .opacity(inkOpacity)
        }
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let month: JournalMonth
    let model: JournalCalendarModel
    let rowIndex: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.calendar.monthTitle(for: month.firstDate))
                .font(LoreTheme.title(.title2))
                .foregroundStyle(LoreTheme.ink)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(model.calendar.orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LoreTheme.tertiaryInk)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(0..<month.leadingBlankCount, id: \.self) { _ in
                    Color.clear.frame(height: 1)
                }

                ForEach(Array(month.days.enumerated()), id: \.element.id) { index, day in
                    let state = model.state(for: day)
                    DayTileLink(state: state) {
                        MonthDayCell(state: state)
                    }
                    .staggeredAppearance(index: rowIndex == 0 ? index / 2 : 0)
                }
            }
        }
    }
}

private struct MonthDayCell: View {
    let state: DayTileState

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        Color.clear
            .aspectRatio(0.82, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let photo = state.photo {
                    DayPhotoImage(photo: photo)
                        .overlay(alignment: .bottomLeading) {
                            Text(state.day.date.formatted(.dateTime.day()))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 3)
                                .padding(5)
                        }
                } else {
                    ZStack {
                        shape.fill(state.hasContent ? LoreTheme.raisedSurface : LoreTheme.surface.opacity(0.6))
                        VStack(spacing: 4) {
                            Text(state.day.date.formatted(.dateTime.day()))
                                .font(.system(size: 15, weight: state.hasContent ? .bold : .regular, design: .serif))
                                .foregroundStyle(state.hasContent ? LoreTheme.ink : LoreTheme.tertiaryInk)
                            Circle()
                                .fill(LoreTheme.ink)
                                .frame(width: 4, height: 4)
                                .opacity(state.hasContent ? 1 : 0)
                        }
                        .opacity(state.isFuture ? 0.45 : 1)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                if state.isToday {
                    shape.strokeBorder(LoreTheme.ink, lineWidth: 1.5)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

// MARK: - Days

/// The selected day as a full-bleed card: photo (or a monochrome serif date),
/// the date, and the week's days as dots that switch the card.
private struct DayHeroCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: JournalCalendarModel
    let dayKey: String
    let select: (String) -> Void

    @State private var isSettled = false

    private var day: JournalDay {
        model.calendar.date(forDayKey: dayKey).map { JournalDay(dayKey: dayKey, date: $0) }
            ?? model.calendar.day(for: model.today)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        let day = day
        let photo = model.photos[day.dayKey]
        let week = model.calendar.week(containing: day.date)

        ZStack(alignment: .bottom) {
            NavigationLink(value: JournalRoute.day(day.dayKey)) {
                face(day: day, photo: photo)
            }
            .buttonStyle(DayTileButtonStyle())
            .accessibilityLabel(model.state(for: day).accessibilityLabel)
            .accessibilityHint("Opens this day")
            .accessibilityIdentifier("dayHeroCard")

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = model.content[day.dayKey]?.title {
                        Text(title)
                            .font(LoreTheme.caption(.callout))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                    }
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(LoreTheme.display(40))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                Spacer(minLength: 0)

                weekDots(week)
            }
            .padding(16)
        }
        .frame(height: 320)
        .rotationEffect(.degrees(isSettled || reduceMotion ? 0 : -4))
        .scaleEffect(isSettled || reduceMotion ? 1 : 0.94)
        .onAppear(perform: settle)
        .onChange(of: dayKey) { _, _ in
            isSettled = false
            settle()
        }
    }

    private func face(day: JournalDay, photo: DayPhoto?) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let photo {
                    DayPhotoImage(photo: photo, variant: .full)
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    ZStack {
                        LoreTheme.surface
                        Text(day.date.formatted(.dateTime.day()))
                            .font(LoreTheme.display(168))
                            .foregroundStyle(LoreTheme.ink.opacity(0.07))
                            .offset(x: 40, y: -10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
            }
            .id(day.dayKey)
            .transition(.opacity)

            Text(day.date.formatted(.dateTime.day().month(.wide).year()))
                .font(LoreTheme.label)
                .foregroundStyle(.white.opacity(0.85))
                .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.3), value: day.dayKey)
    }

    private func weekDots(_ week: JournalWeek) -> some View {
        HStack(spacing: 4) {
            ForEach(week.days) { weekDay in
                let state = model.state(for: weekDay)
                let isSelected = weekDay.dayKey == dayKey
                Button {
                    select(weekDay.dayKey)
                } label: {
                    Text(weekDay.date.formatted(.dateTime.day()))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.black : .white.opacity(state.isFuture ? 0.35 : 0.9))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(isSelected ? Color.white : .white.opacity(state.hasContent ? 0.24 : 0.1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(state.isFuture)
                .accessibilityLabel(state.accessibilityLabel)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("heroDot_\(weekDay.dayKey)")
            }
        }
        .padding(5)
        .background(Capsule().fill(.black.opacity(0.35)))
        .sensoryFeedback(.selection, trigger: dayKey)
    }

    private func settle() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.66).delay(0.04)) {
            isSettled = true
        }
    }
}

/// One day in the list. Its prose and thumbnail open continuously with
/// `zoom`: date and title at `.dayTitles`, a short preview at `.dayPreview`,
/// everything at `.dayFull`.
private struct DayListRow: View {
    let day: JournalDay
    let content: JournalDayContent?
    let photo: DayPhoto?
    let zoom: Double

    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 54
    @ScaledMetric(relativeTo: .body) private var fadeHeight: CGFloat = 22
    @State private var proseHeight: CGFloat = 0

    private var title: String {
        if let title = content?.title { return title }
        if content?.hasNotes == true { return "Voice notes, still being written" }
        return "A photo, no words yet"
    }

    private var prose: String {
        if let entry = content?.entry { return entry.prose }
        return (content?.draftStories ?? []).compactMap(\.biographyProse).joined(separator: "\n\n")
    }

    var body: some View {
        let thumbnail = photo == nil ? 0 : JournalZoom.thumbnailProgress(zoom: zoom)
        let reveal = JournalZoom.proseRevealHeight(zoom: zoom, fullHeight: proseHeight, previewHeight: previewHeight)
        let proseOpacity = prose.isEmpty ? 0 : JournalZoom.proseOpacity(zoom: zoom)

        NavigationLink(value: JournalRoute.day(day.dayKey)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14 * thumbnail) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(day.date.formatted(.dateTime.day().month(.wide)))
                                .foregroundStyle(LoreTheme.ink)
                            Text("·")
                                .foregroundStyle(LoreTheme.tertiaryInk)
                            Text(day.date.formatted(.dateTime.weekday(.wide)))
                                .foregroundStyle(LoreTheme.tertiaryInk)
                        }
                        .font(LoreTheme.label)
                        .lineLimit(1)

                        Text(title)
                            .font(LoreTheme.title(.headline))
                            .foregroundStyle(content?.title == nil ? LoreTheme.secondaryInk : LoreTheme.ink)
                            .lineLimit(1)
                            .padding(.leading, 14)

                        if !prose.isEmpty {
                            proseView(reveal: reveal)
                                .opacity(proseOpacity)
                                .padding(.top, 4 * proseOpacity)
                                .padding(.leading, 14)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let photo, thumbnail > 0 {
                        DayPhotoImage(photo: photo)
                            .frame(width: 64 * thumbnail, height: 84 * thumbnail)
                            .clipShape(RoundedRectangle(cornerRadius: 10 * thumbnail, style: .continuous))
                            .opacity(Double(thumbnail))
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 14)

                Rectangle()
                    .fill(LoreTheme.hairline)
                    .frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(showsProse: proseOpacity > 0.5))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("dayRow_\(day.dayKey)")
    }

    private func proseView(reveal: CGFloat) -> some View {
        let isPartial = reveal < proseHeight - 1
        let fade = min(1, fadeHeight / max(reveal, 1))
        return Text(prose)
            .font(LoreTheme.body)
            .foregroundStyle(LoreTheme.ink.opacity(0.78))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { proseHeight = $0 }
            .frame(height: reveal, alignment: .top)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: isPartial ? 1 - fade : 1),
                        .init(color: isPartial ? .clear : .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private func accessibilityLabel(showsProse: Bool) -> String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)), title]
        if showsProse, !prose.isEmpty { parts.append(prose) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Motion

private struct StaggeredAppearance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.92)
            .onAppear {
                guard !isVisible else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(min(index, 20)) * 0.025)) {
                    isVisible = true
                }
            }
    }
}

private extension View {
    func staggeredAppearance(index: Int) -> some View {
        modifier(StaggeredAppearance(index: index))
    }
}

#Preview("Journal home") {
    JournalHomeView(
        userProfile: UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994),
        speechRecognizer: SpeechRecognitionViewModel(),
        reflectionBackend: LoreRemoteServices.configuredForCurrentBuild().reflectionBackend
    )
    .modelContainer(LoreModelContainer.preview)
    .environmentObject(CloudArchiveStatusMonitor(startsImmediately: false))
}

/// Hides the secondary capture buttons while a voice note is recording or
/// processing, leaving only the record control.
private struct CaptureSideVisibility: ViewModifier {
    let isCapturing: Bool

    func body(content: Content) -> some View {
        content.environment(\.captureSideButtonsHidden, isCapturing)
    }
}

private struct CaptureSideButtonsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var captureSideButtonsHidden: Bool {
        get { self[CaptureSideButtonsHiddenKey.self] }
        set { self[CaptureSideButtonsHiddenKey.self] = newValue }
    }
}

/// A 52pt circular secondary control with a small caption beneath. The
/// caption is an overlay so the circle, not the circle plus label, is what
/// centers against the record button.
private struct CaptureSideButton<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @Environment(\.captureSideButtonsHidden) private var isHidden

    static var diameter: CGFloat { 52 }

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(LoreTheme.raisedSurface))
                .overlay(Circle().strokeBorder(LoreTheme.hairline))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CaptureSideButtonStyle())
        .overlay(alignment: .bottom) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LoreTheme.secondaryInk)
                .lineLimit(1)
                .fixedSize()
                .offset(y: 18)
                .accessibilityHidden(true)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .opacity(isHidden ? 0 : 1)
        .scaleEffect(isHidden ? 0.85 : 1)
        .disabled(isHidden)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isHidden)
    }
}

private struct CaptureSideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Opens today's journal page; shows today's photo when there is one, or the
/// day number otherwise.
private struct TodayCaptureButton: View {
    let dayKey: String
    let action: () -> Void
    @Query private var photos: [DayPhoto]

    init(dayKey: String, action: @escaping () -> Void) {
        self.dayKey = dayKey
        self.action = action
        _photos = Query(
            filter: #Predicate<DayPhoto> { $0.dayKey == dayKey },
            sort: \DayPhoto.updatedAt,
            order: .reverse
        )
    }

    var body: some View {
        CaptureSideButton(title: "Today", action: action) {
            if let photo = photos.first {
                DayPhotoImage(photo: photo)
            } else {
                Text(dayNumber)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(LoreTheme.ink)
            }
        }
        .accessibilityLabel("Open today")
        .accessibilityHint("Shows today's journal page")
        .accessibilityIdentifier("todayButton")
    }

    private var dayNumber: String {
        dayKey.split(separator: "-").last.map { String(Int($0) ?? 0) } ?? ""
    }
}
