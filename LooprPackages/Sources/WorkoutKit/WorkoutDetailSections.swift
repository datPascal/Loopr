import AnalyticsKit
import Charts
import DesignSystem
import DomainKit
import Foundation
import SwiftUI

// Fitness round 2: what the workout detail says about each number and about the week.
// - R2-NEW-05, R2-VET-10, R2-DES-13: one source per value. A typed value says "Typed by you", a band value "From the
//   band", an imported one names the app, a band record whose times the person changed "From the band, edited by you".
// - R2-VET-04: heart rate over the session, the zone split with the zone method the weekly dose uses, average and max.
// - R2-NEW-14: every detail ends with what the session counted for its week.
// - R2-WOD-12: one date style, with the year only for a past year.

// MARK: - Context

/// Which weekly session target a workout counts toward, as the weekly dose classifies it.
public enum WorkoutWeekSessionKind: String, Sendable {
    case strength, mobility

    /// The dose's rule for Loopr's own types: gym and CrossFit are strength; yoga, Pilates and mobility are mobility.
    /// The app passes the dose's own classification, which also reads an imported workout's activity name; this is
    /// the fallback when it does not.
    public static func of(_ activity: ActivityType) -> WorkoutWeekSessionKind? {
        if activity == .strength || activity == .crossfit { return .strength }
        return activity.countsAsMobility ? .mobility : nil
    }
}

/// What the detail needs from outside WorkoutKit: the clock, the person's heart rate zones on the workout's day, and
/// how the weekly dose treats the workout.
public struct WorkoutDetailContext: Equatable, Sendable {
    public var now: Date
    public var calendar: Calendar
    /// The zones the dose used for that day. Nil without an age or a max heart rate.
    public var zones: HeartRateZones?
    /// True when the band measured zone minutes on the workout's day. The band's minutes then win over Apple Health's.
    public var bandCoveredDay: Bool
    /// What the dose counts the workout as. Nil for a type that is neither strength nor mobility.
    public var sessionKind: WorkoutWeekSessionKind?
    /// True when the workout falls in the current week, Monday to Sunday.
    public var isThisWeek: Bool

    public init(now: Date, calendar: Calendar, zones: HeartRateZones? = nil, bandCoveredDay: Bool = false,
                sessionKind: WorkoutWeekSessionKind? = nil, isThisWeek: Bool = true) {
        self.now = now; self.calendar = calendar; self.zones = zones; self.bandCoveredDay = bandCoveredDay
        self.sessionKind = sessionKind; self.isThisWeek = isThisWeek
    }

    /// Without the app's sources: no zones, Loopr's own classification, the device clock.
    public static func fallback(for workout: WorkoutRecord, now: Date = Date(), calendar: Calendar = .current) -> WorkoutDetailContext {
        var week = calendar
        week.firstWeekday = 2
        let start = workout.startedAt ?? workout.createdAt
        let thisWeek = week.dateInterval(of: .weekOfYear, for: now)?.contains(start) ?? false
        return WorkoutDetailContext(now: now, calendar: calendar, sessionKind: .of(workout.activity), isThisWeek: thisWeek)
    }
}

/// The app supplies the context, from the same sources the Fitness tab's dose reads.
public protocol WorkoutDetailContextProviding: Sendable {
    func context(for workout: WorkoutRecord) async -> WorkoutDetailContext
}

public extension EnvironmentValues {
    @Entry var workoutDetailContextProvider: (any WorkoutDetailContextProviding)? = nil
}

// MARK: - Sources

/// Where one value on the detail came from.
public enum WorkoutValueSource: Equatable, Sendable {
    case typed
    case band
    /// A band record whose start or end the person changed.
    case bandEdited
    /// An app that saved the workout to Apple Health ("Garmin Connect"), or an account export.
    case app(String)

    public var label: String {
        switch self {
        case .typed: "Typed by you"
        case .band: "From the band"
        case .bandEdited: "From the band, edited by you"
        case .app(let name): "From \(name)"
        }
    }
}

public extension WorkoutRecord {
    /// The app that saved an Apple Health workout or wrote an export, "Garmin Connect". Nil for Loopr's own records.
    var importingApp: String? {
        guard source == .healthKit || source == .imported else { return nil }
        let name = importedSummary?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Apple Health" : name
    }

    /// True when the person moved the start or end of a band record. A detected record keeps the band's window in its
    /// identity; any record whose band readings fall outside its window was shortened.
    var bandTimesEdited: Bool {
        guard source == .live || source == .detected, let start = startedAt else { return false }
        let parts = identity.canonicalKey.split(separator: ":")
        if parts.count == 4, parts[0] == "window", let from = Double(parts[2]), let to = Double(parts[3]) {
            let end = endedAt.map { $0.timeIntervalSince1970.rounded() } ?? 0
            if from != start.timeIntervalSince1970.rounded() || (to != 0 && to != end) { return true }
        }
        guard let end = endedAt else { return false }
        return samples.contains { $0.heartRate != nil && ($0.timestamp < start.addingTimeInterval(-60) || $0.timestamp > end.addingTimeInterval(60)) }
    }

    /// Who measured the heart rate and distance samples: the importing app, or the band for every other record.
    var measuredSource: WorkoutValueSource {
        if let app = importingApp { return .app(app) }
        return bandTimesEdited ? .bandEdited : .band
    }

    /// The record's own source line on the detail (R2-NEW-05): "Typed by you", "From the band", "Garmin Connect through
    /// Apple Health". A typed record with band heart rate says both, once.
    var detailSourceLine: String {
        switch source {
        case .manual:
            return samples.contains { $0.heartRate != nil } ? "Typed by you, heart rate from the band" : WorkoutValueSource.typed.label
        case .live, .detected:
            return measuredSource.label
        case .healthKit:
            let app = importingApp ?? "Apple Health"
            return app == "Apple Health" ? "From Apple Health" : "\(app) through Apple Health"
        case .imported:
            return WorkoutValueSource.app(importingApp ?? "an export").label
        }
    }

    var detailSourceSymbol: String {
        switch source {
        case .manual: "pencil"
        case .live, .detected: "sensor.tag.radiowaves.forward"
        case .healthKit: "heart.text.square"
        case .imported: "square.and.arrow.down"
        }
    }

    /// Route details and Share preview only where a route can exist: an outdoor type the band recorded live. Apple
    /// Health imports carry no route into Loopr, and a typed or detected session never has one (R2-DES-13).
    var detailMayHaveRoute: Bool {
        source == .live && [.run, .cycle, .walk, .hike].contains(activity)
    }
}

// MARK: - Dates

/// One date style for the detail (R2-WOD-12): "Tue 14 Nov", and "Tue 14 Nov 2022" for a past year.
public enum WorkoutDetailDates {
    public static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        let year = calendar.component(.year, from: date)
        // The year goes on the end by hand: the year style adds a comma after the weekday ("Mon, 14 Nov 2022").
        return year == calendar.component(.year, from: now) ? date.formatted(style) : "\(date.formatted(style)) \(year)"
    }

    public static func time(_ date: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }

    /// "Tue 14 Nov, 06:15 to 06:35". Nil without a start.
    public static func whenLine(_ workout: WorkoutRecord, now: Date, calendar: Calendar,
                                locale: Locale = .autoupdatingCurrent) -> String? {
        guard let start = workout.startedAt else { return nil }
        let day = day(start, now: now, calendar: calendar, locale: locale)
        let from = time(start, calendar: calendar, locale: locale)
        guard let end = workout.endedAt else { return "\(day), from \(from)" }
        return "\(day), \(from) to \(time(end, calendar: calendar, locale: locale))"
    }
}

// MARK: - Rows

/// What the detail lists for a record, each value with where it came from (R1-VET-06, R2-NEW-05).
public enum WorkoutDetailPresentation {
    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let unit: String?
        /// "Typed by you", "From the band", "From Garmin Connect".
        public let source: String?
    }

    /// Distance, effort, energy and a typed heart rate. A measured distance wins over a typed one. Measured heart rate
    /// has its own section (`WorkoutHeartRateSummary`).
    public static func rows(for workout: WorkoutRecord, system: LooprMeasurementSystem = .metric) -> [Row] {
        var rows: [Row] = []
        let measured = workout.measuredSource.label
        if let meters = workout.latestDistanceSample?.distanceMeters, meters > 0 {
            let distance = LooprUnitFormatter.distance(meters: meters, system: system)
            // A recorded session's distance is GPS; the band has no idea how far anyone went.
            rows.append(Row(id: "distance", title: "Distance", value: distance.value, unit: distance.unit,
                            source: workout.source == .live ? "From GPS" : measured))
        } else if let lengths = workout.lengths, let meters = workout.resolvedDistanceMeters {
            let distance = LooprUnitFormatter.distance(meters: meters, system: system)
            rows.append(Row(id: "lengths", title: "Lengths", value: "\(lengths)", unit: "× \(workout.poolLengthMeters ?? WorkoutRecord.defaultPoolLengthMeters) m",
                            source: WorkoutValueSource.typed.label))
            rows.append(Row(id: "distance", title: "Distance", value: distance.value, unit: distance.unit,
                            source: WorkoutValueSource.typed.label))
        } else if let meters = workout.loggedDistanceMeters {
            let distance = LooprUnitFormatter.distance(meters: meters, system: system)
            rows.append(Row(id: "distance", title: "Distance", value: distance.value, unit: distance.unit,
                            source: WorkoutValueSource.typed.label))
        }
        if let effort = workout.effort {
            rows.append(Row(id: "effort", title: "Effort", value: "\(effort) of 10, \(WorkoutEffortPicker.word(for: effort))",
                            unit: nil, source: WorkoutValueSource.typed.label))
        }
        if let calories = workout.loggedCalories {
            rows.append(Row(id: "calories", title: "Calories", value: "\(calories)", unit: "kcal", source: WorkoutValueSource.typed.label))
        }
        if workout.source == .healthKit, let energy = workout.importedSummary?.energyKcal, energy > 0 {
            rows.append(Row(id: "energy", title: "Energy", value: energy.formatted(.number.precision(.fractionLength(0))),
                            unit: "kcal", source: measured))
        }
        if WorkoutHeartRateSummary.make(workout) == nil, let typed = workout.typedAverageHeartRate {
            rows.append(Row(id: "heart-rate", title: "Average heart rate", value: "\(typed)", unit: "bpm",
                            source: "Typed by you, adds no zone minutes"))
        }
        return rows
    }
}

// MARK: - Heart rate and zones

/// The heart rate inside a workout: readings for the chart, average and maximum. Readings come from the record's
/// samples (the band's, or Apple Health's for an import); an import without readings keeps the average and maximum
/// its app saved.
public struct WorkoutHeartRateSummary: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let time: Date
        public let bpm: Int
        public init(time: Date, bpm: Int) { self.time = time; self.bpm = bpm }
    }

    /// Inside the workout's start and end, one per timestamp, oldest first.
    public let points: [Point]
    public let average: Int?
    public let maximum: Int?
    public let source: WorkoutValueSource

    /// Nil when the record has neither readings nor a saved average or maximum.
    public static func make(_ workout: WorkoutRecord) -> WorkoutHeartRateSummary? {
        var byTime: [Date: Int] = [:]
        for sample in workout.samples {
            guard let bpm = sample.heartRate, bpm > 0, byTime[sample.timestamp] == nil else { continue }
            if let start = workout.startedAt, sample.timestamp < start { continue }
            if let end = workout.endedAt, sample.timestamp > end { continue }
            byTime[sample.timestamp] = bpm
        }
        let points = byTime.map { Point(time: $0.key, bpm: $0.value) }.sorted { $0.time < $1.time }
        let average: Int?
        let maximum: Int?
        if points.isEmpty {
            // Only an import's own summary; a typed average is the person's, not a reading.
            guard workout.source == .healthKit || workout.source == .imported else { return nil }
            average = workout.importedSummary?.averageHeartRate.map { Int($0.rounded()) }
            maximum = workout.importedSummary?.maximumHeartRate.map { Int($0.rounded()) }
            guard average != nil || maximum != nil else { return nil }
        } else {
            average = Int((Double(points.map(\.bpm).reduce(0, +)) / Double(points.count)).rounded())
            maximum = points.map(\.bpm).max()
        }
        return WorkoutHeartRateSummary(points: points, average: average, maximum: maximum, source: workout.measuredSource)
    }

    /// True with at least two readings, enough for a line.
    public var hasChart: Bool { points.count >= 2 }

    /// At most `limit` points for the chart: the mean of each run of readings, so a long session draws quickly.
    public func chartPoints(limit: Int = 180) -> [Point] {
        guard points.count > limit, limit > 0 else { return points }
        let size = Int((Double(points.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: points.count, by: size).map { index in
            let slice = points[index..<min(index + size, points.count)]
            let mean = Double(slice.map(\.bpm).reduce(0, +)) / Double(slice.count)
            return Point(time: slice[slice.startIndex].time, bpm: Int(mean.rounded()))
        }
    }
}

/// Minutes in each of the five heart rate zones, worked out the way the weekly dose works out a day's minutes:
/// `ActivityAnalytics.timeInZone` over the person's resolved zones, rounded per zone.
public struct WorkoutZoneSplit: Equatable, Sendable {
    /// Zones 1 to 5.
    public let minutes: [Int]
    public let zones: HeartRateZones

    public var zone2Minutes: Int { minutes[1] }
    /// Zones 4 and 5, the dose's hard minutes.
    public var hardMinutes: Int { minutes[3] + minutes[4] }
    public var totalMinutes: Int { minutes.reduce(0, +) }

    public static func make(_ points: [WorkoutHeartRateSummary.Point], zones: HeartRateZones) -> WorkoutZoneSplit? {
        guard !points.isEmpty else { return nil }
        let source: HRMaxSource = switch zones.source {
        case .manual: .manual
        case .observed: .measured
        case .estimated: .agePredicted
        }
        let samples = points.map { ActivityHeartRateSample(timestamp: $0.time.timeIntervalSince1970, bpm: Double($0.bpm)) }
        guard let zoneSet = ActivityAnalytics.zones(zones, source: source).value,
              let time = ActivityAnalytics.timeInZone(samples, zoneSet: zoneSet).value, time.seconds.count == 5 else { return nil }
        return WorkoutZoneSplit(minutes: time.seconds.map { Int(($0 / 60).rounded()) }, zones: zones)
    }

    /// The bpm range of a zone, 1 to 5, the same edges the dose card and the Heart screen show (R3-VET-03).
    public func range(_ zone: Int) -> ClosedRange<Int> {
        zones.bpmRange(for: zone) ?? 0...0
    }

    /// Heart rate was read but too sparse to place any minute in a zone.
    public var isEmpty: Bool { totalMinutes == 0 }

    public static let tooSparse = "The heart rate readings are too far apart to split into zones."

    /// "Zone 2 is 109 to 126 bpm. Max heart rate 181, estimated from your age. The weekly minutes use the same zones."
    public var methodLine: String {
        let zone2 = range(2)
        let maximum = Int(zones.maximum.rounded())
        let max: String = switch zones.source {
        case .estimated: "Max heart rate \(maximum), estimated from your age."
        case .observed: "Max heart rate \(maximum), the highest the band has seen."
        case .manual: "Max heart rate \(maximum), as you set it in Heart."
        }
        let resting = zones.restingHeartRate.map { " Resting heart rate \(Int($0.rounded()))." } ?? ""
        return "Zone 2 is \(zone2.lowerBound) to \(zone2.upperBound) bpm. \(max)\(resting) Your weekly minutes use the same zones."
    }

    public static let needsZones = "Add your birth year or a max heart rate in Heart to split this by zone."
}

// MARK: - What it counted for the week

/// What a workout added to its week's targets (R2-NEW-14): "Counts as 1 mobility session this week." and
/// "Added 48 Zone 2 minutes this week."
public enum WorkoutWeekCount {
    public static func line(for workout: WorkoutRecord, context: WorkoutDetailContext,
                            heartRate: WorkoutHeartRateSummary?, split: WorkoutZoneSplit?) -> String {
        guard workout.state == .completed else { return "Not counted yet: the workout is not finished." }
        let week = context.isThisWeek ? "this week" : "that week"
        var sentences: [String] = []
        if let kind = context.sessionKind {
            sentences.append(context.isThisWeek ? "Counts as 1 \(kind.rawValue) session \(week)."
                                                : "Counted as 1 \(kind.rawValue) session \(week).")
        }
        let readings = heartRate?.points.isEmpty == false
        let minutesCount = workout.source == .healthKit ? !context.bandCoveredDay : context.bandCoveredDay
        if readings, let split, minutesCount {
            sentences.append(minutesSentence(split, week: week))
        } else if readings, split == nil {
            sentences.append("Zone minutes need your birth year or a max heart rate in Heart.")
        } else if readings, workout.source == .healthKit, context.bandCoveredDay {
            sentences.append("The band covered that day, so its zone minutes count instead of this workout's.")
        } else if readings {
            // A band workout's minutes count through the band's day, which is not in yet. Never "needs heart rate"
            // beside a chart of it (R3-VET-02).
            sentences.append("Not in \(week)'s zone minutes yet. They arrive once the band has synced that day.")
        }
        if sentences.isEmpty {
            sentences.append(context.isThisWeek ? "Adds nothing to this week's targets." : "Added nothing to that week's targets.")
            sentences.append(workout.typedAverageHeartRate != nil ? "A typed heart rate adds no zone minutes."
                                                                   : "Zone minutes need heart rate from the band or Apple Health.")
        }
        return sentences.joined(separator: " ")
    }

    static func minutesSentence(_ split: WorkoutZoneSplit, week: String) -> String {
        switch (split.zone2Minutes, split.hardMinutes) {
        case (0, 0): "No Zone 2 or hard minutes \(week)."
        case (let zone2, 0): "Added \(zone2) Zone 2 \(zone2 == 1 ? "minute" : "minutes") \(week)."
        case (0, let hard): "Added \(hard) hard \(hard == 1 ? "minute" : "minutes") \(week)."
        case (let zone2, let hard):
            "Added \(zone2) Zone 2 \(zone2 == 1 ? "minute" : "minutes") and \(hard) hard \(hard == 1 ? "minute" : "minutes") \(week)."
        }
    }
}

// MARK: - Views

/// Heart rate over the session: average and maximum, the chart, drift with its working, and where it came from.
struct WorkoutHeartRateSection: View {
    let summary: WorkoutHeartRateSummary
    let analysis: WorkoutSessionAnalysis
    let zones: HeartRateZoneSet?
    let workout: WorkoutRecord

    var body: some View {
        LooprSectionGroup(title: "Heart rate") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.lg) {
                        if let average = summary.average { stat("Average", "\(average)", unit: "bpm") }
                        if let maximum = summary.maximum { stat("Max", "\(maximum)", unit: "bpm") }
                        if let strain = analysis.strain {
                            stat("Strain, estimate", strain.formatted(.number.precision(.fractionLength(1)).locale(LooprUnitFormatter.displayLocale)), unit: "/21")
                        }
                    }
                    if summary.hasChart, analysis.samples.count >= 2 {
                        WorkoutEffortChart(samples: analysis.samples, zones: zones, target: workout.currentZoneTarget?.range,
                                           pauses: workout.pauses ?? [], efforts: analysis.efforts)
                    }
                    if let drift = analysis.drift {
                        let percent = LooprSignedNumber.text(drift.percent, fractionDigits: 1)
                        let bpm = { (value: Double) in value.formatted(.number.precision(.fractionLength(1)).locale(LooprUnitFormatter.displayLocale)) }
                        LooprText("Drift \(percent)%: second half \(bpm(drift.secondHalfBPM)) bpm, first half \(bpm(drift.firstHalfBPM)) bpm. The first 10 minutes are left out, and climbs are not adjusted for.",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workout-page-drift")
                    }
                    if analysis.coverageIsPartial, let active = analysis.activeSeconds {
                        LooprText("Heart rate for \(Int(analysis.coveredSeconds / 60)) of \(Int(active / 60)) min. Gaps are left empty.",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workout-page-coverage")
                    }
                    LooprText(sourceLine, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-detail-heart-rate")
    }

    private var sourceLine: String {
        if analysis.source == .bandHistory { return "From the band's history, after a sync." }
        return summary.hasChart ? summary.source.label
            : "\(summary.source.label). It saved no readings over time, so there is no chart or zone split."
    }

    private func stat(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(title, style: .caption, color: .inkSecondary)
            LooprValueText(value, unit: unit)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Minutes in each zone, as a bar and five rows, with the zone method under them.
struct WorkoutZoneSplitSection: View {
    let split: WorkoutZoneSplit?
    /// The session never reached Zone 1, which is a calm hour and no fault of the readings.
    var stayedBelowZones = false
    /// Set when a target ran with a different range than today's Zone 2, so the two numbers do not read as a bug.
    var targetNote: String?

    var body: some View {
        LooprSectionGroup(title: "Time in zones") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if let split, split.isEmpty {
                        LooprText(stayedBelowZones ? "Heart rate stayed below Zone 1 the whole time." : WorkoutZoneSplit.tooSparse,
                                  style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let split {
                        bar(split)
                        ForEach(Array((1...5).reversed()), id: \.self) { zone in row(zone, split) }
                        LooprText(split.methodLine, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let targetNote {
                            LooprText(targetNote, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("workout-page-target-note")
                        }
                    } else {
                        LooprText(WorkoutZoneSplit.needsZones, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-detail-zones")
    }

    private func bar(_ split: WorkoutZoneSplit) -> some View {
        GeometryReader { proxy in
            let total = max(split.totalMinutes, 1)
            let visible = split.minutes.filter { $0 > 0 }.count
            let width = max(proxy.size.width - 2 * CGFloat(max(visible - 1, 0)), 0)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    if split.minutes[index] > 0 {
                        Rectangle()
                            .fill(Color.loopr(LooprZonePalette.token(for: index + 1)))
                            .frame(width: max(4, width * CGFloat(split.minutes[index]) / CGFloat(total)))
                    }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func row(_ zone: Int, _ split: WorkoutZoneSplit) -> some View {
        let minutes = split.minutes[zone - 1]
        let range = split.range(zone)
        return HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.loopr(LooprZonePalette.token(for: zone)))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            LooprText("Zone \(zone)", style: .rowTitle)
            LooprText("\(range.lowerBound) to \(range.upperBound) bpm", style: .caption, color: .inkSecondary)
            Spacer(minLength: LooprSpacing.xs)
            LooprValueText("\(minutes)", unit: "min", color: minutes > 0 ? .ink : .inkSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workout-detail-zone-\(zone)")
    }
}
