import SwiftUI

public enum MetricState: String, Codable, CaseIterable, Sendable {
    case loading
    case noRecords
    case absent
    case measuredZero
    case partial
    case lowConfidence
    case settling
    case stale
    case disconnected
    case bluetoothOff
    case permissionDenied
    case unsupportedHardware
    case recoverableError
    case destructiveFailure

    public var title: String {
        switch self {
        case .loading: "Loading"
        case .noRecords: "No records yet"
        case .absent: "Not measured"
        case .measuredZero: "Measured zero"
        case .partial: "Partial data"
        case .lowConfidence: "Low confidence"
        case .settling: "Updating"
        case .stale: "Out of date"
        case .disconnected: "Strap disconnected"
        case .bluetoothOff: "Bluetooth is off"
        case .permissionDenied: "Permission needed"
        case .unsupportedHardware: "Not supported by this strap"
        case .recoverableError: "Could not load data"
        case .destructiveFailure: "Data recovery needed"
        }
    }

    public var detail: String {
        switch self {
        case .loading: "Getting the latest measurements."
        case .noRecords: "Wear your strap to begin building this view."
        case .absent: "No measurement was recorded for this period."
        case .measuredZero: "A valid measurement of zero was recorded."
        case .partial: "Some measurements are still missing."
        case .lowConfidence: "Use this estimate with caution."
        case .settling: "Recent data is being recomputed."
        case .stale: "Connect your strap to refresh this result."
        case .disconnected: "Reconnect your strap to continue syncing."
        case .bluetoothOff: "Turn on Bluetooth to connect to your strap."
        case .permissionDenied: "Allow access in Settings to show this information."
        case .unsupportedHardware: "This feature is unavailable for the connected model."
        case .recoverableError: "Try again without losing your saved data."
        case .destructiveFailure: "Review recovery options before making changes."
        }
    }

    public var symbol: String {
        switch self {
        case .loading, .settling: "arrow.trianglehead.2.clockwise.rotate.90"
        case .noRecords: "sparkles"
        case .absent: "minus"
        case .measuredZero: "0.circle"
        case .partial: "circle.lefthalf.filled"
        case .lowConfidence: "waveform.badge.exclamationmark"
        case .stale: "clock.badge.exclamationmark"
        case .disconnected: "link.badge.plus"
        case .bluetoothOff: "antenna.radiowaves.left.and.right.slash"
        case .permissionDenied: "hand.raised"
        case .unsupportedHardware: "watch.analog"
        case .recoverableError: "arrow.clockwise"
        case .destructiveFailure: "exclamationmark.triangle"
        }
    }

    public var isValuePresent: Bool { self == .measuredZero }
}

public enum SurfaceEmphasis: Sendable {
    case standard
    case elevated
    case hero(LooprColorToken)
}

/// The card most screens use. It draws through `LooprCard`, so its radius,
/// padding and outline match every other card.
public struct LooprSurface<Content: View>: View {
    private let emphasis: SurfaceEmphasis
    private let content: Content

    public init(emphasis: SurfaceEmphasis = .standard, @ViewBuilder content: () -> Content) {
        self.emphasis = emphasis
        self.content = content()
    }

    public var body: some View {
        LooprCard(style: style) { content }
    }

    private var style: LooprCardStyle {
        switch emphasis {
        case .standard: .standard
        case .elevated: .elevated
        case .hero(let accent): .hero(accent)
        }
    }
}

/// What a metric row actually shows, worked out from the strings the
/// derivation hands over. Every rule of the tabs cleanup lives here so rows on
/// every screen behave the same and the rules can be tested:
///
/// - **Absent is quiet.** A value that is empty, a dash, or a `MetricState`
///   title meaning "no value" ("Not measured", "No records yet") is shown as
///   short secondary text, "No reading" for plain absence, never at metric
///   size. A row that passed its state title as the confidence line and no
///   value is treated the same way.
/// - **Confidence only when it matters.** "High confidence" and "Partial
///   data" (the state every normal production value carries) are not shown.
///   "Low confidence", "Updating", counts such as "6 of 7 nights" and
///   explanations still are.
/// - **Captions that are sentences read as sentences.** Short labels stay
///   uppercase mono; anything longer than a label is sentence case.
/// - **Plain units.** `LooprUnitFormatter.rowValue` turns `7:42 hours` into
///   `7 h 42 m` and drops filler units.
public struct LooprRowPresentation: Equatable, Sendable {
    public let value: String
    public let unit: String?
    /// True when `value` is an absence message, set small and secondary.
    public let isAbsent: Bool
    /// The caption under the title, or nil when there is nothing worth saying.
    public let caption: String?
    /// True when the caption is a sentence and should not be uppercased.
    public let captionIsSentence: Bool

    /// Titles of states that mean "there is no value to show".
    static let absentValueTitles: Set<String> = Set(
        MetricState.allCases.filter { ![.measuredZero, .partial, .lowConfidence, .settling].contains($0) }.map(\.title)
    )
    static let dashes: Set<String> = ["-", "\u{2013}", "\u{2014}", "\u{2212}", "--"]
    /// Confidence lines that say nothing: the normal case.
    static let silentCaptions: Set<String> = ["high confidence", "high", "partial data", "partial"]

    public static func make(title: String, value: String, unit: String?, confidence: String?) -> LooprRowPresentation {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCaption = confidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caption = trimmedCaption.flatMap { $0.isEmpty ? nil : $0 }
        var absentText: String?

        if absentValueTitles.contains(trimmedValue) || dashes.contains(trimmedValue) {
            absentText = trimmedValue
        } else if trimmedValue.isEmpty, let current = caption, absentValueTitles.contains(current) {
            // Sleep rows pass the state title as the caption and no value.
            absentText = current
            caption = nil
        }
        if let current = caption, silentCaptions.contains(current.lowercased()) || current == absentText {
            caption = nil
        }

        let captionIsSentence = caption.map(isSentence) ?? false
        if let absentText {
            let shown = absentText == MetricState.absent.title || dashes.contains(absentText) ? "No reading" : absentText
            return LooprRowPresentation(value: shown, unit: nil, isAbsent: true, caption: caption, captionIsSentence: captionIsSentence)
        }
        let measurement = LooprUnitFormatter.rowValue(value, unit: unit, title: title)
        return LooprRowPresentation(
            value: measurement.value,
            unit: measurement.unit.isEmpty ? nil : measurement.unit,
            isAbsent: false,
            caption: caption,
            captionIsSentence: captionIsSentence
        )
    }

    /// A caption is a sentence when it has more than four words or ends like
    /// one. "6 of 7 nights" is a label; "Estimated from wrist motion" is not.
    static func isSentence(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count > 4 || text.hasSuffix(".")
    }
}

public struct HairlineMetricRow: View, Identifiable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public let id: String
    public let title: String
    public let confidence: String?
    public let value: String
    public let unit: String?
    public let accent: LooprColorToken?
    public let valueStyle: LooprTextStyle?

    public let showsDisclosure: Bool
    private let action: (() -> Void)?

    public init(
        id: String? = nil,
        title: String,
        confidence: String? = nil,
        value: String,
        unit: String? = nil,
        accent: LooprColorToken? = nil,
        valueStyle: LooprTextStyle? = nil,
        showsDisclosure: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.id = id ?? title
        self.title = title
        self.confidence = confidence
        self.value = value
        self.unit = unit
        self.accent = accent
        self.valueStyle = valueStyle
        self.showsDisclosure = showsDisclosure
        self.action = action
    }

    public init(
        id: String? = nil,
        title: String,
        confidence: String? = nil,
        value: String,
        unit: String? = nil,
        accent: LooprColorToken? = nil,
        isNavigable: Bool,
        action: (() -> Void)? = nil
    ) {
        self.init(
            id: id,
            title: title,
            confidence: confidence,
            value: value,
            unit: unit,
            accent: accent,
            showsDisclosure: isNavigable,
            action: action
        )
    }

    /// What the row shows after the cleanup rules. See `LooprRowPresentation`.
    public var presentation: LooprRowPresentation {
        LooprRowPresentation.make(title: title, value: value, unit: unit, confidence: confidence)
    }

    public var accessibilitySummary: String {
        let shown = presentation
        var parts = [title]
        if !shown.value.isEmpty {
            if let unit = shown.unit {
                parts.append("\(shown.value) \(LooprUnitFormatter.spokenUnit(unit))")
            } else {
                parts.append(shown.value)
            }
        }
        if let caption = shown.caption { parts.append(caption) }
        if showsDisclosure || action != nil { parts.append("Opens details") }
        return parts.joined(separator: ", ")
    }

    public var isNavigable: Bool { showsDisclosure || action != nil }

    public var body: some View {
        interactiveRow
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.looprPressableRow)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        let shown = presentation
        // At accessibility sizes the value moves under the title, so neither
        // the title nor the number has to break mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
        return layout {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs - 1) {
                Text(title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = shown.caption {
                    Text(shown.captionIsSentence ? caption : caption.uppercased())
                        .looprTypography(shown.captionIsSentence ? .caption : .confidence)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: LooprSpacing.sm)
            }
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                if let valueStyle {
                    LooprText([shown.value, shown.unit].compactMap { $0 }.joined(separator: " "),
                              style: valueStyle, color: accent ?? .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if shown.isAbsent {
                    Text(shown.value)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                } else {
                    LooprValueText(shown.value, unit: shown.unit, color: accent ?? .ink)
                        .minimumScaleFactor(0.75)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: LooprSpacing.sm)
                }
                if showsDisclosure || action != nil {
                    LooprChevron()
                        .padding(.leading, LooprSpacing.xxs)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        }
        .padding(.vertical, LooprSpacing.metricRowVertical)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

public struct HairlineMetricList: View {
    private let rows: [HairlineMetricRow]

    public init(rows: [HairlineMetricRow]) {
        self.rows = rows
    }

    public init(_ rows: [HairlineMetricRow]) {
        self.init(rows: rows)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                row
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .looprCardBackground()
    }
}

public typealias MetricRow = HairlineMetricRow
public typealias MetricList = HairlineMetricList

private struct LooprHeaderUsesNavigationBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var looprHeaderUsesNavigationBar: Bool {
        get { self[LooprHeaderUsesNavigationBarKey.self] }
        set { self[LooprHeaderUsesNavigationBarKey.self] = newValue }
    }
}

public extension View {
    /// Moves a descendant `StickyHeader` into the native navigation bar.
    /// Apply this only when the screen is pushed; tab and modal roots retain
    /// the full-width header treatment.
    func looprHeaderInNavigationBar() -> some View {
        environment(\.looprHeaderUsesNavigationBar, true)
    }
}

public struct StickyHeader: View {
    @Environment(\.looprHeaderUsesNavigationBar) private var usesNavigationBar
    private let title: String
    private let meta: String
    private let status: StatusChip?
    private let trailingAccessory: AnyView?
    private let isScrolled: Bool

    public init(title: String, meta: String, status: StatusChip? = nil, isScrolled: Bool = true) {
        self.title = title
        self.meta = meta
        self.status = status
        self.trailingAccessory = nil
        self.isScrolled = isScrolled
    }

    public init<Accessory: View>(
        title: String,
        meta: String,
        status: StatusChip? = nil,
        isScrolled: Bool = true,
        @ViewBuilder trailingAccessory: () -> Accessory
    ) {
        self.title = title
        self.meta = meta
        self.status = status
        self.trailingAccessory = AnyView(trailingAccessory())
        self.isScrolled = isScrolled
    }

    public init(
        title: String,
        meta: String,
        status: String,
        tone: ChipTone = .neutral,
        symbol: String = "circle.fill"
    ) {
        self.init(title: title, meta: meta, status: StatusChip(status, symbol: symbol, tone: tone))
    }

    public init(title: String, meta: String, status: String, accent: LooprColorToken) {
        self.init(title: title, meta: meta, status: StatusChip(status, symbol: "circle.fill", accent: accent))
    }

    public var accessibilitySummary: String {
        [title, meta, status?.accessibilitySummary].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder
    public var body: some View {
        if usesNavigationBar {
            navigationHeader
        } else {
            visualHeader
        }
    }

    private var navigationHeader: some View {
        Color.clear
            .frame(height: 0)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                        Text(title)
                            .looprTypography(.screenTitle)
                            .foregroundStyle(Color.loopr(.ink))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(meta.uppercased())
                            .looprTypography(.headerMeta)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([title, meta].joined(separator: ", "))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("loopr-navigation-header")
                }

                if status != nil || trailingAccessory != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: LooprSpacing.xs) {
                            if let status {
                                status
                            }
                            if let trailingAccessory {
                                trailingAccessory
                            }
                        }
                    }
                }
            }
    }

    /// The full-width header, drawn by the same component as the tab roots.
    private var visualHeader: some View {
        LooprTabHeader(
            {
                var content = LooprTabHeaderContent(
                    title: title,
                    accent: .brand,
                    dayPhrase: meta.isEmpty ? nil : meta.uppercased(),
                    status: status,
                    control: trailingAccessory.map(LooprHeaderControl.custom) ?? .none
                )
                content.showsBandButton = false
                return content
            }(),
            showsBar: isScrolled
        )
        .modifier(StickyHeaderAccessibilityModifier(
            summary: accessibilitySummary,
            hasTrailingAccessory: hasTrailingAccessory
        ))
    }

    private var hasTrailingAccessory: Bool {
        switch trailingAccessory {
        case .some: true
        case .none: false
        }
    }
}

private struct StickyHeaderAccessibilityModifier: ViewModifier {
    let summary: String
    let hasTrailingAccessory: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasTrailingAccessory {
            content
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isHeader)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(summary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

public typealias LooprStickyHeader = StickyHeader

private struct BandConnectedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ConnectedEmptyDetailKey: EnvironmentKey {
    static let defaultValue = "Your band is connected. Keep wearing it while Loopr collects measurements. Sleep and recovery need overnight data; live heart rate is available in Heart."
}

public extension EnvironmentValues {
    var bandConnected: Bool {
        get { self[BandConnectedKey.self] }
        set { self[BandConnectedKey.self] = newValue }
    }
    var connectedEmptyDetail: String {
        get { self[ConnectedEmptyDetailKey.self] }
        set { self[ConnectedEmptyDetailKey.self] = newValue }
    }
}

public struct StateMessage: View {
    @Environment(\.bandConnected) private var bandConnected
    @Environment(\.connectedEmptyDetail) private var connectedEmptyDetail
    private var title: String { state == .noRecords && bandConnected ? "Waiting for your first measurements" : state.title }
    private var detail: String { state == .noRecords && bandConnected ? connectedEmptyDetail : state.detail }

    @ScaledMetric(relativeTo: .body) private var symbolSize = 24
    private let state: MetricState
    private let compact: Bool
    private let accent: LooprColorToken?

    /// `accent` replaces the neutral brand tint on states that carry no
    /// meaning of their own, so a neutral glyph inside an accented card takes
    /// that card's accent instead of reading as a second one. States that do
    /// carry meaning, an error, a warning, a measured zero, keep their own
    /// colour and ignore the override.
    public init(_ state: MetricState, compact: Bool = false, accent: LooprColorToken? = nil) {
        self.state = state
        self.compact = compact
        self.accent = accent
    }

    public var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Image(systemName: state.symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(tint)
                .frame(width: symbolSize, height: symbolSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                if !compact {
                    LooprText(detail, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var tint: Color {
        switch state {
        case .recoverableError: .loopr(.warning)
        case .destructiveFailure: .loopr(.critical)
        case .lowConfidence, .partial, .stale: .loopr(.strain)
        case .measuredZero: .loopr(.recovery)
        default: .loopr(accent ?? .brand)
        }
    }
}

/// One loading block. It shares the low-contrast fill and the looping
/// highlight of `LooprLoadingPlaceholder`.
public struct LooprSkeleton: View {
    private let height: CGFloat

    public init(height: CGFloat = 18) { self.height = height }

    public var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LooprPlaceholderStyle.blockFill)
            .frame(height: height)
            .looprShimmer()
            .accessibilityElement()
            .accessibilityLabel("Loading")
    }
}

public enum ChipTone: CaseIterable, Sendable {
    case neutral
    case positive
    case warning
    case critical
    case brand
}

public struct StatusChip: View {
    private let label: String
    private let symbol: String
    private let tone: ChipTone
    private let accentOverride: LooprColorToken?

    public init(
        _ label: String,
        symbol: String = "circle.fill",
        tone: ChipTone = .neutral,
        accent: LooprColorToken? = nil
    ) {
        self.label = label
        self.symbol = symbol
        self.tone = tone
        accentOverride = accent
    }

    public var accessibilitySummary: String { label }
    public var hasNonColorDifferentiator: Bool { !label.isEmpty && !symbol.isEmpty }

    public var body: some View {
        Label {
            Text(label)
                .textCase(.uppercase)
        } icon: {
            Image(systemName: symbol)
        }
            .looprTypography(.chip)
            .foregroundStyle(Color.loopr(labelToken))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.loopr(accentToken).opacity(isDark ? 0.13 : 0.10), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.loopr(accentToken).opacity(isDark ? 0.30 : 0.25), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var accentToken: LooprColorToken {
        if let accentOverride {
            switch accentOverride {
            case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleep
            case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: .heart
            case .strain, .strainSweep, .strainChip, .energy, .warning: .strain
            default: .brand
            }
        } else {
            switch tone {
            case .neutral: .inkSecondary
            case .positive, .brand: .brand
            case .warning: .strain
            case .critical: .heart
            }
        }
    }

    private var labelToken: LooprColorToken {
        if let accentOverride { return accentOverride.spectralChipLabel }
        return switch tone {
        case .neutral: .inkSecondary
        case .positive, .brand: .brandChip
        case .warning: .strainChip
        case .critical: .heartChip
        }
    }

    private var isDark: Bool {
        LooprAppearance.isDark(colorScheme)
    }
}

public typealias StatusPill = StatusChip

public struct MetricCard: View {
    private let title: String
    private let value: String?
    private let unit: String
    private let trend: String?
    private let confidence: String?
    private let state: MetricState
    private let accent: LooprColorToken

    public init(
        title: String,
        value: String?,
        unit: String,
        trend: String? = nil,
        confidence: String? = nil,
        state: MetricState,
        accent: LooprColorToken = .brand
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.trend = trend
        self.confidence = confidence
        self.state = state
        self.accent = accent
    }

    public var accessibilitySummary: String {
        guard state == .measuredZero || (value != nil && ![.loading, .absent, .noRecords].contains(state)) else {
            return "\(title). \(state.title). \(state.detail)"
        }
        return [title, value, unit, trend, confidence, state == .measuredZero ? state.title : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    public var body: some View {
        LooprSurface(emphasis: .hero(accent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                header
                if shouldShowValue, let value {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        MetricNumeral(value)
                        LooprText(unit, style: .metricUnit, color: .inkSecondary)
                    }
                    if let trend {
                        Label(trend, systemImage: "chart.line.uptrend.xyaxis")
                            .looprTypography(.headerMeta)
                            .foregroundStyle(Color.loopr(accent))
                    }
                } else {
                    StateMessage(state)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var shouldShowValue: Bool {
        value != nil && ![.loading, .noRecords, .absent, .disconnected, .bluetoothOff, .permissionDenied, .unsupportedHardware, .recoverableError, .destructiveFailure].contains(state)
    }

    @ViewBuilder
    private var header: some View {
        if let confidence, !LooprRowPresentation.silentCaptions.contains(confidence.lowercased()) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs - 1) {
                LooprText(title, style: .cardTitle)
                LooprText(confidence.uppercased(), style: .confidence, color: .inkSecondary)
            }
        } else {
            LooprText(title, style: .cardTitle)
        }
    }
}

public struct LooprButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public static let minimumTargetHeight: CGFloat = 56
    private let prominent: Bool

    public init(prominent: Bool = true) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .looprTypography(.label)
            .foregroundStyle(prominent ? Color.loopr(.background) : Color.loopr(.brand))
            .frame(maxWidth: .infinity, minHeight: Self.minimumTargetHeight)
            .background(
                prominent ? Color.loopr(.brand) : Color.loopr(.brand).opacity(0.10),
                in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                        .strokeBorder(Color.loopr(.brand).opacity(0.25), lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                reduceMotion || DesignSystemRuntime.state().reduceMotion == true
                    ? .linear(duration: 0)
                    : LooprMotion.stateChange,
                value: configuration.isPressed
            )
    }
}

public struct LooprRow<Trailing: View>: View {
    public static var minimumTargetHeight: CGFloat { 56 }
    private let title: String
    private let subtitle: String?
    private let symbol: String
    private let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }

    public var accessibilitySummary: String {
        subtitle.map { "\(title), \($0)" } ?? title
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.md) {
            Image(systemName: symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.brand))
                .frame(width: 32, height: 32)
                .background(Color.loopr(.brandSoft), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                if let subtitle { LooprText(subtitle, style: .prose, color: .inkSecondary) }
            }
            Spacer(minLength: LooprSpacing.sm)
            trailing
                .foregroundStyle(Color.loopr(.inkSecondary))
                .looprTypography(.metricUnit)
        }
        .frame(minHeight: Self.minimumTargetHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }
}

public extension LooprRow where Trailing == Image {
    init(title: String, subtitle: String? = nil, symbol: String) {
        self.init(title: title, subtitle: subtitle, symbol: symbol) {
            Image(systemName: "chevron.right")
        }
    }
}
