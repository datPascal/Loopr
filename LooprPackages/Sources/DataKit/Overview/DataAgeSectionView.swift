import DesignSystem
import SwiftUI

/// The top of the Data tab: the hero number, the age ruler with its pins, a row for each pin that is missing, and the
/// not-a-medical-device line. On the first visit of the day the pins drop onto the ruler one by one and the hero
/// number counts from real age to its value as they land. Every later visit, and Reduce Motion, shows the final state.
public struct DataAgeSection: View {
    private let ruler: DataAgeRuler
    private let entrance: Bool
    private let openPin: (DataAgePinKind) -> Void
    private let bloodTests: (() -> Void)?
    private let compact: Bool
    @State private var landed = 0

    /// - Parameters:
    ///   - entrance: true on the first visit of the day, from `looprEntrance(tab: "data", ...)`.
    ///   - openPin: opens the pin's method page, Profile for real age, or the blood tests when blood age needs a report.
    ///   - bloodTests: opens the blood tests list. Nil hides the button under the ruler.
    ///   - compact: the smaller hero without its paragraph, for Data's root under the area tiles (Data ICP R1-DES-01).
    ///     The paragraph is on each pin's method page.
    public init(ruler: DataAgeRuler, entrance: Bool, openPin: @escaping (DataAgePinKind) -> Void,
                bloodTests: (() -> Void)? = nil, compact: Bool = false) {
        self.ruler = ruler
        self.entrance = entrance
        self.openPin = openPin
        self.bloodTests = bloodTests
        self.compact = compact
    }

    /// When the first pin lands and the gap to the next.
    static let firstLanding = 0.4
    static let landingGap = 0.18
    /// Long enough for the last pin to land.
    public static let entranceDuration = 1.4

    private var landedPins: Int { entrance ? landed : .max }

    /// "Add a blood test" while blood age needs a report, else "Blood tests".
    static func bloodTestsTitle(_ ruler: DataAgeRuler) -> String {
        ruler.needsBloodTest ? "Add a blood test" : "Blood tests"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            hero
            DataAgeRulerView(ruler: ruler, landedPins: landedPins, openPin: openPin)
                .padding(.top, LooprSpacing.xs)
            absentPins
            if let bloodTests, !ruler.isLoading {
                // Blood tests sit next to the number they feed, not only at the bottom of Explore (ICP R1-LAB-12).
                LooprGlassButton(DataAgeSection.bloodTestsTitle(ruler), symbol: ruler.needsBloodTest ? "plus" : "drop.fill",
                                 prominent: ruler.needsBloodTest, identifier: "data-age-blood-tests", action: bloodTests)
            }
            LooprText(DataAgeRuler.notAMedicalDevice, style: .caption, color: .inkSecondary)
                .accessibilityIdentifier("data-age-not-medical")
        }
        .task(id: entrance) {
            guard entrance else { return }
            landed = 0
            let count = ruler.pins.count
            for index in 0..<count {
                let wait = index == 0 ? Self.firstLanding : Self.landingGap
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { landed = index + 1 }
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.4), trigger: landed) { _, new in entrance && new > 0 }
    }

    // MARK: Hero

    private var hero: some View {
        let hero = ruler.hero
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(hero.eyebrow, style: .label, color: .inkSecondary)
                if let value = hero.value {
                    LooprHeroNumber(value, unit: hero.unit, suffix: hero.suffix, fractionDigits: hero.fractionDigits,
                                    style: compact ? .heroNumeralLarge : .heroNumeralXXL,
                                    color: .brand, countUp: countUp(to: value))
                        .shadow(color: Color.loopr(.brand).opacity(0.35), radius: 24)
                } else {
                    LooprText(ruler.isLoading ? "Loading" : "Your ages show up here", style: .titleLarge, color: .inkSecondary)
                }
                if let change = hero.change {
                    Text(verbatim: change)
                        .looprTypography(.label)
                        .monospacedDigit()
                        .foregroundStyle(Color.loopr(.ink))
                        .accessibilityIdentifier("data-age-hero-change")
                }
                if !compact || hero.value == nil {
                    LooprText(hero.sentence, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hero.spokenLabel)
            .accessibilityIdentifier("data-age-hero")
            if hero.kind != .empty, !ruler.isLoading {
                ProvenanceChip(hero.provenance, qualifier: hero.provenanceQualifier, identifier: "data-age-hero-source") {
                    openPin(hero.kind == .blood ? .blood : hero.kind == .real ? .real : .cardio)
                }
            }
        }
    }

    /// From real age to the hero value, one step per landed pin, during the entrance only.
    private func countUp(to value: Double) -> LooprCountUp? {
        guard entrance, let start = ruler.realYears, ruler.pins.count > 0, landed < ruler.pins.count else { return nil }
        return LooprCountUp(from: start, to: value, total: ruler.pins.count, landed: landed)
    }

    // MARK: Absent pins

    @ViewBuilder private var absentPins: some View {
        let absent: [(DataAgePinKind, String)] = DataAgePinKind.allCases.compactMap { kind -> (DataAgePinKind, String)? in
            guard let sentence = ruler.state(kind).absenceSentence, !sentence.isEmpty else { return nil }
            return (kind, sentence)
        }
        if !absent.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(absent.enumerated()), id: \.element.0) { index, item in
                    if index > 0 { LooprHairline() }
                    Button { openPin(item.0) } label: {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            Circle()
                                .strokeBorder(Color.loopr(item.0.accent).opacity(0.7), style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
                                .frame(width: 12, height: 12)
                                .padding(.top, 4)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(item.0.title, style: .rowTitle)
                                LooprText(item.1, style: .caption, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: LooprSpacing.xs)
                            Image(systemName: "chevron.right")
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, LooprSpacing.xs)
                        .frame(minHeight: LooprRow<Image>.minimumTargetHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.0.title), not on the ruler. \(item.1)")
                    .accessibilityHint("Opens what it needs.")
                    .accessibilityIdentifier(item.0.identifier)
                }
            }
        }
    }
}

/// The precision ruler: quarter-year, year and decade ticks in a `Canvas`, the pins as stems with a glowing head, and
/// each pin's label as a button that opens its method page. Press and hold, then slide, to read the age under the
/// finger; it snaps to tenths of a year (`LooprDetent`) with a selection haptic on each.
struct DataAgeRulerView: View {
    let ruler: DataAgeRuler
    /// Pins drawn so far, in lane order. `.max` draws them all.
    let landedPins: Int
    let openPin: (DataAgePinKind) -> Void

    @State private var width: CGFloat = 0
    @State private var scrubX: CGFloat?
    @State private var scrubIndex: Int?
    @State private var voiceOverYears: Double?

    static let laneTop: CGFloat = 14
    static let laneGap: CGFloat = 24
    /// The baseline under all four lanes, and the ticks and labels below it.
    static let fullBaseline: CGFloat = 88
    static let belowBaseline: CGFloat = 38
    static let headRadius: CGFloat = 5

    static func laneY(_ lane: Int) -> CGFloat { laneTop + CGFloat(lane) * laneGap }

    /// The baseline sits just under the lowest lane in use, so a ruler with no pins is only its ticks and does not
    /// leave a blank band under the hero (ICP R2-UPG-18).
    static func baseline(lanes: Int) -> CGFloat {
        lanes <= 0 ? 6 : min(laneY(lanes - 1) + 26, fullBaseline)
    }

    /// While the ruler loads it keeps every lane, so a ruler with pins does not grow as they arrive.
    private var lanes: Int {
        ruler.isLoading ? DataAgePinKind.allCases.count : (ruler.placements.map(\.lane).max().map { $0 + 1 } ?? 0)
    }
    private var baseline: CGFloat { Self.baseline(lanes: lanes) }

    private var scale: DataAgeRulerScale { ruler.scale }
    private var isEmpty: Bool { ruler.pins.isEmpty }
    /// Placed again for the measured width, so no label crosses a stem on any phone.
    private var placements: [DataAgePinPlacement] {
        width > 0 ? DataAgePinPlacement.place(ruler.pins, on: scale, width: Double(width)) : ruler.placements
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DataAgeRulerTicks(scale: scale, dimmed: isEmpty, span: spanFractions, baseline: baseline)
            pinStems
            if let scrubX, let years = scrubYears {
                LooprScrubReadout(x: scrubX, title: scrubTitle(years), value: "\(DataText.oneDecimal(years)) years", accent: .brand)
            }
        }
        .frame(height: baseline + Self.belowBaseline)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .looprScrub { x in scrub(x) }
        .looprDetentFeedback(scrubIndex, isActive: scrubIndex != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ruler.spokenSummary)
        // Never empty: an adjustable element with no value is read as "nan" (ICP R2-LAB-19).
        .accessibilityValue((voiceOverYears ?? ruler.pins.first?.years).map { "\(DataText.oneDecimal($0)) years" } ?? "No age on the ruler")
        .accessibilityHint(Text(verbatim: isEmpty ? "" : "Swipe up or down to move along the ruler a year at a time."))
        .accessibilityAdjustableAction { direction in
            let current = voiceOverYears ?? ruler.pins.first?.years ?? scale.lower
            switch direction {
            case .increment: voiceOverYears = min(scale.upper, current.rounded(.down) + 1)
            case .decrement: voiceOverYears = max(scale.lower, current.rounded(.up) - 1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("data-age-ruler")
        .overlay(alignment: .topLeading) { pinLabels }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    // MARK: Scrub

    private var scrubYears: Double? { scrubIndex.map { scale.detent.value(at: $0) } }

    private func scrub(_ x: CGFloat?) {
        guard let x, width > 0 else {
            scrubX = nil
            scrubIndex = nil
            return
        }
        let years = scale.years(atFraction: Double(min(max(x / width, 0), 1)))
        scrubIndex = scale.detent.index(for: years, from: scrubIndex)
        scrubX = min(max(x, 0), width)
    }

    private func scrubTitle(_ years: Double) -> String {
        let nearest = ruler.pins.min { abs($0.years - years) < abs($1.years - years) }
        if let nearest, abs(nearest.years - years) < 0.25 { return nearest.kind.title }
        return "Age"
    }

    // MARK: Pins

    /// The shaded stretch between blood age and real age, as shares of the width.
    private var spanFractions: ClosedRange<Double>? {
        guard landedPins >= ruler.pins.count,
              let blood = ruler.state(.blood).pin, let real = ruler.state(.real).pin else { return nil }
        let a = scale.fraction(for: blood.years), b = scale.fraction(for: real.years)
        return min(a, b)...max(a, b)
    }

    private var pinStems: some View {
        ForEach(ruler.placements, id: \.kind) { placement in
            let x = CGFloat(placement.fraction) * width
            let y = Self.laneY(placement.lane)
            let color = Color.loopr(placement.kind.accent)
            let shown = placement.lane < landedPins
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(color)
                    .frame(width: 1.3, height: baseline - y)
                    .position(x: x, y: (y + baseline) / 2)
                Circle()
                    .fill(color)
                    .frame(width: Self.headRadius * 2, height: Self.headRadius * 2)
                    .shadow(color: color.opacity(0.7), radius: 6)
                    .position(x: x, y: y)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -18)
            .accessibilityHidden(true)
        }
    }

    /// Each label sits on its pin's lane, on the side `DataAgePinPlacement` picked so it crosses no other stem.
    private var pinLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placements, id: \.kind) { placement in
                if let pin = ruler.state(placement.kind).pin {
                    let x = CGFloat(placement.fraction) * width
                    let trails = placement.labelTrailsPin
                    let shown = placement.lane < landedPins
                    pinButton(pin, trails: trails, showsMethod: placement.showsMethod)
                        .fixedSize()
                        .frame(width: max(width, 1), height: 44, alignment: trails ? .leading : .trailing)
                        .offset(x: trails ? x - 12 : -(width - x - 12), y: Self.laneY(placement.lane) - 22)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                }
            }
        }
    }

    /// The label and a 24 pt clear area over the pin's head, so a tap on the head or the words opens the method page.
    private func pinButton(_ pin: DataAgePin, trails: Bool, showsMethod: Bool) -> some View {
        Button { openPin(pin.kind) } label: {
            HStack(spacing: 0) {
                if trails { Color.clear.frame(width: 21) }
                Text(showsMethod ? pin.label : pin.shortLabel)
                    .font(LooprTextStyle.caption.font.weight(.medium))
                    .foregroundStyle(Color.loopr(pin.kind.accent))
                    .lineLimit(1)
                    .fixedSize()
                if !trails { Color.clear.frame(width: 21) }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pin.spokenLabel)
        .accessibilityHint(pin.kind == .real ? "Opens your birth year in Profile." : "Opens its inputs, source and version.")
        .accessibilityIdentifier(pin.kind.identifier)
    }
}

/// The ruler's ticks, labels and baseline, drawn once. It redraws only when the scale or the shaded span changes.
struct DataAgeRulerTicks: View, Equatable {
    let scale: DataAgeRulerScale
    let dimmed: Bool
    let span: ClosedRange<Double>?
    let baseline: CGFloat

    var body: some View {
        Canvas { context, size in
            let opacity = dimmed ? 0.45 : 1
            var line = Path()
            line.move(to: CGPoint(x: 0, y: baseline))
            line.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(line, with: .color(Color.loopr(.divider)), lineWidth: 1)
            if let span {
                let rect = CGRect(x: span.lowerBound * size.width, y: baseline - 6,
                                  width: max((span.upperBound - span.lowerBound) * size.width, 2), height: 6)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.loopr(.brand).opacity(0.25)))
            }
            for tick in scale.ticks {
                let x = CGFloat(scale.fraction(for: tick.value)) * size.width
                let length: CGFloat = tick.kind == .decade ? 16 : tick.kind == .year ? 10 : 5
                var path = Path()
                path.move(to: CGPoint(x: x, y: baseline))
                path.addLine(to: CGPoint(x: x, y: baseline + length))
                let token: LooprColorToken = tick.kind == .quarter ? .inkMuted : .inkSecondary
                context.stroke(path, with: .color(Color.loopr(token).opacity(opacity)),
                               lineWidth: tick.kind == .quarter ? 0.7 : tick.kind == .decade ? 1.6 : 1.1)
                if let label = tick.label {
                    let text = Text(verbatim: label)
                        .font(LooprTextStyle.caption.font)
                        // Labels one step brighter than the ticks, so 25 and 35 still read on the dark background (R2-LAB-24).
                        .foregroundStyle(Color.loopr(.inkSecondary).opacity(tick.kind == .decade ? max(opacity, 0.85) : max(opacity, 0.7)))
                    context.draw(text, at: CGPoint(x: min(max(x, 10), size.width - 10), y: baseline + 30), anchor: .center)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
