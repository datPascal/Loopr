import DesignSystem
import SwiftUI
import WorkoutKit

/// What the start sheet asks Train to do.
enum TrainStartChoice: Equatable {
    /// A gym workout from a strength template, or an empty one with nil.
    case gym(UUID?)
    /// Any saved workout. A cardio one starts recording its activity.
    case template(UUID)
    /// The start screen for a recorded activity.
    case activity(ActivityType)
    case intervals
    /// The For time and AMRAP clock with a round counter (R2-WOD-01).
    case wodClock
    /// Save the beginner's full-body workout and start it (R3-NEW-01).
    case starterRoutine
    case logPast
    case newTemplate
}

/// A group of starts in the sheet: a heading and its chips.
struct TrainStartGroup: Equatable, Identifiable {
    enum Chip: Equatable, Hashable {
        case activity(ActivityType)
        case intervals
        case wodClock
        case logPast
    }

    let title: String
    let chips: [Chip]
    var id: String { title }
}

/// Every way to start training in one sheet (R1-DES-07): the gym (empty or from a template), then the activities in
/// groups (Endurance, Classes and mobility, CrossFit, Other) as the same chips the tab's rail uses, the two timers in
/// their own group (R2-VET-05) and the quick log. It opens at half height and drags up to full.
struct TrainStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [TrainTemplateSummary]
    let choose: (TrainStartChoice) -> Void

    /// Every recordable activity sits in exactly one group (tested).
    static let groups: [TrainStartGroup] = [
        TrainStartGroup(title: "Endurance", chips: [.run, .cycle, .walk, .hike, .swim, .rowing, .cardio].map(TrainStartGroup.Chip.activity)),
        TrainStartGroup(title: "Classes and mobility", chips: [.yoga, .pilates, .mobility, .dance, .climbing].map(TrainStartGroup.Chip.activity)),
        TrainStartGroup(title: "CrossFit", chips: [.activity(.crossfit), .activity(.hiit)]),
        TrainStartGroup(title: "Timers", chips: [.wodClock, .intervals]),
        TrainStartGroup(title: "Other", chips: [.activity(.sport), .activity(.other), .logPast])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    gym
                    ForEach(Self.groups) { group in
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader(group.title, identifier: "train-start-group-\(TrainOverviewModel.slug(group.title))")
                            TrainChipFlow(spacing: LooprSpacing.xs) {
                                ForEach(group.chips, id: \.self) { chip(for: $0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
                .padding(.bottom, LooprSpacing.lg)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Start a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("train-start-cancel")
                }
            }
        }
        .tint(Color.loopr(.fitnessTab))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.loopr(.background))
        .accessibilityIdentifier("train-start-sheet")
    }

    @ViewBuilder
    private func chip(for chip: TrainStartGroup.Chip) -> some View {
        switch chip {
        case .activity(let activity):
            TrainRailChip(title: activity.shortName, symbol: activity.symbolName, spoken: activity.displayName,
                          identifier: "train-start-activity-\(activity.rawValue)") { choose(.activity(activity)) }
        case .intervals:
            TrainRailChip(title: "Interval timer", symbol: "timer", spoken: "Interval timer",
                          identifier: "train-start-intervals") { choose(.intervals) }
        case .wodClock:
            TrainRailChip(title: "WOD clock", symbol: "stopwatch", spoken: "WOD clock, for time or AMRAP",
                          identifier: "train-start-wod-clock") { choose(.wodClock) }
        case .logPast:
            TrainRailChip(title: "Log a past session", symbol: "clock.arrow.circlepath", spoken: "Log a session you already did",
                          identifier: "train-start-log") { choose(.logPast) }
        }
    }

    private var gym: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Gym", actionTitle: "New", accent: .fitnessTab, identifier: "train-start-templates",
                               actionIdentifier: "train-start-new-template") { choose(.newTemplate) }
            Button { choose(.gym(nil)) } label: {
                Label("Empty workout", systemImage: "plus")
            }
            .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
            .accessibilityIdentifier("train-start-empty")
            LooprText("Add exercises as you go. Loopr fills in your weights from last time.", style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.xxs)
            if TrainStarterRoutine.isOffered(templateNames: templates.filter { $0.kind == .strength }.map(\.name)) {
                starterRow
            }
            if !templates.isEmpty {
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                            if index > 0 {
                                Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                                    .padding(.leading, LooprSpacing.cardHorizontal + 44 + LooprSpacing.sm).accessibilityHidden(true)
                            }
                            templateRow(template)
                        }
                    }
                }
                .padding(.top, LooprSpacing.xs)
            }
        }
    }

    /// The beginner's workout, for someone with few workouts of their own (R3-NEW-01).
    private var starterRow: some View {
        LooprCard(density: .flush) {
            Button { choose(.starterRoutine) } label: {
                HStack(spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(TrainStarterRoutine.name, style: .rowTitle)
                        LooprText(TrainStarterRoutine.caption, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: LooprSpacing.sm)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.loopr(.fitnessTab))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel("Start \(TrainStarterRoutine.name). \(TrainStarterRoutine.caption)")
            .accessibilityHint("Saves it as your workout, then starts it")
            .accessibilityIdentifier("train-start-starter")
        }
        .padding(.top, LooprSpacing.xs)
    }

    private func templateRow(_ template: TrainTemplateSummary) -> some View {
        Button { choose(template.kind == .strength ? .gym(template.id) : .template(template.id)) } label: {
            HStack(spacing: LooprSpacing.sm) {
                TrainKindBadge(kind: template.kind)
                VStack(alignment: .leading, spacing: 2) {
                    LooprText(template.name, style: .rowTitle)
                    if !template.caption.isEmpty {
                        LooprText(template.caption, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LooprSpacing.sm)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.loopr(.fitnessTab))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight + 8, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel("Start \(template.spokenLabel)")
        .accessibilityIdentifier("train-start-template-\(template.slug)")
    }
}

/// One way to start, as a capsule: a figure and a short name. The tab's rail and the start sheet both draw it
/// (R1-DES-07), so starting looks the same everywhere. At least 56 pt tall.
struct TrainRailChip: View {
    let title: String
    let symbol: String
    let spoken: String
    let identifier: String
    var prominent = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(prominent ? LooprColorToken.fitnessTab.filledLabelColor : Color.loopr(.fitnessTab))
                    .accessibilityHidden(true)
                Text(title)
                    .looprTypography(.label)
                    .foregroundStyle(prominent ? LooprColorToken.fitnessTab.filledLabelColor : Color.loopr(.ink))
                    .lineLimit(1)
            }
            .padding(.horizontal, LooprSpacing.md)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .background(prominent ? Color.loopr(.fitnessTab) : Color.loopr(.fitnessTab).opacity(LooprAppearance.isDark(colorScheme) ? 0.14 : 0.10),
                        in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(identifier)
    }
}

/// Lays chips out left to right and wraps them onto the next line, so every start stays visible at any text size.
struct TrainChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = Self.rows(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in Self.rows(sizes: sizes, width: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes[index]
                // A chip wider than the line is clamped to it rather than pushed off screen.
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row: Equatable {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }

    /// Which chips share a line: as many as fit, at least one each.
    static func rows(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for (index, size) in sizes.enumerated() {
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current = Row(indices: current.indices + [index], width: needed, height: max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A small disc with a figure, in front of a workout or session row.
struct TrainActivityBadge: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.39, weight: .semibold))
            .foregroundStyle(Color.loopr(.fitnessTab))
            .frame(width: size, height: size)
            .background(Color.loopr(.fitnessTab).opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The badge for a saved workout: a dumbbell for the gym, a runner for cardio.
struct TrainKindBadge: View {
    let kind: WorkoutTemplateKind

    var body: some View {
        TrainActivityBadge(symbol: kind == .strength ? ActivityType.strength.symbolName : ActivityType.run.symbolName)
    }
}

/// This week's totals over every finished session: how many, how long, how much lifted.
struct TrainWeekTotals: Equatable {
    let count: Int
    let minutes: Int
    let liftedKg: Int
    /// Workouts in the list that stopped before they were saved. They are not in the totals until they are.
    let unsavedActivities: [String]

    init(workouts: [WorkoutRecord], sessions: [TrainSessionSummary]) {
        let finished = workouts.filter { $0.state == .completed }
        count = finished.count
        unsavedActivities = workouts.filter { $0.state == .interruptedAndRecoverable }.map(\.activity.displayName)
        minutes = finished.reduce(0) { total, workout in
            guard let start = workout.startedAt, let end = workout.endedAt, end > start else { return total }
            return total + Int((end.timeIntervalSince(start) / 60).rounded())
        }
        liftedKg = sessions.reduce(0) { $0 + $1.tonnageKg }
    }

    /// "45" min, or "3.5" h from two hours.
    var timeValue: String {
        minutes < 120 ? "\(minutes)" : (Double(minutes) / 60).formatted(.number.precision(.fractionLength(0...1)).locale(LooprUnitFormatter.displayLocale))
    }

    var timeUnit: String { minutes < 120 ? "min" : "h" }

    /// "8,420" kg, or "12.4" t from ten tonnes.
    var liftedValue: String {
        // The app's one number locale, so a German-region phone reads "8,420 kg" as the row's description does (R3-OPT-11).
        liftedKg < 10_000 ? liftedKg.formatted(.number.grouping(.automatic).locale(LooprUnitFormatter.displayLocale))
            : (Double(liftedKg) / 1_000).formatted(.number.precision(.fractionLength(0...1)).locale(LooprUnitFormatter.displayLocale))
    }

    var liftedUnit: String { liftedKg < 10_000 ? "kg" : "t" }

    /// Why a workout in the list is missing from Sessions and Time (R2-UPG-11). Nil when every workout is counted.
    var unsavedNote: String? {
        switch unsavedActivities.count {
        case 0: nil
        case 1: "\(unsavedActivities[0]) is not counted until you finish saving it."
        default: "\(unsavedActivities.count) workouts are not counted until you finish saving them."
        }
    }
}
