import SharedSurfaceKit
import DesignSystem
import SwiftUI
import WidgetKit

/// Shared by the shipped widget and ImageRenderer capture tests.
struct LooprTodayWidgetContent: View {
    let snapshot: SurfaceSnapshot?
    let now: Date
    let family: WidgetFamily
    private var reading: SurfaceTodayReading { .init(snapshot: snapshot, now: now) }
    private var tint: Color { Color.loopr(LooprRecoveryBand(score: reading.recovery)?.token ?? .inkSecondary) }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let recovery = reading.recovery {
                    Gauge(value: recovery / 100) { Text("Recovery") } currentValueLabel: {
                        Text("\(Int(recovery.rounded()))").privacySensitive()
                    }
                    .gaugeStyle(.accessoryCircularCapacity).tint(tint)
                } else {
                    Gauge(value: 0) { Text("Recovery") } currentValueLabel: {
                        Text("—")
                    }
                    .gaugeStyle(.accessoryCircularCapacity).tint(Color.loopr(.inkSecondary))
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading.recoveryLine).font(.headline).foregroundStyle(tint).privacySensitive()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if reading.isCurrentDay {
                        Text("Sleep \(reading.sleep) · Strain \(reading.strain)").font(.caption).privacySensitive()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(reading.recovery == nil && reading.isCurrentDay ? reading.unavailableReason : reading.status)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
            case .accessoryInline:
                Text(reading.recovery == nil ? reading.status : reading.recoveryLine).privacySensitive()
            default:
                rings
            }
        }
        // Accessory bounds are fixed by the system, as are primary widgets.
        .dynamicTypeSize(...(family == .systemSmall || family == .systemMedium ? DynamicTypeSize.xxxLarge : .large))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([reading.recoveryLine, reading.headline,
            "Sleep \(reading.sleepAccessibility)", reading.sleepContext, "Strain \(reading.strainAccessibility)",
            reading.recovery == nil ? reading.unavailableReason : nil, reading.status].compactMap { $0 }.joined(separator: ", "))
        .widgetURL(URL(string: "loopr://today"))
    }

    private var rings: some View {
        VStack(spacing: 4) {
            if family == .systemMedium {
                let diameter: CGFloat = reading.recovery == nil ? 64 : 84
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        ringLabel("Recovery")
                        ringLabel("Sleep")
                        ringLabel("Strain")
                    }
                    HStack(spacing: LooprSpacing.sm) {
                        recoveryRing(diameter: diameter)
                            .frame(maxWidth: .infinity)
                        LooprProgressRing(value: reading.sleepMinutes,
                            scale: reading.sleepNeedMinutes.map { LooprRingScale(fullValue: $0) },
                            text: reading.sleepRingText, accent: .sleep, diameter: diameter - 20, animates: false)
                            .frame(maxWidth: .infinity)
                        LooprProgressRing(value: reading.strainScore, scale: .init(fullValue: 21),
                            text: reading.strainRingText, accent: .strain, diameter: diameter - 20, animates: false)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: diameter)
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        ringCaption(reading.recoveryVerdict, color: tint)
                        ringCaption(reading.sleepContext ?? (reading.sleepMinutes == nil ? "Waiting" : "Last night"))
                        ringCaption(reading.strainScore == nil ? "Waiting" : "Out of 21")
                    }
                }
            } else {
                ringLabel("Recovery")
                recoveryRing(diameter: reading.recovery == nil ? 60 : 92)
                ringCaption(reading.recoveryVerdict, color: tint)
            }
            if reading.recovery == nil {
                Text(reading.unavailableReason).font(.caption2)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(reading.status).font(.caption2).foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .privacySensitive()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func ringLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity)
    }

    private func ringCaption(_ text: String, color: Color = Color.loopr(.inkSecondary)) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
    }

    private func recoveryRing(diameter: CGFloat) -> some View {
        LooprProgressRing(value: reading.recovery, scale: .init(fullValue: 100),
            text: reading.recoveryText, accent: LooprRecoveryBand(score: reading.recovery)?.token ?? .inkSecondary,
            diameter: diameter, animates: false)
    }

}

struct LooprWidgetContent: View {
    let title: String
    let projection: SurfaceWidgetEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            case .accessoryInline:
                inline
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            statusLabel
                .font(.caption.weight(.semibold))
            Text(projection.primaryText)
                .font(.title3.weight(.bold))
                .privacySensitive()
            Text(projection.secondaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(projection.isStale ? .orange : .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(projection.primaryText)
                    .font(.title3.weight(.bold))
                    .privacySensitive()
                Text(projection.secondaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var circular: some View {
        Gauge(value: projection.isStale ? 0 : 1) {
            Image(systemName: title == "Band" ? "battery.75percent" : "heart.circle")
        } currentValueLabel: {
            Image(systemName: statusSymbol)
                .font(.caption.weight(.bold))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLabel
                .font(.caption2.weight(.semibold))
            Text(projection.primaryText)
                .font(.headline)
                .lineLimit(1)
            Text(projection.secondaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label {
            Text("\(projection.primaryText), \(projection.secondaryText)")
        } icon: {
            Image(systemName: statusSymbol)
        }
        .lineLimit(1)
    }

    private var statusLabel: some View {
        Label(title, systemImage: statusSymbol)
    }

    private var statusSymbol: String {
        projection.isStale ? "exclamationmark.circle" : "checkmark.circle"
    }

    private var accessibilitySummary: String {
        "\(title), \(projection.primaryText), \(projection.secondaryText)"
    }
}

enum LooprLiveActivityVisual {
    case workout(activityName: String, elapsedSeconds: Int, heartRate: Int?, status: String)
    case breathing(completedCycles: Int, status: String)

    var title: String {
        switch self {
        case let .workout(activityName, _, _, _): activityName
        case .breathing: "Breathing"
        }
    }

    var symbol: String {
        switch self {
        case .workout: "figure.run"
        case .breathing: "wind"
        }
    }

    var trailingText: String {
        switch self {
        case let .workout(_, elapsedSeconds, heartRate, _):
            heartRate.map { "\($0) bpm" } ?? "\(elapsedSeconds / 60)m"
        case let .breathing(completedCycles, _):
            "\(completedCycles) cycles"
        }
    }

    var compactTrailingText: String {
        switch self {
        case let .workout(_, elapsedSeconds, heartRate, _):
            heartRate.map(String.init) ?? "\(elapsedSeconds / 60)m"
        case let .breathing(completedCycles, _):
            String(completedCycles)
        }
    }

    var status: String {
        switch self {
        case let .workout(_, _, _, status), let .breathing(_, status): status
        }
    }
}

struct LooprLiveActivityBannerContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        HStack {
            Label(visual.title, systemImage: visual.symbol)
            Spacer()
            Text(visual.status)
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(visual.title), \(visual.trailingText), \(visual.status)")
    }
}

struct LooprLiveActivityLeadingContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        Label(visual.title, systemImage: visual.symbol)
    }
}

struct LooprLiveActivityTrailingContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        Text(visual.trailingText)
    }
}

struct LooprLiveActivityCompactLeadingContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        Image(systemName: visual.symbol)
            .accessibilityLabel(visual.title)
    }
}

struct LooprLiveActivityCompactTrailingContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        Text(visual.compactTrailingText)
            .accessibilityLabel(visual.trailingText)
    }
}

struct LooprLiveActivityMinimalContent: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        Image(systemName: visual.symbol)
            .accessibilityLabel("\(visual.title), \(visual.status)")
    }
}

struct LooprMinimalLiveActivityCandidate: View {
    let visual: LooprLiveActivityVisual

    var body: some View {
        LooprLiveActivityMinimalContent(visual: visual)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black, in: Circle())
    }
}

struct LooprWorkoutLiveActivityVisual {
    let name: String
    let state: LooprWorkoutActivityAttributes.ContentState
    let isStale: Bool

    var heartRate: String {
        guard !isStale, let value = state.heartRate, value > 0 else { return "--" }
        return String(value)
    }
    var heartRateAccessibility: String {
        heartRate == "--" ? "Heart rate unavailable" : "\(heartRate) bpm"
    }
    var zone: Int? {
        guard !isStale, let heartRate = state.heartRate, heartRate > 0 else { return nil }
        return state.zone
    }
    var zoneName: String {
        switch zone {
        case 0: "Below zone 1"
        case 1: "Recovery"
        case 2: "Easy"
        case 3: "Aerobic"
        case 4: "Hard"
        case 5: "Peak"
        default: "Zone unavailable"
        }
    }
    var zoneColor: Color {
        switch zone {
        case 1: .cyan
        case 2: .green
        case 3: .yellow
        case 4: .orange
        case 5: .red
        default: .gray
        }
    }
    var targetLine: String? {
        guard let name = state.targetName else { return nil }
        let status = isStale ? "No heart rate" : state.targetStatus ?? "No heart rate"
        return "\(name) · \(status)"
    }
    var status: String { isStale ? "Stopped updating" : state.status }
    var distance: String? {
        state.distanceMeters.map { String(format: "%.2f km", $0 / 1_000) }
    }
    var pace: String? {
        guard let seconds = state.paceSecondsPerKilometer, seconds.isFinite, seconds > 0 else { return nil }
        guard let rounded = Int(exactly: seconds.rounded()) else { return nil }
        return "Avg \(rounded / 60):\(String(format: "%02d", rounded % 60)) /km"
    }
}

struct LooprWorkoutElapsedView: View {
    let state: LooprWorkoutActivityAttributes.ContentState

    var body: some View {
        if let startedAt = state.startedAt,
           ["Active", "Paused", "Preparing", "Finishing"].contains(state.status) {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false, showsHours: true)
                .monospacedDigit()
        } else {
            let hours = state.elapsedSeconds / 3_600
            let minutes = (state.elapsedSeconds % 3_600) / 60
            let seconds = state.elapsedSeconds % 60
            Text(String(format: "%02d:%02d:%02d", hours, minutes, seconds))
                .monospacedDigit()
        }
    }
}

struct LooprWorkoutLiveActivityBanner: View {
    let visual: LooprWorkoutLiveActivityVisual

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(visual.name).font(.headline)
                Spacer()
                LooprWorkoutElapsedView(state: visual.state).font(.subheadline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "heart.fill").foregroundStyle(visual.zoneColor)
                    Text(visual.heartRate).font(.title.bold()).monospacedDigit()
                    Text("bpm").font(.caption)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(visual.zoneName).font(.subheadline.weight(.semibold))
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { number in
                            Capsule()
                                .fill(number == visual.zone ? visual.zoneColor : .gray.opacity(0.4))
                                .frame(width: 13, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            if let target = visual.targetLine { Text(target).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true) }
            if let distance = visual.distance {
                HStack(spacing: 12) {
                    Text(distance)
                    if let pace = visual.pace { Text(pace) }
                }
                .font(.caption)
            }
            if visual.isStale || visual.status != "Active" {
                Text(visual.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(visual.name), \(visual.targetLine ?? visual.zoneName), \(visual.heartRateAccessibility), \(visual.zoneName), \(visual.status)")
    }
}

struct LooprBreathingLiveActivityBanner: View {
    let state: LooprBreathingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wind")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Breathing").font(.headline)
                Text(isStale ? "Stopped updating" : state.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(state.completedCycles) cycles").font(.headline)
                if let start = state.startedAt,
                   state.status == "In progress" || state.status == "Paused" {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.caption).monospacedDigit()
                }
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Breathing, \(state.completedCycles) cycles, \(isStale ? "Stopped updating" : state.status)")
    }
}
