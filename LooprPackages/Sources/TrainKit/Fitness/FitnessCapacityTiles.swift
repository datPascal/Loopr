import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A saved test on its way into its tile: where the flow's hero was on screen, and what it saved.
struct FitnessCapacityLanding: Equatable, Identifiable {
    let id = UUID()
    let outcome: CapacityFlowOutcome
    /// The flow's hero number, in global coordinates, as it was when the person tapped Save.
    let heroFrame: CGRect
}

/// The capacity tests as four small instruments (the contract's `.cap4`): a grip dial, a dead hang
/// ring against two minutes, ten sit to stand bars and a balance bar, then heart rate recovery from the
/// latest scored workout. Each shows today's best, when to retest, and turns to the warning colour only
/// when the best is under the person's own goal for 85. A tap opens the test. A saved result flies in as
/// dots from the test's hero number and the tile's value counts up as they land.
struct FitnessCapacityTiles: View {
    let tiles: [FitnessCapacityTile]
    let heartRateRecovery: FitnessCapacityTile?
    /// A result saved in a test, to fly in once the test has closed.
    let landing: FitnessCapacityLanding?
    let open: (FitnessCapacityTile) -> Void
    /// Called when the landing has played, so it plays once.
    let landed: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.looprDotFlight) private var flight
    @Environment(\.looprEntranceStore) private var entranceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each tile is on screen. Kept in a box nobody observes, so scrolling never redraws the tiles.
    @State private var globalFrames = FitnessTileFrames()
    @State private var countKind: CapacityTestKind?
    @State private var countUp: LooprCountUp?
    @State private var haptic: LooprHaptic?

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Capacity", identifier: "fitness-capacity-header")
            if tiles.allSatisfy({ $0.valueText == nil }) {
                LooprText(FitnessOverview.capacityIntro, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fitness-capacity-intro")
            }
            // A grid, not a lazy one, so the tiles in a row share the height of the tallest.
            Grid(horizontalSpacing: LooprSpacing.xs, verticalSpacing: LooprSpacing.xs) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: columnCount)), id: \.self) { start in
                    GridRow {
                        ForEach(tiles[start..<min(start + columnCount, tiles.count)]) { tile in button(tile) }
                    }
                }
            }
            // Always one row: with a reading it is one number and its source, which never needed a card's height
            // (R2-UPG-10, R3-UPG-9).
            if let heartRateRecovery { button(heartRateRecovery, row: true) }
        }
        .looprHaptic(haptic)
        .task(id: landing?.id) { await fly() }
    }

    private var columnCount: Int { dynamicTypeSize.isAccessibilitySize ? 1 : 2 }

    /// - Parameter row: a one-line row instead of a tile. Heart rate recovery is one until a workout scores it, so an
    ///   empty instrument does not take a card's height (R2-UPG-10).
    private func button(_ tile: FitnessCapacityTile, row: Bool = false) -> some View {
        Button { open(tile) } label: {
            if row {
                FitnessCapacityRowView(tile: tile)
            } else {
                FitnessCapacityTileView(tile: tile, countingValue: countKind == tile.kind ? countUp?.value : nil)
            }
        }
        .buttonStyle(.looprPressableCard)
        .looprDotFlightTarget(Self.targetID(tile.kind))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrames.frames[tile.kind] = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.spokenLabel)
        .accessibilityHint(tile.kind == .heartRateRecovery ? "Opens your heart rate recovery" : "Opens the test")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(Self.identifier(tile.kind))
    }

    /// `fitness-capacity-dead-hang`
    static func identifier(_ kind: CapacityTestKind) -> String {
        "fitness-capacity-\(kebab(kind))"
    }

    static func targetID(_ kind: CapacityTestKind) -> String { "fitness-capacity-target-\(kebab(kind))" }

    /// `dead-hang`, `one-leg-balance`
    static func kebab(_ kind: CapacityTestKind) -> String { kind.rawValue.replacingOccurrences(of: "_", with: "-") }

    // MARK: Landing

    /// Flies the saved result from where the test's hero was into its tile, counting the value up as the
    /// dots land, and plays the kept-rule success when the result meets the goal for 85.
    @MainActor
    private func fly() async {
        guard let landing else { return }
        let outcome = landing.outcome
        // Let the test's cover finish closing, so the tile is back on screen.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let animates = !entranceStore.forcesFinalState && !LooprMotion.reducesMotion(reduceMotion)
        #if canImport(UIKit)
        if animates, let flight, let target = flight.targets[Self.targetID(outcome.kind)],
           let global = globalFrames.frames[outcome.kind], !landing.heroFrame.isEmpty {
            // The hero's frame, moved from screen coordinates into the host's.
            let source = landing.heroFrame.offsetBy(dx: target.minX - global.minX, dy: target.minY - global.minY)
            let color = UIColor(Color.loopr(.brand))
            var random = SystemRandomNumberGenerator()
            let request = LooprDotFlight.request(from: source, to: .point(CGPoint(x: target.midX, y: target.minY + 48)),
                                                 colors: Array(repeating: color, count: outcome.dotCount), using: &random)
            countKind = outcome.kind
            countUp = LooprCountUp(from: outcome.previousBest ?? 0, to: outcome.newBest, total: outcome.dotCount)
            flight.play(request, onLanding: { _, _ in countUp = countUp?.landing() }, completion: {
                countKind = nil
                countUp = nil
                if outcome.meetsGoal { haptic = .ruleKept }
                landed()
            })
            return
        }
        #endif
        if outcome.meetsGoal { haptic = .ruleKept }
        landed()
    }
}

/// The tiles' frames on screen, read only when a result lands.
final class FitnessTileFrames {
    var frames: [CapacityTestKind: CGRect] = [:]
}

struct FitnessCapacityTileView: View {
    let tile: FitnessCapacityTile
    /// A value counting up while a saved result's dots land. Nil shows the tile's own value.
    var countingValue: Double? = nil

    private var valueColor: LooprColorToken { tile.isBelowGoal ? .warning : .ink }

    private var valueText: String? {
        countingValue.map { FitnessOverview.valueText(tile.kind, $0) } ?? tile.valueText
    }

    private var unitText: String? {
        countingValue == nil ? tile.unitText : FitnessOverview.unitText(tile.kind)
    }

    /// The lines under the title, at most two: the goal warning or what the test needs, then the retest date.
    var hints: [(text: String, color: LooprColorToken)] {
        var lines: [(text: String, color: LooprColorToken)] = []
        if tile.isBelowGoal { lines.append((tile.belowGoalLine ?? FitnessCapacityTile.belowGoal, .warning)) }
        else if let previous = tile.previousLine { lines.append((previous, .inkSecondary)) }
        if tile.valueText == nil, let detail = tile.untestedDetail { lines.append((detail, .inkSecondary)) }
        if let source = tile.sourceLine { lines.append((source, .inkSecondary)) }
        if let retest = tile.retestLine { lines.append((retest, .inkSecondary)) }
        return Array(lines.prefix(2))
    }

    /// One template with fixed rows, so every tile in the grid has the same rows at the same heights and no line runs
    /// into the next (R2-UPG-10): the instrument, the title, the state (today's best, or what an untested tile needs),
    /// and two caption lines that keep their space when empty.
    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            FitnessCapacityInstrument(tile: tile)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            LooprText(tile.title, style: .label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            state
                .frame(maxWidth: .infinity, minHeight: stateHeight, alignment: .bottomLeading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<2, id: \.self) { index in
                    let line = index < hints.count ? hints[index] : nil
                    LooprText(line?.text ?? " ", style: .caption, color: line?.color ?? .inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(LooprSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .looprCardBackground(density: .compact)
        .contentShape(RoundedRectangle(cornerRadius: LooprRadius.compactCard, style: .continuous))
    }

    /// The state row holds one metric line or two short lines, whichever is taller, so tested and untested tiles line up.
    @ScaledMetric(relativeTo: .title2) private var stateHeight: CGFloat = 40

    @ViewBuilder
    private var state: some View {
        if let value = valueText {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .looprTypography(.metric)
                    .foregroundStyle(Color.loopr(valueColor))
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: LooprMotion.fast), value: value)
                if let unit = unitText {
                    Text(verbatim: unit)
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            LooprText(tile.untestedLine, style: .rowTitle, color: tile.isInvitation ? .strain : .inkSecondary)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.85)
        }
    }
}

/// Heart rate recovery as one row: its title, then the reading and the workout it came from, or what it waits for,
/// and a chevron.
struct FitnessCapacityRowView: View {
    let tile: FitnessCapacityTile

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                LooprText(tile.title, style: .rowTitle)
                if let detail = tile.valueText == nil ? tile.untestedDetail : tile.sourceLine {
                    LooprText(detail, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: LooprSpacing.sm)
            if let value = tile.valueText {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: value)
                        .looprTypography(.metric)
                        .foregroundStyle(Color.loopr(.ink))
                    if let unit = tile.unitText {
                        Text(verbatim: unit)
                            .looprTypography(.metricUnit)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
                .lineLimit(1)
            } else {
                LooprText(tile.untestedLine, style: .caption, color: .inkSecondary)
                    .lineLimit(1)
            }
            LooprChevron()
        }
        .padding(.horizontal, LooprSpacing.md)
        .padding(.vertical, LooprSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .looprCardBackground(density: .compact)
        .contentShape(RoundedRectangle(cornerRadius: LooprRadius.compactCard, style: .continuous))
    }
}

/// The drawing on each tile. Before the first test it draws the empty instrument.
struct FitnessCapacityInstrument: View {
    let tile: FitnessCapacityTile

    private var fill: Color { Color.loopr(tile.isBelowGoal ? .warning : .brand) }
    private var track: Color { Color.loopr(.divider) }

    var body: some View {
        Canvas { context, size in
            switch tile.kind {
            case .grip: grip(&context, size)
            case .deadHang: hang(&context, size)
            case .sitToStand: ticks(&context, size)
            case .oneLegBalance, .heartRateRecovery: balance(&context, size)
            }
        }
        .overlay {
            if tile.kind == .deadHang {
                LooprText("of 2:00", style: .caption, color: .inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 46)
            }
        }
    }

    /// A half dial from 0 to the scale, with a needle at the value.
    private func grip(_ context: inout GraphicsContext, _ size: CGSize) {
        let radius = min(size.width / 2, size.height) - 6
        let center = CGPoint(x: size.width / 2, y: size.height - 3)
        func arc(to fraction: Double) -> Path {
            Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction),
                             clockwise: false) }
        }
        context.stroke(arc(to: 1), with: .color(track), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        for step in 0...8 {
            let angle = Double.pi + Double.pi * Double(step) / 8
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + (radius - 8) * cos(angle), y: center.y + (radius - 8) * sin(angle)))
            tick.addLine(to: CGPoint(x: center.x + (radius - 13) * cos(angle), y: center.y + (radius - 13) * sin(angle)))
            context.stroke(tick, with: .color(Color.loopr(.inkMuted)), lineWidth: 1)
        }
        guard let fraction = tile.fraction else { return }
        context.stroke(arc(to: fraction), with: .color(fill), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        let angle = Double.pi + Double.pi * fraction
        var needle = Path()
        needle.move(to: center)
        needle.addLine(to: CGPoint(x: center.x + (radius - 18) * cos(angle), y: center.y + (radius - 18) * sin(angle)))
        context.stroke(needle, with: .color(Color.loopr(.ink)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)), with: .color(Color.loopr(.ink)))
    }

    /// A ring that fills towards two minutes.
    private func hang(_ context: inout GraphicsContext, _ size: CGSize) {
        let radius = min(size.width, size.height) / 2 - 4
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(track), lineWidth: 6)
        guard let fraction = tile.fraction, fraction > 0 else { return }
        let arc = Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction),
                                   clockwise: false) }
        context.stroke(arc, with: .color(Color.loopr(tile.isBelowGoal ? .warning : .sleep)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
    }

    /// Ten bars rising left to right, filled up to the score. A half point fills half a bar's colour.
    private func ticks(_ context: inout GraphicsContext, _ size: CGSize) {
        let gap: CGFloat = 4
        let width = (size.width - gap * 9) / 10
        let score = (tile.fraction ?? 0) * 10
        for index in 0..<10 {
            let height = size.height * (0.4 + 0.06 * CGFloat(index))
            let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            let amount = min(max(score - Double(index), 0), 1)
            context.fill(shape, with: .color(track))
            if tile.fraction != nil, amount > 0 { context.fill(shape, with: .color(fill.opacity(amount < 1 ? 0.45 : 0.9))) }
        }
    }

    /// A bar that fills with the seconds held, with a mark at the goal for 85 when there is one.
    private func balance(_ context: inout GraphicsContext, _ size: CGSize) {
        let bar = CGRect(x: 0, y: size.height / 2 - 4, width: size.width, height: 8)
        context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(track))
        if let fraction = tile.fraction, fraction > 0 {
            let filled = CGRect(x: 0, y: bar.minY, width: bar.width * fraction, height: bar.height)
            context.fill(Path(roundedRect: filled, cornerRadius: 4),
                         with: .linearGradient(Gradient(colors: [fill, fill.opacity(0.5)]),
                                               startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: filled.maxX, y: 0)))
        }
        if let goal = tile.goalFraction {
            let x = bar.width * goal
            context.fill(Path(CGRect(x: x - 0.75, y: size.height / 2 - 14, width: 1.5, height: 28)), with: .color(Color.loopr(.inkSecondary)))
        }
    }
}

/// The saved results of one test, newest first, with the goal for 85 and the line from today's best to
/// it. The goal is set on a ruler; the line is arithmetic between two points, not a forecast.
struct FitnessCapacityHistorySheet: View {
    let tile: FitnessCapacityTile
    /// Saves a goal for 85. Nil when this composition cannot save, and for heart rate recovery.
    let saveGoal: ((Double) async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var goal: Double = 0
    @State private var saving = false
    @State private var problem: String?
    @State private var haptic: LooprHaptic?

    private var scale: CapacityGoalScale? { CapacityGoalScale.scale(for: tile.kind) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    FitnessCapacityTileView(tile: tile)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tile.spokenLabel)
                    if let norm = tile.norm { normSection(norm) }
                    if let scale, saveGoal != nil { goalSection(scale) }
                    LooprSectionHeader("Results")
                    if tile.history.isEmpty {
                        LooprCard {
                            LooprText("No results saved yet.", style: .prose, color: .inkSecondary)
                        }
                        .accessibilityIdentifier("fitness-capacity-history-empty")
                    } else {
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(tile.history.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 {
                                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                                            .padding(.leading, LooprSpacing.cardHorizontal)
                                            .accessibilityHidden(true)
                                    }
                                    historyRow(row, index: index)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.xl)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("\(tile.title) results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("fitness-capacity-history-done")
                }
            }
        }
        .tint(Color.loopr(.strain))
        .looprHaptic(haptic)
        .accessibilityIdentifier("fitness-capacity-history")
        .presentationDetents([.large])
        .onAppear { if let scale { goal = scale.initialValue(goal: tile.goalValue, best: tile.bestValue) } }
    }

    /// The published comparison for this test, with its study named, or why there is none (R2-VET-06).
    private func normSection(_ norm: CapacityNorm) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Compared with others")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(norm.line, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-capacity-norm")
                    if let source = norm.source {
                        LooprText(source, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-capacity-norm-source")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func goalSection(_ scale: CapacityGoalScale) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSectionHeader("Goal for 85", detail: "What you want to still manage at 85. Loopr draws a straight line to it from today's best.")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: FitnessOverview.valueText(tile.kind, goal))
                            .looprTypography(.metric)
                            .foregroundStyle(Color.loopr(.ink))
                            .contentTransition(.numericText(value: goal))
                        if let unit = FitnessOverview.unitText(tile.kind) {
                            Text(verbatim: unit).looprTypography(.metricUnit).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                    }
                    LooprRulerPicker("Goal for 85", value: $goal, in: scale.range, step: scale.step, majorEvery: scale.majorEvery,
                                     unit: tile.kind == .sitToStand ? "points" : FitnessOverview.unitText(tile.kind) ?? "s", accent: .strain,
                                     labelFormat: tile.kind == .deadHang ? .clock : nil, majorsFromZero: true)
                        .frame(height: 64)
                        .accessibilityIdentifier("fitness-goal-ruler-\(FitnessCapacityTiles.kebab(tile.kind))")
                    FitnessTrajectoryChart(tile: tile)
                    if let best = tile.bestValue, scale.snapped(goal) < best {
                        // A goal under today's best is allowed, but said (R2-VET-06).
                        LooprText("This goal is below your best today, \(FitnessOverview.valueText(tile.kind, best)).",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-goal-below-best")
                    }
                    if let problem {
                        LooprText(problem, style: .caption, color: .warning)
                    }
                    Button(tile.goalValue == nil ? "Set goal" : "Change goal") { save(scale) }
                        .buttonStyle(LooprButtonStyle(accent: .strain))
                        .disabled(saving || tile.goalValue.map { scale.snapped($0) == scale.snapped(goal) } == true)
                        .accessibilityIdentifier("fitness-goal-\(FitnessCapacityTiles.kebab(tile.kind))")
                }
            }
        }
    }

    private func save(_ scale: CapacityGoalScale) {
        guard let saveGoal else { return }
        saving = true
        problem = nil
        let value = scale.snapped(goal)
        Task { @MainActor in
            do {
                try await saveGoal(value)
                haptic = .success
            } catch {
                problem = "Loopr could not save this goal. Try again."
            }
            saving = false
        }
    }

    private func historyRow(_ row: FitnessCapacityHistoryRow, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                LooprText(row.dateText, style: .rowTitle)
                LooprText([row.sideText, row.sourceText].compactMap { $0 }.joined(separator: " · "), style: .caption,
                          color: .inkSecondary)
            }
            Spacer(minLength: LooprSpacing.sm)
            Text(verbatim: row.valueText)
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(.ink))
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-capacity-history-row-\(index)")
    }
}

/// The line from today's best to the goal on the 85th birthday. It is the arithmetic between two
/// points the person chose or measured, and says nothing about health.
struct FitnessTrajectoryChart: View {
    let tile: FitnessCapacityTile

    static let caption = "A straight line from today's best to your goal. It is not a forecast."
    static let needsBirthYear = "Add your birth year in your profile to draw the line to 85."
    static let needsResult = "Do the test once to start the line."
    static let needsGoal = "Set a goal to draw the line to 85."

    var body: some View {
        if let line = tile.trajectory {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Canvas { context, size in draw(line, in: &context, size: size) }
                    .frame(height: 72)
                    .accessibilityHidden(true)
                HStack {
                    LooprText("Today \(value(line.start.value))", style: .caption, color: .inkSecondary)
                    Spacer(minLength: LooprSpacing.xs)
                    LooprText("At 85 \(value(line.end.value))", style: .caption, color: .inkSecondary)
                }
                LooprText(Self.caption, style: .caption, color: .inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A straight line from \(value(line.start.value)) today to \(value(line.end.value)) at 85. \(Self.caption)")
            .accessibilityIdentifier("fitness-goal-trajectory")
        } else {
            LooprText(!tile.knowsBirthYear ? Self.needsBirthYear : tile.bestValue == nil ? Self.needsResult : Self.needsGoal,
                      style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fitness-goal-trajectory-absent")
        }
    }

    private func value(_ number: Double) -> String {
        let text = FitnessOverview.valueText(tile.kind, number)
        guard let unit = FitnessOverview.unitText(tile.kind) else { return text }
        return unit == "/10" ? text + unit : "\(text) \(unit)"
    }

    private func draw(_ line: CapacityTrajectory, in context: inout GraphicsContext, size: CGSize) {
        let low = min(line.start.value, line.end.value), high = max(line.start.value, line.end.value)
        let span = max(high - low, 1)
        func y(_ value: Double) -> CGFloat { 10 + (size.height - 20) * CGFloat(1 - (value - low) / span) }
        let points = line.points(count: 12)
        let total = max(line.end.date.timeIntervalSince(line.start.date), 1)
        func x(_ date: Date) -> CGFloat { 6 + (size.width - 12) * CGFloat(date.timeIntervalSince(line.start.date) / total) }
        var path = Path()
        for (index, point) in points.enumerated() {
            let location = CGPoint(x: x(point.date), y: y(point.value))
            if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        context.stroke(path, with: .color(Color.loopr(.strain)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        for point in [line.start, line.end] {
            let center = CGPoint(x: x(point.date), y: y(point.value))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                         with: .color(Color.loopr(point == line.start ? .ink : .strain)))
        }
    }
}
