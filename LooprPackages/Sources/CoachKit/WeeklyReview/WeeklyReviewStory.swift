import DesignSystem
import SwiftUI

/// The weekly review as a story sheet (contract `p-week`): five progress bars on top, one page at a time, the colour
/// field behind. Tap the right of the page to go on and the left third to go back, or swipe. VoiceOver reads each
/// page as one element and offers Next page and Previous page. Under Reduce Motion the pages fade.
///
/// The proposal buttons sit under the page, at least 56 pt tall. Nothing is started or saved until one is tapped.
public struct WeeklyReviewStoryView: View {
    public static let startIdentifier = "weekly-review-start-experiment"
    public static let notNowIdentifier = "weekly-review-not-now"
    public static let closeIdentifier = "weekly-review-close"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private let controller: WeeklyStoryController
    private let onClose: () -> Void
    @State private var pageWidth: CGFloat = 0

    public init(controller: WeeklyStoryController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    /// Three blobs in the Protocol plum, the colour of the check-in the review belongs to (ICP R3-SEN-07, R3-DES-05).
    private static let palette = LooprColorFieldPalette(accent: .protocol, blobs: [
        .init(.protocol, left: -10, top: -6, width: 80, height: 40),
        .init(.cyclePlum, right: -25, top: 20, width: 70, height: 34, delay: -6),
        .init(.sleep, left: 0, top: 55, width: 70, height: 30, opacity: 0.6, delay: -12)
    ])

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }

    public var body: some View {
        ZStack {
            LooprColorField(palette: Self.palette)
            // The page scrolls across the whole width, so a drag anywhere moves a long rule list (ICP R3-VET-02).
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Group {
                    progressBars
                    header
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                pageArea
                Group {
                    if controller.offersProposal { proposalButtons }
                    Text(controller.story.footer)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkMuted))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, LooprSpacing.xs)
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
            }
            .padding(.top, LooprSpacing.sm)
        }
        .onChange(of: controller.resolution) { _, resolution in
            if resolution != nil { onClose() }
        }
    }

    // MARK: Chrome

    private var progressBars: some View {
        HStack(spacing: LooprSpacing.xxs) {
            ForEach(controller.pages.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.loopr(index <= controller.pageIndex ? .ink : .divider))
                    .frame(height: 3)
            }
        }
        .animation(reduces ? nil : .easeOut(duration: LooprMotion.fast), value: controller.pageIndex)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: LooprSpacing.xs) {
            LooprCoachOrb(size: .xs)
            Text(controller.page?.kicker ?? "")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            LooprGlassButton(symbol: "xmark", accessibilityLabel: "Close", size: .small,
                             identifier: Self.closeIdentifier, action: onClose)
        }
    }

    // MARK: Pages

    private var pageArea: some View {
        ScrollView {
            if let page = controller.page {
                pageView(page)
                    .id(page.position)
                    .transition(.opacity)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.bottom, LooprSpacing.md)
            }
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("weekly-review-page-scroll")
        .animation(reduces ? .linear(duration: 0) : .smooth(duration: LooprMotion.standard), value: controller.pageIndex)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pageWidth = $0 }
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            if tap.location.x < pageWidth / 3 { controller.previous() } else { controller.next() }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
            guard abs(drag.translation.width) > 50, abs(drag.translation.width) > abs(drag.translation.height) else { return }
            if drag.translation.width < 0 { controller.next() } else { controller.previous() }
        })
    }

    private func pageView(_ page: WeeklyStoryPage) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            Text(page.title)
                .looprTypography(.titleLarge)
                .foregroundStyle(Color.loopr(.ink))
                .accessibilityAddTraits(.isHeader)
            if page.kind != .proposal {
                Text(Self.attributed(page.note.runs))
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            detailView(page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(page))
        .accessibilityIdentifier(page.identifier)
        .accessibilityAction(named: "Next page") { controller.next() }
        .accessibilityAction(named: "Previous page") { controller.previous() }
    }

    /// The paragraph with its highlighted numbers set in the Protocol plum and a heavier weight (ICP R2-SEN-09).
    static func attributed(_ runs: [NoteRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isHighlighted {
                piece.foregroundColor = Color.loopr(.protocolChip)
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }

    /// What VoiceOver reads for one page.
    static func spokenSummary(_ page: WeeklyStoryPage) -> String {
        var parts = [page.kicker, page.title]
        switch page.detail {
        case .proposal(let proposal): parts += [proposal.label, proposal.changeTitle, page.note.text]
        case .change(let change): parts += [page.note.text] + change.receipt.groups.map(\.label)
        case .kept(let kept): parts += [page.note.text, kept.share.displayed, kept.dayCountText] + kept.key.map(\.text)
        default: parts.append(page.note.text)
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder private func detailView(_ page: WeeklyStoryPage) -> some View {
        switch page.detail {
        case .kept(let kept): keptView(kept)
        case .moved(let rows): movedView(rows)
        case .change(let change): changeView(change)
        case .proposal(let proposal): proposalCard(proposal, text: page.note.runs)
        case .nextWeek(let next): nextWeekView(next)
        }
    }

    /// The share in the Protocol plum, the colour of the check-in it matches (ICP R2-SEN-09), the day count, one mark
    /// per day as the rosette draws it, the key to those marks, and every rule with its count, "1 not known" where a day
    /// had no answer (ICP R3-DES-05, R3-SEN-07, R3-HAB-07, R3-VET-02). A day before the protocol has no mark.
    private func keptView(_ kept: WeeklyKeptDetail) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprHeroNumber(kept.share.value, unit: "%", color: .protocol)
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Text(kept.dayCountText)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .accessibilityIdentifier("weekly-review-day-count")
                    HStack(spacing: LooprSpacing.xs) {
                        ForEach(Array(kept.days.enumerated()), id: \.offset) { _, cell in
                            VStack(spacing: LooprSpacing.xxs) {
                                WeeklyDayDot(mark: cell.mark)
                                Text(String((cell.weekday ?? "").prefix(1)))
                                    .looprTypography(.caption)
                                    .foregroundStyle(Color.loopr(.inkMuted))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if !kept.key.isEmpty { dayKey(kept.key) }
                    ForEach(kept.rules) { rule in ruleRow(rule) }
                }
            }
        }
    }

    /// One line per mark the week shows, the mark drawn beside its words.
    private func dayKey(_ entries: [WeeklyDayKeyEntry]) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            ForEach(entries) { entry in
                HStack(alignment: .center, spacing: LooprSpacing.xs) {
                    WeeklyDayDot(mark: entry.mark, size: 10)
                    Text(entry.text)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, LooprSpacing.xxs)
        .accessibilityIdentifier("weekly-review-key")
    }

    /// The rule's name and its count. From the largest standard text size up the count moves under the name.
    private func ruleRow(_ rule: WeeklyRuleRow) -> some View {
        let layout = typeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.xs))
        return layout {
            Text(rule.title).looprTypography(.rowTitle).foregroundStyle(Color.loopr(.ink))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(rule.countText)
                .looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                .multilineTextAlignment(typeSize >= .xxxLarge ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("weekly-review-rule-\(rule.key.rawValue)")
    }

    private func movedView(_ rows: [WeeklyMovedRow]) -> some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            Text(row.title).looprTypography(.rowTitle).foregroundStyle(Color.loopr(.ink))
                            Text(row.comparison).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                        Spacer(minLength: LooprSpacing.xs)
                        Text(row.weekValue.displayed).looprTypography(.metricValue).foregroundStyle(Color.loopr(.ink))
                    }
                }
            }
        }
    }

    private func changeView(_ change: WeeklyChangeDetail) -> some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                WeeklyReceiptChart(chart: change.receipt)
                    .frame(height: 96)
                HStack(spacing: LooprSpacing.md) {
                    ForEach(Array(change.receipt.groups.enumerated()), id: \.offset) { index, group in
                        HStack(spacing: LooprSpacing.xxs) {
                            Circle().fill(Color.loopr(index == 0 ? .heart : .protocol)).frame(width: 8, height: 8)
                            Text(group.label).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                    }
                }
            }
        }
    }

    private func proposalCard(_ proposal: WeeklyReviewProposal, text: [NoteRun]) -> some View {
        LooprSurface(emphasis: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Text(proposal.label).looprTypography(.caption).foregroundStyle(Color.loopr(.protocolChip))
                Text(proposal.changeTitle).looprTypography(.cardTitle).foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.attributed(text)).looprTypography(.prose).foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nextWeekView(_ next: WeeklyNextWeekDetail) -> some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                ForEach(next.rules) { rule in
                    HStack(alignment: .firstTextBaseline) {
                        Text(rule.time ?? "Any time").looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                            .frame(width: 76, alignment: .leading)
                        Text(rule.title).looprTypography(.rowTitle).foregroundStyle(Color.loopr(.ink))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Proposal buttons

    private var proposalButtons: some View {
        VStack(spacing: LooprSpacing.xs) {
            Button("Start the experiment") { controller.startExperiment() }
                .buttonStyle(LooprButtonStyle(prominent: true, accent: .protocol))
                .accessibilityIdentifier(Self.startIdentifier)
            Button("Not now") { controller.notNow() }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol, quiet: true))
                .accessibilityIdentifier(Self.notNowIdentifier)
        }
    }
}

/// Every night as a dot, the two groups in two rows on one scale, with each group's mean marked.
struct WeeklyReceiptChart: View {
    let chart: NoteReceiptChart

    var body: some View {
        Canvas { context, size in
            let values = chart.groups.flatMap { $0.nights.map(\.value) }
            guard let low = values.min(), let high = values.max(), !chart.groups.isEmpty else { return }
            let span = max(high - low, 1)
            let inset: CGFloat = 8
            func x(_ value: Double) -> CGFloat { inset + CGFloat((value - low) / span) * (size.width - inset * 2) }
            let rowHeight = size.height / CGFloat(chart.groups.count)
            for (index, group) in chart.groups.enumerated() {
                let y = rowHeight * (CGFloat(index) + 0.5)
                let colour = Color.loopr(index == 0 ? .heart : .protocol)
                for (offset, night) in group.nights.enumerated() {
                    // Nights with the same value sit one above the other so none hides another.
                    let lift = CGFloat(offset % 3 - 1) * 5
                    let rect = CGRect(x: x(night.value) - 3, y: y + lift - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(0.75)))
                }
                var mean = Path()
                mean.move(to: CGPoint(x: x(group.mean), y: y - rowHeight * 0.4))
                mean.addLine(to: CGPoint(x: x(group.mean), y: y + rowHeight * 0.4))
                context.stroke(mean, with: .color(colour), lineWidth: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.groups.map(\.label).joined(separator: ", "))
    }
}

/// One day of the kept page, in the rosette's marks (ICP R3-DES-02, R3-DES-05): Kept a filled plum dot, Not kept a
/// filled plum dot with a small cross cut out, Skipped a ring with a slash, Open a hairline ring, and nothing before the
/// protocol started.
struct WeeklyDayDot: View {
    let mark: WeeklyDayMark
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: 0.75, dy: 0.75)
            let plum = Color.loopr(.protocol)
            switch mark {
            case .none:
                break
            case .kept:
                context.fill(Path(ellipseIn: rect), with: .color(plum))
            case .notKept:
                context.drawLayer { layer in
                    layer.fill(Path(ellipseIn: rect), with: .color(plum))
                    var cross = Path()
                    let inset = rect.width * 0.32
                    cross.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
                    cross.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                    cross.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
                    cross.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
                    layer.blendMode = .destinationOut
                    layer.stroke(cross, with: .color(.black), style: StrokeStyle(lineWidth: max(rect.width * 0.14, 1.5), lineCap: .round))
                }
            case .skipped:
                context.stroke(Path(ellipseIn: rect), with: .color(plum), lineWidth: 1.2)
                var slash = Path()
                slash.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.2))
                slash.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.2))
                context.stroke(slash, with: .color(plum), lineWidth: 1.2)
            case .open:
                context.stroke(Path(ellipseIn: rect), with: .color(plum.opacity(0.7)), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
