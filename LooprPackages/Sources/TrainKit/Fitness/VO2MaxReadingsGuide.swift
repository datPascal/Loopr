import AnalyticsKit
import DesignSystem
import SwiftUI

// How a person gets the VO₂max readings that the gauge and Cardio Age need. The rule is `VO2MaxMedian`'s: three
// readings on different days in the last 42 days, the first and last at least 14 days apart. The progress below
// reads the same rule, so "2 more" here and the gauge or Cardio Age appearing cannot disagree.

/// Where the person stands against the reading rule, and what the next reading has to be.
public struct VO2MaxReadingProgress: Equatable, Sendable {
    /// One day with a reading that counts today.
    public struct Day: Equatable, Sendable, Identifiable {
        public let date: Date
        /// ml/kg/min, the day's latest reading.
        public let value: Double
        /// The day the reading leaves the 42-day window.
        public let dropsOut: Date
        public var id: Date { date }
    }

    /// Oldest first.
    public let days: [Day]
    /// Readings on new days still needed. Zero once the rule is met.
    public let stillNeeded: Int
    /// The last needed reading has to be on this day or later, so the first and last are 14 days apart. Nil when any
    /// new day works.
    public let lastOneFrom: Date?
    public let calendar: Calendar

    public var isComplete: Bool { stillNeeded == 0 }

    public static func make(readings: [VO2MaxReading], asOf now: Date, calendar: Calendar) -> VO2MaxReadingProgress {
        let rule = VO2MaxSourceSelector()
        let used = readings
            .filter { $0.value.isFinite && $0.value > 0 && $0.date <= now && now.timeIntervalSince($0.date) <= rule.healthKitWindow }
            .sorted { $0.date < $1.date }
        let byDay = Dictionary(grouping: used) { calendar.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted().compactMap { day -> Day? in
            guard let latest = byDay[day]?.last else { return nil }
            return Day(date: day, value: latest.value,
                       dropsOut: calendar.startOfDay(for: latest.date.addingTimeInterval(rule.healthKitWindow)))
        }
        var spanMet = false
        var lastOneFrom: Date?
        if let first = used.first?.date, let last = used.last?.date {
            spanMet = last.timeIntervalSince(first) >= rule.minimumHealthKitSpan
            let threshold = first.addingTimeInterval(rule.minimumHealthKitSpan)
            if !spanMet, threshold > now {
                // Rounded up to a whole day, so a reading on that day counts at any time of day.
                let day = calendar.startOfDay(for: threshold)
                lastOneFrom = day == threshold ? day : calendar.date(byAdding: .day, value: 1, to: day)
            }
        }
        let needed = max(rule.minimumHealthKitSamples - days.count, spanMet || used.isEmpty ? 0 : 1)
        return VO2MaxReadingProgress(days: days, stillNeeded: used.isEmpty ? rule.minimumHealthKitSamples : needed,
                                     lastOneFrom: lastOneFrom, calendar: calendar)
    }

    // MARK: Text

    static var required: Int { VO2MaxSourceSelector().minimumHealthKitSamples }

    /// "1 of 3 readings", or "4 readings, all within 2 weeks".
    public var headline: String {
        if days.count < Self.required || isComplete { return "\(min(days.count, Self.required)) of \(Self.required) readings" }
        return "\(days.count) readings, all within 2 weeks"
    }

    /// What the next reading has to be.
    public var nextStep: String {
        if isComplete { return "That is enough. Loopr uses the middle value of these readings." }
        if days.isEmpty {
            return "No readings in the last 6 weeks yet. 1 or 2 outdoor walks, runs or hikes a week for 3 weeks usually gets you there."
        }
        guard let lastOneFrom else {
            return stillNeeded == 1 ? "1 more reading on a new day." : "\(stillNeeded) more readings, each on a new day."
        }
        let day = Self.day(lastOneFrom, calendar: calendar)
        if stillNeeded == 1 { return "1 more reading, on \(day) or later." }
        return "\(stillNeeded) more readings on new days. The last one has to be on \(day) or later."
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func value(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

/// The sheet that explains how to get VO₂max readings, with the person's progress on top.
public struct VO2MaxReadingsGuide: View {
    private let progress: VO2MaxReadingProgress?
    /// A line about what else the number needs, such as the birth year in Profile.
    private let alsoNeeds: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(progress: VO2MaxReadingProgress?, alsoNeeds: String? = nil) {
        self.progress = progress
        self.alsoNeeds = alsoNeeds
    }

    public struct Step: Equatable, Sendable {
        public let symbol: String
        public let title: String
        public let detail: String
    }

    public static let title = "Getting VO₂max readings"
    // Sources: docs/research/2026-10-28-apple-watch-vo2max-readings.md (Apple support 108790 and the VO₂max white paper).
    public static let intro = "Apple Watch estimates your VO₂max during outdoor workouts and saves it to Apple Health. Loopr reads it from there."
    public static let steps: [Step] = [
        Step(symbol: "applewatch", title: "Wear your Apple Watch",
             detail: "Series 3 or later. Wear it for a day before the first workout, snug enough to read your heart rate."),
        Step(symbol: "figure.walk", title: "Start an Outdoor Walk, Outdoor Run or Hike",
             detail: "Use the Workout app on the watch. Indoor and gym workouts don't give a reading."),
        Step(symbol: "heart.fill", title: "Get your heart rate up on flat ground",
             detail: "Walk fast enough to breathe harder, or run. Stay on fairly flat ground outside, where the watch has GPS."),
        Step(symbol: "calendar", title: "Do it on 3 different days",
             detail: "The first and last need to be at least 2 weeks apart, all within 6 weeks. Not every workout gives a reading, so plan 1 or 2 a week for 3 weeks."),
        Step(symbol: "person.text.rectangle", title: "Check your Health Details",
             detail: "The watch uses your age, sex, height and weight, and whether you take medicine that slows your heart rate. In the Health app, tap your picture, then Health Details."),
    ]
    public static let footnote = "Values typed into the Health app by hand may not count. Loopr only uses readings that say they came from a workout."

    public var body: some View {
        NavigationStack {
            LooprDetailScaffold(spacing: LooprSpacing.md) {
                LooprText(Self.intro, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress { progressCard(progress) }
                if let alsoNeeds {
                    LooprText(alsoNeeds, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("vo2max-guide-also-needs")
                }
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                            if index > 0 { LooprHairline() }
                            stepRow(step)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                }
                .accessibilityIdentifier("vo2max-guide-steps")
                LooprText(Self.footnote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let health = URL(string: "x-apple-health://") {
                    LooprGlassButton("Open Apple Health", symbol: "heart.fill", identifier: "vo2max-guide-open-health") {
                        openURL(health)
                    }
                }
            }
            .navigationTitle(Self.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("vo2max-guide-done")
                }
            }
        }
        .accessibilityIdentifier("vo2max-guide")
    }

    private func progressCard(_ progress: VO2MaxReadingProgress) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    LooprText(progress.headline, style: .rowTitle)
                    Spacer(minLength: LooprSpacing.xs)
                    VO2MaxReadingDots(filled: progress.days.count, total: VO2MaxReadingProgress.required)
                }
                LooprText(progress.nextStep, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(progress.days) { day in
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        LooprText(VO2MaxReadingProgress.day(day.date, calendar: progress.calendar), style: .caption)
                        Text(verbatim: "\(VO2MaxReadingProgress.value(day.value)) \(FitnessGaugeReading.unit)")
                            .looprTypography(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(.ink))
                        Spacer(minLength: LooprSpacing.xs)
                        LooprText("Counts until \(VO2MaxReadingProgress.day(day.dropsOut, calendar: progress.calendar))",
                                  style: .caption, color: .inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vo2max-guide-progress")
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Image(systemName: step.symbol)
                .looprTypography(.metricUnit)
                .foregroundStyle(Color.loopr(.brand))
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(step.title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(step.detail, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LooprSpacing.sm)
        .accessibilityElement(children: .combine)
    }
}

/// Three dots, one per reading, filled for the days Loopr has.
struct VO2MaxReadingDots: View {
    let filled: Int
    let total: Int

    var body: some View {
        HStack(spacing: LooprSpacing.xxs) {
            ForEach(0..<total, id: \.self) { index in
                Group {
                    if index < filled { Circle().fill(Color.loopr(.brand)) }
                    else { Circle().strokeBorder(Color.loopr(.inkMuted), lineWidth: 1.2) }
                }
                .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}
