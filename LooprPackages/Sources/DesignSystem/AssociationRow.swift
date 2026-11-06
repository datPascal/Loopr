import SwiftUI

/// A measured association. The signed bar shows relative effect size; the
/// supplied description names the units, comparison and uncertainty.
public struct LooprAssociationRow: View {
    private let title: String
    private let detail: String
    private let evidence: String?
    private let titleColor: LooprColorToken
    private let share: Double?
    private let accent: LooprColorToken
    private let identifier: String
    private let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barWidth = LooprSpacing.xxl * 2

    public init(title: String, detail: String, evidence: String?, share: Double?,
                accent: LooprColorToken, identifier: String, titleColor: LooprColorToken = .ink,
                action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.titleColor = titleColor
        self.share = share
        self.accent = accent
        self.identifier = identifier
        self.action = action
    }

    public var accessibilitySummary: String {
        "\(title). \(detail)" + (evidence.map { " \($0)" } ?? "")
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(title, style: .rowTitle, color: titleColor)
                    LooprText(detail, style: .prose, color: .inkSecondary)
                    if let evidence { LooprText(evidence, style: .caption, color: .inkSecondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let share, !dynamicTypeSize.isAccessibilitySize {
                    LooprImpactBar(impact: .init(share: share), accent: accent)
                        .frame(width: barWidth)
                }
                LooprChevron()
            }
            .padding(.vertical, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(LooprPressableRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    LooprCard {
        LooprAssociationRow(title: "Alcohol", detail: "HRV was 8 ms lower after days with a Yes answer.",
            evidence: "Clear association · 64 nights", share: -0.8, accent: .heart,
            identifier: "association-preview") {}
    }
    .padding()
}

#Preview("Collecting association") {
    LooprCard {
        LooprAssociationRow(title: "Sauna", detail: "Not enough days yet · 8 with",
            evidence: nil, share: nil, accent: .cyclePlum,
            identifier: "collecting-association-preview", titleColor: .inkSecondary) {}
    }
    .padding()
}
