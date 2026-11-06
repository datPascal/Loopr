import CoreTransferable
import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A recorded route, cut down to what the page draws. RouteKit builds it from a `RouteRecord`.
public struct WorkoutPageRoute: Equatable, Sendable {
    public struct Coordinate: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    }

    public struct Split: Equatable, Sendable, Identifiable {
        public let number: Int
        public let meters: Double
        public let seconds: TimeInterval
        public let averageBPM: Int?
        public let climbMeters: Double?
        /// The last stretch, shorter than the others.
        public let isPartial: Bool
        public var id: Int { number }
        public var secondsPerKilometer: Double { meters > 0 ? seconds / meters * 1000 : 0 }
        public init(number: Int, meters: Double, seconds: TimeInterval, averageBPM: Int?, climbMeters: Double?, isPartial: Bool) {
            self.number = number; self.meters = meters; self.seconds = seconds
            self.averageBPM = averageBPM; self.climbMeters = climbMeters; self.isPartial = isPartial
        }
    }

    public struct ElevationPoint: Equatable, Sendable, Identifiable {
        public let meters: Double
        public let altitude: Double
        public var id: Double { meters }
        public init(meters: Double, altitude: Double) { self.meters = meters; self.altitude = altitude }
    }

    /// Never bridged: a GPS gap ends one segment and starts the next.
    public let segments: [[Coordinate]]
    public let distanceMeters: Double
    public let movingSeconds: TimeInterval
    public let elapsedSeconds: TimeInterval
    public let ascentMeters: Double?
    public let descentMeters: Double?
    public let highestMeters: Double?
    /// Seconds between GPS points that were more than a stretch apart, such as a lost signal.
    public let gapSeconds: TimeInterval
    public let splits: [Split]
    public let elevation: [ElevationPoint]
    public let pointCount: Int

    /// A line this short or this sparse is not drawn: two points make a false straight line.
    public static let minimumPoints = 20
    public static let minimumMeters = 100.0
    public var canBeDrawn: Bool { pointCount >= Self.minimumPoints && distanceMeters >= Self.minimumMeters }

    public init(segments: [[Coordinate]], distanceMeters: Double, movingSeconds: TimeInterval, elapsedSeconds: TimeInterval,
                ascentMeters: Double?, descentMeters: Double?, highestMeters: Double?, gapSeconds: TimeInterval,
                splits: [Split], elevation: [ElevationPoint], pointCount: Int) {
        self.segments = segments; self.distanceMeters = distanceMeters; self.movingSeconds = movingSeconds
        self.elapsedSeconds = elapsedSeconds; self.ascentMeters = ascentMeters; self.descentMeters = descentMeters
        self.highestMeters = highestMeters; self.gapSeconds = gapSeconds; self.splits = splits
        self.elevation = elevation; self.pointCount = pointCount
    }
}

/// What the page needs from outside the workout record. Everything optional: what is missing is left off the page.
public struct WorkoutPageContext: Equatable, Sendable {
    /// Band history for the session's window, for a session with no samples of its own.
    public var history: WorkoutHeartSeries?
    public var route: WorkoutPageRoute?
    /// "Last similar run, 12 Oct: 5.1 km, 5:20 /km, 148 bpm."
    public var comparison: String?
    /// For a capture fixture, which has no real dose to read zones from. The app's `WorkoutDetailContext` wins.
    public var fallbackZones: HeartRateZones?
    public init(history: WorkoutHeartSeries? = nil, route: WorkoutPageRoute? = nil, comparison: String? = nil,
                fallbackZones: HeartRateZones? = nil) {
        self.history = history; self.route = route; self.comparison = comparison; self.fallbackZones = fallbackZones
    }
}

public protocol WorkoutPageProviding: Sendable {
    func context(for workout: WorkoutRecord) async -> WorkoutPageContext
}

public extension EnvironmentValues {
    /// The app reads band history, routes and earlier sessions for the page.
    @Entry var workoutPageProvider: (any WorkoutPageProviding)? = nil
}

public enum WorkoutPageModule: String, CaseIterable, Sendable {
    case effort, zones, map, splits, elevation, efforts, recovery, howHard
}

/// The words and numbers of the page. Pure, so every type's page is tested without a screen.
public struct WorkoutPagePresentation: Equatable, Sendable {
    public struct Companion: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public let unit: String?
        public var id: String { label }
        public init(label: String, value: String, unit: String? = nil) { self.label = label; self.value = value; self.unit = unit }
    }

    public let headlineValue: String?
    public let headlineUnit: String?
    public let companions: [Companion]
    public let sentence: String?
    public let modules: [WorkoutPageModule]

    public init(workout: WorkoutRecord, analysis: WorkoutSessionAnalysis, route: WorkoutPageRoute?,
                system: LooprMeasurementSystem = .metric) {
        let route = route.flatMap { $0.canBeDrawn ? $0 : nil }
        let summary = WorkoutTargetZoneSummary(workout: workout)
        let distance = route?.distanceMeters ?? workout.resolvedDistanceMeters
        let time = route?.movingSeconds ?? workout.duration
        let timeLabel = route == nil ? "Time" : "Moving"
        let timeText = WorkoutDurationText.formatted(time)
        let average = analysis.averageBPM.map { Companion(label: "Average", value: "\($0)", unit: "bpm") }
        let peak = analysis.peakBPM.map { Companion(label: "Max", value: "\($0)", unit: "bpm") }

        var headline: (String, String?)?
        var side: [Companion] = []
        if let summary, summary.observedSeconds > 0 {
            let inside = Int((summary.insideSeconds / 60).rounded())
            let total = Int((summary.targetSeconds / 60).rounded())
            headline = ("\(inside) of \(total)", "min in \(summary.title == "Target" ? "target" : summary.title)")
            if let distance {
                let measure = LooprUnitFormatter.distance(meters: distance, system: system)
                side.append(Companion(label: "Distance", value: measure.value, unit: measure.unit))
            }
            if let timeText { side.append(Companion(label: timeLabel, value: timeText)) }
            if let distance, let pace = Self.speedCompanion(activity: workout.activity, meters: distance, seconds: time, system: system) {
                side.append(pace)
            } else if let average {
                side.append(average)
            }
        } else if let distance {
            let measure = LooprUnitFormatter.distance(meters: distance, system: system)
            headline = (measure.value, measure.unit)
            if let timeText { side.append(Companion(label: timeLabel, value: timeText)) }
            if let pace = Self.speedCompanion(activity: workout.activity, meters: distance, seconds: time, system: system) {
                side.append(pace)
            }
            if let average { side.append(average) }
        } else {
            if let timeText { headline = (timeText, nil) }
            if !analysis.efforts.isEmpty {
                side.append(Companion(label: "Efforts", value: "\(analysis.efforts.count)"))
            } else if let average {
                side.append(average)
            }
            if let peak { side.append(peak) }
        }
        headlineValue = headline?.0
        headlineUnit = headline?.1
        companions = Array(side.prefix(3))
        sentence = Self.sentence(workout: workout, analysis: analysis, summary: summary)
        modules = Self.modules(activity: workout.activity, hasTarget: summary != nil)
    }

    /// The order of the page per type. A module with nothing to show draws nothing.
    public static func modules(activity: ActivityType, hasTarget: Bool) -> [WorkoutPageModule] {
        switch activity {
        case .run, .cycle:
            return [.effort, .zones, .map, .splits, .elevation, .recovery, .howHard]
        case .hike:
            return [.map, .elevation, .effort, .zones, .splits, .recovery, .howHard]
        case .walk:
            return hasTarget ? [.effort, .zones, .map, .splits, .howHard] : [.map, .effort, .zones, .splits, .howHard]
        case .hiit, .crossfit:
            return [.effort, .efforts, .zones, .recovery, .howHard]
        case .yoga, .pilates, .mobility, .dance, .other:
            return [.effort, .zones, .howHard]
        default:
            return [.effort, .zones, .recovery, .howHard]
        }
    }

    /// One sentence from stored data, with no praise and no verdict on the person.
    static func sentence(workout: WorkoutRecord, analysis: WorkoutSessionAnalysis, summary: WorkoutTargetZoneSummary?) -> String? {
        guard analysis.hasHeartRate else {
            // An import carries its own totals, and a typed average is shown as typed further down.
            if workout.source == .imported || workout.source == .healthKit || workout.typedAverageHeartRate != nil { return nil }
            return "No heart rate for this session. The band had no reading."
        }
        // A target session says it in the headline and the target card already.
        if let summary, summary.observedSeconds > 0 { return nil }
        if !analysis.efforts.isEmpty, let peak = analysis.peakBPM {
            return "\(analysis.efforts.count) \(analysis.efforts.count == 1 ? "effort" : "efforts"), heart rate up to \(peak) bpm."
        }
        guard let top = analysis.secondsInZones.max(by: { $0.value < $1.value }), analysis.coveredSeconds > 0 else {
            guard let average = analysis.averageBPM, let peak = analysis.peakBPM else { return nil }
            return "Heart rate averaged \(average) bpm and reached \(peak)."
        }
        let minutes = Int((top.value / 60).rounded())
        let total = max(1, Int((analysis.coveredSeconds / 60).rounded()))
        // "Recovery" is a score on Today, so Zone 1 gets another word here.
        let words = [1: "very easy", 2: "easy", 3: "moderate", 4: "hard", 5: "peak"]
        let name = "Zone \(top.key), \(words[top.key] ?? "")"
        if minutes == total { return "All \(total) min in \(name)." }
        return top.value / analysis.coveredSeconds >= 0.5
            ? "Mostly \(name): \(minutes) of \(total) min."
            : "Mixed effort. Most time in \(name): \(minutes) of \(total) min."
    }

    /// Pace on foot, speed on a bike, pace per 100 m in a pool.
    public static func speedCompanion(activity: ActivityType, meters: Double, seconds: TimeInterval?, system: LooprMeasurementSystem) -> Companion? {
        guard let seconds, seconds > 0, meters > 0 else { return nil }
        switch activity {
        case .cycle:
            let perHour = meters / seconds * 3.6
            let value = system == .metric ? perHour : perHour / 1.609_344
            return Companion(label: "Speed", value: value.formatted(.number.precision(.fractionLength(1)).locale(LooprUnitFormatter.displayLocale)), unit: system == .metric ? "km/h" : "mph")
        case .swim:
            let total = Int((seconds / meters * 100).rounded())
            return Companion(label: "Pace", value: String(format: "%d:%02d", total / 60, total % 60), unit: "/100 m")
        case .rowing:
            let total = Int((seconds / meters * 500).rounded())
            return Companion(label: "Split", value: String(format: "%d:%02d", total / 60, total % 60), unit: "/500 m")
        case .run, .walk, .hike:
            let pace = LooprUnitFormatter.pace(secondsPerKilometer: seconds / meters * 1000, system: system)
            return Companion(label: "Pace", value: pace.value, unit: pace.unit)
        default:
            return nil
        }
    }

}

/// One line comparing a session with the last one like it. It states numbers and never says better or worse.
public enum WorkoutComparison {
    /// The newest earlier session of the same type and about the same size.
    public static func similar(to workout: WorkoutRecord, in rows: [WorkoutRecord]) -> WorkoutRecord? {
        guard let start = workout.startedAt, let duration = workout.duration, duration > 0 else { return nil }
        let distance = workout.resolvedDistanceMeters
        return rows
            .filter { row in
                guard row.id != workout.id, row.activity == workout.activity, row.state == .completed,
                      let rowStart = row.startedAt, rowStart < start, let rowDuration = row.duration else { return false }
                if let distance, let other = row.resolvedDistanceMeters, distance > 0 {
                    return abs(other - distance) / distance <= 0.1
                }
                return distance == nil && abs(rowDuration - duration) / duration <= 0.2
            }
            .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    /// - Parameter movingSeconds: The earlier session's moving time from its route. Today's pace is moving pace, so
    ///   the two compare like with like. Without a route the elapsed pace is used and says so.
    public static func line(previous: WorkoutRecord, averageBPM: Int?, movingSeconds: TimeInterval? = nil,
                            system: LooprMeasurementSystem = .metric, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let start = previous.startedAt else { return nil }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        var parts: [String] = []
        if let meters = previous.resolvedDistanceMeters {
            parts.append(LooprUnitFormatter.distance(meters: meters, system: system).combined)
            if let speed = WorkoutPagePresentation.speedCompanion(activity: previous.activity, meters: meters, seconds: movingSeconds ?? previous.duration, system: system) {
                parts.append([speed.value, speed.unit, previous.activity.recordsRoute && movingSeconds == nil ? "elapsed" : nil].compactMap { $0 }.joined(separator: " "))
            }
        } else if let time = WorkoutDurationText.formatted(previous.duration) {
            parts.append(time)
        }
        if let averageBPM { parts.append("\(averageBPM) bpm") }
        guard !parts.isEmpty else { return nil }
        // "HIIT" and "WOD" keep their capitals.
        let name = previous.activity.shortName
        let noun = name == name.uppercased() ? name : name.lowercased()
        return "Last similar \(noun), \(start.formatted(style)): \(parts.joined(separator: ", "))."
    }
}

/// Plain CSV, for a spreadsheet or another app.
public struct WorkoutCSVFile: Equatable, Sendable, Transferable {
    public let text: String
    public let filename: String
    public init(text: String, filename: String) { self.text = text; self.filename = filename }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { file in Data(file.text.utf8) }
            .suggestedFileName { file in file.filename }
    }

    /// One row per reading, in UTC.
    public static func heartRate(samples: [WorkoutHeartSample], startedAt: Date) -> WorkoutCSVFile {
        var lines = ["time_utc,seconds_from_start,bpm"]
        let formatter = ISO8601DateFormatter()
        for sample in samples {
            lines.append("\(formatter.string(from: sample.date)),\(Int(sample.date.timeIntervalSince(startedAt).rounded())),\(Int(sample.bpm.rounded()))")
        }
        let day = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
        return WorkoutCSVFile(text: lines.joined(separator: "\n") + "\n", filename: "heart-rate-\(startedAt.formatted(day)).csv")
    }
}
