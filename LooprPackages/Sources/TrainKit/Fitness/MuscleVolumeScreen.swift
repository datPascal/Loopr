import DesignSystem
import SwiftUI

/// Hard sets per muscle group this week (R2-LIFT-06): one bar per group, most sets first, the counting rule written
/// under the bars, and the exercises behind each bar. A thin mark at 10 sets names its source; there are no target
/// colours. Opened from the "Hard sets this week" row under the dose field.
public struct MuscleVolumeScreen: View {
    private let week: MuscleVolumeWeek?
    private let failure: String?
    private let calendar: Calendar

    /// - Parameters:
    ///   - week: Nil while it loads.
    ///   - calendar: The calendar the week was counted in, for the date range.
    public init(week: MuscleVolumeWeek?, failure: String? = nil, calendar: Calendar) {
        self.week = week; self.failure = failure; self.calendar = calendar
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                if let failure {
                    LooprInlineMessage(failure, tone: .warning).accessibilityIdentifier("muscle-volume-failure")
                } else if let week {
                    content(week)
                } else {
                    ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("muscle-volume-loading")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabSection)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Hard sets this week")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("muscle-volume-screen")
    }

    @ViewBuilder
    private func content(_ week: MuscleVolumeWeek) -> some View {
        let range = rangeText(week)
        let sessions = week.sessionCount == 1 ? "1 gym session" : "\(week.sessionCount) gym sessions"
        if week.isEmpty {
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText("No hard sets yet this week", style: .cardTitle)
                    LooprText("Finish a gym session and its working sets show up here, one bar per muscle group.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("muscle-volume-empty")
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("By muscle group", detail: "\(range), from \(sessions)", identifier: "muscle-volume-header")
                LooprCard(density: .flush) {
                    let top = max(week.groups.map(\.sets).max() ?? 1, MuscleVolumeWeek.referenceSets)
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(week.groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                            }
                            MuscleVolumeBarRow(group: group, scale: top)
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(MuscleVolumeWeek.rule, style: .prose, color: .ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("muscle-volume-rule")
            if !week.isEmpty, !week.untrained.isEmpty {
                LooprText("No sets this week: " + week.untrained.map(\.title).joined(separator: ", ") + ".",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("muscle-volume-untrained")
            }
            if week.unmappedSets > 0 {
                LooprText(week.unmappedSets == 1
                          ? "1 set is left out because its exercise has no muscles saved."
                          : "\(week.unmappedSets) sets are left out because their exercises have no muscles saved.",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("muscle-volume-unmapped")
            }
            if !week.isEmpty {
                LooprText(MuscleVolumeWeek.referenceNote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("muscle-volume-reference")
            }
        }
    }

    /// "Mon 13 to Sun 19 Nov".
    private func rangeText(_ week: MuscleVolumeWeek) -> String {
        let last = week.end.addingTimeInterval(-1)
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day()
        style.timeZone = calendar.timeZone
        var withMonth = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        withMonth.timeZone = calendar.timeZone
        let sameMonth = calendar.component(.month, from: week.start) == calendar.component(.month, from: last)
        return "\((sameMonth ? style : withMonth).format(week.start)) to \(withMonth.format(last))"
    }
}

/// One group: its name and sets on one line, the bar with the reference mark, and the exercises that added to it.
struct MuscleVolumeBarRow: View {
    let group: MuscleVolumeWeek.Group
    /// The value at the bar's right end.
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(group.group.title, style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                LooprText(MuscleVolumeWeek.setsPhrase(group.sets), style: .metricUnit, color: .ink)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.loopr(.surfaceSunk))
                    Capsule().fill(Color.loopr(.fitnessTab))
                        .frame(width: max(LooprSpacing.xs, width * min(group.sets / scale, 1)))
                    Rectangle().fill(Color.loopr(.inkSecondary))
                        .frame(width: LooprSpacing.hairline * 2, height: LooprSpacing.md)
                        .offset(x: width * min(MuscleVolumeWeek.referenceSets / scale, 1) - LooprSpacing.hairline)
                }
                .frame(height: LooprSpacing.xs)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: LooprSpacing.md)
            .accessibilityHidden(true)
            if !group.exercises.isEmpty {
                LooprText(group.exercises.joined(separator: ", "), style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MuscleVolumeWeek.spoken(group))
        .accessibilityValue(group.exercises.joined(separator: ", "))
        .accessibilityIdentifier("muscle-volume-group-\(group.group.rawValue)")
    }
}
