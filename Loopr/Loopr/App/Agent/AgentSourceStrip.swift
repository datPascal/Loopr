import AIKit
import DesignSystem
import SwiftUI

/// The words on one source button: what was read and how much, such as "Food log · 5 days".
nonisolated enum AgentSourceCopy {
    static func text(_ source: AgentSource) -> String {
        "\(source.label) · \(source.count) \(noun(source))"
    }

    static func noun(_ source: AgentSource) -> String {
        let (one, many): (String, String)
        if case .sleep = source.link { (one, many) = ("night", "nights") }
        else if source.id == "patterns" { (one, many) = ("pattern", "patterns") }
        else if source.id == "protocol" { (one, many) = ("rule", "rules") }
        else if source.id.hasPrefix("experiments.") { (one, many) = ("experiment", "experiments") }
        else if source.id.hasPrefix("capacity.") { (one, many) = ("result", "results") }
        else if source.id == "ages" { (one, many) = ("age", "ages") }
        else {
            switch source.domain {
            case .labs: (one, many) = ("report", "reports")
            case .supplements: (one, many) = ("day", "days")
            case .training: (one, many) = ("workout", "workouts")
            case .journalNotes: (one, many) = ("note", "notes")
            case .cycle: (one, many) = ("record", "records")
            case .metrics, .food, .journalAnswers: (one, many) = ("day", "days")
            }
        }
        return source.count == 1 ? one : many
    }

    /// What VoiceOver says. A source with no screen to open is read as plain text.
    static func spoken(_ source: AgentSource) -> String {
        "\(source.label), \(source.count) \(noun(source))"
    }
}

/// Where Ask got its answer, one mono caption per read. A source that has a screen opens it. Ask closes
/// and the app shows the record, so the person can check the answer against it. Without `open`, where
/// Ask is pushed instead of presented, the captions are plain text.
struct AgentSourceStrip: View {
    let sources: [AgentSource]
    var open: (@MainActor @Sendable (AgentSourceLink) -> Void)?

    var body: some View {
        AgentFlowLayout(horizontalSpacing: LooprSpacing.sm, verticalSpacing: 0) {
            ForEach(sources) { source in
                if let link = source.link, let open {
                    Button { open(link) } label: { caption(source, underlined: true) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AgentSourceCopy.spoken(source))
                        .looprAccessibilityHint("Closes Ask and opens these records.")
                        .accessibilityIdentifier("agent-source-\(source.id)")
                } else {
                    caption(source, underlined: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(AgentSourceCopy.spoken(source))
                        .accessibilityIdentifier("agent-source-\(source.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("agent-source-strip")
    }

    private func caption(_ source: AgentSource, underlined: Bool) -> some View {
        Text(verbatim: AgentSourceCopy.text(source))
            .looprTypography(.headerMeta)
            .underline(underlined, color: Color.loopr(.inkMuted))
            .foregroundStyle(Color.loopr(.inkSecondary))
            .multilineTextAlignment(.leading)
            .padding(.vertical, LooprSpacing.sm)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Lays items out left to right and wraps to a new row when one does not fit.
struct AgentFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
        }
    }

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            // An item wider than the line wraps its own text, so offer it the whole line.
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            let needed = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + verticalSpacing)
            }
            current.width = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
