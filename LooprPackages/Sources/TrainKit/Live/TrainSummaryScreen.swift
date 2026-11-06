import DesignSystem
import SwiftUI
import WorkoutKit

/// A finished gym session: right after Finish, or opened again from a list (R2-LIFT-02, R2-WOD-07, R2-DES-05).
///
/// Both read the same way: a hero with the headline (volume for lifts, time held for holds), then every exercise with
/// its sets in their measure, tags, RPE and PR marks, then the bests, then the totals with the heart rate when the
/// workout record has it. Right after Finish the hero says "Session saved" and shows what the session added to the
/// week in the dose field's dots, and Done sits in the navigation bar. Opened later it says "Saved Tue 7 Nov", drops
/// the week line and Done, and Back returns to the list. Estimated values carry an "Estimated" chip, and a first
/// performance is a "First time", never a "New best".
public struct TrainSummaryScreen: View {
    /// Where the screen was opened from.
    public enum Mode: Equatable, Sendable {
        /// Right after Finish. The hero shows the week's new dots and Done leaves.
        case finished
        /// From a list. No saved chip of the moment, no week line, no Done.
        case past
    }

    private struct EditTarget: Identifiable, Equatable {
        let exercise: Int
        /// One past the last set means a new one.
        let set: Int
        var id: String { "\(exercise)-\(set)" }
    }

    /// The session as last saved here. A corrected set shows at once.
    @State private var session: TrainSession?
    @State private var corrected: TrainSessionDetail?
    @State private var editTarget: EditTarget?
    @State private var deleteTarget: EditTarget?
    @State private var saveFailed = false
    private let detail: TrainSessionDetail
    private let mode: Mode
    private let onDone: (() -> Void)?
    private let history: [TrainSession]
    private let workout: WorkoutRecord?
    private let save: (@Sendable (TrainSession) async throws -> TrainSession)?

    /// - Parameters:
    ///   - onDone: Leaves a just-finished summary. Ignored for `.past`, where Back leaves.
    ///   - session: The stored session. With `save`, a tap on a set fixes it.
    ///   - history: Earlier sessions, for what last time was.
    public init(detail: TrainSessionDetail, mode: Mode, session: TrainSession? = nil, history: [TrainSession] = [],
                workout: WorkoutRecord? = nil, save: (@Sendable (TrainSession) async throws -> TrainSession)? = nil,
                onDone: (() -> Void)? = nil) {
        self.detail = detail
        self.mode = mode
        self.onDone = onDone
        self.history = history
        self.workout = workout
        self.save = save
        _session = State(initialValue: session)
    }

    private var shown: TrainSessionDetail { corrected ?? detail }
    private var summary: TrainSummaryModel { shown.summary }
    private var comparison: TrainSessionComparison? { session.map { TrainSessionComparison(session: $0, history: history) } }

    public var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.cardStack) {
            hero
            exercisesSection
            bestsSection
            totalsSection
        }
        .navigationTitle(mode == .finished ? "Session summary" : summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(mode == .finished)
        .toolbar {
            if mode == .finished, let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                        .tint(Color.loopr(.fitnessTab))
                        .accessibilityIdentifier("train-summary-done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-summary-screen")
        .sheet(item: $editTarget) { target in editSheet(target) }
        .confirmationDialog(deleteTarget.map { "Delete set \($0.set + 1)?" } ?? "", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { target in
            Button("Delete set", role: .destructive) {
                apply { try TrainSessionCorrection.deleting($0, exerciseIndex: target.exercise, setIndex: target.set, history: history) }
            }
            .accessibilityIdentifier("train-detail-delete-confirm")
            Button("Keep", role: .cancel) {}
        } message: { target in
            Text(deleteMessage(target))
        }
    }

    @ViewBuilder
    private func editSheet(_ target: EditTarget) -> some View {
        if let line = session?.exercises[safe: target.exercise] {
            if let set = line.sets[safe: target.set] {
                TrainEditSetSheet(setNumber: target.set + 1, measure: line.planned.measure, wasSkipped: set.skipped,
                                  values: set.values, tag: set.tag, onDelete: { deleteTarget = target }, rpe: set.rpe,
                                  onSaveWithRPE: { values, tag, rpe in
                    apply {
                        try TrainSessionCorrection.editing($0, exerciseIndex: target.exercise, setIndex: target.set, values: values,
                                                           tag: tag, rpe: rpe, history: history)
                    }
                })
            } else {
                // A set forgotten in the gym starts from the one before it.
                TrainEditSetSheet(setNumber: target.set + 1, measure: line.planned.measure, wasSkipped: true,
                                  values: line.sets.last?.values ?? TrainSetValues(reps: line.planned.repsMax), tag: nil,
                                  rpe: line.sets.last?.rpe, onSaveWithRPE: { values, tag, rpe in
                    apply {
                        try TrainSessionCorrection.adding($0, exerciseIndex: target.exercise, values: values, tag: tag, rpe: rpe, history: history)
                    }
                })
            }
        }
    }

    private func deleteMessage(_ target: EditTarget) -> String {
        guard let line = session?.exercises[safe: target.exercise], let set = line.sets[safe: target.set] else { return "" }
        return "\(line.exercise.name), \(TrainSetFormat.set(set.values, measure: line.planned.measure)). Volume and bests update."
    }

    private func apply(_ change: (TrainSession) throws -> TrainSession) {
        guard let save, let current = session else { return }
        saveFailed = false
        guard let next = try? change(current) else { saveFailed = true; return }
        Task { @MainActor in
            do {
                let stored = try await save(next)
                session = stored
                corrected = TrainSessionDetail(session: stored, workout: workout)
            } catch {
                saveFailed = true
            }
        }
    }

    private var duration: String { LooprUnitFormatter.duration(minutes: summary.durationSeconds / 60) ?? "0 min" }

    // MARK: Hero

    private var hero: some View {
        let headline = summary.headlineParts
        return LooprSurface(emphasis: .hero(.fitnessTab)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Group {
                    switch mode {
                    case .finished: StatusChip("Session saved", symbol: "checkmark.circle.fill", tone: .positive)
                    case .past: StatusChip(detail.savedLine, symbol: "calendar", tone: .neutral)
                    }
                }
                .accessibilityIdentifier("train-summary-saved")
                LooprText(summary.name, style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprValueText(headline.value, unit: headline.unit, valueStyle: .metric)
                    LooprText("\(headline.caption) in \(duration)", style: .caption, color: .inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("train-summary-headline")
                if mode == .finished {
                    weekAddition
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-summary-hero")
    }

    /// The week's new dots: one plate for the strength session, then the zone minutes the band measured during it,
    /// drawn as the dose field draws them (R2-DES-05, R2-DES-20).
    @ViewBuilder
    private var weekAddition: some View {
        let added = detail.weekAddition
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("Added to your week".looprLabelCased, style: .sectionLabel, color: .inkSecondary)
            if added.strengthSessions > 0 {
                HStack(spacing: LooprSpacing.sm) {
                    LooprBarbellGraphic(plates: [20], outlines: 0, tint: .strain)
                        .frame(width: 120, height: 40)
                        .accessibilityHidden(true)
                    LooprText("1 strength session", style: .rowTitle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("train-summary-week-strength")
            }
            if added.zone2Dots > 0 {
                dotsRow(dots: added.zone2Dots, diameter: FitnessDotLayout.standardDiameter, tint: .strain,
                        text: "\(added.zone2Minutes) min in zone 2", identifier: "train-summary-week-zone2")
            }
            if added.hardDots > 0 {
                dotsRow(dots: added.hardDots, diameter: FitnessDotLayout.hardDiameter, tint: .heart,
                        text: "\(added.hardMinutes) min in zones 4 and 5", identifier: "train-summary-week-hard")
            }
            LooprText(summary.weekLine, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("train-summary-week")
            if added.zone2Dots + added.hardDots > 0 {
                LooprText("Zone minutes are the band's heart rate during this session. One dot is 5 minutes.",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, LooprSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-summary-week-dots")
    }

    private func dotsRow(dots: Int, diameter: CGFloat, tint: LooprColorToken, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(text, style: .rowTitle)
            FitnessDotsView(fill: FitnessDotFill(filled: dots, total: nil), diameter: diameter, tint: tint, entrance: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Exercises

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Exercises", detail: summary.exercisesText, accent: .fitnessTab,
                               identifier: "train-summary-exercises-header")
            ForEach(shown.exercises) { block in
                exerciseCard(block, comparison: comparison?.exercises[block.index])
            }
            if saveFailed {
                LooprInlineMessage("That set could not be saved. Your earlier numbers are still there.", tone: .warning)
                    .accessibilityIdentifier("train-detail-save-error")
            }
        }
    }

    private func exerciseCard(_ block: TrainSessionDetail.ExerciseBlock, comparison: TrainSessionComparison.Exercise?) -> some View {
        LooprCard(density: .flush) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(block.name, style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    LooprText(block.detail, style: .caption, color: .inkSecondary)
                    if let change = comparison?.changeLine {
                        LooprText(change, style: .caption)
                            .accessibilityIdentifier("train-detail-change-\(block.index)")
                    }
                    if let last = comparison?.lastTimeLine {
                        LooprText(last, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("train-detail-last-time-\(block.index)")
                    }
                    if let oneRepMax = comparison?.oneRepMaxLine {
                        LooprText(oneRepMax, style: .caption, color: .inkSecondary)
                            .accessibilityIdentifier("train-detail-1rm-\(block.index)")
                    }
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.sm)
                ForEach(block.sets) { set in
                    Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                        .padding(.leading, LooprSpacing.cardHorizontal).accessibilityHidden(true)
                    setRow(set, exercise: block.index)
                }
                if let rest = comparison?.restLine {
                    Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                        .padding(.leading, LooprSpacing.cardHorizontal).accessibilityHidden(true)
                    LooprText(rest, style: .caption, color: .inkSecondary)
                        .padding(.horizontal, LooprSpacing.cardHorizontal)
                        .padding(.vertical, LooprSpacing.xs)
                        .accessibilityIdentifier("train-detail-rest-\(block.index)")
                }
                if save != nil, let count = session?.exercises[safe: block.index]?.sets.count {
                    Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                        .padding(.leading, LooprSpacing.cardHorizontal).accessibilityHidden(true)
                    Button { editTarget = EditTarget(exercise: block.index, set: count) } label: {
                        LooprText("Add set", style: .settingsRow, color: LooprColorToken.fitnessTab.textInk)
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight - LooprSpacing.sm, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityIdentifier("train-detail-add-set-\(block.index)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(block.identifier)
    }

    @ViewBuilder
    private func setRow(_ set: TrainSessionDetail.SetLine, exercise: Int) -> some View {
        if save != nil, session != nil {
            Button { editTarget = EditTarget(exercise: exercise, set: set.index) } label: { setRowContent(set, exercise: exercise) }
                .buttonStyle(.looprPressableRow)
                .accessibilityLabel(set.spokenLabel)
                .accessibilityHint("Edit this set")
                .accessibilityIdentifier("train-detail-set-\(exercise)-\(set.index + 1)")
        } else {
            setRowContent(set, exercise: exercise)
        }
    }

    private func setRowContent(_ set: TrainSessionDetail.SetLine, exercise: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            Text(set.marker)
                .looprTypography(.metricValue)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(set.tagTitle == nil ? .inkSecondary : LooprColorToken.fitnessTab.textInk))
                .frame(minWidth: LooprSpacing.xl, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.valuesText)
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(set.isSkipped ? .inkMuted : .ink))
                    .fixedSize(horizontal: false, vertical: true)
                if let tag = set.tagTitle {
                    LooprText(tag, style: .caption, color: .inkSecondary)
                }
            }
            Spacer(minLength: LooprSpacing.xs)
            if set.isRecord {
                Text("PR")
                    .looprTypography(.confidence)
                    .foregroundStyle(Color.loopr(.recoveryHigh))
            }
            if let rpe = set.rpeText {
                LooprText(rpe, style: .caption, color: .inkSecondary)
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight - LooprSpacing.sm, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(set.spokenLabel)
        .accessibilityIdentifier("train-detail-set-\(exercise)-\(set.index + 1)")
    }

    // MARK: Bests

    @ViewBuilder
    private var bestsSection: some View {
        if !summary.bests.isEmpty || mode == .finished {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Personal bests", accent: .fitnessTab, identifier: "train-summary-bests-header")
                if summary.bests.isEmpty {
                    LooprCard {
                        LooprText("No new bests this time. Estimated values count only when they beat an earlier session.",
                                  style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("train-summary-no-bests")
                } else {
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(summary.bests) { best in
                                if best.index > 0 {
                                    Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                                        .accessibilityHidden(true)
                                }
                                bestRow(best)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bestRow(_ best: TrainSummaryModel.Best) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(best.exerciseName, style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText([best.metricTitle, best.setText].compactMap { $0 }.joined(separator: " · "),
                              style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: LooprSpacing.sm)
                VStack(alignment: .trailing, spacing: LooprSpacing.xxs) {
                    LooprText(best.valueText, style: .metricValue)
                    if let previous = best.previousText { LooprText(previous, style: .caption, color: .inkSecondary) }
                }
            }
            HStack(spacing: LooprSpacing.xs) {
                StatusChip(best.isNewBest ? "New best" : "First time", symbol: nil, tone: best.isNewBest ? .positive : .neutral)
                if best.isEstimated { StatusChip("Estimated", symbol: nil, tone: .neutral) }
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.metricRowVertical)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(best.spokenLabel)
        .accessibilityIdentifier(best.identifier)
    }

    // MARK: Totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Totals", accent: .fitnessTab, identifier: "train-summary-totals-header")
            HairlineMetricList(rows: metricRows)
            if let heart = detail.heart {
                LooprText("Heart rate: \(heart.source.prefix(1).lowercased() + heart.source.dropFirst()).",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .accessibilityIdentifier("train-summary-heart-source")
            }
        }
    }

    private var metricRows: [HairlineMetricRow] {
        var rows = [HairlineMetricRow(id: "train-summary-duration", title: "Duration", value: duration, valueStyle: .rowTitle)]
        if summary.tonnageKg > 0 {
            rows.append(HairlineMetricRow(id: "train-summary-volume", title: "Volume", value: summary.volumeText, unit: "kg"))
        }
        if summary.holdSeconds > 0 {
            rows.append(HairlineMetricRow(id: "train-summary-held", title: "Time held", value: summary.holdText))
        }
        if summary.metres > 0 {
            rows.append(HairlineMetricRow(id: "train-summary-distance", title: "Distance", value: summary.distanceText))
        }
        rows.append(HairlineMetricRow(id: "train-summary-sets", title: "Sets", value: summary.setsText,
                                      valueStyle: summary.warmUpSetCount > 0 ? .rowTitle : nil))
        rows.append(HairlineMetricRow(id: "train-summary-exercises", title: "Exercises", value: summary.exercisesText,
                                      valueStyle: .rowTitle))
        if let heart = detail.heart {
            rows.append(HairlineMetricRow(id: "train-summary-heart-average", title: "Average heart rate",
                                          value: "\(heart.averageBPM)", unit: "bpm"))
            rows.append(HairlineMetricRow(id: "train-summary-heart-max", title: "Max heart rate",
                                          value: "\(heart.maximumBPM)", unit: "bpm"))
            if let zone2 = heart.zone2Minutes, zone2 > 0 {
                rows.append(HairlineMetricRow(id: "train-summary-zone2", title: "Zone 2", value: "\(zone2)", unit: "min"))
            }
            if let hard = heart.hardMinutes, hard > 0 {
                rows.append(HairlineMetricRow(id: "train-summary-hard", title: "Zones 4 and 5", value: "\(hard)", unit: "min"))
            }
        }
        return rows
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
