import DesignSystem
import SwiftUI

/// The week of rosettes, the Protocol tab's signature object. One Canvas draws all seven days; a row of transparent
/// columns on top carries each day's VoiceOver summary and identifier, today's pulse and the landing point for dots
/// from the deck. The seven columns are equal, so the strip reads as a week (ICP R2-DES-03): a past day's rosette is
/// about 44 pt across with a hairline ring that shows where to tap (R2-SEN-07), today's is 1.5 times that inside the
/// accent ring, and a day ahead is one small dot. The whole column, letter included, is the tap target.
struct ProtocolRosetteWeek: View {
    static let flightTarget = "protocol-rosette-today"
    /// The rosette row's height: today's rosette at its largest with its ring.
    static let height: CGFloat = 72
    /// The letter row under the rosettes.
    static let letterHeight: CGFloat = 22
    /// A past day's rosette at most, across, dots included.
    static let maximumPastSize: CGFloat = 44
    /// Today's rosette is this many times a past day's.
    static let todayScale: CGFloat = 1.5
    /// The space between today's ring and the next day's rosette.
    static let ringGap: CGFloat = 2

    let days: [ProtocolDayPresentation]
    /// How many dots the entrance has landed so far, Monday first. Nil draws every dot.
    let revealed: Int?
    /// Opens a day's rules. Nil leaves the days as labels only.
    var open: ((ProtocolDayPresentation) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false

    /// A past day's rosette across `width` split into seven equal columns: 44 pt, or less on a narrow phone so today's
    /// ring never touches its neighbours.
    static func pastSize(width: CGFloat, count: Int = 7) -> CGFloat {
        let column = width / CGFloat(max(count, 1))
        // Today's radius (1.5 × half), its ring gap and a neighbour's half must fit in one column, with a 2 pt margin.
        let fit = (column - 2 * ringGap) / (todayScale / 2 + 0.5)
        return max(0, min(maximumPastSize, fit))
    }

    /// The rosette's size, across, for a day.
    static func size(width: CGFloat, isToday: Bool, count: Int = 7) -> CGFloat {
        pastSize(width: width, count: count) * (isToday ? todayScale : 1)
    }

    /// The radius of the ring the dots sit on, for a rosette `size` across. The dots stay inside the size.
    static func dotRing(size: CGFloat, count: Int) -> CGFloat {
        let half = size / 2
        let share = count > 8 ? 0.2 : 0.28
        return half / (1 + share)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(max(days.count, 1))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(in: &context, size: size) }
                    .frame(height: Self.height)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        column(day, size: Self.size(width: proxy.size.width, isToday: day.isToday, count: days.count))
                            .frame(width: width)
                    }
                }
            }
        }
        .frame(height: Self.height + Self.letterHeight)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This week")
    }

    private func column(_ day: ProtocolDayPresentation, size: CGFloat) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if day.isToday {
                    Circle()
                        .stroke(Color.loopr(.protocol), lineWidth: 1.2)
                        .frame(width: size + 2 * Self.ringGap, height: size + 2 * Self.ringGap)
                        .modifier(ProtocolPulse(active: day.pulses && isVisible && !LooprMotion.reducesMotion(reduceMotion)))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .modifier(ProtocolTodayTarget(isToday: day.isToday))
            Text(day.letter)
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(day.isToday ? .protocolChip : .inkSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .frame(height: Self.letterHeight)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // A tap anywhere in the column opens the day sheet: every rule of the day, who checked it, and a way to change it
        // (ICP R1-DES-04, R2-SEN-07).
        .onTapGesture { open?(day) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilitySummary)
        .accessibilityAddTraits(open == nil ? [] : .isButton)
        .accessibilityHint(open == nil ? "" : "Lists this day's rules, so you can change one.")
        .accessibilityIdentifier("protocol-rosette-\(day.identifierKey)")
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let column = size.width / CGFloat(max(days.count, 1))
        let dark = LooprAppearance.isDark(colorScheme)
        var index = 0
        for (offset, day) in days.enumerated() {
            let center = CGPoint(x: column * (CGFloat(offset) + 0.5), y: Self.height / 2)
            let across = Self.size(width: size.width, isToday: day.isToday, count: days.count)
            let half = across / 2
            var layer = context
            if day.phase == .future {
                // A day ahead is one small dot, not a ring of empty outlines (ICP R1-DES-05).
                let r: CGFloat = 2.5
                layer.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                           with: .color(Color.loopr(.inkMuted).opacity(dark ? 0.7 : 0.45)))
                continue
            }
            let outline = Path(ellipseIn: CGRect(x: center.x - half, y: center.y - half, width: across, height: across))
            if day.dots.isEmpty {
                layer.stroke(outline, with: .color(Color.loopr(.inkMuted).opacity(0.35)),
                             style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                continue
            }
            if !day.isToday {
                // The hairline that shows a past day is a place to tap (R2-SEN-07).
                layer.stroke(outline, with: .color(Color.loopr(.inkMuted).opacity(dark ? 0.35 : 0.25)), lineWidth: 0.6)
            }
            let ring = Self.dotRing(size: across * 0.9, count: day.dots.count)
            let positions = ProtocolRosetteLayout.positions(count: day.dots.count, center: center, radius: ring)
            let dotRadius = ProtocolRosetteLayout.dotRadius(count: day.dots.count, radius: ring)
            for (dot, point) in zip(day.dots, positions) {
                defer { index += 1 }
                if let revealed, index >= revealed { continue }
                let grow: CGFloat = revealed.map { index == $0 - 1 ? 1.25 : 1 } ?? 1
                ProtocolDotDrawing.draw(dot.state, at: point, radius: dotRadius * grow, in: &layer, dark: dark)
            }
        }
    }
}

/// How each dot state draws, in the rosettes, the key and the day sheet, so they never disagree. Kept is a filled accent
/// dot, not kept a filled accent dot with a small cross cut out of it, open a hairline grey ring, skipped a ring with a
/// slash and not known a short dash. Not kept and open are different shapes, so a miss stands out in a 38 pt rosette and
/// not known never looks like open (ICP R1-DES-05, R3-DES-02).
enum ProtocolDotDrawing {
    static func draw(_ state: ProtocolDotState, at point: CGPoint, radius r: CGFloat, in layer: inout GraphicsContext,
                     dark: Bool) {
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        let circle = Path(ellipseIn: rect)
        let ring = Path(ellipseIn: rect.insetBy(dx: 0.55, dy: 0.55))
        switch state {
        case .kept:
            if dark {
                var glow = layer
                glow.addFilter(.blur(radius: 3))
                glow.fill(circle, with: .color(Color.loopr(.protocol).opacity(0.55)))
            }
            layer.fill(circle, with: .color(Color.loopr(.protocol)))
        case .missed:
            // A grey dot among plum ones was a miss nobody could see (ICP R2-DES-03), and a plum ring read as open
            // (R3-DES-02). Not kept is a solid dot like kept, with a cross cut through it to the page, so it keeps the
            // weight of a decided rule and its own shape. The cut happens in the dot's own layer, so only the dot loses it.
            layer.drawLayer { dot in
                dot.fill(circle, with: .color(Color.loopr(.protocol)))
                var cross = Path()
                let arm = r * 0.48
                cross.move(to: CGPoint(x: point.x - arm, y: point.y - arm))
                cross.addLine(to: CGPoint(x: point.x + arm, y: point.y + arm))
                cross.move(to: CGPoint(x: point.x + arm, y: point.y - arm))
                cross.addLine(to: CGPoint(x: point.x - arm, y: point.y + arm))
                dot.blendMode = .destinationOut
                dot.stroke(cross, with: .color(.black), style: StrokeStyle(lineWidth: max(0.9, r * 0.32), lineCap: .round))
            }
        case .pending:
            layer.stroke(ring, with: .color(Color.loopr(.inkMuted)), lineWidth: 0.8)
        case .skipped:
            let color = Color.loopr(.inkMuted).opacity(dark ? 0.85 : 0.6)
            layer.stroke(ring, with: .color(color), lineWidth: 1)
            var slash = Path()
            let inset = r * 0.3
            slash.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            slash.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
            layer.stroke(slash, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case .unknown:
            var dash = Path()
            dash.move(to: CGPoint(x: point.x - r * 0.8, y: point.y))
            dash.addLine(to: CGPoint(x: point.x + r * 0.8, y: point.y))
            layer.stroke(dash, with: .color(Color.loopr(.inkMuted).opacity(dark ? 0.8 : 0.55)),
                         style: StrokeStyle(lineWidth: max(1.2, r * 0.45), lineCap: .round))
        }
    }
}

/// Today's ring breathes while a rule is still open. It holds still under Reduce Motion, off screen and once the day
/// is decided.
private struct ProtocolPulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.scaleEffect(phase ? 1.1 : 0.94).opacity(phase ? 0.25 : 0.7)
            } animation: { _ in .easeInOut(duration: 1.1) }
        } else {
            content.opacity(0.6)
        }
    }
}

/// Marks today's column as the place deck dots land.
private struct ProtocolTodayTarget: ViewModifier {
    let isToday: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        if isToday { content.looprDotFlightTarget(ProtocolRosetteWeek.flightTarget) } else { content }
        #else
        content
        #endif
    }
}

/// A single rosette of outline dots, for the first-run and unavailable cards.
struct ProtocolRosetteOutline: View {
    var count = 8
    var size: CGFloat = 72

    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let radius = min(canvas.width, canvas.height) * 0.36
            let dot = ProtocolRosetteLayout.dotRadius(count: count, radius: radius)
            for point in ProtocolRosetteLayout.positions(count: count, center: center, radius: radius) {
                let rect = CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(Color.loopr(.protocol).opacity(0.7)), lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The week in one line under the rosettes (ICP R2-NEW-01, R2-DES-01, R2-HAB-03): the percent from the protocol's
/// third day, then "12 of 13 kept this week · In bed not kept on Monday", which opens Monday when a rule was not kept,
/// and the info button with the key, the counting rule and where the numbers come from. On the first two days it is
/// one plain line (R2-DES-06). Nothing else sits between the week and the deck.
struct ProtocolKeptHero: View {
    let summary: ProtocolWeekSummary
    /// Opens the day the named rule was last not kept.
    var openSlip: (() -> Void)?
    /// Opens "This week", every rule's count behind the number (ICP R3-VET-01). With it the number and the words that
    /// name a rule not kept are two taps: the first opens the week, the second that day.
    var openWeek: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: LooprSpacing.xs) {
            if let openWeek {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    Button(action: openWeek) { line(summary.heroLead).contentShape(Rectangle()) }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityHint("Opens each rule's count for this week.")
                        .accessibilityIdentifier("protocol-kept-week")
                    if let openSlip, let slip = summary.heroSlip {
                        Button(action: openSlip) {
                            LooprText(slip, style: .rowTitle, color: .protocolChip)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, LooprSpacing.xxs)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityHint("Opens that day's rules.")
                        .accessibilityIdentifier("protocol-kept-slip")
                    }
                }
            } else if let openSlip, summary.slippedDay != nil {
                Button(action: openSlip) { line(summary.hero).contentShape(Rectangle()) }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityHint("Opens that day's rules.")
                    .accessibilityIdentifier("protocol-kept-slip")
            } else {
                line(summary.hero)
            }
            ProtocolWeekInfoButton(summary: summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-kept-hero")
    }

    /// "92%" in the accent, then the line, which wraps beside it at large text sizes.
    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            if let percent = summary.percent {
                Text("\(percent)%")
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(.protocol))
                    .fixedSize()
            }
            LooprText(text, style: .rowTitle, color: summary.percent == nil ? .ink : .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.percent.map { "\($0) percent. \(text)" } ?? text)
        .accessibilityIdentifier("protocol-kept-line")
    }
}

/// "Tap a day to see each rule", under the week until the person has opened a day once (ICP R1-SEN-07). The screen
/// shows it only while no card is due, so it never pushes the deck down.
struct ProtocolRosetteHint: View {
    static let openedKey = "loopr.protocol.dayOpened"
    static let text = "Tap a day to see each rule"
    @AppStorage(openedKey) private var opened = false

    var body: some View {
        if !opened {
            LooprText(Self.text, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("protocol-rosette-tap-hint")
        }
    }
}

/// The week's info button. Its popover holds what used to sit between the week and the deck (ICP R2-DES-01): how to
/// open a day, the key to the dots, the counting rule and the source of the numbers.
struct ProtocolWeekInfoButton: View {
    let summary: ProtocolWeekSummary
    @State private var shows = false

    var body: some View {
        Button { shows = true } label: {
            Image(systemName: "info.circle")
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How the week is counted")
        .accessibilityIdentifier("protocol-rosette-key")
        .popover(isPresented: $shows) {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(ProtocolRosetteHint.text + ".", style: .label, color: .ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ProtocolRosetteLegend()
                    LooprText(summary.countingLine, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protocol-kept-rule")
                    ProvenanceChip(.onThisPhone, qualifier: "from your rule checks", identifier: "protocol-kept-source")
                }
                .padding(LooprSpacing.md)
            }
            .frame(minWidth: 280, idealWidth: 320, minHeight: 300)
            .presentationCompactAdaptation(.popover)
            .accessibilityIdentifier("protocol-week-info")
        }
    }
}

/// The key to the dots (ICP R1-UPG-25): one dot is one rule on that day, drawn the way the rosette draws it.
struct ProtocolRosetteLegend: View {
    static let lead = "Each dot is one rule on that day."
    static let accessibilityText = "Each dot is one rule on that day. A filled dot is kept, a filled dot with a cross is "
        + "not kept, a thin grey ring is still open, a ring with a line through it is skipped, and a dash means nothing could "
        + "check it."
    static let states: [ProtocolDotState] = [.kept, .missed, .pending, .skipped, .unknown]

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(Self.lead, style: .label, color: .ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.states, id: \.self) { state in
                HStack(spacing: LooprSpacing.xs) {
                    ProtocolStateDot(state: state)
                    LooprText(Self.label(state), style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText)
        .accessibilityIdentifier("protocol-rosette-legend")
    }

    static func label(_ state: ProtocolDotState) -> String {
        switch state {
        case .kept: "Kept"
        case .missed: "Not kept"
        case .pending: "Open, still to answer"
        case .skipped: "Skipped"
        case .unknown: "Not known, nothing could check it"
        }
    }
}

/// One dot drawn the way the rosette draws its state, for the key and the day sheet.
struct ProtocolStateDot: View {
    let state: ProtocolDotState
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, canvas in
            ProtocolDotDrawing.draw(state, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                                    radius: min(canvas.width, canvas.height) / 2 - 0.5, in: &context,
                                    dark: LooprAppearance.isDark(colorScheme))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
