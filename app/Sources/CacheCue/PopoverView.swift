import ServiceManagement
import SwiftUI
import CacheCueCore

// MARK: - Building blocks

/// Three capsules that fill left to right with `value` (0 to 1).
struct SegmentedProgressBar: View {
    let value: Double
    let tint: Color
    var segments = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segments, id: \.self) { index in
                GeometryReader { geometry in
                    let fill = min(max((value - Double(index) / Double(segments)) * Double(segments), 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.segmentBg)
                        Capsule()
                            .fill(LinearGradient(colors: [tint, tint.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * CGFloat(fill))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder, lineWidth: 1))
    }
}

struct IconBadge: View {
    let symbol: String
    var tint: Color = .brandAccent

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.1)).frame(width: 32, height: 32)
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundColor(tint)
        }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.rounded(8, .bold))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// A headline number over a tiny caption.
struct Figure: View {
    let value: String
    let caption: String
    var tint: Color = .primary
    var size: CGFloat = 15

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.rounded(size, .bold)).monospacedDigit().foregroundColor(tint)
            Text(caption).font(.rounded(8, .medium)).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Cards

/// The app's reason for being: is now a good moment to run /compact, and why.
struct AdviceCard: View {
    let advice: CompactAdvice
    let strings: Strings
    /// Opens the lesson that explains this advice; nil where there is none to open.
    var onWhy: (() -> Void)?
    @State private var didCopy = false

    private var tint: Color { .tone(advice.level, default: .brandAccent) }

    private var symbol: String {
        switch advice.kind {
        case .running: return "hourglass"
        case .notNeeded: return "checkmark"
        case .optional: return "arrow.triangle.branch"
        case .worthIt: return "flag.fill"
        case .beforeExpiry: return "figure.walk"
        case .cold: return "snowflake"
        case .nearFull: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(strings.adviceTitle.uppercased()).font(.rounded(8, .bold)).foregroundColor(.secondary)
                    Text(advice.headline(strings))
                        .font(.system(.subheadline, design: .rounded)).fontWeight(.bold)
                        .foregroundColor(advice.level == .plain || advice.level == .ok ? .primary : tint)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(advice.detail(strings))
                        .font(.rounded(10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
            // The command, ready to paste, only when running it is the advice.
            if advice.kind != .running && advice.kind != .notNeeded {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/compact", forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                        Text(didCopy ? strings.copied : strings.copyCompact).font(.rounded(10, .semibold))
                    }
                    .foregroundColor(tint)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            if let onWhy {
                Button(action: onWhy) {
                    HStack(spacing: 4) {
                        Image(systemName: "book").font(.system(size: 9, weight: .semibold))
                        Text(strings.why).font(.rounded(10, .semibold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            }
            .padding(.leading, 44)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [tint.opacity(0.10), Color.cardBg], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.28), lineWidth: 1))
    }
}

/// A newer release is out: says which, and hands over to the updater to install it.
struct UpdateCard: View {
    let version: String
    let strings: Strings
    let install: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundColor(.brandAccent)
                Text(String(format: strings.updateAvailable, version))
                    .font(.rounded(11, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(strings.download, action: install)
                    .buttonStyle(.plain).font(.rounded(11, .bold)).foregroundColor(.brandAccent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
            }
        }
    }
}

/// The update card, watching the updater so it appears the moment a check finds something.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    let strings: Strings

    var body: some View {
        if let version = updater.availableVersion {
            UpdateCard(version: version, strings: strings, install: updater.showUpdate)
        }
    }
}

/// The switch for Sparkle's scheduled checks.
struct UpdateSwitch: View {
    @ObservedObject var updater: Updater
    let strings: Strings

    var body: some View {
        Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })) {
            Text(strings.checkUpdates).font(.rounded(11, .semibold)).lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Shown until the terminal status line points at this app: one press sets it up.
struct SetupCard: View {
    let strings: Strings
    @State private var state = StatusLineSetup.state()
    @State private var isConfirming = false
    @State private var message: String?

    var body: some View {
        if state != .ours || message != nil {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        Text(message ?? (isConfirming ? strings.setupReplace : strings.setupTitle))
                            .font(.rounded(11, .semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    if state != .ours {
                        HStack(spacing: 8) {
                            Spacer()
                            if isConfirming {
                                Button(strings.cancel) { isConfirming = false }
                                    .buttonStyle(.plain).font(.rounded(11, .semibold)).foregroundColor(.secondary)
                            }
                            Button(strings.setupButton, action: setUp)
                                .buttonStyle(.plain).font(.rounded(11, .bold)).foregroundColor(.brandAccent)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
                        }
                    }
                }
            }
        }
    }

    private func setUp() {
        // Someone else's status line is replaced only on a second, deliberate press.
        if case .other = state, !isConfirming {
            isConfirming = true
            return
        }
        guard let executable = Bundle.main.executablePath else { return }
        do {
            try StatusLineSetup.install(executable: executable)
            message = strings.setupDone
        } catch {
            message = String(format: strings.setupFailed, error.localizedDescription)
        }
        isConfirming = false
        state = StatusLineSetup.state()
    }
}

/// One rate-limit window: how much is used and when it resets.
struct LimitCard: View {
    let title: String
    let symbol: String
    let limit: LimitView?
    let strings: Strings

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(.subheadline, design: .rounded)).fontWeight(.bold)
                        Spacer()
                        Text(limit?.resetsIn.map { strings.reset(in: $0) } ?? strings.noReading)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        SegmentedProgressBar(
                            value: (limit?.used ?? 0) / 100, tint: .tone(limit?.level ?? .plain, default: .secondary))
                        Figure(value: limit.map { "\($0.percent)%" } ?? "--", caption: strings.used)
                            .frame(minWidth: 34)
                    }
                }
            }
        }
    }
}

/// The session that last did something: its cache, its context window, its cost.
struct SessionCard: View {
    let session: SessionView
    let strings: Strings
    /// On a subscription the dollars are a value at API prices, not what is billed.
    var isSubscription = false
    /// Set when the person chose this session; pressing it goes back to following the latest.
    var unpin: (() -> Void)?

    private var cacheTint: Color {
        switch session.cache {
        case .unknown: return .secondary
        case .active: return .tone(.ok)
        case .expires: return .tone(session.cache.level, default: .tone(.ok))
        case .expired: return .tone(.crit)
        }
    }

    private var cacheCaption: String {
        switch session.cache {
        case .unknown: return strings.cacheUnknown
        case .active: return strings.cacheActive
        case .expires: return strings.cacheExpiresCaption
        case .expired: return strings.cacheExpired
        }
    }

    private var cacheHeadline: String {
        switch session.cache {
        case .unknown: return "--:--"
        case .active: return "LIVE"
        case .expires(let left): return Format.countdown(left)
        case .expired: return "00:00"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(symbol: session.source == "terminal" ? "terminal.fill" : "macwindow")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(.subheadline, design: .rounded)).fontWeight(.bold)
                            .lineLimit(1).truncationMode(.middle)
                        Text(unpin == nil ? strings.currentSession : strings.pinned)
                            .font(.system(.caption2, design: .rounded)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let unpin {
                        Button(action: unpin) {
                            HStack(spacing: 3) {
                                Image(systemName: "pin.slash.fill").font(.system(size: 8))
                                Text(strings.followLatest).font(.rounded(8, .bold)).lineLimit(1)
                            }
                            .foregroundColor(.tone(.warn))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tone(.warn).opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                    Pill(text: strings.source(session.source), tint: .brandAccent)
                }

                // Cache: the hour running down.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(cacheTint)
                        Text(cacheHeadline).font(.rounded(20, .bold)).monospacedDigit()
                            .foregroundColor(session.cache == .unknown ? .secondary : .primary)
                        Text(cacheCaption).font(.rounded(10, .medium)).foregroundColor(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                    SegmentedProgressBar(value: session.cache.remainingFraction, tint: cacheTint)
                }

                HStack(spacing: 0) {
                    Figure(
                        value: session.turnHit.map { "\($0)%" } ?? "--", caption: strings.turnHit,
                        tint: session.turnHit.map { .tone(Format.hitLevel($0)) } ?? .secondary)
                        .frame(maxWidth: .infinity)
                    Divider().frame(height: 22)
                    Figure(
                        value: session.avgHit.map { "\($0)%" } ?? "--", caption: strings.avgHit,
                        tint: session.avgHit.map { .tone(Format.hitLevel($0)) } ?? .secondary)
                        .frame(maxWidth: .infinity)
                    Divider().frame(height: 22)
                    Figure(value: session.costUSD.map { String(format: "$%.2f", $0) } ?? "--", caption: isSubscription ? strings.costEquivalent : strings.cost)
                        .frame(maxWidth: .infinity)
                }

                // Context window.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(strings.context).font(.rounded(10, .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Format.tokens(session.contextTokens)) / \(Format.tokens(session.contextWindow))")
                            .font(.rounded(10, .semibold)).monospacedDigit()
                        if let percent = session.contextPercent {
                            Text("\(Int(percent.rounded()))%").font(.rounded(10, .bold)).monospacedDigit()
                                .foregroundColor(.tone(Format.level(percent, warn: 60, crit: 85)))
                        }
                    }
                    SegmentedProgressBar(
                        value: (session.contextPercent ?? 0) / 100,
                        tint: .tone(Format.level(session.contextPercent ?? 0, warn: 60, crit: 85)))
                }
            }
        }
    }
}

/// A session that is not the current one, on one line.
struct OtherSessionRow: View {
    let session: SessionView

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.source == "terminal" ? "terminal.fill" : "macwindow")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).frame(width: 14)
            Text(session.name).font(.rounded(11, .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let hit = session.turnHit {
                Text("\(hit)%").font(.rounded(10, .bold)).monospacedDigit().foregroundColor(.tone(Format.hitLevel(hit)))
            }
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                Text(session.cache.shortText).font(.rounded(10, .semibold)).monospacedDigit()
            }
            .foregroundColor(.tone(session.cache.level, default: .secondary))
            .frame(minWidth: 52, alignment: .trailing)
            Text(session.costUSD.map { String(format: "$%.2f", $0) } ?? "--")
                .font(.rounded(10, .semibold)).monospacedDigit().foregroundColor(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

/// The mark that support has answered: an envelope that keeps ringing out until it is pressed.
struct ReplyBeacon: View {
    let count: Int
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "envelope.badge.fill").font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isPulsing ? 9 : -9))
            // One reply needs no number.
            if count > 1 {
                Text("\(count)").font(.rounded(9, .bold)).monospacedDigit()
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(Color.orange))
        .background(
            // A ring that spreads from the badge and fades, over and over.
            Capsule().stroke(Color.orange, lineWidth: 2)
                .scaleEffect(isPulsing ? 1.45 : 1)
                .opacity(isPulsing ? 0 : 0.8)
        )
        .scaleEffect(isPulsing ? 1.06 : 0.97)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isPulsing = true }
        }
    }
}

// MARK: - The guide

/// The list of lessons, with the ones already read ticked.
struct GuideList: View {
    let lessons: [Lesson]
    let read: Set<String>
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                Button {
                    open(lesson.id)
                } label: {
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle().fill(Color.brandAccent.opacity(read.contains(lesson.id) ? 0.10 : 0.16))
                                    .frame(width: 26, height: 26)
                                if read.contains(lesson.id) {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.brandAccent)
                                } else {
                                    Text("\(index + 1)").font(.rounded(12, .bold)).foregroundColor(.brandAccent)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.title).font(.rounded(12, .bold)).foregroundColor(.primary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Text(lesson.summary).font(.rounded(10)).foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary).padding(.top, 8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }
}

/// One lesson: its points, the takeaway, where it comes from, and the way on.
struct LessonPage: View {
    let lesson: Lesson
    let number: Int
    let count: Int
    let strings: Strings
    /// The off-screen render cannot draw a link, so it gets the label alone.
    var isPreview = false
    /// Steps to the lesson before (-1) or after (+1).
    let step: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number) / \(count)").font(.rounded(9, .bold)).foregroundColor(.brandAccent)
                Text(lesson.title).font(.system(.title3, design: .rounded)).fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(lesson.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.brandAccent.opacity(0.6)).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(point).font(.rounded(11)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(strings.takeaway.uppercased()).font(.rounded(8, .bold)).foregroundColor(.tone(.ok))
                Text(lesson.takeaway).font(.rounded(12, .bold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.tone(.ok).opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tone(.ok).opacity(0.25), lineWidth: 1))

            HStack(spacing: 8) {
                if isPreview {
                    sourceLabel.foregroundColor(.brandAccent)
                } else {
                    Link(destination: lesson.source) { sourceLabel }
                }
                Spacer(minLength: 8)
                if number > 1 {
                    navigation(strings.previous, symbol: "chevron.backward", leading: true) { step(-1) }
                }
                if number < count {
                    navigation(strings.next, symbol: "chevron.forward", leading: false) { step(1) }
                }
            }
        }
        .padding(16)
    }

    private var sourceLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.forward.square").font(.system(size: 10, weight: .semibold))
            Text(strings.readDocs).font(.rounded(10, .semibold)).lineLimit(1)
        }
    }

    private func navigation(_ title: String, symbol: String, leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if leading { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title).font(.rounded(11, .bold)).lineLimit(1)
                if !leading { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            }
            .foregroundColor(.brandAccent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The popover

/// What the popover is showing: the figures, the guide's list, or one lesson.
enum Page: Equatable {
    case dashboard
    case guide
    case lesson(String)
}

struct PopoverView: View {
    let summary: Summary
    /// The off-screen render cannot draw native controls, so it gets a painted footer.
    var isPreview = false
    /// The render's language; the app reads the person's choice from its defaults.
    var previewLanguage: Language?
    var initialPage = Page.dashboard
    /// Sparkle, in a release build; nil in the off-screen render.
    var updater: Updater?
    /// Keeps a session in view by its id; nil goes back to following the latest.
    var pin: (String?) -> Void = { _ in }
    /// The support pages' state, which outlives the popover.
    var support: SupportModel?
    /// Whether the support pages are showing; mirrors `support.isPresented`.
    var isShowingSupport = false
    /// How many tickets have a reply from support not opened yet; mirrors `support.unread`.
    var unreadReplies = 0

    @State private var page: Page?
    /// Lesson ids already opened, comma-separated.
    @AppStorage("readLessons") private var readLessons = ""

    @AppStorage(Preferences.themeKey) private var themeChoice = AppTheme.system.rawValue
    @AppStorage(Preferences.languageKey) private var languageChoice = Language.system
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var language: Language { previewLanguage ?? Language.resolve(choice: languageChoice) }
    private var strings: Strings { .of(language) }
    private var theme: AppTheme { .stored(themeChoice) }
    private var sessionCount: Int { (summary.current == nil ? 0 : 1) + summary.others.count }
    private var shown: Page { page ?? initialPage }
    private var lessons: [Lesson] { Guide.lessons(language) }
    private var read: Set<String> { Set(readLessons.split(separator: ",").map(String.init)) }

    private func open(_ id: String) {
        readLessons = read.union([id]).sorted().joined(separator: ",")
        page = .lesson(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let support, isShowingSupport {
                SupportView(model: support, strings: strings, isPreview: isPreview)
            } else {
            switch shown {
            case .dashboard:
                dashboard
                Divider()
                footer
            case .guide:
                GuideList(lessons: lessons, read: read, open: open)
            case .lesson(let id):
                if let index = lessons.firstIndex(where: { $0.id == id }) {
                    LessonPage(
                        lesson: lessons[index], number: index + 1, count: lessons.count, strings: strings,
                        isPreview: isPreview
                    ) { by in
                        open(lessons[index + by].id)
                    }
                }
            }
            }
        }
        .frame(width: 320)
        .tint(.brandAccent)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private var dashboard: some View {
        VStack(spacing: 10) {
            if let updater {
                UpdateBanner(updater: updater, strings: strings)
            }
            if let current = summary.current {
                AdviceCard(
                    advice: current.advice, strings: strings,
                    onWhy: Guide.lessonID(for: current.advice.kind).map { id in { open(id) } })
            }
            LimitCard(title: strings.fiveHourTitle, symbol: "bolt.fill", limit: summary.fiveHour, strings: strings)
            LimitCard(title: strings.sevenDayTitle, symbol: "calendar", limit: summary.sevenDay, strings: strings)
            if let current = summary.current {
                SessionCard(
                    session: current, strings: strings, isSubscription: summary.isSubscription,
                    unpin: summary.isPinned ? { pin(nil) } : nil)
            } else {
                emptyState
            }
            if !summary.others.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(strings.otherSessions).font(.rounded(10, .semibold)).foregroundColor(.secondary)
                        // Pressing a session keeps it in view.
                        ForEach(summary.others, id: \.id) { session in
                            Button {
                                pin(session.id)
                            } label: {
                                OtherSessionRow(session: session).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !isPreview {
                SetupCard(strings: strings)
            }
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark()
            if isShowingSupport {
                Text(strings.support).font(.system(.headline, design: .rounded)).lineLimit(1)
                Spacer()
                Button {
                    support?.isPresented = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward").font(.system(size: 9, weight: .bold))
                        Text(strings.back).font(.rounded(11, .semibold))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else if shown == .dashboard {
                Text("CacheCue").font(.system(.headline, design: .rounded))
                Spacer()
                Pill(
                    text: sessionCount == 0 ? strings.idle : String(format: strings.activeCount, sessionCount),
                    tint: sessionCount == 0 ? .secondary : .brandAccent)
                Button {
                    page = .guide
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "book.fill").font(.system(size: 10))
                        Text("\(read.intersection(lessons.map(\.id)).count)/\(lessons.count)").font(.rounded(9, .bold)).monospacedDigit()
                    }
                    .foregroundColor(.brandAccent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(strings.guideTitle)
                if let support, unreadReplies > 0 {
                    // Support has answered: the way into support becomes the way to that answer.
                    Button {
                        support.showUnread()
                    } label: {
                        ReplyBeacon(count: unreadReplies)
                    }
                    .buttonStyle(.plain)
                    .help(strings.supportNewReply)
                    .accessibilityLabel(strings.supportNewReply)
                } else if let support {
                    Button {
                        support.isPresented = true
                    } label: {
                        Image(systemName: "lifepreserver").font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.brandAccent)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(strings.support)
                }
            } else {
                Text(strings.guideTitle).font(.system(.headline, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Button {
                    // From a lesson back to the list, from the list back to the figures.
                    page = shown == .guide ? .dashboard : .guide
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward").font(.system(size: 9, weight: .bold))
                        Text(strings.back).font(.rounded(11, .semibold))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: "moon.zzz.fill", tint: .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(strings.emptyTitle).font(.system(.subheadline, design: .rounded)).fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(strings.emptyHint)
                        .font(.rounded(10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isPreview {
                    paintedSwitch
                    Text(strings.launchAtLogin).font(.rounded(11, .semibold)).lineLimit(1)
                } else {
                    Toggle(isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin)) {
                        Text(strings.launchAtLogin).font(.rounded(11, .semibold)).lineLimit(1)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Spacer(minLength: 8)
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        Text(strings.quit).font(.rounded(11, .semibold))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            }
            HStack(spacing: 8) {
                if isPreview {
                    languageLabel
                } else {
                    Menu {
                        languageButton(Language.system, title: strings.followSystem)
                        Divider()
                        ForEach(Language.allCases) { language in
                            languageButton(language.rawValue, title: language.nativeName)
                        }
                    } label: {
                        languageLabel
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(strings.language)
                }
                Spacer(minLength: 8)
                Button {
                    let next = theme.next
                    themeChoice = next.rawValue
                    next.apply()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: theme.symbol).font(.system(size: 12))
                        Text(theme.label(strings)).font(.rounded(11, .semibold)).lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(strings.appearance)
            }
            HStack(spacing: 8) {
                if isPreview {
                    paintedSwitch
                    Text(strings.checkUpdates).font(.rounded(11, .semibold)).lineLimit(1)
                } else if let updater, updater.canCheck {
                    UpdateSwitch(updater: updater, strings: strings)
                }
                Spacer(minLength: 8)
                // Pressing the version checks for an update there and then.
                Button {
                    updater?.showUpdate()
                } label: {
                    Text(Preferences.versionLabel).font(.rounded(10, .semibold)).monospacedDigit().foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(updater?.canCheck != true)
            }
            HStack(spacing: 8) {
                // The app is free; this only hands the tip page to the browser.
                Button {
                    NSWorkspace.shared.open(SupportAPI.coffeeURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .semibold))
                        Text(strings.buyCoffee).font(.rounded(11, .semibold)).lineLimit(1)
                    }
                    .foregroundColor(.tone(.warn))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.tone(.warn).opacity(0.12)))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
            }
            if let loginError {
                Text(loginError).font(.rounded(9)).foregroundColor(.tone(.crit)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.015))
    }

    /// The chosen language by its own name, or "System" while the system decides.
    private var languageLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe").font(.system(size: 12))
            Text(languageChoice == Language.system && previewLanguage == nil ? strings.followSystem : language.nativeName)
                .font(.rounded(11, .semibold)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(.secondary)
    }

    private func languageButton(_ choice: String, title: String) -> some View {
        Button {
            languageChoice = choice
        } label: {
            if languageChoice == choice {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var paintedSwitch: some View {
        ZStack(alignment: launchesAtLogin ? .trailing : .leading) {
            Capsule().fill(launchesAtLogin ? Color.brandAccent : Color.secondary.opacity(0.3)).frame(width: 26, height: 15)
            Circle().fill(Color.white).frame(width: 13, height: 13).padding(.horizontal, 1)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = String(format: strings.loginError, error.localizedDescription)
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
