import Charts
import MapKit
import SwiftUI

public enum GraphicDataState: String, CaseIterable, Sendable {
    case present
    case absent
    case partial
    case lowConfidence
    case stale
}

/// The signature circle.  In light mode the design seats the lens *and* its
/// supporting line on one white hero card, so the caption line is passed in as
/// `footer` and rendered inside that card rather than under it.
public struct SpectralLens<Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let value: String
    private let caption: String
    private let accent: LooprColorToken
    private let diameter: CGFloat
    private let footer: Footer

    public init(
        value: String,
        caption: String,
        accent: LooprColorToken,
        diameter: CGFloat = 172,
        @ViewBuilder footer: () -> Footer
    ) {
        self.value = value
        self.caption = caption
        self.accent = accent
        self.diameter = diameter
        self.footer = footer()
    }

    public var accessibilitySummary: String { value + ", " + caption }

    public var body: some View {
        presentation
    }

    @ViewBuilder
    private var presentation: some View {
        if usesLargeLensLayout {
            if isDark {
                heroStack
                    .padding(.top, 26)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            } else {
                heroStack
                    .padding(.top, 26)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color.loopr(.sheetFill),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .shadow(color: Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
                    .shadow(color: Color.loopr(.ink).opacity(0.05), radius: 15, y: 10)
                    .padding(.horizontal, 16)
            }
        } else {
            VStack(spacing: 10) {
                labelledLensCore(includeCaption: false)
                Text(caption.uppercased())
                    .looprTypography(.lensCaption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                footer
            }
        }
    }

    private var heroStack: some View {
        VStack(spacing: 14) {
            labelledLensCore()
            footer
        }
        .frame(maxWidth: .infinity)
    }

    /// The circle is one VoiceOver element; the footer keeps whatever elements
    /// the caller gave it.
    private func labelledLensCore(includeCaption: Bool = true) -> some View {
        lensCore(includeCaption: includeCaption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func lensCore(includeCaption: Bool = true) -> some View {
        ZStack {
            baseFill
            spectralRing
            innerGlow
            rim
            if isDark {
                specularHighlight
            } else {
                lightInset
            }
            VStack(spacing: 5) {
                Text(value)
                    .looprTypography(.lensValue)
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if includeCaption {
                    Text(caption.uppercased())
                        .looprTypography(.lensCaption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(width: effectiveDiameter, height: effectiveDiameter)
    }

    private var baseFill: some View {
        return Circle()
            .fill(
                RadialGradient(
                    colors: [Color.loopr(.surfaceElevated), Color.loopr(.surfaceSunk)],
                    center: UnitPoint(x: 0.5, y: isDark ? 0.28 : 0.26),
                    startRadius: 0,
                    endRadius: effectiveDiameter * 0.5
                )
            )
            .frame(width: effectiveDiameter, height: effectiveDiameter)
            .shadow(
                color: baseShadow.color,
                radius: baseShadow.radius,
                y: baseShadow.y
            )
            .overlay {
                if isDark {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }

    private var spectralRing: some View {
        let alphas = gradientAlphas
        let locations = gradientLocations
        let gradient = AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color.loopr(accent).opacity(0), location: 0),
                .init(color: Color.loopr(accent).opacity(alphas.accent), location: locations.accent),
                .init(color: Color.loopr(accent.spectralSweepPartner).opacity(alphas.partner), location: locations.partner),
                .init(color: Color.loopr(accent).opacity(0), location: locations.fade),
                .init(color: Color.loopr(accent).opacity(0), location: 1)
            ]),
            center: .center,
            startAngle: .degrees(accent.spectralStartAngle),
            endAngle: .degrees(accent.spectralStartAngle + 360)
        )

        return gradient
            .frame(width: effectiveDiameter + ringOverscan, height: effectiveDiameter + ringOverscan)
            .mask(ringMask)
            .blur(radius: effectiveDiameter < 140 ? (isDark ? 4 : 3) : (isDark ? 5 : 4))
            .accessibilityHidden(true)
    }

    private var ringMask: some View {
        let outerDiameter = effectiveDiameter + ringOverscan
        let outerRadius = outerDiameter / 2
        let transparentRadius = max(effectiveDiameter / 2 - 7, 0)
        let opaqueRadius = max(effectiveDiameter / 2 - 6, 0)

        return Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: transparentRadius / outerRadius),
                        .init(color: .white, location: opaqueRadius / outerRadius),
                        .init(color: .white, location: 1)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: outerRadius
                )
            )
            .frame(width: outerDiameter, height: outerDiameter)
    }

    private var innerGlow: some View {
        Circle()
            .stroke(
                Color.loopr(accent).opacity(isDark ? innerGlowAlpha : 0),
                lineWidth: effectiveDiameter < 140 ? 14 : 22
            )
            .frame(width: effectiveDiameter, height: effectiveDiameter)
            .blur(radius: effectiveDiameter < 140 ? 2 : 3)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var rim: some View {
        Circle()
            .stroke(
                Color.loopr(accent).opacity(isDark ? rimAlpha.dark : rimAlpha.light),
                lineWidth: 1
            )
            .frame(width: effectiveDiameter, height: effectiveDiameter)
            .accessibilityHidden(true)
    }

    private var lightInset: some View {
        Circle()
            .stroke(Color.loopr(.ink).opacity(0.06), lineWidth: 1)
            .frame(width: effectiveDiameter, height: effectiveDiameter)
            .accessibilityHidden(true)
    }

    private var specularHighlight: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(
                width: effectiveDiameter * (effectiveDiameter < 140 ? 0.34 : 0.32),
                height: effectiveDiameter * (effectiveDiameter < 140 ? 0.22 : 0.20)
            )
            .offset(
                x: -effectiveDiameter * (effectiveDiameter < 140 ? 0.21 : 0.20),
                y: -effectiveDiameter * (effectiveDiameter < 140 ? 0.29 : 0.31)
            )
            .accessibilityHidden(true)
    }

    private var isDark: Bool {
        LooprAppearance.isDark(colorScheme)
    }

    private var effectiveDiameter: CGFloat {
        let requestedDiameter = max(diameter, 1)
        return !isDark && requestedDiameter == 172 ? 168 : requestedDiameter
    }

    private var baseShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if isDark {
            return (
                Color.black.opacity(effectiveDiameter < 140 ? 0.40 : 0.45),
                effectiveDiameter < 140 ? 9 : 14,
                effectiveDiameter < 140 ? 6 : 10
            )
        }
        return (Color.loopr(.ink).opacity(0.08), 6, 4)
    }

    private var usesLargeLensLayout: Bool { effectiveDiameter >= 140 }

    private var ringOverscan: CGFloat {
        if effectiveDiameter < 140 { return isDark ? 6 : 4 }
        return isDark ? 8 : 6
    }

    private var gradientAlphas: (accent: Double, partner: Double) {
        switch accent {
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical:
            return isDark ? (0.85, 0.60) : (0.70, 0.50)
        case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake:
            return isDark ? (0.90, 0.60) : (0.80, 0.50)
        case .sleep, .sleepSweep, .sleepChip, .sleepLight, .sleepDeep, .sleepREM:
            return isDark ? (0.85, 0.70) : (0.75, 0.55)
        default:
            return isDark ? (0.90, 0.60) : (0.80, 0.55)
        }
    }

    private var gradientLocations: (accent: Double, partner: Double, fade: Double) {
        if effectiveDiameter < 140 {
            switch accent {
            case .heart, .heartSoft, .heartSweep, .stress, .cycle, .cyclePlum, .critical:
                return (turnFraction(42), turnFraction(76), turnFraction(124))
            case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake:
                return (turnFraction(44), turnFraction(78), turnFraction(128))
            case .sleep, .sleepSweep, .sleepChip, .sleepLight, .sleepDeep, .sleepREM:
                return (turnFraction(40), turnFraction(70), turnFraction(120))
            default:
                return (turnFraction(46), turnFraction(80), turnFraction(130))
            }
        }

        switch accent {
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical:
            if isDark { return (turnFraction(42), turnFraction(76), turnFraction(124)) }
            return (turnFraction(42), turnFraction(76), turnFraction(122))
        case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake:
            if isDark { return (turnFraction(44), turnFraction(78), turnFraction(128)) }
            return (turnFraction(44), turnFraction(78), turnFraction(124))
        case .sleep, .sleepSweep, .sleepChip, .sleepLight, .sleepDeep, .sleepREM:
            if isDark { return (turnFraction(44), turnFraction(78), turnFraction(128)) }
            return (turnFraction(42), turnFraction(74), turnFraction(120))
        default:
            if isDark { return (turnFraction(46), turnFraction(80), turnFraction(130)) }
            return (turnFraction(46), turnFraction(80), turnFraction(126))
        }
    }

    private func turnFraction(_ degrees: Double) -> Double { degrees / 360 }

    private var innerGlowAlpha: Double {
        if effectiveDiameter < 140 {
            switch accent {
            case .sleep, .sleepSweep, .sleepChip, .sleepLight, .sleepDeep, .sleepREM: return 0.18
            case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake: return 0.16
            case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: return 0.16
            default: return 0.20
            }
        }

        return switch accent {
        case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake: 0.14
        default: 0.16
        }
    }

    private var rimAlpha: (dark: Double, light: Double) {
        if effectiveDiameter < 140 {
            switch accent {
            case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake: return (0.42, 0.35)
            case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: return (0.40, 0.32)
            case .sleep, .sleepSweep, .sleepChip, .sleepLight, .sleepDeep, .sleepREM: return (0.40, 0.35)
            default: return (0.45, 0.40)
            }
        }

        return switch accent {
        case .strain, .strainSweep, .strainChip, .energy, .warning, .sleepAwake: (0.42, 0.35)
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: (0.40, 0.32)
        default: (0.40, 0.35)
        }
    }
}

public extension SpectralLens where Footer == EmptyView {
    init(
        value: String,
        caption: String,
        accent: LooprColorToken,
        diameter: CGFloat = 172
    ) {
        self.init(value: value, caption: caption, accent: accent, diameter: diameter) {
            EmptyView()
        }
    }
}

public struct ScoreArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    private let value: Double?
    private let unit: String
    private let trend: String?
    private let confidence: String?
    private let state: GraphicDataState
    private let accent: LooprColorToken

    public init(
        value: Double?,
        unit: String = "percent",
        trend: String? = nil,
        confidence: String? = nil,
        state: GraphicDataState = .present,
        accent: LooprColorToken = .recovery
    ) {
        self.value = value
        self.unit = unit
        self.trend = trend
        self.confidence = confidence
        self.state = state
        self.accent = accent
    }

    public var accessibilitySummary: String {
        guard let value, state != .absent else { return "Score not measured" }
        return ["Score \(Int(value)) \(unit)", trend, confidence, state == .present ? nil : stateLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    public var body: some View {
        ZStack {
            Canvas { context, size in
                let lineWidth = max(10, min(size.width, size.height) * 0.075)
                let rect = CGRect(x: lineWidth, y: lineWidth, width: size.width - lineWidth * 2, height: size.height - lineWidth * 2)
                var base = Path()
                base.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(145), endAngle: .degrees(395), clockwise: false)
                context.stroke(base, with: .color(.loopr(.surfaceElevated)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                guard state != .absent, let value else { return }
                let fraction = max(0, min(value / 100, 1)) * (revealed || shouldReduceMotion ? 1 : 0)
                var progress = Path()
                progress.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(145), endAngle: .degrees(145 + 250 * fraction), clockwise: false)
                let stroke = StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: state == .stale ? .butt : .round,
                    dash: state == .partial || state == .lowConfidence ? [lineWidth * 0.7, lineWidth * 0.55] : []
                )
                context.stroke(progress, with: .color(.loopr(accent).opacity(state == .stale ? 0.55 : 1)), style: stroke)
            }
            VStack(spacing: LooprSpacing.xxs) {
                MetricNumeral(value.map { String(Int($0)) } ?? "-")
                if state == .present {
                    LooprText(unit, style: .metricUnit, color: .inkSecondary)
                } else {
                    LooprText(stateLabel.uppercased(), style: .confidence, color: .inkSecondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            guard !shouldReduceMotion else { revealed = true; return }
            withAnimation(LooprMotion.revealAnimation) { revealed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var stateLabel: String {
        switch state {
        case .present: unit
        case .absent: "Not measured"
        case .partial: "Partial"
        case .lowConfidence: "Low confidence"
        case .stale: "Out of date"
        }
    }

    private var shouldReduceMotion: Bool {
        reduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }
}

public struct ChartSample: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let value: Double

    public init(id: String? = nil, label: String, value: Double) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

public struct TrendChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: String
    private let unit: String
    private let samples: [ChartSample]
    private let accent: LooprColorToken

    public init(title: String, unit: String, samples: [ChartSample], accent: LooprColorToken = .brand) {
        self.title = title
        self.unit = unit
        self.samples = samples
        self.accent = accent
    }

    public var accessibilitySummary: String {
        guard let low = samples.min(by: { $0.value < $1.value }), let high = samples.max(by: { $0.value < $1.value }) else {
            return "\(title), no data"
        }
        return "\(title), \(samples.count) points, low \(low.value.formatted()) \(unit), high \(high.value.formatted()) \(unit)"
    }

    public var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText(title, style: .title)
                Chart(samples) { sample in
                    AreaMark(x: .value("Period", sample.label), y: .value(unit, sample.value))
                        .foregroundStyle(LinearGradient(colors: [.loopr(accent).opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Period", sample.label), y: .value(unit, sample.value))
                        .foregroundStyle(Color.loopr(accent))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Period", sample.label), y: .value(unit, sample.value))
                        .foregroundStyle(Color.loopr(accent))
                        .symbolSize(28)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis {
                    AxisMarks(values: xAxisLabels) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        Text(String((value.as(String.self) ?? "").prefix(1)))
                            .looprTypography(.metricUnit)
                    }
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var xAxisLabels: [String] {
        if dynamicTypeSize >= .accessibility1 {
            return samples.enumerated().compactMap { index, sample in
                index.isMultiple(of: 2) || index == samples.count - 1 ? sample.label : nil
            }
        }
        return samples.map(\.label)
    }
}

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case awake
    case rem
    case light
    case deep

    var level: Double {
        switch self { case .awake: 0.1; case .rem: 0.36; case .light: 0.64; case .deep: 0.9 }
    }

    var color: LooprColorToken {
        switch self { case .awake: .sleepAwake; case .rem: .sleepREM; case .light: .sleepLight; case .deep: .sleepDeep }
    }

    var marker: String {
        switch self { case .awake: "A"; case .rem: "R"; case .light: "L"; case .deep: "D" }
    }
}

public struct SleepSegment: Codable, Identifiable, Sendable {
    public let id: Int
    public let stage: SleepStage
    public let durationMinutes: Int

    public init(id: Int, stage: SleepStage, durationMinutes: Int) {
        self.id = id
        self.stage = stage
        self.durationMinutes = durationMinutes
    }
}

public struct Hypnogram: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let segments: [SleepSegment]
    private let startLabel: String
    private let endLabel: String

    public init(segments: [SleepSegment]) {
        self.init(segments: segments, startLabel: "Start", endLabel: "End")
    }

    public init(segments: [SleepSegment], startLabel: String, endLabel: String) {
        self.segments = segments
        self.startLabel = startLabel
        self.endLabel = endLabel
    }

    public var accessibilitySummary: String {
        segments.map { "\($0.stage.rawValue), \($0.durationMinutes) minutes" }.joined(separator: "; ")
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.xs) {
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Self.stageOrder, id: \.self) { stage in
                        Text(stage.label)
                            .looprTypography(.metricUnit)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: LooprSpacing.hero + LooprSpacing.xs)

                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    drawSegments(in: &context, size: size)
                }
            }
            .frame(height: chartHeight)

            HStack {
                Color.clear
                    .frame(width: LooprSpacing.hero + LooprSpacing.xs + LooprSpacing.sm)
                Text(startLabel.uppercased())
                Spacer()
                Text(endLabel.uppercased())
            }
            .looprTypography(.sectionLabel)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private static let stageOrder: [SleepStage] = [.awake, .rem, .light, .deep]

    private var chartHeight: CGFloat {
        dynamicTypeSize >= .accessibility1
            ? LooprSpacing.hero * 6
            : LooprSpacing.hero * 4 + LooprSpacing.xl
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let rowHeight = size.height / CGFloat(Self.stageOrder.count)
        for index in 0...Self.stageOrder.count {
            var line = Path()
            let y = min(CGFloat(index) * rowHeight, size.height)
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.loopr(.divider)), lineWidth: 1)
        }
    }

    private func drawSegments(in context: inout GraphicsContext, size: CGSize) {
        let total = max(segments.reduce(0) { $0 + max($1.durationMinutes, 0) }, 1)
        let rowHeight = size.height / CGFloat(Self.stageOrder.count)
        let bandHeight = min(LooprSpacing.xl, rowHeight - LooprSpacing.sm)
        var x: CGFloat = 0
        var previousStage: SleepStage?

        for segment in segments where segment.durationMinutes > 0 {
            let width = size.width * CGFloat(segment.durationMinutes) / CGFloat(total)
            let y = yCenter(for: segment.stage, rowHeight: rowHeight)

            if let previousStage, previousStage != segment.stage {
                var connector = Path()
                connector.move(to: CGPoint(x: x, y: yCenter(for: previousStage, rowHeight: rowHeight)))
                connector.addLine(to: CGPoint(x: x, y: y))
                context.stroke(
                    connector,
                    with: .color(Color.loopr(.inkMuted).opacity(0.45)),
                    style: StrokeStyle(lineWidth: LooprSpacing.xxs / 2, lineCap: .round)
                )
            }

            let gap = min(LooprSpacing.xxs / 2, width / 4)
            let rect = CGRect(
                x: x + gap / 2,
                y: y - bandHeight / 2,
                width: max(width - gap, 1),
                height: bandHeight
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: min(LooprRadius.control, bandHeight / 2)),
                with: .color(.loopr(segment.stage.color))
            )

            x += width
            previousStage = segment.stage
        }
    }

    private func yCenter(for stage: SleepStage, rowHeight: CGFloat) -> CGFloat {
        let index = Self.stageOrder.firstIndex(of: stage) ?? 0
        return (CGFloat(index) + 0.5) * rowHeight
    }
}

private extension SleepStage {
    var label: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .light: "Light"
        case .deep: "Deep"
        }
    }
}

public struct ZoneSample: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let minutes: Double
    public let symbol: String

    public init(id: Int, name: String, minutes: Double, symbol: String) {
        self.id = id
        self.name = name
        self.minutes = minutes
        self.symbol = symbol
    }
}

public struct ZoneChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let zones: [ZoneSample]

    public init(zones: [ZoneSample]) { self.zones = zones }

    public var accessibilitySummary: String {
        zones.map { "\($0.name), \($0.minutes.formatted()) minutes" }.joined(separator: "; ")
    }

    public var body: some View {
        Chart(zones) { zone in
            BarMark(x: .value("Minutes", zone.minutes), y: .value("Zone", "\(zone.symbol) \(zone.name)"))
                .foregroundStyle(by: .value("Zone", zone.name))
                .cornerRadius(6)
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(minHeight: dynamicTypeSize >= .accessibility1 ? 420 : 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

public struct RouteGraphic: View {
    private let coordinates: [CLLocationCoordinate2D]
    private let distance: String
    private let duration: String

    public init(coordinates: [CLLocationCoordinate2D], distance: String, duration: String) {
        self.coordinates = coordinates
        self.distance = distance
        self.duration = duration
    }

    public var accessibilitySummary: String { "Route, \(distance), \(duration)" }

    public var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--loopr-visual-capture") {
                deterministicRoute
            } else {
                map
            }
            #else
            map
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var map: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Color.loopr(.movement), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
    }

    private var deterministicRoute: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.loopr(.surface)))

            var grid = Path()
            let spacing = max(min(size.width, size.height) / 5, 28)
            var position = spacing
            while position < size.width {
                grid.move(to: CGPoint(x: position, y: 0))
                grid.addLine(to: CGPoint(x: position, y: size.height))
                position += spacing
            }
            position = spacing
            while position < size.height {
                grid.move(to: CGPoint(x: 0, y: position))
                grid.addLine(to: CGPoint(x: size.width, y: position))
                position += spacing
            }
            context.stroke(grid, with: .color(Color.loopr(.divider)), lineWidth: 1)

            guard coordinates.count > 1 else { return }
            let latitudes = coordinates.map(\.latitude)
            let longitudes = coordinates.map(\.longitude)
            guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
                  let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else { return }
            let latitudeRange = max(maxLatitude - minLatitude, 0.000_001)
            let longitudeRange = max(maxLongitude - minLongitude, 0.000_001)
            let inset = min(size.width, size.height) * 0.16
            let drawingWidth = max(size.width - inset * 2, 1)
            let drawingHeight = max(size.height - inset * 2, 1)

            var route = Path()
            for (index, coordinate) in coordinates.enumerated() {
                let point = CGPoint(
                    x: inset + ((coordinate.longitude - minLongitude) / longitudeRange) * drawingWidth,
                    y: inset + (1 - (coordinate.latitude - minLatitude) / latitudeRange) * drawingHeight
                )
                if index == 0 {
                    route.move(to: point)
                } else {
                    route.addLine(to: point)
                }
            }
            context.stroke(
                route,
                with: .color(Color.loopr(.movement)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private var region: MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let latitudeDelta = max((latitudes.max() ?? first.latitude) - (latitudes.min() ?? first.latitude), 0.006) * 1.5
        let longitudeDelta = max((longitudes.max() ?? first.longitude) - (longitudes.min() ?? first.longitude), 0.006) * 1.5
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (latitudes.max()! + latitudes.min()!) / 2, longitude: (longitudes.max()! + longitudes.min()!) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

public struct RecapChart: View {
    private let samples: [ChartSample]

    public init(samples: [ChartSample]) { self.samples = samples }

    public var accessibilitySummary: String {
        samples.map { "\($0.label), \($0.value.formatted())" }.joined(separator: "; ")
    }

    public var body: some View {
        Chart(samples) { sample in
            BarMark(x: .value("Period", sample.label), y: .value("Score", sample.value))
                .foregroundStyle(Color.loopr(.brand).gradient)
                .cornerRadius(8)
                .annotation(position: .top) {
                    Text(sample.value.formatted(.number.precision(.fractionLength(0))))
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
        }
        .chartLegend(.hidden)
        .frame(minHeight: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}
