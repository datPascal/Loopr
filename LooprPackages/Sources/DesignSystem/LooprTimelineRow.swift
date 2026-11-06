import SwiftUI

/// What one `LooprTimelineRow` says, with the wording VoiceOver reads. Kept apart from the view so
/// the rules can be tested without drawing.
public struct LooprTimelineRowModel: Hashable, Sendable {
    /// The clock time as the person reads it, such as "06:52".
    public let time: String
    public let title: String
    public let detail: String?
    /// True for something still ahead today. The row draws quieter and VoiceOver says "upcoming".
    public let isDimmed: Bool

    /// How strong a dimmed row draws. Time, title and detail share it, so the row still reads.
    public static let dimmedOpacity: Double = 0.5

    public init(time: String, title: String, detail: String? = nil, isDimmed: Bool = false) {
        self.time = time
        self.title = title
        self.detail = detail.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.isDimmed = isDimmed
    }

    public var opacity: Double { isDimmed ? Self.dimmedOpacity : 1 }

    /// What the whole row draws at: always full strength. Fading a row ahead to half took its title, detail and
    /// chevron to near-invisible on the dark card (R1-OPT-22); only its time and, in light mode, its title step down.
    public func opacity(isDark: Bool) -> Double { 1 }

    /// The title colour. A row ahead in light mode reads in the secondary ink; in dark mode every title keeps the
    /// standard ink.
    public func titleToken(isDark: Bool) -> LooprColorToken { isDimmed && !isDark ? .inkSecondary : .ink }

    /// The time's colour. A row ahead in dark mode mutes its time, the one part that says "not yet".
    public func timeToken(isDark: Bool) -> LooprColorToken { isDimmed && isDark ? .inkMuted : .inkSecondary }

    /// "06:52, Woke up, Smart alarm, 8 min early" and, for a row ahead, ", upcoming".
    public var accessibilityLabel: String {
        var parts = [time, title]
        if let detail { parts.append(detail) }
        if isDimmed { parts.append("upcoming") }
        return parts.joined(separator: ", ")
    }
}

/// One moment in the day: a time in mono type, a title and a quiet detail line. Today's timeline
/// card stacks them for the wake time, meals, workouts, reminders and bedtime.
///
/// ```swift
/// LooprCard(density: .flush) {
///     LooprTimelineRow(time: "06:52", title: "Woke up", detail: "Smart alarm, 8 min early",
///                      identifier: "today-timeline-wake")
///     LooprTimelineRow(time: "07:30", title: "Breakfast", detail: "Yogurt, berries, granola · 520 kcal",
///                      identifier: "today-timeline-meal") { openMeal() }
///     LooprTimelineRow(time: "18:00", title: "Upper A", detail: "Planned", isDimmed: true,
///                      identifier: "today-timeline-workout", showsDivider: false)
/// }
/// ```
///
/// - A row with an action shows the one chevron and is a button. Without one it is plain text.
/// - A dimmed row is for something that has not happened yet. It stays tappable.
/// - The row is at least 56 pt tall and one VoiceOver element.
/// - Each row draws its own divider. The last row of a card passes `showsDivider: false`.
/// - At accessibility text sizes the time moves above the title.
public struct LooprTimelineRow: View {
    public static let minimumHeight: CGFloat = LooprSpacing.interactiveRowHeight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 58
    private let model: LooprTimelineRowModel
    private let identifier: String
    private let showsDivider: Bool
    private let action: (() -> Void)?

    public init(time: String, title: String, detail: String? = nil, isDimmed: Bool = false,
                identifier: String, showsDivider: Bool = true, action: (() -> Void)? = nil) {
        model = LooprTimelineRowModel(time: time, title: title, detail: detail, isDimmed: isDimmed)
        self.identifier = identifier
        self.showsDivider = showsDivider
        self.action = action
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            Group {
                if let action {
                    Button(action: action) { content(showsChevron: true) }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityAddTraits(.isButton)
                } else {
                    content(showsChevron: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityIdentifier(identifier)
            if showsDivider {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(height: LooprSpacing.hairline)
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .accessibilityHidden(true)
            }
        }
    }

    private func content(showsChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.md) {
            if !dynamicTypeSize.isAccessibilitySize { timeText.frame(width: timeWidth, alignment: .leading) }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                if dynamicTypeSize.isAccessibilitySize { timeText }
                LooprText(model.title, style: .rowTitle, color: model.titleToken(isDark: isDark))
                if let detail = model.detail {
                    LooprText(detail, style: .caption, color: .inkSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron { LooprChevron() }
        }
        .opacity(model.opacity(isDark: isDark))
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.sm)
        .frame(minHeight: Self.minimumHeight)
        .contentShape(Rectangle())
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }

    private var timeText: some View {
        LooprText(model.time, style: .headerMeta, color: model.timeToken(isDark: isDark))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

#Preview("Timeline rows") {
    LooprCard(density: .flush) {
        VStack(spacing: LooprSpacing.none) {
            LooprTimelineRow(time: "06:52", title: "Woke up", detail: "Smart alarm, 8 min early", identifier: "preview-wake")
            LooprTimelineRow(time: "07:30", title: "Breakfast", detail: "Yogurt, berries, granola · 520 kcal",
                             identifier: "preview-breakfast") {}
            LooprTimelineRow(time: "18:00", title: "Upper A", detail: "Planned", isDimmed: true,
                             identifier: "preview-workout") {}
            LooprTimelineRow(time: "22:45", title: "Bedtime", detail: "For 8 h 10 m of sleep", isDimmed: true,
                             identifier: "preview-bedtime", showsDivider: false)
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
