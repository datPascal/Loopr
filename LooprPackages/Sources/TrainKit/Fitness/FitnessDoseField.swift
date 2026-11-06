import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Fitness signature object (DESIGN_LANGUAGE premium check 1): this week's dose as dots, one per
/// five minutes the band measured in any activity, the strength sessions as plates on the set log's
/// bar, and mobility as rings. Dots that arrive with a sync fly in from the card's header and the
/// counts roll up as they land.
///
/// Under the title, one line on what Zone 2 is and one on where the minutes came from (R2-VET-02, R2-VET-03). The
/// verdict says how far into the week it is and carries an info button with its basis and what each row counts
/// (R2-DES-07); each row is its title and count on one line over its dots (R2-DES-08). A tap on Zone 2 or Hard minutes
/// lists the week day by day (R2-VET-03, R2-WOD-08). A row the band has not measured draws its target as hollow dots,
/// and the band note says why (R1-DES-18). Without any target the field offers a starter week (R2-NEW-06).
struct FitnessDoseField: View {
    let dose: FitnessDose
    /// True on the first visit of the day: the dots drop in and the plates slide on.
    let entrance: Bool
    var openProtocol: () -> Void = {}
    var useStarterWeek: () -> Void = {}
    var shownStore: FitnessDoseShownStore = .shared

    @Environment(\.looprDotFlight) private var flight
    @Environment(\.looprEntranceStore) private var entranceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var arriving = FitnessDoseShown(zone2: 0, hard: 0)
    @State private var zone2Count: LooprCountUp?
    @State private var hardCount: LooprCountUp?
    @State private var platesShown: Int?
    @State private var showsBasis = false
    @State private var showsDays = false

    static let sourceID = "fitness-dose-source"
    static let zone2TargetID = "fitness-dose-zone2-dots"
    static let hardTargetID = "fitness-dose-hard-dots"

    var body: some View {
        LooprSurface(emphasis: .hero(.fitnessTab)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    header
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(dose.zoneLine, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-dose-zone-line")
                        if let source = dose.minutesSource {
                            LooprText(source, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("fitness-dose-minutes-source")
                        }
                    }
                    verdictLine
                }
                minutesRow(dose.zone2, standardDiameter: FitnessDotLayout.standardDiameter, tint: .strain,
                           arriving: arriving.zone2, count: zone2Count, identifier: "fitness-dose-zone2",
                           target: Self.zone2TargetID, starterMinutes: DoseTargets.starterTargets.zone2Minutes)
                if dose.showsHardMinutes {
                    minutesRow(dose.hard, standardDiameter: FitnessDotLayout.hardDiameter, tint: .heart,
                               arriving: arriving.hard, count: hardCount, identifier: "fitness-dose-hard",
                               target: Self.hardTargetID, starterMinutes: nil)
                }
                if let note = dose.bandAbsence ?? dose.coverageNote {
                    LooprText(note, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-dose-band-note")
                }
                strengthRow
                mobilityRow
                LooprText(dose.targetSource, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fitness-dose-target-source")
                if dose.offersStarterWeek { starterOffer }
            }
        }
        .looprPressTilt()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dose.spokenSummary)
        .accessibilityIdentifier("fitness-dose")
        .sheet(isPresented: $showsBasis) { FitnessDoseBasisSheet(dose: dose) }
        .sheet(isPresented: $showsDays) { FitnessDoseDaysSheet(days: dose.days, zoneLine: dose.zoneLine) }
        .task(id: entrance) {
            // The plates slide on from the sleeve ends a moment after the dots start to drop.
            if entrance, !reduces {
                platesShown = 0
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            platesShown = dose.strength.count
        }
        .onChange(of: dose.strength.count) { _, count in platesShown = count }
        .task(id: dose) { await flyNewDots() }
    }

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }

    /// The verdict with an info button that says what "on pace" means (R2-DES-07, R2-NEW-04, R2-VET-08). The button
    /// also carries the row definitions that used to take a line under every row (R2-DES-08).
    private var verdictLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            if let verdict = dose.verdict {
                LooprText(verdict, style: .prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fitness-dose-verdict")
            } else if dose.offersStarterWeek {
                LooprText(FitnessDose.starterTitle, style: .prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fitness-dose-starter-title")
            }
            Spacer(minLength: 0)
            Button { showsBasis = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.loopr(.fitnessTab))
                    .frame(width: LooprSpacing.interactiveRowHeight, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel("How the week is read")
            .accessibilityIdentifier("fitness-dose-basis")
        }
    }

    /// The starter week (R2-NEW-06, R2-DES-09, R1-NEW-03): what it holds, labelled as a common starting point, one tap
    /// to add it to Protocol, and the way to set your own week there.
    private var starterOffer: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(FitnessDose.starterNote, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fitness-dose-starter-note")
            Button(FitnessDose.starterUse) { useStarterWeek() }
                .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                .accessibilityHint("Adds these three weekly rules to your protocol")
                .accessibilityIdentifier("fitness-dose-starter-use")
            Button(FitnessDose.openProtocol) { openProtocol() }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                .accessibilityIdentifier("fitness-dose-open-protocol")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(FitnessDose.title, style: .rowTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LooprSpacing.xs)
            LooprText(FitnessDose.scale, style: .caption, color: .inkSecondary)
        }
        .looprDotFlightSource(Self.sourceID)
    }

    // MARK: Rows

    private func countLabel(value: Int?, shown: Double?, suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let value {
                let number = Int((shown ?? Double(value)).rounded())
                Text(verbatim: "\(number)")
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.ink))
                    .contentTransition(reduces ? .opacity : .numericText(value: Double(number)))
                    .animation(.smooth(duration: LooprMotion.fast), value: number)
                Text(verbatim: suffix)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            } else {
                Text(verbatim: suffix)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
    }

    private func rowTitle(_ title: String, caption: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            LooprText(title, style: .rowTitle)
            if let caption {
                Text(verbatim: caption)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
    }

    private func rowHeader(_ title: String, caption: String? = nil, count: some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                rowTitle(title, caption: caption)
                Spacer(minLength: LooprSpacing.xs)
                count
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                rowTitle(title, caption: caption)
                count
            }
        }
    }

    /// A minutes row as a button: a tap lists the week day by day (R2-VET-03). Without a reading, the target, or in an
    /// empty week the starter week's, is drawn hollow so the row keeps its shape without reading as zero (R1-DES-18).
    private func minutesRow(_ row: FitnessDoseMinutesRow, standardDiameter: CGFloat, tint: LooprColorToken, arriving: Int,
                            count: LooprCountUp?, identifier: String, target: String, starterMinutes: Double?) -> some View {
        let starter = dose.offersStarterWeek && row.minutes == nil ? starterMinutes : nil
        let suffix = starter.map { "Starter week: \(Int($0)) min" } ?? row.suffix
        return Button { showsDays = true } label: {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                rowHeader(row.title, caption: row.caption,
                          count: countLabel(value: row.minutes, shown: count?.value, suffix: suffix))
                switch row.state {
                case .absent:
                    let total = row.targetDots ?? starter.flatMap { DoseDots(minutes: 0, target: $0).total }
                    if let total, total > 0 {
                        FitnessDotsView(fill: FitnessDotFill(filled: 0, total: total),
                                        diameter: FitnessDotLayout.diameter(forCount: total, standard: standardDiameter),
                                        tint: tint, entrance: false)
                    }
                case .dots(let dots):
                    let fill = FitnessDotFill(dots, arriving: arriving)
                    FitnessDotsView(fill: fill, diameter: FitnessDotLayout.diameter(forCount: fill.count, standard: standardDiameter),
                                    tint: tint, entrance: entrance)
                        .looprDotFlightTarget(target)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityHint("Shows each day's minutes and where they came from")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }

    /// The sessions a row draws hollow: its target, or in an empty week the starter week's.
    private func outlineTarget(_ target: Int?, starter: Int?) -> Int {
        target ?? (dose.offersStarterWeek ? starter ?? 0 : 0)
    }

    private func sessionsSuffix(_ row: FitnessDoseSessionsRow, starter: Int?) -> String {
        guard dose.offersStarterWeek, row.count == 0, let starter else { return row.suffix }
        return "Starter week: \(starter)"
    }

    private var strengthRow: some View {
        let row = dose.strength
        let loaded = min(platesShown ?? row.count, row.count)
        let target = outlineTarget(row.target, starter: DoseTargets.starterTargets.strengthSessions)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            rowHeader(row.title, count: countLabel(value: row.shownCount, shown: nil,
                                                   suffix: sessionsSuffix(row, starter: DoseTargets.starterTargets.strengthSessions)))
            LooprBarbellGraphic(plates: Array(repeating: 20, count: loaded),
                                outlines: max(target - loaded, row.count - loaded), outlineWeight: 20, tint: .strain)
                .frame(height: 40)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityIdentifier("fitness-dose-strength")
    }

    private var mobilityRow: some View {
        let row = dose.mobility
        let rings = max(outlineTarget(row.target, starter: DoseTargets.starterTargets.mobilitySessions), row.count)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            rowHeader(row.title, count: countLabel(value: row.shownCount, shown: nil,
                                                   suffix: sessionsSuffix(row, starter: DoseTargets.starterTargets.mobilitySessions)))
            if rings > 0 {
                HStack(spacing: LooprSpacing.sm) {
                    ForEach(0..<rings, id: \.self) { index in
                        FitnessRing(isDone: index < row.count)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityIdentifier("fitness-dose-mobility")
    }

    // MARK: Flight

    /// Flies the dots that arrived since the week was last shown, then records what is shown now.
    @MainActor
    private func flyNewDots() async {
        // A flight cut short by newer data leaves nothing held back.
        arriving = FitnessDoseShown(zone2: 0, hard: 0)
        zone2Count = nil
        hardCount = nil
        guard let current = dose.shown else { return }
        let last = shownStore.lastShown(week: dose.weekKey)
        let animates = !entranceStore.forcesFinalState && !reduces && flight != nil
        let plan = FitnessDoseFlight.plan(current: current, lastShown: last, animates: animates)
        guard plan.zone2 + plan.hard > 0 else {
            shownStore.record(current, week: dose.weekKey)
            return
        }
        arriving = plan
        zone2Count = Self.countUp(minutes: dose.zone2.minutes, dots: plan.zone2)
        hardCount = Self.countUp(minutes: dose.hard.minutes, dots: plan.hard)
        // The flight reads the frames the host resolved from this layout pass.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        #if canImport(UIKit)
        if let flight, let request = request(plan: plan, current: current, flight: flight) {
            let zone2Color = request.zone2Color
            flight.play(request.request, onLanding: { _, landing in
                if landing.color === zone2Color {
                    arriving.zone2 = max(arriving.zone2 - 1, 0)
                    zone2Count = zone2Count?.landing()
                } else {
                    arriving.hard = max(arriving.hard - 1, 0)
                    hardCount = hardCount?.landing()
                }
            }, completion: {
                finish(current)
            })
            return
        }
        #endif
        finish(current)
    }

    private func finish(_ current: FitnessDoseShown) {
        arriving = FitnessDoseShown(zone2: 0, hard: 0)
        zone2Count = nil
        hardCount = nil
        shownStore.record(current, week: dose.weekKey)
    }

    /// Every dot a row draws, filled and still to go.
    static func drawn(_ row: FitnessDoseMinutesRow) -> Int {
        guard case .dots(let dots) = row.state else { return 0 }
        return FitnessDotFill(dots).count
    }

    /// The minutes before the new dots, counting up five a dot.
    static func countUp(minutes: Int?, dots: Int) -> LooprCountUp? {
        guard let minutes, dots > 0 else { return nil }
        let from = max(Double(minutes) - Double(dots) * DoseDots.minutesPerDot, 0)
        return LooprCountUp(from: from, to: Double(minutes), total: dots)
    }

    #if canImport(UIKit)
    private struct PlannedFlight {
        let request: LooprDotFlightRequest
        let zone2Color: UIColor
    }

    /// One flight for both rows: each dot lands on the slot its row draws it in, in arrival order.
    @MainActor
    private func request(plan: FitnessDoseShown, current: FitnessDoseShown, flight: LooprDotFlightCoordinator) -> PlannedFlight? {
        guard let source = flight.sources[Self.sourceID] else { return nil }
        let isDark = colorScheme == .dark
        let trait = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let zone2Color = UIColor(Color.loopr(.strain)).resolvedColor(with: trait)
        let hardColor = UIColor(Color.loopr(.heart)).resolvedColor(with: trait)
        var random = SystemRandomNumberGenerator()
        var landings: [LooprDotLanding] = []
        func land(count: Int, filled: Int, total: Int, target: String, diameter: CGFloat, color: UIColor) {
            guard count > 0, let frame = flight.targets[target] else { return }
            // The same layout the row draws, so each dot lands on its slot.
            let layout = FitnessDotLayout.fitting(count: total, width: frame.width, diameter: diameter)
            let starts = (0..<count).map { _ in
                LooprDotStart(unit: CGPoint(x: .random(in: 0...1, using: &random), y: .random(in: 0...1, using: &random)), color: color)
            }
            let dots = LooprDotFlight.schedule(starts, in: source, using: &random).sorted { $0.arrival < $1.arrival }
            for (rank, dot) in dots.enumerated() {
                let center = layout.center(of: filled - count + rank)
                landings.append(LooprDotLanding(dot: dot, target: CGPoint(x: frame.minX + center.x, y: frame.minY + center.y),
                                                color: color))
            }
        }
        let zone2Total = Self.drawn(dose.zone2), hardTotal = Self.drawn(dose.hard)
        land(count: plan.zone2, filled: current.zone2, total: zone2Total, target: Self.zone2TargetID,
             diameter: FitnessDotLayout.diameter(forCount: zone2Total, standard: FitnessDotLayout.standardDiameter), color: zone2Color)
        land(count: plan.hard, filled: current.hard, total: hardTotal, target: Self.hardTargetID,
             diameter: FitnessDotLayout.diameter(forCount: hardTotal, standard: FitnessDotLayout.hardDiameter), color: hardColor)
        guard !landings.isEmpty else { return nil }
        return PlannedFlight(request: LooprDotFlightRequest(landings: landings, away: CGPoint(x: source.midX, y: source.midY)),
                             zone2Color: zone2Color)
    }
    #endif
}

/// One row of dots, drawn in a Canvas from `FitnessDotLayout`. On the day's first visit the filled
/// dots drop in one after another; every later visit draws them at rest.
struct FitnessDotsView: View {
    let fill: FitnessDotFill
    let diameter: CGFloat
    let tint: LooprColorToken
    let entrance: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var startedAt: Date?

    /// The contract's drop: 0.3 s before the first dot, 40 ms between dots, 0.6 s each.
    static let firstDelay = 0.3
    static let stagger = 0.04
    static let dropDuration = 0.6

    static func entranceDuration(dots: Int) -> Double { firstDelay + Double(max(dots - 1, 0)) * stagger + dropDuration }

    /// How far dot `index` has dropped `elapsed` seconds into the entrance, 0 to 1, with a small overshoot.
    static func dropProgress(index: Int, elapsed: Double) -> Double {
        let local = (elapsed - firstDelay - Double(index) * stagger) / dropDuration
        guard local > 0 else { return 0 }
        guard local < 1 else { return 1 }
        // Ease out with a little overshoot, like the contract's cubic-bezier(.2, 1.5, .4, 1).
        let t = local - 1
        return 1 + 2.2 * t * t * t + 1.2 * t * t
    }

    var body: some View {
        let layout = FitnessDotLayout.fitting(count: fill.count, width: width, diameter: diameter)
        let animating = startedAt.map { Date().timeIntervalSince($0) < Self.entranceDuration(dots: fill.filled) } ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? .infinity
            Canvas { canvas, _ in
                draw(in: &canvas, layout: layout, elapsed: elapsed)
            }
        }
        .frame(height: max(layout.height, layout.diameter))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: entrance, initial: true) { _, plays in
            guard plays, !LooprMotion.reducesMotion(reduceMotion), startedAt == nil else { return }
            startedAt = Date()
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            let remaining = Self.entranceDuration(dots: fill.filled) - Date().timeIntervalSince(startedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            // The entrance is over: stop the timeline.
            self.startedAt = nil
        }
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, layout: FitnessDotLayout, elapsed: Double) {
        let color = Color.loopr(tint)
        let ring = Color.loopr(.inkMuted).opacity(0.7)
        // Empty and arriving slots: a thin ring.
        for index in 0..<layout.count where fill.dot(at: index) != .filled {
            let rect = layout.frame(of: index).insetBy(dx: 0.6, dy: 0.6)
            canvas.stroke(Path(ellipseIn: rect), with: .color(ring), lineWidth: 1.2)
        }
        // Filled dots in one glowing layer, lit from the upper left.
        canvas.drawLayer { layer in
            layer.addFilter(.shadow(color: color.opacity(0.55), radius: layout.diameter / 3))
            for index in 0..<layout.count where fill.dot(at: index) == .filled {
                let progress = Self.dropProgress(index: index, elapsed: elapsed)
                guard progress > 0 else { continue }
                var rect = layout.frame(of: index)
                let scale = 0.4 + 0.6 * min(progress, 1.1)
                rect = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
                rect = rect.offsetBy(dx: 0, dy: -26 * (1 - min(progress, 1)))
                layer.opacity = min(progress * 1.4, 1)
                layer.fill(Path(ellipseIn: rect), with: .color(color))
                let highlight = Gradient(colors: [.white.opacity(0.55), .white.opacity(0)])
                layer.fill(Path(ellipseIn: rect), with: .radialGradient(
                    highlight, center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3),
                    startRadius: 0, endRadius: rect.width * 0.45))
            }
        }
    }
}

/// A mobility session: a ring in the Protocol accent once done, a thin outline while still to go.
struct FitnessRing: View {
    let isDone: Bool

    var body: some View {
        Circle()
            .strokeBorder(isDone ? Color.loopr(.protocol) : Color.loopr(.inkMuted).opacity(0.7), lineWidth: isDone ? 5 : 2)
            .frame(width: 24, height: 24)
            .shadow(color: isDone ? Color.loopr(.protocol).opacity(0.5) : .clear, radius: 6)
    }
}
