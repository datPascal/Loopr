import SwiftUI

/// The one "this opens something" glyph: SF Symbol `chevron.right` in the
/// quietest ink (tabs spec, principle 9). Put it on every row that navigates
/// and on no row that does not. It scales with Dynamic Type and is hidden
/// from VoiceOver; the row's own label and button trait say it opens.
///
/// ```swift
/// HStack { LooprText("Sleep trends", style: .rowTitle); Spacer(); LooprChevron() }
/// ```
public struct LooprChevron: View {
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 11

    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.loopr(.inkTertiary))
            .accessibilityHidden(true)
    }
}

/// A section eyebrow with an optional trailing action, for example
/// `YOUR NUMBERS ········ Edit ›` or `CONTRIBUTORS ······ See all ›`.
///
/// ```swift
/// LooprSectionHeader("Your numbers", actionTitle: "Edit", accent: .brand) { isEditing = true }
/// LooprSectionHeader("Contributors", detail: "vs your last 30 days")
/// ```
///
/// - The title is set uppercase in mono (`.sectionLabel`), as every Loopr
///   eyebrow is. Pass it in sentence case; VoiceOver reads it that way.
/// - `detail` is a quiet second line in sentence case, for the window or the
///   source ("vs your last 30 days").
/// - The action is a 44 pt tall button in the accent's text colour with the
///   one chevron. Leave `action` nil for a plain eyebrow.
///
/// Put it directly above the card or list it names, with `LooprSpacing.xs`
/// between them.
public struct LooprSectionHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: String
    private let detail: String?
    private let actionTitle: String?
    private let accent: LooprColorToken
    private let identifier: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        accent: LooprColorToken = .brand,
        identifier: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.accent = accent
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        // At accessibility sizes the action drops under the title.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
        return layout {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                Text(title.uppercased())
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .modifier(LooprOptionalIdentifier(identifier))
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: LooprSpacing.sm)
            }
            if let action, let actionTitle {
                Button(action: action) {
                    HStack(spacing: LooprSpacing.xxs) {
                        Text(actionTitle)
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(accent.textInk))
                        LooprChevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionTitle)
                .accessibilityHint(Text(title))
                .modifier(LooprOptionalIdentifier(identifier.map { "\($0)-action" }))
            }
        }
        .padding(.horizontal, LooprSpacing.xxs)
        .frame(minHeight: action == nil ? nil : 44, alignment: .bottom)
    }
}

/// Applies an accessibility identifier only when there is one.
struct LooprOptionalIdentifier: ViewModifier {
    let identifier: String?

    init(_ identifier: String?) { self.identifier = identifier }

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

#Preview("Section header") {
    VStack(alignment: .leading, spacing: LooprSpacing.lg) {
        LooprSectionHeader("Your numbers", actionTitle: "Edit") {}
        LooprSectionHeader("Contributors", detail: "Compared with your last 30 days")
        LooprSectionHeader("Sleep debt", actionTitle: "See all", accent: .sleep) {}
    }
    .padding()
    .background(Color.loopr(.background))
}
