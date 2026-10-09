import AnalyticsKit
import DesignSystem
import SwiftUI

struct WorkoutTargetStatusView: View {
    let target: WorkoutZoneTarget
    let heartRate: Int?
    let status: String
    private var tone: Color {
        status.hasPrefix("Above") ? Color.loopr(.warning) : status.hasPrefix("Below") ? Color.loopr(.inkSecondary) : Color.loopr(.recovery)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                Text(line).font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title).font(.subheadline.weight(.semibold))
                    Text(status).font(.subheadline)
                }
            }
            GeometryReader { geometry in
                let lower = Double(target.lower) - 20
                let upper = Double(target.upper) + 20
                let width = upper - lower
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.loopr(.surfaceSunk))
                    Capsule().fill(Color.loopr(.recovery).opacity(0.45))
                        .frame(width: geometry.size.width * Double(target.upper - target.lower) / width)
                        .offset(x: geometry.size.width * 20 / width)
                    if let heartRate {
                        Circle().fill(tone).frame(width: 10, height: 10)
                            .offset(x: max(0, min(geometry.size.width - 10, geometry.size.width * (Double(heartRate) - lower) / width - 5)))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            Text("\(target.lower)–\(target.upper) bpm").font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line), \(heartRate.map { "\($0) bpm" } ?? "No heart rate"), target \(target.lower) to \(target.upper) beats per minute")
        .accessibilityIdentifier("workout-target-status")
    }
    private var line: String {
        "\(target.title) · \(status)"
    }
}

struct WorkoutTargetSummaryView: View {
    let workout: WorkoutRecord
    var body: some View {
        if let summary = WorkoutTargetZoneSummary(workout: workout), let start = workout.startedAt, let end = workout.endedAt {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Text("Target time").font(.headline)
                    Text(summaryLine(summary)).font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("workout-target-time")
                    Text(summary.rangeText).font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    Canvas { context, size in
                        let duration = end.timeIntervalSince(start)
                        guard duration > 0 else { return }
                        for span in summary.spans {
                            let left = (span.start - start.timeIntervalSince1970) / duration * size.width
                            let width = (span.end - span.start) / duration * size.width
                            let rect = CGRect(x: left, y: 0, width: width, height: size.height)
                            context.fill(Path(rect), with: .color(color(span.position)))
                        }
                    }
                    .frame(height: 8)
                    .background(Color.loopr(.surfaceSunk))
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    HStack(spacing: LooprSpacing.md) {
                        legend("In zone", .inside, seconds: summary.insideSeconds)
                        legend("Above", .above, seconds: summary.seconds(in: .above))
                        legend("Below", .below, seconds: summary.seconds(in: .below))
                    }
                    .font(.caption)
                    if summary.observedSeconds < summary.targetSeconds - 5 {
                        Text("Gaps have no heart rate reading.").font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workout-target-summary")
        }
    }
    private func summaryLine(_ summary: WorkoutTargetZoneSummary) -> String {
        let label = summary.title == "Target" ? "In target" : "In \(summary.title.lowercased())"
        guard summary.observedSeconds > 0 else { return "No heart rate recorded for this target" }
        let inside = Int((summary.insideSeconds / 60).rounded())
        let total = Int((summary.targetSeconds / 60).rounded())
        return "\(label): \(inside) of \(total) min · \(summary.percent.map { "\($0)%" } ?? "--")"
    }
    private func color(_ position: TargetZoneTimeline.Position) -> Color {
        switch position { case .inside: Color.loopr(.recovery); case .above: Color.loopr(.warning); case .below: Color.loopr(.inkSecondary) }
    }
    private func legend(_ label: String, _ position: TargetZoneTimeline.Position, seconds: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(position)).frame(width: 6, height: 6)
            Text("\(label) \(Int((seconds / 60).rounded())) min")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
