import SwiftUI
import DesignSystem

/// Fourteen nights as vertical bars from bedtime (top) to wake time (bottom)
/// on a clock scale, with the usual bedtime and wake ranges as soft bands.
/// Hold and drag to read a night.
struct SleepTimingChart: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubIndex: Int?

    let consistency: SleepConsistency
    var height: CGFloat = 164

    private let headroom: CGFloat = 34
    private var scaleWidth: CGFloat { dynamicTypeSize >= .accessibility1 ? 60 : 44 }

    var body: some View {
        if let domain = consistency.chartDomain {
            VStack(spacing: LooprSpacing.xxs + 2) {
                HStack(alignment: .top, spacing: LooprSpacing.xs) {
                    plot(domain)
                    scale(domain)
                }
                .frame(height: height)
                axis
                    .padding(.trailing, scaleWidth + LooprSpacing.xs)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bedtime and wake time, last 14 nights")
            .accessibilityValue(spokenSummary)
            .accessibilityIdentifier("sleep-timing-chart")
        }
    }

    private func y(_ minutes: Double, domain: ClosedRange<Double>, plotHeight: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return headroom }
        return headroom + CGFloat((minutes - domain.lowerBound) / span) * plotHeight
    }

    private func plot(_ domain: ClosedRange<Double>) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotHeight = proxy.size.height - headroom
            let count = max(consistency.nights.count, 1)
            let slot = width / CGFloat(count)
            let barWidth = max(4, min(slot * 0.5, 14))
            ZStack(alignment: .topLeading) {
                // Hour gridlines.
                ForEach(ticks(domain), id: \.self) { tick in
                    Rectangle()
                        .fill(Color.loopr(.divider).opacity(0.7))
                        .frame(width: width, height: 1)
                        .offset(y: y(tick, domain: domain, plotHeight: plotHeight))
                }
                // Usual bedtime and wake time.
                if consistency.usesMiddleHalf {
                    ForEach(Array([consistency.bedRange, consistency.wakeRange].compactMap { $0 }.enumerated()), id: \.offset) { _, range in
                        let top = y(range.lowerBound, domain: domain, plotHeight: plotHeight)
                        let bottom = y(range.upperBound, domain: domain, plotHeight: plotHeight)
                        Rectangle()
                            .fill(Color.loopr(.sleep).opacity(isDark ? 0.14 : 0.1))
                            .frame(width: width, height: max(bottom - top, 2))
                            .offset(y: top)
                    }
                }
                ForEach(Array(consistency.nights.enumerated()), id: \.element.id) { index, night in
                    let centerX = LooprScrubMath.center(of: index, count: count, width: width)
                    if let bed = night.bed, let wake = night.wake, wake > bed {
                        let top = y(bed, domain: domain, plotHeight: plotHeight)
                        let bottom = y(wake, domain: domain, plotHeight: plotHeight)
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(Color.loopr(.sleep).opacity(opacity(index)))
                            .frame(width: barWidth, height: max(bottom - top, barWidth))
                            .position(x: centerX, y: (top + bottom) / 2)
                    } else {
                        Circle()
                            .fill(Color.loopr(.inkMuted))
                            .frame(width: 4, height: 4)
                            .position(x: centerX, y: headroom + plotHeight / 2)
                    }
                }
                if let scrubIndex, consistency.nights.indices.contains(scrubIndex) {
                    let night = consistency.nights[scrubIndex]
                    LooprScrubReadout(
                        x: LooprScrubMath.center(of: scrubIndex, count: count, width: width),
                        title: night.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                        value: readoutValue(night),
                        accent: .sleep
                    )
                    .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .looprScrub { x in
                scrubIndex = x.flatMap { LooprScrubMath.index(x: $0, width: width, count: consistency.nights.count) }
            }
        }
    }

    private func scale(_ domain: ClosedRange<Double>) -> some View {
        GeometryReader { proxy in
            let plotHeight = proxy.size.height - headroom
            ZStack(alignment: .topLeading) {
                ForEach(ticks(domain), id: \.self) { tick in
                    Text(SleepClock.text(minutesAfterNoon: tick, timeZone: consistency.timeZone))
                        .looprTypography(.confidence)
                        .monospacedDigit()
                        .foregroundStyle(Color.loopr(.inkMuted))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: scaleWidth, alignment: .leading)
                        .position(x: scaleWidth / 2, y: y(tick, domain: domain, plotHeight: plotHeight))
                }
            }
        }
        .frame(width: scaleWidth)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    private var axis: some View {
        GeometryReader { proxy in
            let count = consistency.nights.count
            ZStack(alignment: .topLeading) {
                ForEach(Array(consistency.nights.enumerated()), id: \.element.id) { index, night in
                    Text(night.date.formatted(.dateTime.weekday(.narrow)).uppercased())
                        .looprTypography(.confidence)
                        .foregroundStyle(Color.loopr(index == count - 1 ? .ink : .inkSecondary))
                        .fixedSize()
                        .position(x: LooprScrubMath.center(of: index, count: count, width: proxy.size.width), y: 7)
                }
            }
        }
        .frame(height: 14)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    /// Whole hours inside the domain, every 2 or 3 hours so four labels fit.
    private func ticks(_ domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        let step: Double = span > 600 ? 180 : 120
        var tick = (domain.lowerBound / step).rounded(.up) * step
        var result: [Double] = []
        while tick <= domain.upperBound {
            result.append(tick)
            tick += step
        }
        return result
    }

    private func opacity(_ index: Int) -> Double {
        if let scrubIndex { return scrubIndex == index ? 1 : 0.3 }
        return index == consistency.nights.count - 1 ? 1 : 0.7
    }

    private func readoutValue(_ night: SleepConsistency.Night) -> String? {
        guard let bed = night.bed, let wake = night.wake else { return nil }
        return "\(SleepClock.text(minutesAfterNoon: bed, timeZone: consistency.timeZone)) to \(SleepClock.text(minutesAfterNoon: wake, timeZone: consistency.timeZone))"
    }

    private var spokenSummary: String {
        let measured = consistency.measured
        guard let last = measured.last, let bed = last.bed, let wake = last.wake else { return "No nights" }
        var parts = ["\(measured.count) of \(consistency.nights.count) nights measured"]
        parts.append("latest from \(SleepClock.text(minutesAfterNoon: bed, timeZone: consistency.timeZone)) to \(SleepClock.text(minutesAfterNoon: wake, timeZone: consistency.timeZone))")
        if let summary = consistency.summary { parts.append(summary) }
        return parts.joined(separator: ", ")
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
