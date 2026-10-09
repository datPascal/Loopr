import SharedSurfaceKit
import SwiftUI
import WidgetKit

struct LooprWatchComplicationContent: View {
    let family: WidgetFamily
    let snapshot: SurfaceSnapshot?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var now: Date = .now
    var body: some View {
        let reading = SurfaceTodayReading(snapshot: snapshot, now: now)
        Group {
            if family == .accessoryCircular {
                if let recovery = reading.recovery {
                    Gauge(value: recovery / 100) { Image(systemName: "heart.fill") } currentValueLabel: {
                        Text("\(Int(recovery.rounded()))").font(.caption.bold()).privacySensitive()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(LooprWatchRecoveryColor.color(reading.style, dark: colorScheme == .dark, highContrast: contrast == .increased))
                } else {
                    Gauge(value: 0) { Image(systemName: "heart.fill") } currentValueLabel: {
                        Text("—").font(.caption.bold())
                    }
                    .gaugeStyle(.accessoryCircularCapacity).tint(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading.recoveryLine).font(.headline)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(LooprWatchRecoveryColor.color(reading.style, dark: colorScheme == .dark, highContrast: contrast == .increased)).privacySensitive()
                    if reading.isCurrentDay {
                        Text("Sleep \(reading.sleep) · Strain \(reading.strain)").font(.caption2)
                            .lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                    }
                    Text(reading.recovery == nil && reading.isCurrentDay ? reading.unavailableReason : reading.status).font(.caption2)
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.recoveryLine), Sleep \(reading.sleepAccessibility), Strain \(reading.strainAccessibility), \(reading.status)")
    }
}

/// The phone exports DesignSystem's palette, including contrast variants.
enum LooprWatchRecoveryColor {
    static func color(_ style: SurfaceRecoveryStyle?, dark: Bool, highContrast: Bool) -> Color {
        guard let style else { return .secondary }
        let rgb = highContrast
            ? (dark ? style.highContrastDarkRGB ?? style.darkRGB : style.highContrastLightRGB ?? style.lightRGB)
            : (dark ? style.darkRGB : style.lightRGB)
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

/// The Watch dashboard's rows, also rendered by the phone capture tests.
struct LooprWatchSummaryRows: View {
    let snapshot: SurfaceSnapshot?
    let now: Date
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let reading = SurfaceTodayReading(snapshot: snapshot, now: now)
        let projection = snapshot.map { WatchSurfaceProjector.project($0, now: now) }
        Group {
            VStack(spacing: 5) {
                    Text("RECOVERY").font(.system(.caption2, design: .monospaced)).tracking(1.5)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .foregroundStyle(.secondary)
                    LooprWatchRing(value: reading.recovery, fullValue: 100, text: reading.recoveryText,
                        accent: recoveryColor(reading), endColor: LooprWatchRingPalette.recoverySweep(reading.recovery,
                            dark: colorScheme == .dark, highContrast: contrast == .increased), diameter: 100)
                    Text(reading.recoveryVerdict).font(.caption.weight(.semibold)).foregroundStyle(recoveryColor(reading))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reading.recoveryLine)
            if reading.recovery == nil { Text(reading.unavailableReason).font(.caption) }
            if let headline = reading.headline { Text(headline).font(.caption).privacySensitive() }
            let rings = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            rings {
                miniRing("Sleep", value: reading.sleepMinutes, fullValue: reading.sleepNeedMinutes,
                    text: reading.sleepRingText, metric: .sleep, spoken: reading.sleepAccessibility)
                miniRing("Strain", value: reading.strainScore, fullValue: 21,
                    text: reading.strainRingText, metric: .strain, spoken: reading.strainAccessibility)
            }
            if let context = reading.sleepContext { Text(context).font(.caption2).foregroundStyle(.secondary) }
            metric("Estimated steps", projection?.steps ?? "—", icon: "shoeprints.fill")
                .accessibilityIdentifier("watch-summary-steps")
            metric("Band", projection?.battery ?? "—", icon: "battery.75percent")
                .accessibilityIdentifier("watch-summary-band")
            Text(reading.status).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func recoveryColor(_ reading: SurfaceTodayReading) -> Color {
        LooprWatchRecoveryColor.color(reading.style, dark: colorScheme == .dark, highContrast: contrast == .increased)
    }
    private func miniRing(_ title: String, value: Double?, fullValue: Double?, text: String,
                          metric: LooprWatchRingPalette.Metric, spoken: String) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(.secondary)
            LooprWatchRing(value: value, fullValue: fullValue, text: text,
                accent: LooprWatchRingPalette.color(metric, sweep: false, dark: colorScheme == .dark, highContrast: contrast == .increased),
                endColor: LooprWatchRingPalette.color(metric, sweep: true, dark: colorScheme == .dark, highContrast: contrast == .increased), diameter: 64)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(spoken)")
    }
    private func metric(_ title: String, _ value: String, icon: String, spoken: String? = nil) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        return layout {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value).font(.caption.weight(.semibold)).monospacedDigit().privacySensitive()
            } else {
                Label(title, systemImage: icon)
                Spacer()
                Text(value).fontWeight(.semibold).monospacedDigit().privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(spoken ?? (value == "—" ? "unavailable" : value))")
    }
}

struct LooprWatchEmptySummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LooprWatchSummaryRows(snapshot: nil, now: .now)
        }
    }
}


/// Watch targets link SharedSurfaceKit only. Match ProgressRing's compact
/// geometry here: an inset path, 8.5% rounded stroke, twelve-o'clock start,
/// angular sweep and end cap. The watch uses the system numeral font.
private struct LooprWatchRing: View {
    let value: Double?
    let fullValue: Double?
    let text: String
    let accent: Color
    let endColor: Color
    let diameter: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var width: CGFloat { max(4, diameter * 0.085) }
    private var progress: Double? {
        guard let value, value.isFinite, let fullValue, fullValue.isFinite, fullValue > 0 else { return nil }
        return min(max(value / fullValue, 0), 1)
    }
    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(colorScheme == .dark ? (contrast == .increased ? 0.30 : 0.17) : (contrast == .increased ? 0.26 : 0.13)), lineWidth: width)
            if let progress, progress > 0 {
                Circle().trim(from: 0, to: progress)
                    .stroke(AngularGradient(colors: [accent, endColor], center: .center,
                        startAngle: .zero, endAngle: .degrees(360 * progress)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                Circle().fill(endColor).frame(width: width, height: width)
                    .shadow(color: endColor.opacity(contrast == .increased ? 0 : 0.45), radius: width * 0.6)
                    .offset(x: (diameter - width) / 2).rotationEffect(.degrees(360 * progress))
            }
        }
        .frame(width: diameter - width, height: diameter - width)
        .rotationEffect(.degrees(-90))
        .overlay {
            Text(text).font(.system(size: diameter * 0.25, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: (diameter - width * 2) * 0.84).privacySensitive()
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// These RGB values are DesignTokens.swift's sleep/strain and recovery sweeps.
/// Keep their light, dark and increased-contrast variants together.
private enum LooprWatchRingPalette {
    enum Metric { case sleep, strain }
    static func color(_ metric: Metric, sweep: Bool, dark: Bool, highContrast: Bool) -> Color {
        let colors: [UInt32] = switch (metric, sweep) {
        case (.sleep, false): [0x6C48FF, 0x7C5CFF, 0x5230DB, 0xA794FF]
        case (.sleep, true): [0x4078FF, 0x5A8CFF, 0x275ACF, 0x8CB0FF]
        case (.strain, false): [0xE07400, 0xFF9A2E, 0xB65300, 0xFFB867]
        case (.strain, true): [0xE64628, 0xFF603C, 0xB72E18, 0xFF9D83]
        }
        return rgb(colors[(highContrast ? 2 : 0) + (dark ? 1 : 0)])
    }
    static func recoverySweep(_ score: Double?, dark: Bool, highContrast: Bool) -> Color {
        guard let score else { return .secondary }
        let colors: [UInt32] = score.rounded() >= 67 ? [0x22B8A0, 0x7CF0B4, 0x11806F, 0xBBF7D0]
            : score.rounded() >= 34 ? [0xE8B400, 0xFFE27A, 0xA37A00, 0xFFF0B8]
            : [0xE8663A, 0xFF8A66, 0xB2401D, 0xFFB8A3]
        return rgb(colors[(highContrast ? 2 : 0) + (dark ? 1 : 0)])
    }
    private static func rgb(_ color: UInt32) -> Color {
        Color(red: Double((color >> 16) & 255) / 255,
              green: Double((color >> 8) & 255) / 255, blue: Double(color & 255) / 255)
    }
}
