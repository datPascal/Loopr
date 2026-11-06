import DesignSystem
import SwiftUI

/// What the focus cards can do without leaving Today. The app fills these in; a nil action hides its button.
public struct TodayDialActions {
    /// Opens Food's meal editor over Today, by meal id.
    public var editMeal: (@MainActor (String) -> Void)?
    /// Ticks a manual protocol rule, by key. True when it was kept.
    public var tickRule: (@MainActor (String) async -> Bool)?

    public init(editMeal: (@MainActor (String) -> Void)? = nil, tickRule: (@MainActor (String) async -> Bool)? = nil) {
        self.editMeal = editMeal
        self.tickRule = tickRule
    }
}

public extension EnvironmentValues {
    /// What the dial's focus cards can do. Empty by default, so a card shows only what it reads.
    @Entry var todayDialActions = TodayDialActions()
}

/// Where everything sits inside the focus card, in the dial square's points. The UIKit transition flies the photo, the
/// badge and the stage spans to these rects, and the SwiftUI content leaves room for them.
struct TodayDialFocusLayout: Equatable {
    static let inset: CGFloat = 4
    static let padding: CGFloat = 18
    static let badgeSide: CGFloat = 44
    static let closeSide: CGFloat = 44

    let side: CGFloat
    /// `LooprStageTimeline`'s lane height at the current text size.
    let laneHeight: CGFloat

    var card: CGRect { CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: Self.inset, dy: Self.inset) }
    var cornerRadius: CGFloat { LooprRadius.card + 4 }

    var photo: CGRect {
        CGRect(x: card.minX + 10, y: card.minY + 10, width: card.width - 20, height: (card.height * 0.44).rounded())
    }

    var badge: CGRect {
        CGRect(x: card.minX + Self.padding, y: card.minY + Self.padding, width: Self.badgeSide, height: Self.badgeSide)
    }

    var close: CGRect {
        CGRect(x: card.maxX - Self.closeSide - 8, y: card.minY + 8, width: Self.closeSide, height: Self.closeSide)
    }

    var chart: CGRect {
        let height = TodayDialStageChartLayout.height(laneHeight: laneHeight)
        return CGRect(x: card.minX + Self.padding - 6, y: card.maxY - Self.padding - height,
                      width: card.width - (Self.padding - 6) * 2, height: height)
    }

    /// Room the SwiftUI content leaves above and below itself for what UIKit draws.
    func contentInsets(for detail: TodayDialFocusDetail) -> EdgeInsets {
        let top: CGFloat, bottom: CGFloat
        switch detail {
        case .meal: top = photo.maxY - card.minY + LooprSpacing.sm; bottom = Self.padding
        case .lastNight: top = Self.padding; bottom = card.maxY - chart.minY + LooprSpacing.sm
        case .tonight, .training, .rule, .bedtime, .alarm: top = badge.maxY - card.minY + LooprSpacing.sm; bottom = Self.padding
        }
        return EdgeInsets(top: top, leading: Self.padding, bottom: bottom, trailing: Self.padding)
    }
}

/// The live state one open card reads: the detail, and the chart's scrub and highlight, which the header shows.
@MainActor
final class TodayDialFocusStore: ObservableObject {
    @Published var detail: TodayDialFocusDetail?
    @Published var layout: TodayDialFocusLayout
    @Published var selection: Date?
    @Published var highlightedStage: SleepStage?
    /// A rule tick is on its way.
    @Published var ticking = false
    var actions = TodayDialActions()

    init(layout: TodayDialFocusLayout) {
        self.layout = layout
    }
}

/// The card's words and buttons. The plate, the photo, the badge, the close button and the chart are UIKit's.
struct TodayDialFocusCardContent: View {
    @ObservedObject var store: TodayDialFocusStore

    var body: some View {
        if let detail = store.detail {
            ScrollView(.vertical) {
                content(detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(store.layout.contentInsets(for: detail))
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(width: store.layout.card.width, height: store.layout.card.height)
        }
    }

    @ViewBuilder
    private func content(_ detail: TodayDialFocusDetail) -> some View {
        switch detail {
        case .meal(let meal): TodayDialMealCard(meal: meal, edit: store.actions.editMeal.map { edit in { edit(meal.id) } })
        case .lastNight(let night): TodayDialNightHeader(night: night, store: store)
        case .tonight(let tonight): TodayDialTonightCard(tonight: tonight)
        case .training(let training): TodayDialTrainingCard(training: training)
        case .rule(let rule): TodayDialRuleCard(rule: rule, store: store)
        case .bedtime(let bedtime): TodayDialBedtimeCard(bedtime: bedtime)
        case .alarm(let alarm): TodayDialAlarmCard(alarm: alarm)
        }
    }
}

/// The chart under the night header: Sleep's own stage timeline, scrubbable, sharing its scrub with the header.
struct TodayDialFocusChart: View {
    @ObservedObject var store: TodayDialFocusStore

    var body: some View {
        if case .lastNight(let night) = store.detail {
            LooprStageTimeline(spans: night.spans, highlightedStage: $store.highlightedStage, selection: $store.selection,
                               timeZone: night.timeZone, identifier: "today-dial-focus-stages", showsReadout: false)
                .frame(width: store.layout.chart.width, height: store.layout.chart.height, alignment: .top)
        }
    }
}

// MARK: - Cards

private struct TodayDialMealCard: View {
    let meal: TodayDialFocusDetail.Meal
    let edit: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(alignment: .center, spacing: LooprSpacing.xs) {
                LooprText(meal.title, style: .cardTitle)
                    .accessibilityAddTraits(.isHeader)
                LooprText(meal.time, style: .metricUnit, color: .inkSecondary)
                    .monospacedDigit()
                Spacer(minLength: LooprSpacing.xs)
                if let edit {
                    Button(action: edit) {
                        Label("Edit", systemImage: "pencil")
                            .looprTypography(.chip)
                            .foregroundStyle(Color.loopr(.energy))
                            .padding(.horizontal, LooprSpacing.sm)
                            .frame(minHeight: 32)
                            .background(Capsule().fill(Color.loopr(.energy).opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit meal")
                    .accessibilityIdentifier("today-dial-focus-edit-meal")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                LooprText(meal.energy ?? "Calories not known", style: .metricValue, color: meal.energy == nil ? .inkSecondary : .ink)
                    .monospacedDigit()
                Spacer(minLength: LooprSpacing.xs)
                ProvenanceChip(meal.provenance)
            }
            if !meal.macros.isEmpty {
                splitBar
                HStack(spacing: LooprSpacing.sm) {
                    ForEach(meal.macros) { macro in
                        HStack(spacing: LooprSpacing.xxs) {
                            Circle().fill(Color.loopr(macro.token)).frame(width: 7, height: 7)
                            Text("\(macro.letter) \(macro.text)")
                                .looprTypography(.caption)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let items = meal.items {
                LooprText(items, style: .caption, color: .inkSecondary)
                    .lineLimit(2)
            }
            if let note = meal.note {
                LooprText(note, style: .caption, color: .inkMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !filled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.2).delay(0.25)) { filled = true }
        }
    }

    /// The meal's energy split by macro, filling from the left once the card has landed.
    private var splitBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(meal.macros.filter { $0.energyShare != nil }) { macro in
                    Capsule()
                        .fill(Color.loopr(macro.token))
                        .frame(width: max((proxy.size.width - 4) * (macro.energyShare ?? 0) * (filled ? 1 : 0), 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Color.loopr(.ink).opacity(0.06)))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct TodayDialNightHeader: View {
    let night: TodayDialFocusDetail.Night
    @ObservedObject var store: TodayDialFocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText("Last night", style: .sectionLabel, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                LooprText(night.asleep ?? "Not counted", style: .metric)
                    .monospacedDigit()
                LooprText("asleep", style: .body, color: .inkSecondary)
                if night.isPartial { StatusChip("Partial", symbol: nil, accent: .warning) }
            }
            .padding(.trailing, TodayDialFocusLayout.closeSide)
            HStack(spacing: LooprSpacing.xs) {
                LooprText(night.range, style: .caption, color: .inkSecondary)
                    .monospacedDigit()
                ProvenanceChip(night.provenance)
            }
            LooprText(readout, style: .caption, color: store.selection == nil && store.highlightedStage == nil ? .inkMuted : .ink)
                .monospacedDigit()
                .lineLimit(2)
                .contentTransition(.numericText())
                .padding(.top, LooprSpacing.xxs)
        }
    }

    /// The chart's scrub readout, as Sleep shows it above its lanes.
    private var readout: String {
        let model = LooprStageTimelineModel(spans: night.spans, timeZone: night.timeZone)
        if let selection = store.selection, let span = model.span(at: selection) { return model.readout(for: span) }
        if let stage = store.highlightedStage { return model.highlightSummary(for: stage) }
        return night.stages.isEmpty ? "Hold the chart and drag to read the night" : night.stages
    }
}

private struct TodayDialTonightCard: View {
    let tonight: TodayDialFocusDetail.Tonight

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText("Tonight", style: .sectionLabel, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LooprText(tonight.bedtime, style: .cardTitle)
            HStack(spacing: LooprSpacing.xs) {
                if let countdown = tonight.countdown { StatusChip(countdown, symbol: "moon.fill", accent: .sleep) }
                ProvenanceChip(tonight.provenance, qualifier: tonight.bedtimeSource)
            }
            if let windDown = tonight.windDown { line(windDown, symbol: "sparkles") }
            if let wake = tonight.wake { line(wake, symbol: "sunrise") }
        }
    }

    private func line(_ text: String, symbol: String) -> some View {
        Label { LooprText(text, style: .body, color: .inkSecondary) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.loopr(.sleep))
        }
    }
}

private struct TodayDialTrainingCard: View {
    let training: TodayDialFocusDetail.Training

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(training.title, style: .cardTitle)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: LooprSpacing.xs) {
                LooprText(training.time, style: .body, color: .inkSecondary)
                    .monospacedDigit()
                if let duration = training.duration {
                    LooprText("· \(duration)", style: .body, color: .inkSecondary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: LooprSpacing.xs) {
                StatusChip(training.status, symbol: training.isPlanned ? "calendar" : "checkmark", accent: .strain)
                ProvenanceChip(training.provenance)
            }
        }
    }
}

private struct TodayDialRuleCard: View {
    let rule: TodayDialFocusDetail.Rule
    @ObservedObject var store: TodayDialFocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(rule.title, style: .cardTitle)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: LooprSpacing.xs) {
                LooprText(rule.time, style: .body, color: .inkSecondary)
                    .monospacedDigit()
                StatusChip(rule.status, symbol: symbol, accent: accent)
            }
            LooprText(rule.source, style: .caption, color: .inkSecondary)
            if rule.canTick, let tick = store.actions.tickRule {
                Button {
                    store.ticking = true
                    Task { @MainActor in
                        _ = await tick(rule.key)
                        store.ticking = false
                    }
                } label: {
                    Label(store.ticking ? "Saving" : "Mark as done", systemImage: "checkmark")
                }
                .buttonStyle(LooprButtonStyle(prominent: true, accent: .protocol))
                .disabled(store.ticking)
                .padding(.top, LooprSpacing.xxs)
                .accessibilityIdentifier("today-dial-focus-tick")
            }
        }
    }

    private var symbol: String {
        switch rule.state {
        case .kept: "checkmark"
        case .missed: "xmark"
        case .pending: "clock"
        case .unknown: "questionmark"
        }
    }

    private var accent: LooprColorToken {
        switch rule.state {
        case .kept: .protocol
        case .missed: .inkSecondary
        case .pending: .protocol
        case .unknown: .inkMuted
        }
    }
}

private struct TodayDialBedtimeCard: View {
    let bedtime: TodayDialFocusDetail.Bedtime

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText("Bedtime", style: .sectionLabel, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LooprText(bedtime.time, style: .metric)
                .monospacedDigit()
            HStack(spacing: LooprSpacing.xs) {
                if let countdown = bedtime.countdown { StatusChip(countdown, symbol: "moon.fill", accent: .sleep) }
                if let status = bedtime.status { StatusChip(status, symbol: nil, accent: .protocol) }
            }
            ProvenanceChip(bedtime.provenance, qualifier: bedtime.source)
        }
    }
}

private struct TodayDialAlarmCard: View {
    let alarm: TodayDialFocusDetail.Alarm

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText("Wake alarm", style: .sectionLabel, color: .inkSecondary)
                .accessibilityAddTraits(.isHeader)
            LooprText(alarm.time, style: .metric)
                .monospacedDigit()
            LooprText(alarm.day, style: .body, color: .inkSecondary)
            if let window = alarm.smartWindow {
                LooprText(window, style: .caption, color: .inkSecondary)
            }
        }
    }
}
