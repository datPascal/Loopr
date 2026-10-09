import Foundation
import SwiftUI

// MARK: - Meta line

/// What the right half of the meta line says about how fresh the numbers are.
public enum LooprHeaderFreshness: Equatable, Sendable {
    /// "SYNCED 5 MIN AGO", or "SYNCING" while the band hands over data.
    /// `now` pins the clock for fixture launches; nil is the real clock.
    case sync(lastSync: Date?, now: Date? = nil)
    /// The band is streaming heart rate right now.
    case live
    /// Nothing to say.
    case hidden
}

/// The one grammar every tab header uses: `DAY PHRASE · FRESHNESS`.
public enum LooprHeaderMeta {
    /// "WED 23 SEP" on today, "YESTERDAY · WED 23 SEP", or "TUE 22 SEP".
    /// The title already names the tab, so the day lives here.
    public static func dayPhrase(_ navigation: LooprDayNavigation) -> String {
        if navigation.isToday || navigation.title == navigation.dateText {
            return navigation.dateText.uppercased()
        }
        return "\(navigation.title) · \(navigation.dateText)".uppercased()
    }

    /// Sleep's day phrase: "LAST NIGHT" on today, otherwise the night
    /// itself, "TUE 22 → WED 23 SEP".
    public static func nightPhrase(_ navigation: LooprDayNavigation) -> String {
        navigation.isToday ? "LAST NIGHT" : navigation.nightRange.uppercased()
    }

    /// The freshness words, or nil when the slot stays empty.
    public static func freshness(
        _ freshness: LooprHeaderFreshness,
        indicator: LooprBandIndicator?,
        now: Date
    ) -> Freshness? {
        switch freshness {
        case .hidden:
            return nil
        case .live:
            return Freshness(text: "LIVE", isActive: true)
        case .sync(let lastSync, let pinnedNow):
            if indicator?.link == .notPaired { return nil }
            if indicator?.link == .syncing { return Freshness(text: "SYNCING", isActive: true) }
            let newest = [lastSync, indicator?.lastSyncedAt].compactMap { $0 }.max()
            return LooprSyncAge.label(lastSync: newest, now: pinnedNow ?? now)
                .map { Freshness(text: $0.uppercased(), isActive: false) }
        }
    }

    public struct Freshness: Equatable, Sendable {
        public let text: String
        /// Drawn in the tab accent with a pulsing dot: live or syncing.
        public let isActive: Bool
    }

    /// Both halves joined, for VoiceOver and tests.
    public static func line(dayPhrase: String?, freshness: Freshness?) -> String {
        [dayPhrase, freshness?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Header content

/// The second slot of the trailing cluster.
public enum LooprHeaderControl {
    case none
    /// The compact day navigator, on the four day tabs.
    case day(LooprDayNavigation)
    /// A glass button in the same slot, such as Workouts' "+".
    case action(LooprHeaderAction)
    /// Any other view. `StickyHeader` uses it for its trailing accessory.
    case custom(AnyView)
}

public struct LooprHeaderAction {
    public let symbol: String
    public let label: String
    public let identifier: String
    public let run: @MainActor () -> Void

    public init(symbol: String, label: String, identifier: String, run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.label = label
        self.identifier = identifier
        self.run = run
    }
}

/// Everything a tab header shows. Built by the screen, drawn by
/// `LooprTabHeader`.
public struct LooprTabHeaderContent {
    public var title: String
    public var accent: LooprColorToken
    public var dayPhrase: String?
    public var freshness: LooprHeaderFreshness
    public var status: StatusChip?
    public var control: LooprHeaderControl
    /// Band state and settings action for hosts that do not put them in the
    /// environment.
    public var bandFallback: LooprBandIndicator?
    public var settingsFallback: (@MainActor () -> Void)?
    /// False for headers outside the tab roots, which have no band button.
    public var showsBandButton: Bool = true

    public init(
        title: String,
        accent: LooprColorToken,
        dayPhrase: String? = nil,
        freshness: LooprHeaderFreshness = .hidden,
        status: StatusChip? = nil,
        control: LooprHeaderControl = .none,
        bandFallback: LooprBandIndicator? = nil,
        settingsFallback: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.accent = accent
        self.dayPhrase = dayPhrase
        self.freshness = freshness
        self.status = status
        self.control = control
        self.bandFallback = bandFallback
        self.settingsFallback = settingsFallback
    }
}

// MARK: - Collapse state

/// How far the header has collapsed, 0 to 1. Only the header reads it, so a
/// scroll re-renders the header and not the screen under it.
@MainActor @Observable
public final class LooprHeaderCollapse {
    public internal(set) var progress: CGFloat = 0
    public init() {}

    func apply(_ reading: LooprHeaderScrollReading) {
        if progress != reading.progress { progress = reading.progress }
    }
}

struct LooprHeaderScrollReading: Equatable {
    let progress: CGFloat

    init(geometry: ScrollGeometry) {
        let travelled = geometry.contentOffset.y + geometry.contentInsets.top
        let raw = travelled / LooprSpacing.headerCollapseDistance
        // Rounded to a hundredth so a scroll deep in the page, or a sub-point
        // wobble, does not count as a change.
        progress = (min(max(raw, 0), 1) * 100).rounded() / 100
    }
}

/// Where a scroll that came to rest inside the collapse range should settle,
/// as a change to the content offset, or nil when it already rests outside
/// the range. Past the middle settles collapsed.
enum LooprHeaderSnap {
    static func adjustment(travelled: CGFloat, distance: CGFloat = LooprSpacing.headerCollapseDistance) -> CGFloat? {
        guard travelled > 0.5, travelled < distance - 0.5 else { return nil }
        return (travelled > distance / 2 ? distance : 0) - travelled
    }
}

// MARK: - Scaffold

/// A tab root: the shared header over a scroll view, the tab's glow behind
/// both, and pull to refresh when the app provides it.
///
/// The header sits in the scroll view's top safe area, so content scrolls
/// under its material. Scrolling collapses it continuously over the first
/// 44 pt and the scroll always comes to rest expanded or collapsed.
public struct LooprTabScaffold<Content: View>: View {
    @Environment(\.looprRefresh) private var refresh
    @Environment(\.looprHeaderUsesNavigationBar) private var usesNavigationBar
    @State private var collapse = LooprHeaderCollapse()
    @State private var position = ScrollPosition()
    @Environment(\.looprTabScrollRequest) private var homeScrollRequest
    @State private var finishedRefreshes = 0

    private let header: LooprTabHeaderContent
    private let glow: LooprColorToken?
    private let identifier: String
    private let content: Content

    /// - Parameters:
    ///   - glow: The tint of the ambient glow. Nil keeps the last tint, for
    ///     a tab that is loading its next day.
    ///   - identifier: The accessibility identifier of the scroll view.
    public init(
        header: LooprTabHeaderContent,
        glow: LooprColorToken?,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.glow = glow
        self.identifier = identifier
        self.content = content()
    }

    public var body: some View {
        if usesNavigationBar {
            // Pushed onto another tab's stack: the header moves into the
            // system bar beside the back button.
            scrollView
                .background { LooprAmbientBackground(tint: glow, fallback: header.accent) }
                .overlay(alignment: .top) {
                    StickyHeader(title: header.title, meta: header.dayPhrase ?? "", status: header.status) {
                        LooprHeaderControlView(control: header.control, accent: header.accent)
                    }
                }
                .sensoryFeedback(.success, trigger: finishedRefreshes)
        } else {
            scrollView
                .safeAreaInset(edge: .top, spacing: 0) {
                    LooprTabHeader(header, collapse: collapse)
                }
                .background { LooprAmbientBackground(tint: glow, fallback: header.accent) }
                .sensoryFeedback(.success, trigger: finishedRefreshes)
        }
    }

    @ViewBuilder
    private var scrollView: some View {
        let scroll = ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .scrollPosition($position)
        .onChange(of: homeScrollRequest) { _, request in
            guard request != nil else { return }
            position.scrollTo(edge: .top)
        }
        .onScrollPhaseChange { _, phase, context in
            // A scroll never rests with the header half collapsed.
            guard phase == .idle, !usesNavigationBar else { return }
            let geometry = context.geometry
            guard let delta = LooprHeaderSnap.adjustment(
                travelled: geometry.contentOffset.y + geometry.contentInsets.top
            ) else { return }
            withAnimation(LooprMotion.headerCollapse) {
                position.scrollTo(y: geometry.contentOffset.y + delta)
            }
        }
        .onScrollGeometryChange(for: LooprHeaderScrollReading.self) { geometry in
            LooprHeaderScrollReading(geometry: geometry)
        } action: { _, reading in
            collapse.apply(reading)
        }
        .accessibilityIdentifier(identifier)

        if let refresh {
            scroll.refreshable {
                await refresh.run()
                finishedRefreshes += 1
            }
        } else {
            scroll
        }
    }
}

// MARK: - Header

/// The header every tab shares:
///
/// ```
/// [Title]                         [chip?] [day control] [band]
/// [DAY PHRASE · FRESHNESS]
/// ```
///
/// Collapsing scales the title to 80 %, fades the meta line, and fades in a
/// material bar with a hairline. With Reduce Motion only the fades run. At
/// accessibility text sizes the chip and the day control drop to a second
/// row inside the same bar.
public struct LooprTabHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let content: LooprTabHeaderContent
    private let collapse: LooprHeaderCollapse?
    private let showsBar: Bool

    /// - Parameters:
    ///   - collapse: Scroll-driven collapse. Nil keeps the header expanded.
    ///   - showsBar: Without `collapse`, whether the material bar is drawn.
    public init(_ content: LooprTabHeaderContent, collapse: LooprHeaderCollapse? = nil, showsBar: Bool = false) {
        self.content = content
        self.collapse = collapse
        self.showsBar = showsBar
    }

    public var body: some View {
        let progress = collapse?.progress ?? 0
        let barProgress = collapse == nil ? (showsBar ? 1 : 0) : progress
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        let isLarge = dynamicTypeSize.isAccessibilitySize
        // The bar gives back the meta line's height as it collapses.
        let shrink = reduces || isLarge ? 0 : LooprSpacing.headerMetaCollapse * progress

        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                titleBlock(progress: progress, reduces: reduces, isLarge: isLarge)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: LooprSpacing.headerClusterSpacing) {
                    if !isLarge {
                        chip
                        control
                    }
                    band
                }
                .offset(y: -shrink / 2)
            }
            if isLarge, content.status != nil || hasControl {
                HStack(spacing: LooprSpacing.headerClusterSpacing) {
                    chip
                    Spacer(minLength: 0)
                    control
                }
            }
        }
        .padding(.horizontal, LooprSpacing.headerHorizontal)
        .padding(.vertical, LooprSpacing.headerVertical)
        .background(alignment: .top) {
            LooprHeaderBar(progress: barProgress)
                .padding(.bottom, shrink)
                .animation(collapse == nil ? .easeOut(duration: LooprMotion.fast) : nil, value: barProgress)
                .ignoresSafeArea(.container, edges: .top)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    private func titleBlock(progress: CGFloat, reduces: Bool, isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            Text(content.title)
                .looprTypography(.screenTitle)
                .foregroundStyle(Color.loopr(.ink))
                .lineLimit(isLarge ? 2 : 1)
                .minimumScaleFactor(0.7)
                // Scaled about its leading edge, so it stays where it is
                // while the bar shrinks around it.
                .scaleEffect(reduces || isLarge ? 1 : 1 - 0.2 * progress, anchor: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tab-header-title")
            LooprHeaderMetaLine(
                dayPhrase: content.dayPhrase,
                freshness: content.freshness,
                accent: content.accent,
                stacked: isLarge
            )
            // At accessibility sizes the meta line is several rows tall; it
            // stays, so the collapsed bar is never a tall empty band.
            .opacity(isLarge ? 1 : Double(max(0, 1 - progress * 1.6)))
            .offset(y: reduces || isLarge ? 0 : -4 * progress)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var chip: some View {
        if let status = content.status {
            status
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var hasControl: Bool {
        if case .none = content.control { return false }
        return true
    }

    private var control: some View {
        LooprHeaderControlView(control: content.control, accent: content.accent)
    }

    @ViewBuilder
    private var band: some View {
        if content.showsBandButton {
            bandButton
        }
    }

    private var bandButton: some View {
        LooprBandButton(
            accent: content.accent,
            fallbackIndicator: content.bandFallback,
            fallbackAction: content.settingsFallback
        )
    }
}

/// The second slot of the trailing cluster: the day navigator, a glass
/// action, or a custom view.
struct LooprHeaderControlView: View {
    let control: LooprHeaderControl
    let accent: LooprColorToken

    var body: some View {
        switch control {
        case .none:
            EmptyView()
        case .day(let navigation):
            LooprDayNavigator(navigation, accent: accent)
        case .custom(let view):
            view
        case .action(let action):
            Button(action: action.run) {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.loopr(.ink))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            // The same slot as the band button, so the row keeps its height.
            .frame(width: LooprBandButton.diameter, height: LooprBandButton.diameter)
            .accessibilityLabel(action.label)
            .accessibilityIdentifier(action.identifier)
        }
    }
}

/// The material that fades in behind the header as it collapses.
private struct LooprHeaderBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let progress: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            if reduceTransparency {
                Color.loopr(.background)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.loopr(.background).opacity(LooprAppearance.isDark(colorScheme) ? 0.62 : 0.58))
            }
            Rectangle()
                .fill(Color.loopr(.divider))
                .frame(height: 1)
        }
        .opacity(Double(progress))
        .allowsHitTesting(progress > 0.5)
        .accessibilityHidden(true)
    }
}

/// `DAY PHRASE · FRESHNESS` in mono caps. The freshness half reads the band
/// state and the clock itself, so a new sync age or a sync starting redraws
/// only this line. When both halves do not fit, the day phrase stays.
struct LooprHeaderMetaLine: View {
    @Environment(\.looprBandIndicator) private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let dayPhrase: String?
    let freshness: LooprHeaderFreshness
    let accent: LooprColorToken
    let stacked: Bool

    var body: some View {
        if case .hidden = freshness {
            lineContent(freshness: nil)
        } else if case .sync(_, let pinned?) = freshness {
            lineContent(freshness: LooprHeaderMeta.freshness(freshness, indicator: indicator, now: pinned))
        } else {
            TimelineView(.everyMinute) { context in
                lineContent(freshness: LooprHeaderMeta.freshness(freshness, indicator: indicator, now: context.date))
            }
        }
    }

    @ViewBuilder
    private func lineContent(freshness: LooprHeaderMeta.Freshness?) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                if let dayPhrase { phrase(dayPhrase) }
                if let freshness { freshnessView(freshness) }
            }
        } else if let dayPhrase, let freshness {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    phrase(dayPhrase)
                    separator
                    freshnessView(freshness)
                }
                phrase(dayPhrase)
            }
        } else if let dayPhrase {
            phrase(dayPhrase)
        } else if let freshness {
            freshnessView(freshness)
        } else {
            // Keeps the title block the same height on every tab.
            Text(" ").looprTypography(.headerMeta).accessibilityHidden(true)
        }
    }

    private func phrase(_ text: String) -> some View {
        Text(text)
            .looprTypography(.headerMeta)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .lineLimit(stacked ? nil : 1)
            .fixedSize(horizontal: !stacked, vertical: true)
    }

    private var separator: some View {
        Text(" · ")
            .looprTypography(.headerMeta)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func freshnessView(_ freshness: LooprHeaderMeta.Freshness) -> some View {
        HStack(spacing: 5) {
            if freshness.isActive {
                Circle()
                    .fill(Color.loopr(accent))
                    .frame(width: 5, height: 5)
                    .modifier(LooprBreathing(active: !LooprMotion.reducesMotion(reduceMotion)))
                    .accessibilityHidden(true)
            }
            Text(freshness.text)
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(freshness.isActive ? accent.textInk : .inkSecondary))
                .lineLimit(stacked ? nil : 1)
                .fixedSize(horizontal: !stacked, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(LooprMotion.stateChange, value: freshness)
    }
}
