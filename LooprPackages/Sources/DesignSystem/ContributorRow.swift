import SwiftUI

/// Where a contributor's value sits against its usual range, for the compact
/// range bar on the right of a `LooprContributorRow`.
public struct LooprContributorRange: Hashable, Sendable {
    public let value: Double
    public let usual: ClosedRange<Double>
    /// The track's full scale. Nil widens the usual range on both sides.
    public let domain: ClosedRange<Double>?

    public init(value: Double, usual: ClosedRange<Double>, domain: ClosedRange<Double>? = nil) {
        self.value = value
        self.usual = usual
        self.domain = domain
    }

    /// Builds the range from a baseline band, or nil when there is no band.
    public init?(value: Double?, band: LooprBaselineBand?, domain: ClosedRange<Double>? = nil) {
        guard let value, value.isFinite, let band else { return nil }
        self.init(value: value, usual: band.lower...band.upper, domain: domain)
    }
}

/// How hard one input pushed a score, as a share of the day's biggest push.
///
/// `share` runs from -1 to 1: 1 is the input that raised the score most today,
/// -1 the one that lowered it most. Build a set with `scaled(_:)` so every row
/// in a list shares one scale.
public struct LooprContributorImpact: Hashable, Sendable {
    public let share: Double
    /// Optional text at the end of the bar, for example "+6 pts".
    public let label: String?

    public init(share: Double, label: String? = nil) {
        self.share = share.isFinite ? min(max(share, -1), 1) : 0
        self.label = label
    }

    /// Scales raw signed pushes so the largest magnitude becomes ±1. Nil
    /// entries (inputs with no reading) stay nil; an all-zero set stays zero.
    public static func scaled(_ pushes: [Double?]) -> [Double?] {
        let largest = pushes.compactMap { $0 }.filter(\.isFinite).map(abs).max() ?? 0
        return pushes.map { push in
            guard let push, push.isFinite else { return nil }
            return largest > 0 ? push / largest : 0
        }
    }

    /// Words for VoiceOver: "raises the score a lot", "lowers it a little".
    public var spokenText: String {
        let size = abs(share)
        guard size >= 0.05 else { return "barely moves the score" }
        let amount = size >= 0.66 ? "a lot" : size >= 0.33 ? "somewhat" : "a little"
        return "\(share > 0 ? "raises" : "lowers") the score \(amount)"
    }
}

/// One input to a score: name, value, how it compares with usual, where it
/// sits in its usual range and, optionally, how hard it pushed the score.
///
/// ```swift
/// LooprContributorRow(
///     title: "HRV",
///     value: "58", unit: "ms",
///     delta: .compare(58, usual: hrvBand, higherIsBetter: true, unit: "ms", withinRange: .signed),
///     range: LooprContributorRange(value: 58, band: hrvBand),
///     impact: LooprContributorImpact(share: 0.8, label: "+6 pts"),
///     accent: .recovery,
///     identifier: "today-contributor-hrv"
/// ) { metricLink?.open(LooprMetricLinkID.rmssd) }
/// ```
///
/// Use it under the Today recovery hero, on the recovery and strain breakdown
/// pages, and anywhere a score explains itself. Wrap several in
/// `LooprContributorList`. A row with an action shows the one chevron and is
/// a single VoiceOver button; a row without one shows no chevron.
///
/// With `value: nil` the row says "No reading" in small secondary text and
/// drops the delta, the range bar and the impact bar.
public struct LooprContributorRow: View, Identifiable {
    public let id: String
    private let title: String
    private let value: String?
    private let unit: String?
    private let delta: LooprDelta?
    private let comparison: String?
    private let range: LooprContributorRange?
    private let impact: LooprContributorImpact?
    private let status: String?
    private let accent: LooprColorToken
    private let identifier: String?
    private let action: (() -> Void)?

    @ScaledMetric(relativeTo: .caption) private var rangeWidth: CGFloat = 76
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `comparison` replaces `delta` with regular secondary text when supplied.
    public init(
        title: String,
        value: String?,
        unit: String? = nil,
        delta: LooprDelta? = nil,
        comparison: String? = nil,
        range: LooprContributorRange? = nil,
        impact: LooprContributorImpact? = nil,
        status: String? = nil,
        accent: LooprColorToken,
        identifier: String? = nil,
        action: (() -> Void)? = nil
    ) {
        id = identifier ?? title
        self.title = title
        self.value = value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.unit = unit
        self.delta = delta
        self.comparison = LooprOvernightSignalRowModel(comparison: comparison).comparison
        self.range = range
        self.impact = impact
        self.status = status
        self.accent = accent
        self.identifier = identifier
        self.action = action
    }

    /// Everything VoiceOver reads, in order: "HRV, 58 milliseconds, 6
    /// milliseconds above your usual, raises the score a lot".
    public var accessibilitySummary: String {
        var parts = [title]
        if let value {
            let spokenUnit = unit.map(LooprUnitFormatter.spokenUnit) ?? ""
            parts.append(spokenUnit.isEmpty ? value : "\(value) \(spokenUnit)")
            if let comparison { parts.append(comparison) }
            else if let delta { parts.append(delta.spokenText) }
            if let impact { parts.append(impact.spokenText) }
        } else {
            parts.append("No reading")
        }
        if let status { parts.append(status) }
        return parts.joined(separator: ", ")
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(LooprPressableRowStyle())
                    .accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .modifier(LooprOptionalIdentifier(identifier))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: one thing per line, full width.
                Text(title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    valueView
                    Spacer(minLength: LooprSpacing.xs)
                    if action != nil { LooprChevron() }
                }
                if value != nil {
                    if comparison != nil || delta != nil {
                        comparisonCaption
                            .lineLimit(2)
                    }
                    if let range {
                        LooprTypicalRangeBar(value: range.value, typical: range.usual, domain: range.domain, accent: accent)
                    }
                    if let impact {
                        LooprImpactBar(impact: impact, accent: accent)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    Text(title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: LooprSpacing.xs)
                    valueView
                    if action != nil { LooprChevron() }
                }
                if value != nil, comparison != nil || delta != nil || range != nil {
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        if comparison != nil || delta != nil {
                            comparisonCaption
                                .layoutPriority(1)
                        }
                        Spacer(minLength: LooprSpacing.xs)
                        if let range {
                            LooprTypicalRangeBar(value: range.value, typical: range.usual, domain: range.domain, accent: accent)
                                .frame(width: rangeWidth)
                                .padding(.trailing, action == nil ? 0 : chevronInset)
                        }
                    }
                }
                if value != nil, let impact {
                    LooprImpactBar(impact: impact, accent: accent)
                        .padding(.trailing, action == nil ? 0 : chevronInset)
                }
            }
            if let status {
                LooprText(status, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, LooprSpacing.sm + 1)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The range bar and impact bar end where the value ends, not under the
    /// chevron.
    private var chevronInset: CGFloat { LooprSpacing.sm + 4 }

    /// Custom comparison wording uses regular secondary text at every size.
    /// It replaces the formatted delta without changing other contributor rows.
    @ViewBuilder
    private var comparisonCaption: some View {
        if let comparison {
            LooprText(comparison, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let delta {
            LooprDeltaCaption(delta, accent: accent)
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if let value {
            LooprValueText(value, unit: unit)
            .fixedSize()
        } else {
            Text("No reading")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
        }
    }
}

/// A thin signed bar around a centre tick: right and in the accent when an
/// input raised the score, left and grey when it lowered it. Length is the
/// share of the day's biggest push.
public struct LooprImpactBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    private let impact: LooprContributorImpact
    private let accent: LooprColorToken

    public init(impact: LooprContributorImpact, accent: LooprColorToken) {
        self.impact = impact
        self.accent = accent
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.xs) {
            GeometryReader { proxy in
                let half = proxy.size.width / 2
                let length = half * CGFloat(abs(impact.share)) * (drawn || shouldReduceMotion ? 1 : 0)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.07 : 0.06))
                        .frame(height: 4)
                    Capsule(style: .continuous)
                        .fill(Color.loopr(impact.share >= 0 ? accent : .inkSecondary).opacity(impact.share >= 0 ? 1 : 0.7))
                        .frame(width: max(length, 0), height: 4)
                        .offset(x: impact.share >= 0 ? half : half - length)
                    Rectangle()
                        .fill(Color.loopr(.inkSecondary).opacity(0.6))
                        .frame(width: 1, height: 10)
                        .offset(x: half - 0.5)
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            if let label = impact.label {
                Text(label)
                    .looprTypography(.confidence)
                    .foregroundStyle(Color.loopr(impact.share >= 0 ? accent.textInk : .inkSecondary))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .onAppear {
            guard !drawn else { return }
            if shouldReduceMotion { drawn = true } else {
                withAnimation(.snappy(duration: LooprMotion.deliberate).delay(0.1)) { drawn = true }
            }
        }
        .accessibilityHidden(true)
    }

    private var shouldReduceMotion: Bool { reduceMotion || DesignSystemRuntime.state().reduceMotion == true }
    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

/// The card that holds contributor rows, with hairlines between them. It
/// matches `HairlineMetricList`: dark cards with a stroke, light cards white
/// with a soft shadow.
public struct LooprContributorList: View {
    @Environment(\.colorScheme) private var colorScheme
    private let rows: [LooprContributorRow]

    public init(_ rows: [LooprContributorRow]) {
        self.rows = rows
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
        .padding(.horizontal, isDark ? 17 : 18)
        .background(
            isDark ? Color.loopr(.surface) : Color.loopr(.sheetFill),
            in: RoundedRectangle(cornerRadius: isDark ? LooprRadius.compactCard : LooprRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isDark ? LooprRadius.compactCard : LooprRadius.card, style: .continuous)
                .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: isDark ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: isDark ? .clear : Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

/// A row button style that dims slightly while pressed, with no scale jump.
struct LooprPressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

#Preview("Contributors") {
    let hrv = LooprBaselineBand(center: 51, lower: 46.5, upper: 55.5, measuredDays: 28)
    let rhr = LooprBaselineBand(center: 54, lower: 52.4, upper: 55.6, measuredDays: 28)
    let impacts = LooprContributorImpact.scaled([6, 3, -1.5, nil])
    return ScrollView {
        LooprContributorList([
            LooprContributorRow(title: "HRV", value: "58", unit: "ms",
                                delta: .compare(58, usual: hrv, higherIsBetter: true, unit: "ms", withinRange: .signed),
                                range: LooprContributorRange(value: 58, band: hrv),
                                impact: LooprContributorImpact(share: impacts[0]!, label: "+6 pts"),
                                accent: .recovery) {},
            LooprContributorRow(title: "Resting heart rate", value: "51", unit: "bpm",
                                delta: .compare(51, usual: rhr, higherIsBetter: false, unit: "bpm", withinRange: .signed),
                                range: LooprContributorRange(value: 51, band: rhr),
                                impact: LooprContributorImpact(share: impacts[1]!, label: "+3 pts"),
                                accent: .recovery) {},
            LooprContributorRow(title: "Breathing rate", value: "15.4", unit: "br/min",
                                delta: .compare(15.4, usual: LooprBaselineBand(center: 14.8, lower: 14.5, upper: 15.1, measuredDays: 28),
                                                higherIsBetter: nil, unit: "br/min", format: .number(digits: 1), withinRange: .signed),
                                impact: LooprContributorImpact(share: impacts[2]!, label: "−1 pt"),
                                accent: .recovery),
            LooprContributorRow(title: "Sleep vs need", value: nil, accent: .recovery) {}
        ])
        .padding()
    }
    .background(Color.loopr(.background))
}
