import SwiftUI

public struct LooprStorageSegment: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let bytes: Int64
    public let accent: LooprColorToken
    public init(id: String, title: String, bytes: Int64, accent: LooprColorToken) {
        self.id = id; self.title = title; self.bytes = max(0, bytes); self.accent = accent
    }
    public static func shares(_ segments: [Self]) -> [Double] {
        let total = segments.reduce(0.0) { $0 + Double($1.bytes) }
        return segments.map { total > 0 ? Double($0.bytes) / total : 0 }
    }
}

/// A stored-content distribution. The caller labels overhead separately when
/// these sizes describe field payloads rather than allocated database pages.
public struct LooprStorageBreakdown: View {
    @ScaledMetric(relativeTo: .caption) private var legendMinimumWidth: CGFloat = 100
    public let segments: [LooprStorageSegment]
    private let compactLegend: Bool
    public init(segments: [LooprStorageSegment], compactLegend: Bool = false) {
        self.segments = segments
        self.compactLegend = compactLegend
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    let shares = LooprStorageSegment.shares(segments)
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        Rectangle().fill(Color.loopr(segment.accent))
                            .frame(width: geometry.size.width * shares[index])
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: LooprSpacing.xs)
            .accessibilityHidden(true)
            if compactLegend {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.sm) { legend }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: legendMinimumWidth), alignment: .leading)], alignment: .leading) { legend }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: legendMinimumWidth), alignment: .leading)],
                          alignment: .leading, spacing: LooprSpacing.sm) {
                    legend
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by domain")
        .accessibilityValue(segments.map { "\($0.title), \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" }.joined(separator: "; "))
    }
    @ViewBuilder private var legend: some View {
        ForEach(segments.filter { !compactLegend || $0.id != "other" }) { segment in
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                Circle().fill(Color.loopr(segment.accent)).frame(width: LooprSpacing.xs, height: LooprSpacing.xs).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(compactLegend ? segment.title.looprLabelCased : segment.title,
                              style: compactLegend ? .sectionLabel : .caption, color: .inkSecondary)
                    if !compactLegend {
                        LooprText(ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file), style: .caption, color: .inkSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file))
        }
    }
}

#Preview {
    LooprCard {
        LooprStorageBreakdown(segments: [
            .init(id: "band", title: "Band", bytes: 180_000, accent: .heart),
            .init(id: "journal", title: "Journal", bytes: 20_000, accent: .cyclePlum)
        ])
    }
    .padding()
}
