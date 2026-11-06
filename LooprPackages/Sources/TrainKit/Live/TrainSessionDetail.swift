import Foundation
import WorkoutKit

/// A finished gym session in full, for its detail and for the summary right after Finish (R2-LIFT-02, R2-WOD-07,
/// R2-DES-05, R2-NEW-07, R2-VET-07). Pure value logic.
///
/// It reads the session and, when there is one, the workout record behind it: each exercise with its sets in the
/// exercise's measure (tag, RPE and a PR mark), the totals and bests of `TrainSummaryModel`, and the average and
/// maximum heart rate with the zone minutes when the record has heart-rate samples.
public struct TrainSessionDetail: Equatable, Sendable {
    /// One logged set, as the detail lists it.
    public struct SetLine: Equatable, Sendable, Identifiable {
        public let index: Int
        /// "1", or the tag's letter for a warm-up, drop or failure set: "W".
        public let marker: String
        /// "80 kg × 8", "20 kg assist × 7", "0:55", "45 m at 32 kg". "Skipped" for a skipped set.
        public let valuesText: String
        /// "RPE 7". Nil when none was given.
        public let rpeText: String?
        /// "Warm-up", "Drop set", "To failure". Nil for a working set.
        public let tagTitle: String?
        /// True when this set set a new best. A first performance is a baseline and is not marked.
        public let isRecord: Bool
        public let isSkipped: Bool
        public let spokenLabel: String

        public var id: Int { index }
    }

    /// One exercise and its sets.
    public struct ExerciseBlock: Equatable, Sendable, Identifiable {
        public let index: Int
        public let name: String
        /// "4 sets", "4 sets · bodyweight", "Skipped", "Swapped from Barbell row · 2 sets".
        public let detail: String
        public let sets: [SetLine]

        public var id: Int { index }
        public var identifier: String { "train-detail-exercise-\(index)" }
    }

    /// Heart rate during the session, from the workout record's samples. Built only when there are samples.
    public struct Heart: Equatable, Sendable {
        public let averageBPM: Int
        public let maximumBPM: Int
        /// Minutes the samples sat in zone 2, and in zones 4 and 5. Nil when the samples carry no zone.
        public let zone2Minutes: Int?
        public let hardMinutes: Int?
        /// "From the band", "From Apple Health".
        public let source: String
    }

    /// What the session added to the week, for the dots on the summary right after Finish.
    public struct WeekAddition: Equatable, Sendable {
        /// 1 when the session counts as a strength session, 0 for warm-ups only.
        public let strengthSessions: Int
        /// Five-minute dots, as the dose field draws them. 0 when the band measured under five minutes.
        public let zone2Dots: Int
        public let hardDots: Int
        public let zone2Minutes: Int
        public let hardMinutes: Int
    }

    public let summary: TrainSummaryModel
    public let exercises: [ExerciseBlock]
    public let heart: Heart?
    /// "Tue 7 Nov", the day the session was done, in its own time zone.
    public let dayLabel: String

    /// - Parameters:
    ///   - workout: The linked record. Its heart-rate samples feed `heart`. Nil, or a record with no samples, leaves it out.
    public init(session: TrainSession, workout: WorkoutRecord? = nil) {
        summary = TrainSummaryModel(session: session)
        dayLabel = TrainOverviewModel.dayLabel(localDay: session.localDay)
        let records = Set(session.bests.filter(\.isNewBest).map(\.setID))
        exercises = session.exercises.enumerated().map { index, line in
            Self.block(line, index: index, records: records)
        }
        heart = workout.flatMap(Self.heart(from:))
    }

    /// "Saved Tue 7 Nov": the chip on a session opened from a list (R2-NEW-07).
    public var savedLine: String { dayLabel.isEmpty ? "Saved" : "Saved \(dayLabel)" }

    /// What the session added to the week. Zone minutes come from the heart-rate samples, so without them only the
    /// strength session shows.
    public var weekAddition: WeekAddition {
        let zone2 = heart?.zone2Minutes ?? 0
        let hard = heart?.hardMinutes ?? 0
        return WeekAddition(strengthSessions: summary.countsTowardWeek ? 1 : 0,
                            zone2Dots: DoseDots(minutes: Double(zone2), target: nil).filled,
                            hardDots: DoseDots(minutes: Double(hard), target: nil).filled,
                            zone2Minutes: zone2, hardMinutes: hard)
    }

    // MARK: Building

    private static func block(_ line: SessionExercise, index: Int, records: Set<UUID>) -> ExerciseBlock {
        let measure = line.planned.measure
        let sets = line.sets.enumerated().map { offset, set in setLine(set, number: offset + 1, measure: measure, records: records) }
        let logged = line.sets.filter { !$0.skipped }.count
        var parts: [String] = []
        if let from = line.swappedFrom { parts.append("Swapped from \(from.name)") }
        if line.status == .skipped || logged == 0 {
            parts.append("Skipped")
        } else {
            parts.append("\(logged) \(logged == 1 ? "set" : "sets")")
            if measure != .weight { parts.append(measure.title.lowercased()) }
        }
        return ExerciseBlock(index: index, name: line.exercise.name, detail: parts.joined(separator: " · "), sets: sets)
    }

    private static func setLine(_ set: LoggedSet, number: Int, measure: TrainSetMeasure, records: Set<UUID>) -> SetLine {
        let values = set.skipped ? "Skipped" : TrainSetFormat.set(set.values, measure: measure)
        let rpe = set.rpe.map { "RPE \(TrainLiveFormat.rpe($0))" }
        let record = records.contains(set.id)
        var spoken = ["Set \(number)"]
        if let tag = set.tag { spoken.append(tag.title.lowercased()) }
        spoken.append(set.skipped ? "skipped" : TrainSetFormat.spoken(set.values, measure: measure))
        if let rpe { spoken.append(rpe) }
        if record { spoken.append("new best") }
        return SetLine(index: number - 1, marker: set.tag?.letter ?? "\(number)", valuesText: values, rpeText: rpe,
                       tagTitle: set.tag?.title, isRecord: record, isSkipped: set.skipped,
                       spokenLabel: spoken.joined(separator: ", "))
    }

    /// The longest gap between two samples that still counts as time in a zone. Past it the band lost contact.
    static let zoneSampleGapSeconds: TimeInterval = 60

    static func heart(from workout: WorkoutRecord) -> Heart? {
        let samples = workout.samples.sorted { $0.timestamp < $1.timestamp }
        let rates = samples.compactMap(\.heartRate).filter { $0 > 0 }
        guard !rates.isEmpty, let maximum = rates.max() else { return nil }
        let average = Int((Double(rates.reduce(0, +)) / Double(rates.count)).rounded())
        var seconds: [Int: TimeInterval] = [:]
        var zoned = false
        for (index, sample) in samples.enumerated() {
            guard let zone = sample.zone, let rate = sample.heartRate, rate > 0 else { continue }
            zoned = true
            guard index + 1 < samples.count else { continue }
            let gap = samples[index + 1].timestamp.timeIntervalSince(sample.timestamp)
            guard gap > 0, gap <= zoneSampleGapSeconds else { continue }
            seconds[zone, default: 0] += gap
        }
        func minutes(_ zones: [Int]) -> Int? {
            zoned ? Int((zones.reduce(0) { $0 + (seconds[$1] ?? 0) } / 60).rounded(.down)) : nil
        }
        let source = switch workout.source {
        case .healthKit: "From Apple Health"
        case .imported: "From an imported workout"
        case .live, .manual, .detected: "From the band"
        }
        return Heart(averageBPM: average, maximumBPM: maximum, zone2Minutes: minutes([2]), hardMinutes: minutes([4, 5]),
                     source: source)
    }
}
