import SwiftUI

/// A compact summary for a widget or another read-only glance.
public struct LooprGlanceSummary: View {
    public struct Item: Identifiable, Sendable {
        public let id: String
        public let value: String
        public let tint: LooprColorToken
        public let detail: String?
        public init(_ title: String, value: String, tint: LooprColorToken, detail: String? = nil) {
            id = title; self.value = value; self.tint = tint; self.detail = detail
        }
    }
    private let title: String
    private let value: String
    private let verdict: String
    private let tint: LooprColorToken
    private let detail: String?
    private let status: String
    private let items: [Item]
    public init(title: String, value: String, verdict: String, tint: LooprColorToken, detail: String?, status: String, items: [Item]) {
        self.title = title; self.value = value; self.verdict = verdict; self.tint = tint
        self.detail = detail; self.status = status; self.items = items
    }
    public var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            content.dynamicTypeSize(...DynamicTypeSize.large).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            Text(title.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1.5)
                .foregroundStyle(Color.loopr(.inkSecondary))
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                Text(value).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                Text(verdict).font(.subheadline.weight(.semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(Color.loopr(tint)).privacySensitive()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    .privacySensitive()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: LooprSpacing.xs) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.id.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                        Text(item.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(Color.loopr(item.tint)).privacySensitive()
                        if let detail = item.detail {
                            Text(detail).font(.caption2).foregroundStyle(Color.loopr(.inkSecondary))
                                .privacySensitive()
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(status).font(.caption2).foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
