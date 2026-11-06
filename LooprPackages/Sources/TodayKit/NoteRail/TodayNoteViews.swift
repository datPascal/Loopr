import DesignSystem
import Foundation
import SwiftUI

/// The coach note card: the orb and "Loopr · morning note", the rule-written sentence with its numbers emphasised,
/// the receipt chart, where each number came from, and the actions.
struct TodayNoteCardView: View {
    let state: TodayNoteState
    let act: @MainActor (TodayNoteAction) -> Void
    /// The comparison chart and the sources wait behind "See the nights", so the note reads as two sentences first
    /// (UX R1-DES-01, R1-DES-07).
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            header
            switch state {
            case .note(let card):
                TodayNoteText(card: card)
                if showsDetail {
                    if let receipt = card.receipt {
                        TodayNoteReceiptView(receipt: receipt)
                    }
                    if !card.sources.isEmpty {
                        TodayFlowLayout(spacing: LooprSpacing.xxs) {
                            ForEach(Array(card.sources.enumerated()), id: \.offset) { index, source in
                                ProvenanceChip(source.provenance, qualifier: source.number,
                                               identifier: "today-note-source-\(index)")
                            }
                        }
                    }
                } else if card.receipt != nil || !card.sources.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: LooprMotion.fast)) { showsDetail = true }
                    } label: {
                        HStack(spacing: LooprSpacing.xxs) {
                            Text(TodayNoteCard.detailToggle)
                                .looprTypography(.label)
                                .foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the nights this note compares and where its numbers came from.")
                    .accessibilityIdentifier("today-note-detail")
                }
                if !card.chips.isEmpty {
                    TodayFlowLayout(spacing: LooprSpacing.xs) {
                        ForEach(card.chips) { chip in
                            LooprGlassButton(chip.label, identifier: chip.action.identifier) { act(chip.action) }
                        }
                    }
                }
            case .learning(let have, let need):
                Text(TodayNoteState.learningText(have: have, need: need))
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("today-note-learning")
            case .absent:
                Text(TodayNoteState.absentText)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("today-note-absent")
            }
        }
        .padding(.vertical, LooprSpacing.md)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-note")
    }

    private var kind: TodayNoteKind { state.card?.kind ?? .morning }

    private var header: some View {
        TodayFlowLayout(spacing: LooprSpacing.xs) {
            HStack(spacing: LooprSpacing.xs) {
                LooprCoachOrb(size: .xs)
                Text(kind.header)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.ink))
            }
            Text("on this iPhone")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The note's sentence. Number runs are semibold; highlighted numbers take the brand's text colour.
struct TodayNoteText: View {
    let card: TodayNoteCard

    var body: some View {
        Text(Self.attributed(card.runs))
            .looprTypography(.prose)
            .foregroundStyle(Color.loopr(.ink))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(card.text)
            .accessibilityHint(card.coverage)
            .accessibilityIdentifier("today-note-text")
    }

    static func attributed(_ runs: [TodayNoteRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isNumber {
                piece.inlinePresentationIntent = .stronglyEmphasized
                if run.isHighlighted { piece.foregroundColor = Color.loopr(LooprColorToken.brand.textInk) }
            }
            result += piece
        }
        return result
    }
}

/// The two comparison groups side by side as dots, with each group's average as a dashed line and last night ringed.
/// The dots land once a day under `LooprEntranceStore`; every later visit and Reduce Motion show them in place.
struct TodayNoteReceiptView: View {
    let receipt: TodayNoteReceipt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.looprEntranceStore) private var entranceStore
    @State private var entrance = false
    @State private var startedAt: Date?

    static let entranceTab = "today-note-receipt"
    static let entranceDuration = 0.9
    static let chartHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            chart
                .frame(height: Self.chartHeight)
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel(receipt.spokenSummary)
                .accessibilityIdentifier("today-note-receipt")
            TodayFlowLayout(spacing: LooprSpacing.sm) {
                ForEach(receipt.groups) { group in
                    HStack(spacing: LooprSpacing.xxs + 2) {
                        Circle().fill(Color.loopr(group.tint)).frame(width: 8, height: 8)
                        Text(group.label)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(LooprSpacing.sm)
        .background(Color.loopr(.divider).opacity(0.6), in: RoundedRectangle(cornerRadius: LooprRadius.compactCard, style: .continuous))
        .looprEntrance(tab: Self.entranceTab, animates: $entrance, duration: Self.entranceDuration)
        .onChange(of: entrance, initial: true) { _, animates in
            guard animates, !LooprMotion.reducesMotion(reduceMotion), !entranceStore.forcesFinalState else { return }
            startedAt = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.entranceDuration + 0.1))
                startedAt = nil
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if let startedAt {
            TimelineView(.animation) { context in
                canvas(progress: min(max(context.date.timeIntervalSince(startedAt) / Self.entranceDuration, 0), 1))
            }
        } else {
            canvas(progress: 1)
        }
    }

    private func canvas(progress: Double) -> some View {
        let receipt = receipt
        let ink = Color.loopr(.ink)
        let tints = receipt.groups.map { Color.loopr($0.tint) }
        return Canvas { context, size in
            let layout = TodayNoteReceiptLayout(receipt: receipt, size: size)
            for (index, lane) in layout.lanes.enumerated() {
                let tint = tints[index]
                var mean = Path()
                mean.move(to: CGPoint(x: lane.frame.minX, y: lane.meanY))
                mean.addLine(to: CGPoint(x: lane.frame.maxX, y: lane.meanY))
                context.stroke(mean, with: .color(tint.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                for dot in lane.dots {
                    // Each dot drops in on its turn and settles in place.
                    let share = min(max((progress - dot.delay) / 0.35, 0), 1)
                    guard share > 0 else { continue }
                    let y = dot.center.y - (1 - share) * 14
                    let rect = CGRect(x: dot.center.x - TodayNoteReceiptLayout.dotRadius, y: y - TodayNoteReceiptLayout.dotRadius,
                                      width: TodayNoteReceiptLayout.dotRadius * 2, height: TodayNoteReceiptLayout.dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.82 * share)))
                }
            }
            if let marker = layout.lastNight, progress >= 1 {
                let radius = TodayNoteReceiptLayout.dotRadius + 2.5
                context.stroke(Path(ellipseIn: CGRect(x: marker.x - radius, y: marker.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(ink), lineWidth: 1.5)
            }
        }
    }
}

/// Where each dot of the receipt chart sits. Pure, so the layout is tested without drawing.
struct TodayNoteReceiptLayout {
    struct Dot: Equatable {
        let center: CGPoint
        /// When the dot starts to land, 0 to 0.65 of the entrance.
        let delay: Double
    }

    struct Lane: Equatable {
        let frame: CGRect
        let meanY: CGFloat
        let dots: [Dot]
    }

    static let dotRadius: CGFloat = 4
    static let laneGap: CGFloat = 16

    let lanes: [Lane]
    /// Last night's value, in the lane of the group like last night.
    let lastNight: CGPoint?

    init(receipt: TodayNoteReceipt, size: CGSize) {
        guard let range = receipt.valueRange, !receipt.groups.isEmpty, size.width > 0, size.height > 0 else {
            lanes = []; lastNight = nil; return
        }
        let inset = Self.dotRadius + 3
        func y(_ value: Double) -> CGFloat {
            let share = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
            return inset + (size.height - inset * 2) * CGFloat(1 - share)
        }
        let count = CGFloat(receipt.groups.count)
        let laneWidth = (size.width - Self.laneGap * (count - 1)) / count
        let total = max(receipt.groups.map(\.values.count).reduce(0, +), 1)
        var order = 0
        var lanes: [Lane] = []
        var marker: CGPoint?
        for (index, group) in receipt.groups.enumerated() {
            let frame = CGRect(x: CGFloat(index) * (laneWidth + Self.laneGap), y: 0, width: laneWidth, height: size.height)
            // Dots spread across the lane in history order, so equal values sit side by side instead of on top of each other.
            let step = group.values.count > 1 ? (laneWidth - Self.dotRadius * 4) / CGFloat(group.values.count - 1) : 0
            let start = group.values.count > 1 ? frame.minX + Self.dotRadius * 2 : frame.midX
            let dots = group.values.enumerated().map { offset, value in
                defer { order += 1 }
                return Dot(center: CGPoint(x: start + step * CGFloat(offset), y: y(value)),
                           delay: 0.65 * Double(order) / Double(total))
            }
            lanes.append(Lane(frame: frame, meanY: y(group.mean), dots: dots))
            if group.isLikeLastNight, let value = receipt.lastNightValue, let last = dots.last {
                // The history's newest night is last night: ring it where it sits.
                marker = CGPoint(x: last.center.x, y: y(value))
            }
        }
        self.lanes = lanes
        lastNight = marker
    }
}

/// The first-evening card: the bedtime Live Activity stays off until the person starts it here or in Settings.
struct TodayFirstEveningCard: View {
    let act: @MainActor (Bool) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            Text(TodayFirstEveningCopy.title)
                .looprTypography(.cardTitle)
                .foregroundStyle(Color.loopr(.ink))
                .accessibilityAddTraits(.isHeader)
            Text(TodayFirstEveningCopy.body(locale: locale))
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TodayFlowLayout(spacing: LooprSpacing.xs) {
                LooprGlassButton(TodayFirstEveningCopy.start, symbol: "moon.stars", prominent: true,
                                 identifier: "today-first-evening-start") { act(true) }
                LooprGlassButton(TodayFirstEveningCopy.dismiss, identifier: "today-first-evening-dismiss") { act(false) }
            }
        }
        .padding(.vertical, LooprSpacing.md)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-first-evening")
    }
}
