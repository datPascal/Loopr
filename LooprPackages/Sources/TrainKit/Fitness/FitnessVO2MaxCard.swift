import DesignSystem
import SwiftUI

/// VO2 max as a gauge: the published FRIEND percentile bands for the person's age and reference curve,
/// the 42-day median as the needle, last year's median as a faint needle, the value as a hero number,
/// the source chip, and an age bar with the person's age and Cardio Age. Press and hold, then slide,
/// to read the band boundaries; each one is a detent with a selection haptic. Without what it needs,
/// the gauge keeps its arc and says what is missing.
struct FitnessVO2MaxCard: View {
    let vo2Max: FitnessVO2Max
    /// Readings so far while the gauge has too few. Nil hides the guide button.
    var progress: VO2MaxReadingProgress?
    /// True on the first visit of the day: the needle sweeps up from the low end.
    let entrance: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var needleUp = true
    @State private var scrubIndex: Int?
    @State private var voiceOverIndex: Int?
    @State private var gaugeSize = CGSize(width: 300, height: 180)
    @State private var showsGuide = false

    /// The contract's gauge box: 300 by 180, the arc's centre at (150, 150) and its radius 120.
    static let aspect: CGFloat = 300.0 / 180.0
    static let centreY: CGFloat = 150.0 / 180.0
    static let radiusShare: CGFloat = 120.0 / 300.0

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                header
                switch vo2Max {
                case .gauge(let reading):
                    gauge(reading)
                    if let bar = reading.ageBar {
                        // The gauge is ml/kg/min. The ruler under it is ages in years, so it gets its own title.
                        Divider().overlay(Color.loopr(.divider))
                        LooprText(FitnessAgeBar.unitCaption, style: .label, color: .inkSecondary)
                            .accessibilityHidden(true)
                        FitnessAgeBarView(bar: bar)
                    }
                    LooprText(reading.note, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-vo2max-note")
                    // The age bar shows a Cardio Age, so the card carries the medical line (LV-10.6).
                    if reading.ageBar != nil {
                        LooprText(LooprMedicalLine.text, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-vo2max-not-medical")
                    }
                case .absent(let sentence):
                    // Before there is a reading the card stays one short row, so it does not outrank the plan
                    // and the person's own data. The arc keeps its shape at a small size.
                    HStack(alignment: .center, spacing: LooprSpacing.md) {
                        FitnessGaugeCanvas(reading: nil, needleUp: true, scrubValue: nil)
                            .aspectRatio(Self.aspect, contentMode: .fit)
                            .frame(width: 84)
                            .accessibilityHidden(true)
                        LooprText(sentence, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-vo2max-absent")
                    }
                    if let progress {
                        HStack(spacing: LooprSpacing.sm) {
                            VO2MaxReadingDots(filled: progress.days.count, total: VO2MaxReadingProgress.required)
                            LooprText(progress.headline, style: .caption, color: .inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fitness-vo2max-progress")
                        LooprGlassButton("How to get readings", symbol: "applewatch", identifier: "fitness-vo2max-guide") {
                            showsGuide = true
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-vo2max")
        .sheet(isPresented: $showsGuide) { VO2MaxReadingsGuide(progress: progress) }
        .task(id: entrance) {
            guard entrance, !LooprMotion.reducesMotion(reduceMotion) else { needleUp = true; return }
            needleUp = false
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            needleUp = true
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = LooprText("VO₂max", style: .rowTitle).accessibilityAddTraits(.isHeader)
        if case .gauge(let reading) = vo2Max {
            let chip = ProvenanceChip(.appleHealth(source: reading.sourceLabel), qualifier: FitnessGaugeReading.qualifier,
                                      identifier: "fitness-vo2max-chip")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) { title; chip }
            } else {
                HStack(spacing: LooprSpacing.sm) { title; Spacer(minLength: LooprSpacing.xs); chip }
            }
        } else {
            title
        }
    }

    private func gauge(_ reading: FitnessGaugeReading) -> some View {
        let boundaries = reading.boundaries
        let shownIndex = scrubIndex ?? voiceOverIndex
        let scrubbed = shownIndex.flatMap { boundaries.indices.contains($0) ? boundaries[$0] : nil }
        return VStack(spacing: LooprSpacing.xs) {
            ZStack {
                FitnessGaugeCanvas(reading: reading, needleUp: needleUp, scrubValue: scrubbed?.value)
                GeometryReader { proxy in
                    VStack(spacing: LooprSpacing.xxs) {
                        LooprHeroNumber(reading.gauge.value, fractionDigits: 1, style: .heroNumeralLarge, color: .ink)
                        LooprText(reading.unitLine, style: .caption, color: .inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: proxy.size.width * 0.6)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.6)
                }
            }
            .aspectRatio(Self.aspect, contentMode: .fit)
            .frame(maxWidth: 360)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { gaugeSize = $0 }
            .contentShape(Rectangle())
            // The shared UIKit hold-then-drag: a scroll that starts on the gauge still scrolls the page.
            .looprScrub { x in
                scrubIndex = x.flatMap { Self.boundaryIndex(atX: $0, width: gaugeSize.width, reading: reading) }
            }
            .looprDetentFeedback(scrubIndex, isActive: scrubIndex != nil)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reading.spokenLabel)
            .accessibilityValue(scrubbed.map { "\($0.label), \(FitnessOverview.oneDecimal($0.value)) \(FitnessGaugeReading.unit)" } ?? "")
            .accessibilityHint("Swipe up or down to read the band boundaries.")
            .accessibilityAdjustableAction { direction in
                let last = boundaries.count - 1
                guard last >= 0 else { return }
                switch direction {
                case .increment: voiceOverIndex = min((voiceOverIndex ?? -1) + 1, last)
                case .decrement: voiceOverIndex = max((voiceOverIndex ?? boundaries.count) - 1, 0)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("fitness-vo2max-gauge")
            LooprText(scrubbed.map { "The \($0.label) for your age and sex is \(FitnessOverview.oneDecimal($0.value)) \(FitnessGaugeReading.unit)." }
                      ?? reading.bandLine + ". Press and hold the gauge to read the bands.", style: .caption, color: .inkSecondary)
                // The line wraps; on one line it was cut to "Press and hold th..." (UX R1-VET-14).
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
        }
    }

    /// The boundary nearest the value under a finger at `x` across a gauge `width` wide: the arc runs
    /// from its low end on the left to its high end on the right, so the finger's share of the width is
    /// its share of the scale.
    static func boundaryIndex(atX x: CGFloat, width: CGFloat, reading: FitnessGaugeReading) -> Int? {
        let fraction = LooprScrubMath.fraction(x: x, width: width)
        let value = reading.scale.lower + fraction * (reading.scale.upper - reading.scale.lower)
        return VO2MaxGaugeBoundary.nearest(to: value, in: reading.boundaries, reach: .infinity)
    }
}

/// The gauge itself: band arcs in the Fitness accent, a tick per unit, labels every ten, last year's
/// faint needle and the current needle. Without a reading it draws the bare arc and ticks.
struct FitnessGaugeCanvas: View {
    let reading: FitnessGaugeReading?
    let needleUp: Bool
    let scrubValue: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let radius = width * FitnessVO2MaxCard.radiusShare
            let center = CGPoint(x: width / 2, y: proxy.size.height * FitnessVO2MaxCard.centreY)
            let scale = reading?.scale ?? VO2MaxGaugeScale(lower: 20, upper: 60)
            ZStack {
                Canvas { context, _ in
                    drawArc(in: &context, scale: scale, center: center, radius: radius, unit: width / 300)
                }
                if let reading {
                    if let last = reading.gauge.lastYearValue {
                        needle(diameter: 12 * width / 300, color: Color.loopr(.ink).opacity(0.3), glow: false)
                            .offset(y: -radius)
                            .rotationEffect(.degrees(scale.angle(for: last)))
                            .position(center)
                            .accessibilityHidden(true)
                    }
                    needle(diameter: 20 * width / 300, color: Color.loopr(.strain), glow: true)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(needleUp ? scale.angle(for: reading.gauge.value) : VO2MaxGaugeScale.startAngle))
                        .position(center)
                        .animation(LooprMotion.reducesMotion(reduceMotion) ? nil : .spring(response: 1.2, dampingFraction: 0.72),
                                   value: needleUp)
                        .accessibilityHidden(true)
                    if let scrubValue {
                        Capsule()
                            .fill(Color.loopr(.ink))
                            .frame(width: 2, height: 30 * width / 300)
                            .offset(y: -radius)
                            .rotationEffect(.degrees(scale.angle(for: scrubValue)))
                            .position(center)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func needle(diameter: CGFloat, color: Color, glow: Bool) -> some View {
        ZStack {
            Circle().fill(color)
            if glow { Circle().fill(.white).frame(width: diameter * 0.4, height: diameter * 0.4) }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: glow ? color.opacity(0.8) : .clear, radius: glow ? diameter * 0.5 : 0)
    }

    private func drawArc(in context: inout GraphicsContext, scale: VO2MaxGaugeScale, center: CGPoint, radius: CGFloat, unit: CGFloat) {
        let stroke = 14 * unit
        func arc(_ start: Double, _ end: Double) -> Path {
            Path { path in
                path.addArc(center: center, radius: radius, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false)
            }
        }
        if let reading {
            let arcs = scale.arcs(for: reading.gauge.bands)
            for (index, band) in arcs.enumerated() where band.endAngle - band.startAngle > 1.6 {
                let opacity = 0.16 + Double(index) * 0.19
                context.stroke(arc(band.startAngle + 0.8, band.endAngle - 0.8),
                               with: .color(Color.loopr(.strain).opacity(opacity)), lineWidth: stroke)
            }
        } else {
            context.stroke(arc(VO2MaxGaugeScale.startAngle, VO2MaxGaugeScale.endAngle),
                           with: .color(Color.loopr(.divider)), style: StrokeStyle(lineWidth: stroke, dash: [3 * unit, 4 * unit]))
        }
        for value in scale.ticks {
            let major = value.truncatingRemainder(dividingBy: 5) == 0
            let angle = scale.angle(for: value)
            let outer = VO2MaxGaugeScale.point(angle: angle, radius: radius - stroke, center: center)
            let inner = VO2MaxGaugeScale.point(angle: angle, radius: radius - (major ? 24 : 19) * unit, center: center)
            var tick = Path()
            tick.move(to: outer)
            tick.addLine(to: inner)
            context.stroke(tick, with: .color(Color.loopr(major ? .inkSecondary : .inkMuted)), lineWidth: major ? 1.4 : 0.8)
        }
        for value in scale.labels {
            let point = VO2MaxGaugeScale.point(angle: scale.angle(for: value), radius: radius + 18 * unit, center: center)
            context.draw(Text(verbatim: String(Int(value))).font(.system(size: 10.5 * unit)).foregroundStyle(Color.loopr(.inkMuted)),
                         at: point)
        }
    }
}

/// A line of ages with two pins: the person's age and their Cardio Age, as the contract's age bar.
struct FitnessAgeBarView: View {
    let bar: FitnessAgeBar

    var body: some View {
        VStack(spacing: LooprSpacing.xxs) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    // Ticks every ten years, then the baseline.
                    ForEach(bar.axisLabels, id: \.self) { age in
                        Rectangle()
                            .fill(Color.loopr(.divider))
                            .frame(width: 1, height: 12)
                            .position(x: width * bar.fraction(for: Double(age)), y: 30)
                    }
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(width: width, height: 1)
                        .position(x: width / 2, y: 36)
                    pin(label: bar.realLabel, color: .ink, glow: false, x: width * bar.fraction(for: Double(bar.realAge)),
                        width: width, above: true)
                    if let cardio = bar.cardioAge, let label = bar.cardioLabel {
                        pin(label: bar.cardioPinLabel ?? Self.cardioText(label), color: .strain, glow: true, x: width * bar.fraction(for: cardio),
                            width: width, above: false)
                    }
                }
            }
            .frame(height: 62)
            HStack {
                ForEach(bar.axisLabels, id: \.self) { age in
                    Text(verbatim: "\(age)")
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkMuted))
                    if age != bar.axisLabels.last { Spacer(minLength: 0) }
                }
            }
        }
        // A chart's labels stop growing at the largest standard size, so the pins keep their places.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.spokenLabel)
        .accessibilityIdentifier("fitness-vo2max-age-bar")
    }

    /// "Cardio age 34", or "Cardio age 25 or younger" at the ends of the reference curve.
    static func cardioText(_ label: String) -> String { "Cardio age \(label)" }

    private func pin(label: String, color: LooprColorToken, glow: Bool, x: CGFloat, width: CGFloat, above: Bool) -> some View {
        let clamped = min(max(x, 5), width - 5)
        return ZStack {
            Circle()
                .fill(Color.loopr(color))
                .frame(width: 10, height: 10)
                .shadow(color: glow ? Color.loopr(color).opacity(0.8) : .clear, radius: glow ? 6 : 0)
                .position(x: clamped, y: 36)
            Text(label)
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(color == .ink ? .inkSecondary : color))
                .lineLimit(1)
                .fixedSize()
                .position(x: min(max(clamped, 40), width - 40), y: above ? 14 : 56)
        }
    }
}
