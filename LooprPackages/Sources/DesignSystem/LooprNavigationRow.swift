import SwiftUI

/// A hairline list row that opens something: title, a quiet caption, an
/// optional progress bar and an optional mono value, then the one chevron.
/// Train uses it for programs and templates.
///
/// Put rows in a flush card. Each row draws its own divider, so the last row
/// of a card passes `showsDivider: false`.
///
/// ```swift
/// LooprCard(density: .flush) {
///     LooprNavigationRow(title: "Strength block", caption: "8 weeks · 5 days a week",
///                        progress: 3.0 / 8.0, value: "3", valueUnit: "of 8", accent: .movement,
///                        accessibilityLabel: "Strength block, week 3 of 8",
///                        identifier: "train-program-strength-block") { open() }
///     LooprNavigationRow(title: "Upper A", caption: "Bench press, Pull-up and 4 more",
///                        accessibilityLabel: "Upper A, 6 exercises",
///                        identifier: "train-template-upper-a", showsDivider: false) { open() }
/// }
/// ```
///
/// - The row is at least 56 pt tall and one VoiceOver element that reads
///   `accessibilityLabel`. Pass a label that carries the state, such as
///   "Half marathon, paused".
/// - `progress` runs from 0 to 1. Nil draws no bar.
/// - At accessibility text sizes the value moves under the caption.
public struct LooprNavigationRow: View {
    public static let minimumHeight: CGFloat = LooprSpacing.interactiveRowHeight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: String
    private let caption: String?
    private let progress: Double?
    private let value: String?
    private let valueUnit: String?
    private let accent: LooprColorToken
    private let accessibilityLabel: String
    private let identifier: String
    private let showsDivider: Bool
    private let action: () -> Void

    public init(title: String, caption: String? = nil, progress: Double? = nil, value: String? = nil,
                valueUnit: String? = nil, accent: LooprColorToken = .movement,
                accessibilityLabel: String, identifier: String, showsDivider: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.caption = caption
        self.progress = progress
        self.value = value
        self.valueUnit = valueUnit
        self.accent = accent
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.showsDivider = showsDivider
        self.action = action
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            Button(action: action) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(title, style: .rowTitle)
                        if let caption {
                            LooprText(caption, style: .caption, color: .inkSecondary)
                        }
                        if let progress {
                            LooprLinearProgress(value: progress, target: 1, accent: accent)
                                .padding(.top, LooprSpacing.xxs)
                        }
                        if dynamicTypeSize.isAccessibilitySize { valueText }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize { valueText }
                    LooprChevron()
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: Self.minimumHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
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

    @ViewBuilder
    private var valueText: some View {
        if let value {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                LooprText(value, style: .metricValue)
                if let valueUnit { LooprText(valueUnit, style: .metricUnit, color: .inkSecondary) }
            }
            .fixedSize()
        }
    }
}

#Preview("Navigation rows") {
    LooprCard(density: .flush) {
        VStack(spacing: LooprSpacing.none) {
            LooprNavigationRow(title: "Strength block", caption: "8 weeks · 5 days a week", progress: 3.0 / 8.0,
                               value: "3", valueUnit: "of 8", accessibilityLabel: "Strength block, week 3 of 8",
                               identifier: "preview-program") {}
            LooprNavigationRow(title: "Half marathon", caption: "Paused", accessibilityLabel: "Half marathon, paused",
                               identifier: "preview-paused") {}
            LooprNavigationRow(title: "Upper A", caption: "Bench press, Pull-up and 4 more",
                               accessibilityLabel: "Upper A, 6 exercises", identifier: "preview-template",
                               showsDivider: false) {}
        }
    }
    .padding(LooprSpacing.screenGutter)
    .background(Color.loopr(.background))
}
