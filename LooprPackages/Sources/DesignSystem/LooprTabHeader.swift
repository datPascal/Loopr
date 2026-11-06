import Foundation
import SwiftUI

// MARK: - Meta line

/// What the right half of the meta line says about how fresh the numbers are.
public enum LooprHeaderFreshness: Equatable, Sendable {
    /// "SYNCED 5 MIN AGO", or "Syncing" while the band hands over data.
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
            return navigation.dateText.looprLabelCased
        }
        return "\(navigation.title) · \(navigation.dateText)".looprLabelCased
    }

    /// Sleep's day phrase: "Last night" on today, otherwise the night
    /// itself, "TUE 22 → WED 23 SEP".
    public static func nightPhrase(_ navigation: LooprDayNavigation) -> String {
        navigation.isToday ? "Last night" : navigation.nightRange.looprLabelCased
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
            return Freshness(text: "Live", isActive: true)
        case .sync(let lastSync, let pinnedNow):
            if indicator?.link == .notPaired { return nil }
            if indicator?.link == .syncing { return Freshness(text: "Syncing", isActive: true) }
            let newest = [lastSync, indicator?.lastSyncedAt].compactMap { $0 }.max()
            return LooprSyncAge.label(lastSync: newest, now: pinnedNow ?? now)
                .map { Freshness(text: $0.looprLabelCased, isActive: false) }
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

/// The header's top row at default text sizes: the title, then the cluster (chip, shortcut, day control), then the band
/// button. It is one row while the title fits at `minimumTitleScale` or more of its own width beside the cluster and the
/// band button. Otherwise the title keeps the first row with the band button, and the cluster moves to a second row,
/// trailing. Subviews, in order: title, cluster, band.
struct LooprHeaderTopRow: Layout {
    /// The smallest share of its width the title may shrink to before the controls move down.
    static let minimumTitleScale: CGFloat = 0.85
    /// The smallest scale the header asks for when it is the last resort, after the compact controls: 0.72 keeps
    /// "Today" beside a past day's Today pill on a 402 pt phone instead of dropping the controls to a second row.
    /// It stays above the title's `minimumScaleFactor` (0.7), so the title shrinks rather than truncates.
    static let lastResortTitleScale: CGFloat = 0.72

    enum Arrangement: Equatable, Sendable { case oneRow, twoRows }

    var titleSpacing: CGFloat = LooprSpacing.sm
    var clusterSpacing: CGFloat = LooprSpacing.headerClusterSpacing
    var rowSpacing: CGFloat = LooprSpacing.xs
    var titleScale: CGFloat = LooprHeaderTopRow.minimumTitleScale

    /// The arrangement for a row `width` wide, from each part's own width.
    static func arrangement(width: CGFloat, title: CGFloat, cluster: CGFloat, band: CGFloat,
                            titleSpacing: CGFloat = LooprSpacing.sm,
                            clusterSpacing: CGFloat = LooprSpacing.headerClusterSpacing,
                            titleScale: CGFloat = minimumTitleScale) -> Arrangement {
        guard width.isFinite else { return .oneRow }
        let trailing = cluster + band + (cluster > 0 && band > 0 ? clusterSpacing : 0)
        let room = width - trailing - (trailing > 0 ? titleSpacing : 0)
        return room >= title * titleScale ? .oneRow : .twoRows
    }

    private struct Parts {
        var title: CGSize, cluster: CGSize, band: CGSize
    }

    private func parts(_ subviews: Subviews) -> Parts {
        func size(_ index: Int) -> CGSize {
            guard subviews.indices.contains(index) else { return .zero }
            return subviews[index].sizeThatFits(.unspecified)
        }
        return Parts(title: size(0), cluster: size(1), band: size(2))
    }

    private func arrangement(_ parts: Parts, width: CGFloat) -> Arrangement {
        Self.arrangement(width: width, title: parts.title.width, cluster: parts.cluster.width, band: parts.band.width,
                         titleSpacing: titleSpacing, clusterSpacing: clusterSpacing, titleScale: titleScale)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let parts = parts(subviews)
        let trailing = parts.cluster.width + parts.band.width + (parts.cluster.width > 0 && parts.band.width > 0 ? clusterSpacing : 0)
        let natural = parts.title.width + (trailing > 0 ? titleSpacing + trailing : 0)
        let width = proposal.width ?? natural
        switch arrangement(parts, width: width) {
        case .oneRow:
            return CGSize(width: width, height: max(parts.title.height, parts.cluster.height, parts.band.height))
        case .twoRows:
            let first = max(parts.title.height, parts.band.height)
            let second = parts.cluster.width > 0 ? rowSpacing + parts.cluster.height : 0
            return CGSize(width: width, height: first + second)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let parts = parts(subviews)
        switch arrangement(parts, width: bounds.width) {
        case .oneRow:
            let height = bounds.height
            let bandX = bounds.maxX - parts.band.width
            let clusterX = bandX - (parts.band.width > 0 && parts.cluster.width > 0 ? clusterSpacing : 0) - parts.cluster.width
            let titleWidth = max(0, min(parts.title.width, clusterX - bounds.minX - (parts.cluster.width + parts.band.width > 0 ? titleSpacing : 0)))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (height - parts.title.height) / 2),
                              proposal: ProposedViewSize(width: titleWidth, height: parts.title.height))
            subviews[1].place(at: CGPoint(x: clusterX, y: bounds.minY + (height - parts.cluster.height) / 2),
                              proposal: ProposedViewSize(parts.cluster))
            subviews[2].place(at: CGPoint(x: bandX, y: bounds.minY + (height - parts.band.height) / 2),
                              proposal: ProposedViewSize(parts.band))
        case .twoRows:
            let first = max(parts.title.height, parts.band.height)
            let bandX = bounds.maxX - parts.band.width
            let titleWidth = max(0, min(parts.title.width, bandX - bounds.minX - (parts.band.width > 0 ? titleSpacing : 0)))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (first - parts.title.height) / 2),
                              proposal: ProposedViewSize(width: titleWidth, height: parts.title.height))
            subviews[2].place(at: CGPoint(x: bandX, y: bounds.minY + (first - parts.band.height) / 2),
                              proposal: ProposedViewSize(parts.band))
            subviews[1].place(at: CGPoint(x: bounds.maxX - parts.cluster.width, y: bounds.minY + first + rowSpacing),
                              proposal: ProposedViewSize(parts.cluster))
        }
    }
}

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
    /// A short word drawn beside the symbol, such as "Ask". Nil draws the symbol alone in a circle.
    public let title: String?
    public let identifier: String
    public let run: @MainActor () -> Void

    public init(symbol: String, label: String, title: String? = nil, identifier: String,
                run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.label = label
        self.title = title
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
    /// A glass button left of `control`, for a shortcut that has to stay
    /// reachable at any scroll depth, such as Today's coach.
    public var secondaryAction: LooprHeaderAction?
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
        secondaryAction: LooprHeaderAction? = nil,
        bandFallback: LooprBandIndicator? = nil,
        settingsFallback: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.accent = accent
        self.dayPhrase = dayPhrase
        self.freshness = freshness
        self.status = status
        self.control = control
        self.secondaryAction = secondaryAction
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
    @Environment(\.looprAsk) private var ask
    @Environment(\.looprRefresh) private var refresh
    @Environment(\.looprHeaderUsesNavigationBar) private var usesNavigationBar
    @State private var collapse = LooprHeaderCollapse()
    @State private var position = ScrollPosition()
    @Environment(\.looprTabScrollRequest) private var homeScrollRequest
    @State private var finishedRefreshes = 0

    private let header: LooprTabHeaderContent
    private let glow: LooprColorToken?
    /// The tab's drifting colour field (DESIGN_LANGUAGE premium check 4). Nil keeps the ambient glow.
    let field: LooprColorFieldTab?
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
        self.init(header: header, glow: glow, field: nil, identifier: identifier, content: content)
    }

    /// A tab with its colour field behind the scroll view in place of the
    /// ambient glow. The field pauses itself while the tab is hidden, in Low
    /// Power Mode and under Reduce Motion.
    ///
    /// - Parameter field: The tab whose field is drawn. Nil draws the glow.
    public init(
        header: LooprTabHeaderContent,
        glow: LooprColorToken?,
        field: LooprColorFieldTab?,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.glow = glow
        self.field = field
        self.identifier = identifier
        self.content = content()
    }

    @ViewBuilder
    private var backdrop: some View {
        if let field {
            LooprColorField(tab: field)
        } else {
            LooprAmbientBackground(tint: glow, fallback: header.accent)
        }
    }

    public var body: some View {
        if usesNavigationBar {
            // Pushed onto another tab's stack: the header moves into the
            // system bar beside the back button.
            scrollView
                .background { backdrop }
                .navigationTitle(header.title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LooprText(header.title, style: .title)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("loopr-navigation-header")
                    }
                }
                .looprAskToolbar(origin: header.title)
                .sensoryFeedback(.success, trigger: finishedRefreshes)
        } else {
            scrollView
                .safeAreaInset(edge: .top, spacing: 0) {
                    LooprTabHeader(header, collapse: collapse)
                }
                .overlay(alignment: .bottom) { LooprTabBarScrim() }
                .background { backdrop }
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

    @Environment(\.looprAsk) private var ask
    private let originalContent: LooprTabHeaderContent
    private var content: LooprTabHeaderContent {
        var value = originalContent
        if let ask { value.secondaryAction = ask.header(for: value.title, identifier: value.secondaryAction?.identifier) }
        return value
    }
    private let collapse: LooprHeaderCollapse?
    private let showsBar: Bool

    /// - Parameters:
    ///   - collapse: Scroll-driven collapse. Nil keeps the header expanded.
    ///   - showsBar: Without `collapse`, whether the material bar is drawn.
    public init(_ content: LooprTabHeaderContent, collapse: LooprHeaderCollapse? = nil, showsBar: Bool = false) {
        self.originalContent = content
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

        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            if !isLarge {
                // One row, always tried in this order: the title at full size beside the labelled shortcut; then
                // beside the shortcut as a symbol alone; then the title shrunk to 80 % beside the compact controls. A
                // past day's Today pill made the controls drop to a second row under the title, which read as a
                // broken header (Pascal, 2026-11-03). The second row stays only for a title that cannot fit at all.
                ViewThatFits(in: .horizontal) {
                    oneRow(progress: progress, reduces: reduces, shrink: shrink, compact: false)
                    oneRow(progress: progress, reduces: reduces, shrink: shrink, compact: true)
                    LooprHeaderTopRow(titleScale: LooprHeaderTopRow.lastResortTitleScale) {
                        titleBlock(progress: progress, reduces: reduces, isLarge: isLarge)
                        cluster(compact: true)
                            .offset(y: -shrink / 2)
                        HStack(spacing: 0) { band }
                            .offset(y: -shrink / 2)
                    }
                }
            } else {
                topRow(progress: progress, reduces: reduces, isLarge: isLarge, shrink: shrink, showsChip: true)
            }
            LooprHeaderMetaLine(dayPhrase: content.dayPhrase, freshness: content.freshness,
                accent: content.accent, stacked: isLarge)
                .opacity(isLarge ? 1 : Double(max(0, 1 - progress * 1.6)))
                .offset(y: reduces || isLarge ? 0 : -LooprSpacing.xxs * progress)
            if isLarge, content.status != nil || hasControl || content.secondaryAction != nil {
                // The chip, the shortcut and the day control share a second
                // row. When they do not fit side by side the chip takes its
                // own line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.headerClusterSpacing) {
                        chip
                        Spacer(minLength: 0)
                        secondary
                        control
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.headerClusterSpacing) {
                        chip
                        HStack(spacing: LooprSpacing.headerClusterSpacing) {
                            Spacer(minLength: 0)
                            secondary
                            control
                        }
                    }
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

    /// The title at its full width with the controls beside it. `ViewThatFits` takes it only when all of it fits.
    private func oneRow(progress: CGFloat, reduces: Bool, shrink: CGFloat, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            titleBlock(progress: progress, reduces: reduces, isLarge: false)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            HStack(spacing: LooprSpacing.headerClusterSpacing) {
                cluster(compact: compact)
                band
            }
            .offset(y: -shrink / 2)
        }
    }

    /// The chip, the shortcut and the day control. `compact` draws the shortcut as its symbol alone.
    private func cluster(compact: Bool) -> some View {
        HStack(spacing: LooprSpacing.headerClusterSpacing) {
            chip
            if let action = content.secondaryAction {
                LooprHeaderActionButton(action: action, compact: compact)
            }
            control
        }
    }

    private func topRow(
        progress: CGFloat,
        reduces: Bool,
        isLarge: Bool,
        shrink: CGFloat,
        showsChip: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            titleBlock(progress: progress, reduces: reduces, isLarge: isLarge)
                .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: LooprSpacing.headerClusterSpacing) {
                if !isLarge {
                    if showsChip { chip }
                    secondary
                    control
                }
                band
            }
            .offset(y: -shrink / 2)
        }
    }

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
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var secondary: some View {
        if let action = content.secondaryAction {
            LooprHeaderActionButton(action: action)
        }
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
            LooprHeaderActionButton(action: action)
        }
    }
}

/// A glass circle in the header cluster, the size of the band button.
public struct LooprHeaderActionButton: View {
    let action: LooprHeaderAction
    private let accent: LooprColorToken
    /// Draws a labelled action as its symbol alone in a 48 pt circle, for a header short of room.
    private let compact: Bool
    public init(action: LooprHeaderAction, accent: LooprColorToken = .ink, compact: Bool = false) {
        self.action = action
        self.accent = accent
        self.compact = compact
    }

    public var body: some View {
        if compact {
            Button(action: action.run) {
                Image(systemName: action.symbol)
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(accent))
                    .frame(width: LooprSpacing.headerControlDiameter, height: LooprSpacing.headerControlDiameter)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(.interaction, Circle())
            }
            .buttonStyle(.plain)
            .frame(width: LooprSpacing.headerControlDiameter, height: LooprSpacing.interactiveRowHeight)
            .accessibilityLabel(action.label)
            .accessibilityIdentifier(action.identifier)
        } else if let title = action.title {
            // A labelled action: the symbol and its word in a glass capsule, so a first-time reader knows what it does
            // (R1-NEW-17). Same height as the circle, so the row keeps its height.
            Button(action: action.run) {
                HStack(spacing: LooprSpacing.xxs) {
                    Image(systemName: action.symbol)
                        .looprTypography(.label)
                    Text(title)
                        .looprTypography(.label)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.loopr(accent))
                .padding(.horizontal, LooprSpacing.sm)
                .frame(height: LooprSpacing.headerControlDiameter)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(action.label)
            .accessibilityIdentifier(action.identifier)
        } else {
            Button(action: action.run) {
                Image(systemName: action.symbol)
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(accent))
                    .frame(width: LooprSpacing.headerControlDiameter, height: LooprSpacing.headerControlDiameter)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.plain)
            // The same slot as the band button, so the row keeps its height.
            .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
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

/// A backing under the glass tab bar. The bar's own glass is so clear that body text scrolled under it stayed readable
/// as ghost lines between the labels (R1-NEW-13, R1-LAB-22). This scrim fades the page's ground in over the bar's
/// height, so content dissolves before it reaches the labels. With Reduce Transparency it is solid.
struct LooprTabBarScrim: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// How far above the bar the fade starts.
    static let lead: CGFloat = 24
    /// The ground's strength under the labels.
    static func strength(isDark: Bool, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : (isDark ? 0.86 : 0.9)
    }

    var body: some View {
        GeometryReader { proxy in
            let ground = Color.loopr(.background)
            let strength = Self.strength(isDark: LooprAppearance.isDark(colorScheme), reduceTransparency: reduceTransparency)
            let height = proxy.safeAreaInsets.bottom + Self.lead
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(stops: [
                    .init(color: ground.opacity(0), location: 0),
                    .init(color: ground.opacity(strength), location: min(Self.lead / max(height, 1) * 1.6, 0.6)),
                    .init(color: ground.opacity(strength), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
