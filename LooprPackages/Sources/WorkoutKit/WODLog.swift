import Foundation

// Fitness round 1 (R1-WOD-01, 02, 03, 13, R1-DES-02): a CrossFit session logged as the whiteboard has it. A format,
// a name, the movements as text, a time cap, one score typed by format, Rx or Scaled. Benchmark history compares
// results with the same name: lower time wins for a timed WOD, more rounds and reps win for an AMRAP.

/// How a WOD is run.
public enum WODFormat: String, Codable, CaseIterable, Sendable {
    case forTime
    case amrap
    case emom
    case roundsForTime
    case tabata
    case other

    public var displayName: String {
        switch self {
        case .forTime: "For time"
        case .amrap: "AMRAP"
        case .emom: "EMOM"
        case .roundsForTime: "Rounds for time"
        case .tabata: "Tabata"
        case .other: "Other"
        }
    }

    /// The score this format takes. Nil for Other, where the person picks.
    public var scoreKind: WODScoreKind? {
        switch self {
        case .forTime, .roundsForTime: .time
        case .amrap: .roundsAndReps
        case .emom, .tabata: .reps
        case .other: nil
        }
    }

    /// True when the clock stops the work, so a time cap can be hit.
    public var canBeCapped: Bool { self == .forTime || self == .roundsForTime }

    /// What the minutes field is called: a cap for timed work, the length for AMRAP and EMOM.
    public var timeLabel: String? {
        switch self {
        case .forTime, .roundsForTime, .other: "Time cap"
        case .amrap, .emom: "Length"
        case .tabata: nil
        }
    }
}

public enum WODScoreKind: String, Codable, CaseIterable, Sendable {
    case time, roundsAndReps, reps, load

    public var displayName: String {
        switch self {
        case .time: "Time"
        case .roundsAndReps: "Rounds + reps"
        case .reps: "Reps"
        case .load: "Load"
        }
    }
}

/// One score. Only the fields of its kind are set.
public struct WODScore: Codable, Equatable, Sendable {
    public let kind: WODScoreKind
    public let seconds: Int?
    public let rounds: Int?
    public let reps: Int?
    public let kilograms: Double?

    private init(kind: WODScoreKind, seconds: Int? = nil, rounds: Int? = nil, reps: Int? = nil, kilograms: Double? = nil) {
        self.kind = kind; self.seconds = seconds; self.rounds = rounds; self.reps = reps; self.kilograms = kilograms
    }

    public static func time(seconds: Int) -> Self { .init(kind: .time, seconds: max(0, seconds)) }
    public static func roundsAndReps(rounds: Int, reps: Int) -> Self {
        .init(kind: .roundsAndReps, rounds: max(0, rounds), reps: max(0, reps))
    }
    public static func reps(_ reps: Int) -> Self { .init(kind: .reps, reps: max(0, reps)) }
    public static func load(kilograms: Double) -> Self { .init(kind: .load, kilograms: max(0, kilograms)) }

    /// "4:37", "5 rounds + 12", "150 reps", "60 kg".
    public var text: String {
        switch kind {
        case .time: Self.clock(seconds ?? 0)
        case .roundsAndReps:
            "\(rounds ?? 0) \((rounds ?? 0) == 1 ? "round" : "rounds")" + ((reps ?? 0) > 0 ? " + \(reps ?? 0)" : "")
        case .reps: "\(reps ?? 0) reps"
        case .load: "\((kilograms ?? 0).formatted(.number.precision(.fractionLength(0...1)))) kg"
        }
    }

    /// "4:37" for 277 seconds, "1:02:05" past an hour.
    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Reads "4:37", "04:37", "1:02:05" or plain seconds ("277"). Nil for anything else.
    public static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        if values.count > 1, values.dropFirst().contains(where: { $0 > 59 }) { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}

/// Rx is the workout as written. Scaled is a lighter or easier version.
public enum WODScaling: String, Codable, CaseIterable, Sendable {
    case rx, scaled

    public var displayName: String { self == .rx ? "Rx" : "Scaled" }
}

/// A WOD as logged.
public struct WODResult: Codable, Equatable, Sendable {
    public var format: WODFormat
    /// "Fran", or the gym's name for the day's workout.
    public var name: String?
    /// The whiteboard, one line per movement.
    public var movements: [String]
    public var timeCapSeconds: Int?
    public var score: WODScore?
    /// True when a timed WOD hit its cap. The score is then rounds and reps.
    public var capped: Bool
    public var scaling: WODScaling
    /// What was scaled: "30 kg thrusters, banded pull-ups".
    public var scalingNote: String?

    public init(format: WODFormat, name: String? = nil, movements: [String] = [], timeCapSeconds: Int? = nil,
                score: WODScore? = nil, capped: Bool = false, scaling: WODScaling = .rx, scalingNote: String? = nil) {
        self.format = format; self.name = name; self.movements = movements; self.timeCapSeconds = timeCapSeconds
        self.score = score; self.capped = capped; self.scaling = scaling; self.scalingNote = scalingNote
    }

    /// Trimmed text, empty lines dropped, a scaling note only when scaled.
    var cleaned: WODResult {
        var result = self
        result.name = WorkoutLogEntry.cleaned(name)
        result.movements = movements.compactMap { WorkoutLogEntry.cleaned($0) }
        result.scalingNote = scaling == .scaled ? WorkoutLogEntry.cleaned(scalingNote) : nil
        if let cap = timeCapSeconds, cap <= 0 { result.timeCapSeconds = nil }
        if !format.canBeCapped { result.capped = false }
        return result
    }

    /// The score as a line: "4:37 Rx", "Capped at 12:00, 4 rounds + 10, Scaled".
    public var scoreLine: String? {
        guard let score else { return nil }
        let value = capped
            ? "Capped" + (timeCapSeconds.map { " at \(WODScore.clock($0))" } ?? "") + ", " + score.text
            : score.text
        return "\(value) \(scaling.displayName)"
    }

    /// The key benchmark history groups by: lowercased, single spaces.
    public var historyKey: String? { name.flatMap(Self.historyKey) }

    public static func historyKey(_ name: String) -> String? {
        let words = name.lowercased().split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// True when this result is better than `other`. Results of the same scaling compare by score: a finished
    /// time beats a capped one, a lower time wins, more rounds and reps win, more reps and more load win.
    /// Scores of different kinds do not compare.
    public func beats(_ other: WODResult) -> Bool {
        guard let mine = rank, let theirs = other.rank, mine.family == theirs.family else { return false }
        for (left, right) in zip(mine.values, theirs.values) where left != right { return left > right }
        return false
    }

    /// Which scores compare (`family`) and how, larger first, element by element. Nil without a score.
    private var rank: (family: Int, values: [Double])? {
        guard let score else { return nil }
        switch score.kind {
        case .time:
            // A finished time ranks above any capped result, and a shorter one above a longer one.
            return (0, [1, -Double(score.seconds ?? 0), 0])
        case .roundsAndReps:
            if format.canBeCapped || capped { return (0, [0, Double(score.rounds ?? 0), Double(score.reps ?? 0)]) }
            return (1, [Double(score.rounds ?? 0), Double(score.reps ?? 0)])
        case .reps: return (2, [Double(score.reps ?? 0)])
        case .load: return (3, [score.kilograms ?? 0])
        }
    }
}

/// A named benchmark WOD with its standard movements. Loads are the usual men's/women's Rx in kilograms.
public struct WODBenchmark: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let format: WODFormat
    public let movements: [String]
    public let timeCapSeconds: Int?

    public init(name: String, format: WODFormat, movements: [String], timeCapSeconds: Int? = nil) {
        self.name = name; self.format = format; self.movements = movements; self.timeCapSeconds = timeCapSeconds
    }

    public static let catalog: [WODBenchmark] = [
        .init(name: "Fran", format: .forTime, movements: ["21-15-9", "Thrusters 43/29 kg", "Pull-ups"]),
        .init(name: "Grace", format: .forTime, movements: ["30 clean and jerks 61/43 kg"]),
        .init(name: "Helen", format: .roundsForTime,
              movements: ["3 rounds", "400 m run", "21 kettlebell swings 24/16 kg", "12 pull-ups"]),
        .init(name: "Diane", format: .forTime, movements: ["21-15-9", "Deadlifts 102/70 kg", "Handstand push-ups"]),
        .init(name: "Elizabeth", format: .forTime, movements: ["21-15-9", "Cleans 61/43 kg", "Ring dips"]),
        .init(name: "Isabel", format: .forTime, movements: ["30 snatches 61/43 kg"]),
        .init(name: "Annie", format: .forTime, movements: ["50-40-30-20-10", "Double-unders", "Sit-ups"]),
        .init(name: "Cindy", format: .amrap, movements: ["5 pull-ups", "10 push-ups", "15 air squats"],
              timeCapSeconds: 20 * 60),
        .init(name: "Karen", format: .forTime, movements: ["150 wall-ball shots 9/6 kg"]),
        .init(name: "Jackie", format: .forTime, movements: ["1,000 m row", "50 thrusters 20/15 kg", "30 pull-ups"]),
        .init(name: "Nancy", format: .roundsForTime, movements: ["5 rounds", "400 m run", "15 overhead squats 43/29 kg"]),
        .init(name: "Murph", format: .forTime,
              movements: ["1.6 km run", "100 pull-ups", "200 push-ups", "300 air squats", "1.6 km run",
                          "Rx wears a 9/6 kg vest"]),
        .init(name: "DT", format: .roundsForTime,
              movements: ["5 rounds", "12 deadlifts 70/47 kg", "9 hang power cleans 70/47 kg", "6 push jerks 70/47 kg"])
    ]

    /// The benchmark with this name, ignoring case and spacing.
    public static func named(_ name: String) -> WODBenchmark? {
        guard let key = WODResult.historyKey(name) else { return nil }
        return catalog.first { WODResult.historyKey($0.name) == key }
    }

    /// Benchmarks whose name starts with what was typed. Every one for an empty field.
    public static func suggestions(for typed: String) -> [WODBenchmark] {
        guard let key = WODResult.historyKey(typed) else { return catalog }
        return catalog.filter { $0.name.lowercased().hasPrefix(key) && $0.name.lowercased() != key }
    }
}

/// Every result logged under one WOD name, newest first, with the best and PR marks.
public struct WODBenchmarkHistory: Equatable, Sendable, Identifiable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let result: WODResult
        /// True when this result beat every earlier one of the same scaling.
        public let isPR: Bool
    }

    public var id: String { key }
    public let key: String
    /// The name as last written.
    public let name: String
    public let entries: [Entry]

    public var last: Entry? { entries.first }

    /// The best Rx result, or the best Scaled one when there is no Rx.
    public var best: Entry? {
        let rx = entries.filter { $0.result.scaling == .rx && $0.result.score != nil }
        let pool = rx.isEmpty ? entries.filter { $0.result.score != nil } : rx
        return pool.reduce(Entry?.none) { best, entry in
            guard let best else { return entry }
            return entry.result.beats(best.result) ? entry : best
        }
    }

    /// Every named WOD in `records`, the most recently done first.
    public static func all(_ records: [WorkoutRecord]) -> [WODBenchmarkHistory] {
        let named = records.filter { $0.state == .completed && $0.wod?.historyKey != nil }
        let groups = Dictionary(grouping: named) { $0.wod?.historyKey ?? "" }
        return groups.compactMap { key, rows in make(key: key, records: rows) }
            .sorted { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
    }

    /// The history for `name` in `records`. Nil when nothing was logged under it.
    public static func named(_ name: String, in records: [WorkoutRecord]) -> WODBenchmarkHistory? {
        guard let key = WODResult.historyKey(name) else { return nil }
        return make(key: key, records: records.filter { $0.state == .completed && $0.wod?.historyKey == key })
    }

    private static func make(key: String, records: [WorkoutRecord]) -> WODBenchmarkHistory? {
        let oldestFirst = records.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        guard let newest = oldestFirst.last, let wod = newest.wod else { return nil }
        var entries: [Entry] = []
        for record in oldestFirst {
            guard let result = record.wod else { continue }
            let earlier = entries.filter { $0.result.scaling == result.scaling && $0.result.score != nil }
            let isPR = result.score != nil && !earlier.isEmpty && earlier.allSatisfy { result.beats($0.result) }
            entries.append(Entry(id: record.id, date: record.startedAt ?? record.createdAt, result: result, isPR: isPR))
        }
        return WODBenchmarkHistory(key: key, name: wod.name ?? key, entries: entries.reversed())
    }
}
