import Charts
import DesignSystem
import SwiftUI

/// Every exercise the person has logged, newest first, with a search.
public struct ExerciseListScreen: View {
    @State private var query = ""
    private let history: ExerciseHistory?
    private let failure: String?
    private let open: (String) -> Void

    /// - Parameters:
    ///   - history: Nil while it loads.
    ///   - open: Called with the exercise key.
    public init(history: ExerciseHistory?, failure: String? = nil, open: @escaping (String) -> Void) {
        self.history = history; self.failure = failure; self.open = open
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                if let failure {
                    LooprInlineMessage(failure, tone: .warning).accessibilityIdentifier("exercise-history-failure")
                } else if let history {
                    if history.exercises.isEmpty {
                        LooprCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                                LooprText("No lifts yet", style: .cardTitle)
                                LooprText("Finish a gym workout and every exercise shows up here with its weights, reps and bests.",
                                          style: .prose, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("exercise-history-empty")
                    } else {
                        LooprCard(density: .flush) {
                            LooprSearchField("Search your exercises", text: $query, identifier: "exercise-history-search")
                        }
                        let shown = filtered(history)
                        LooprCard(density: .flush) {
                            LazyVStack(spacing: LooprSpacing.none) {
                                ForEach(Array(shown.enumerated()), id: \.element.key) { index, exercise in
                                    if index > 0 {
                                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                                    }
                                    row(exercise)
                                }
                            }
                        }
                        if shown.isEmpty {
                            LooprText("No exercise matches.", style: .prose, color: .inkSecondary)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("exercise-history-loading")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabSection)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-history-screen")
    }

    private func filtered(_ history: ExerciseHistory) -> [ExerciseHistory.Exercise] {
        let text = ExerciseName.compact(query)
        guard !text.isEmpty else { return history.exercises }
        let aliased = ExerciseAliases.key(forAlias: query)
        return history.exercises.filter { ExerciseName.compact($0.name).contains(text) || $0.key == aliased }
    }

    private func row(_ exercise: ExerciseHistory.Exercise) -> some View {
        let progress = ExerciseProgress(exercise)
        let best = progress.headline
        let last = exercise.lastDone.map { "Last \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? ""
        let sessions = exercise.entries.count == 1 ? "1 session" : "\(exercise.entries.count) sessions"
        return Button { open(exercise.key) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(exercise.name, style: .rowTitle).fixedSize(horizontal: false, vertical: true)
                    LooprText("\(last) · \(sessions)", style: .caption, color: .inkSecondary)
                }
                Spacer(minLength: LooprSpacing.sm)
                if let best { LooprText(best, style: .metricUnit, color: .ink) }
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel([exercise.name, progress.spokenHeadline.map { "best \($0)" }, last, sessions].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("exercise-history-row-\(exercise.key)")
    }
}

/// One exercise: its bests, the heaviest load per rep count, a chart and every session's sets. The bests, the chart
/// and the set lines follow the exercise's measure (R2-LIFT-01): a plank shows its longest hold, a carry its distance
/// and load, an assisted pull-up its least assistance. With fewer than three sessions the chart shows dots and no line.
public struct ExerciseDetailScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    private let exercise: ExerciseHistory.Exercise
    private let progress: ExerciseProgress

    public init(exercise: ExerciseHistory.Exercise) {
        self.exercise = exercise
        progress = ExerciseProgress(exercise)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                bests
                if !progress.points.isEmpty { chart }
                if !repBests.isEmpty { repBestList }
                sessions
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabSection)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-detail-screen")
    }

    private var bests: some View {
        let rows = stride(from: 0, to: progress.stats.count, by: 2).map { Array(progress.stats[$0..<min($0 + 2, progress.stats.count)]) }
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Bests")
            LooprCard {
                Grid(alignment: .leading, horizontalSpacing: LooprSpacing.md, verticalSpacing: LooprSpacing.sm) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row) { stat($0) }
                            if row.count == 1 { Color.clear.frame(height: LooprSpacing.hairline).accessibilityHidden(true) }
                        }
                    }
                }
            }
            if let footnote = progress.footnote {
                LooprText(footnote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("exercise-bests-footnote")
            }
        }
    }

    private func stat(_ stat: ExerciseProgress.Stat) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(stat.title.looprLabelCased, style: .sectionLabel, color: .inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                LooprText(stat.value ?? "–", style: .metricCompact)
                if let unit = stat.unit, stat.value != nil { LooprText(unit, style: .metricUnit, color: .inkSecondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("exercise-stat-\(stat.id)")
    }

    private var chart: some View {
        let progress = self.progress
        let points = progress.points
        let title = progress.metric.title
        let drawsLine = ExerciseTrend.drawsLine(pointCount: points.count)
        let dates = points.map(\.date)
        let spoken = points.map { "\(progress.spoken($0.value)) on \($0.date.formatted(.dateTime.day().month(.wide)))" }
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Progress", detail: title)
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Chart(points) { point in
                        if drawsLine {
                            LineMark(x: .value("Date", point.date), y: .value(title, point.value))
                                .foregroundStyle(Color.loopr(.fitnessTab))
                                .interpolationMethod(.monotone)
                        }
                        PointMark(x: .value("Date", point.date), y: .value(title, point.value))
                            .foregroundStyle(Color.loopr(.fitnessTab))
                            .symbolSize(drawsLine ? 30 : 60)
                    }
                    .chartYScale(domain: progress.valueDomain)
                    .chartXScale(domain: progress.dateDomain ?? (Date.distantPast...Date.distantFuture))
                    .chartXAxis {
                        // Up to two sessions, each dot gets its own date under it. After that four dates spread out.
                        if drawsLine {
                            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                AxisGridLine().foregroundStyle(Color.loopr(.divider))
                                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Color.loopr(.inkSecondary))
                            }
                        } else {
                            AxisMarks(values: dates) { _ in
                                AxisGridLine().foregroundStyle(Color.loopr(.divider))
                                AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(Color.loopr(.divider))
                            AxisValueLabel {
                                if let number = value.as(Double.self) { Text(progress.text(number)) }
                            }
                            .foregroundStyle(Color.loopr(.inkSecondary))
                        }
                    }
                    .frame(height: 180)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(points.count == 1
                        ? "\(title), one session, \(spoken.first ?? "")"
                        : "\(title) over \(points.count) sessions, from \(spoken.first ?? "") to \(spoken.last ?? "")")
                    .accessibilityIdentifier("exercise-progress-chart")
                    if let caption = progress.chartCaption {
                        LooprText(caption, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("exercise-progress-caption")
                    }
                }
            }
        }
    }

    /// Heaviest by reps is for loaded weight lifts only.
    private var repBests: [ExerciseRepBest] {
        progress.metric == .estimatedOneRepMax ? ExerciseRepBest.bests(for: exercise) : []
    }

    /// The heaviest load per rep count, for the rep counts the history has.
    private var repBestList: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Heaviest by reps", detail: "Sets you lifted, not estimates")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(repBests.enumerated()), id: \.element.id) { index, best in
                        if index > 0 {
                            Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                        }
                        let reps = best.reps == 1 ? "1 rep" : "\(best.reps) reps"
                        let day = best.date.formatted(.dateTime.day().month(.abbreviated).year())
                        HStack(spacing: LooprSpacing.sm) {
                            LooprText(reps, style: .rowTitle)
                            Spacer(minLength: LooprSpacing.sm)
                            VStack(alignment: .trailing, spacing: LooprSpacing.xxs) {
                                LooprText("\(TrainLiveFormat.kilograms(best.loadKg)) kg", style: .metricUnit, color: .ink)
                                LooprText(day, style: .caption, color: .inkSecondary)
                            }
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal)
                        .padding(.vertical, LooprSpacing.sm)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(reps), \(TrainLiveFormat.kilograms(best.loadKg)) kilograms, \(day)")
                        .accessibilityIdentifier("exercise-rep-best-\(best.reps)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-rep-bests")
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("History", detail: "Every session, newest first")
            LooprCard(density: .flush) {
                LazyVStack(alignment: .leading, spacing: LooprSpacing.none) {
                    ForEach(Array(exercise.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            HStack {
                                LooprText(entry.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()), style: .rowTitle)
                                Spacer(minLength: LooprSpacing.sm)
                                if let e1rm = entry.estimatedOneRepMax {
                                    LooprText("est. 1RM \(ExerciseFormat.kilograms(e1rm)) kg", style: .caption, color: .inkSecondary)
                                }
                            }
                            LooprText(ExerciseHistory.setsText(entry.sets, measure: entry.measure), style: .body)
                                .fixedSize(horizontal: false, vertical: true)
                            LooprText([entry.sessionName, ExerciseFormat.entryTotal(entry)].compactMap { $0 }.joined(separator: " · "),
                                      style: .caption, color: .inkSecondary)
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal)
                        .padding(.vertical, LooprSpacing.sm)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("exercise-history-entry-\(index)")
                    }
                }
            }
        }
    }
}

enum ExerciseFormat {
    /// The estimate rounded to half a kilo: anything finer suggests a precision it does not have.
    static func kilograms(_ value: Double) -> String { ExerciseProgressFormat.halfKilograms(value) }

    /// What one session's sets add up to, by measure: "3,200 kg lifted", "2:15 held", "120 m". Nil when there is
    /// nothing to add, so a bodyweight session never reads "0 kg lifted".
    static func entryTotal(_ entry: ExerciseHistory.Entry) -> String? {
        switch entry.measure {
        case .weight, .bodyweight:
            return entry.volumeKg > 0 ? "\(TrainLiveFormat.kilograms(entry.volumeKg)) kg lifted" : nil
        case .time:
            let seconds = entry.sets.reduce(0) { $0 + ($1.seconds ?? 0) }
            return seconds > 0 ? "\(TrainSetFormat.seconds(seconds)) held" : nil
        case .distance:
            let metres = entry.sets.reduce(0) { $0 + ($1.metres ?? 0) }
            return metres > 0 ? TrainSetFormat.metres(metres) : nil
        }
    }
}
